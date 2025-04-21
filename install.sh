#!/usr/bin/env bash
# =====================================================================
#  Gentoo “one‑curl” installer
#  Built for business class Intel/AMD64 laptops.
#  • Desktop: XFCE/LightDM  or  LXQt/LXDM
#  • Kernel : genkernel  |  manual‑interactive  |  unattended‑manual
#  • UEFI *or* legacy BIOS automatically detected
#  • Auto‑detect: disks, CPU vendor (microcode), GPU (VIDEO_CARDS)
#  • NVMe suffix handling, Wi‑Fi fallback, dynamic swap size
#  • Ext4 (default) or Btrfs root filesystem
# =====================================================================
set -euo pipefail
IFS=$'\n\t'

########################  cosmetics  ##################################
if [[ -t 1 ]]; then
  nc='\e[0m'; red='\e[31m'; grn='\e[32m'; ylw='\e[33m'
else
  nc=''; red=''; grn=''; ylw='';
fi
log()  { printf "${grn}▶ %s${nc}\n"  "$*"; }
warn() { printf "${ylw}⚠ %s${nc}\n"  "$*"; }
die()  { printf "${red}❌ %s${nc}\n" "$*"; exit 1; }

########################  helpers  ####################################
need() { command -v "$1" &>/dev/null || die "Missing tool: $1"; }
ask() {                         # ask VAR "Prompt" "default"
  local var="$1" msg="$2" def="${3-}" val
  read -rp "${msg}${def:+ [${def}]}: " val
  printf -v "$var" '%s' "${val:-$def}"
}

########################  required tools  #############################
for bin in curl wget sgdisk lsblk lspci lscpu awk openssl; do need "$bin"; done

########################  sync clock  #################################
log "Synchronising clock …"
(ntpd -q -g || chronyd -q) &>/dev/null || warn "NTP sync failed (continuing)"

########################  net check  ##################################
if ! ping -c1 -W2 1.1.1.1 &>/dev/null; then
  warn "No network connectivity detected."

  wifi_with_iwd() {
    local wlan_if ssid psk
    # Pick first wireless interface shown by iwd
    wlan_if=$(iwctl device list | awk '/^[[:space:]]*Device/ {print $2; exit}')
    [[ -n $wlan_if ]] || die "No wireless device found (iwd)."

    read -rp "SSID: " ssid
    read -rsp "Passphrase (empty for open network): " psk;  echo
    [[ -n $ssid ]] || die "SSID cannot be empty."

    if [[ -n $psk ]]; then
      iwctl --passphrase "$psk" station "$wlan_if" connect "$ssid"
    else
      iwctl station "$wlan_if" connect "$ssid"
    fi
  }

  wifi_with_wpa() {
    local wlan_if ssid psk
    wlan_if=$(awk '$3=="0000" && $2=="IEEE80211"{print $1;exit}' /proc/net/dev)
    [[ -n $wlan_if ]] || die "No wireless device found (wpa_cli)."

    read -rp "SSID: " ssid
    read -rsp "Passphrase (empty for open network): " psk;  echo
    [[ -n $ssid ]] || die "SSID cannot be empty."

    wpa_passphrase "$ssid" "$psk" >/etc/wpa_supplicant.conf
    wpa_supplicant -B -i "$wlan_if" -c /etc/wpa_supplicant.conf
    dhcpcd "$wlan_if"
  }

  if command -v iwctl &>/dev/null; then
    log "Launching interactive Wi-Fi setup via iwd…"
    wifi_with_iwd
  elif command -v wpa_cli &>/dev/null; then
    log "iwd not present → falling back to wpa_cli"
    wifi_with_wpa
  else
    die "Neither iwctl nor wpa_cli present - aborting."
  fi

  ping -c1 -W4 1.1.1.1 || die "Still offline after Wi-Fi attempt."
fi
log "Network OK."

########################  detect disks  ###############################
log "Detecting installable disks …"
mapfile -t DISKS < <(lsblk -dpn -o NAME,SIZE -P | grep -E 'NAME="/dev/(sd|nvme|vd)')
[[ ${#DISKS[@]} -gt 0 ]] || die "No suitable block devices found."

echo "Select target disk:"
select d in "${DISKS[@]}"; do
  [[ -n $d ]] && DISK="${d%% *}" && break
done
log "Selected disk: $DISK"

[[ $DISK =~ nvme ]] && P='p' || P=''   # NVMe partition suffix

########################  gather generic answers  #####################
ask HOSTNAME "Hostname"                 "gentoobox"
ask TZ       "Timezone (e.g. America/Chicago)" ""
ask LOCALE   "Primary locale"           "en_US.UTF-8"
ask USERNAME "Regular user name"        "user"

########################  swap size (GiB)  ############################
RAM_GB=$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo)
def_swap=$(( RAM_GB < 8 ? 2 : 4 ))
ask SWAPSIZE "Swap size in GiB" "$def_swap"

########################  detect CPU / microcode  #####################
CPU_VENDOR=$(lscpu | awk -F': *' '/Vendor ID/{print $2}')
case "$CPU_VENDOR" in
  GenuineIntel) MCPKG="sys-firmware/intel-microcode" ;;
  AuthenticAMD) MCPKG="sys-firmware/amd-microcode"   ;;
  *)            MCPKG="" ;;
esac
ask MCPKG "Detected $CPU_VENDOR CPU. Microcode pkg" "$MCPKG"

########################  detect GPU / VIDEO_CARDS ####################
GPU_LINE=$(lspci -nnk | grep -Ei 'VGA|3D')
case "$GPU_LINE" in
  *Intel*)  VC="intel i965 iris" ;;
  *AMD*|*ATI*) VC="amdgpu radeonsi" ;;
  *NVIDIA*) VC="nouveau" ;;
  *) VC="" ;;
esac
ask VC "Detected GPU ($GPU_LINE). VIDEO_CARDS string" "$VC"

########################  kernel / desktop choices  ###################
ask KMETHOD "Kernel: [1] genkernel(menuconfig)  [2] manual-interactive  [3] manual-AUTO" "1"
ask DESKTOP "Desktop:      [1] XFCE + LightDM       [2] LXQt + LXDM" "1"

########################  filesystem choice  ##########################
ask FS "Root filesystem: [1] ext4  [2] btrfs" "1"
[[ $FS == 1 ]] && FSTYPE="ext4" || FSTYPE="btrfs"

########################  firmware type  ################################
if [[ -d /sys/firmware/efi ]]; then
  UEFI="yes"
  log "UEFI firmware detected."
else
  UEFI="no"
  log "Legacy BIOS detected."
fi

########################  partition  ##################################
log "Partitioning $DISK …"
if [[ $UEFI == yes ]]; then
  sgdisk --zap-all "$DISK"
  sgdisk -n1:0:+512M -t1:ef00 -c1:"EFI System" "$DISK"
  sgdisk -n2:0:+${SWAPSIZE}G -t2:8200 -c2:"swap" "$DISK"
  sgdisk -n3:0:0        -t3:8300 -c3:"rootfs" "$DISK"
else
  parted -s "$DISK" mklabel msdos
  parted -s "$DISK" mkpart primary linux-swap 1MiB "${SWAPSIZE}GiB"
  parted -s "$DISK" mkpart primary ext4 "${SWAPSIZE}GiB" 100%
fi
partprobe "$DISK"

ESP="${DISK}${P}1"
SWP="${DISK}${P}2"
ROOT="${DISK}${P}3"

[[ $UEFI == yes ]] && mkfs.fat -F32 "$ESP"

mkswap       "$SWP"
if [[ $FSTYPE == ext4 ]]; then
  mkfs.ext4 -L gentoo "$ROOT"
else
  mkfs.btrfs -L gentoo "$ROOT"
fi

ESP_UUID="$(blkid -s PARTUUID -o value "$ESP" 2>/dev/null || true)"
SWP_UUID="$(blkid -s UUID      -o value "$SWP")"

mount "$ROOT" /mnt/gentoo
[[ $FSTYPE == btrfs ]] && btrfs subvolume create /mnt/gentoo/@ && umount /mnt/gentoo && mount -o subvol=@ "$ROOT" /mnt/gentoo

mkdir -p /mnt/gentoo/boot
[[ $UEFI == yes ]] && mount "$ESP"  /mnt/gentoo/boot
swapon "$SWP"

cleanup() {
  umount -lR /mnt/gentoo 2>/dev/null || true
  [ -n "${SWP:-}" ] && swapoff "$SWP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

########################  stage3  #####################################
log "Downloading latest stage3 …"
STAGE=$(curl -s https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt | awk 'NF{print $1}')
wget -q --show-progress "https://distfiles.gentoo.org/releases/amd64/autobuilds/$STAGE"
tar xpf stage3-*.tar.xz -C /mnt/gentoo --xattrs-include='*.*' --numeric-owner
cp -L /etc/resolv.conf /mnt/gentoo/etc/

########################  bind mounts  ################################
for fs in proc sys dev; do mount --rbind /$fs /mnt/gentoo/$fs; mount --make-rslave /mnt/gentoo/$fs; done

########################  second‑stage (inside chroot)  ###############
cat > /mnt/gentoo/root/inside.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
source /etc/profile

# -------- placeholders filled by outer script --------
TZ_PLACEHOLDER="TZVAL"
LOCALE_PLACEHOLDER="LOCALEVAL"
HOST_PLACEHOLDER="HOSTVAL"
USER_PLACEHOLDER="USERVAL"
ROOTPW_PLACEHOLDER="ROOTPW"
USERPW_PLACEHOLDER="USERPW"
MICROCODE_PLACEHOLDER="MCPKG"
VIDEO_PLACEHOLDER="VIDEOSTR"
KERNEL_PLACEHOLDER="KVAL"
DESKTOP_PLACEHOLDER="DVAL"
GRUBTARGET_PLACEHOLDER="GRUBTGT"
FSTYPE_PLACEHOLDER="FSTYPE"
ESP_UUID_PLACEHOLDER="ESP_UUID"
SWP_UUID_PLACEHOLDER="SWP_UUID"
MAKEOPTS_PLACEHOLDER="MAKEOPTS"
# -----------------------------------------------------

### base config ###

echo "${TZ_PLACEHOLDER}" > /etc/timezone
emerge --config sys-libs/timezone-data --quiet

echo "${LOCALE_PLACEHOLDER} UTF-8" > /etc/locale.gen
locale-gen
eselect locale set ${LOCALE_PLACEHOLDER}.utf8
env-update && source /etc/profile

echo "HOSTNAME=\"${HOST_PLACEHOLDER}\"" > /etc/conf.d/hostname

# make.conf tweaks
cat >> /etc/portage/make.conf <<EOF
USE="bluetooth pulseaudio"
VIDEO_CARDS="${VIDEO_PLACEHOLDER}"
MAKEOPTS="${MAKEOPTS_PLACEHOLDER}"
EOF

### sync & update ###
emerge --sync --quiet
emerge -uDN @world --quiet

### kernel ###
case "${KERNEL_PLACEHOLDER}" in
  genkernel)
      emerge --quiet sys-kernel/gentoo-sources sys-kernel/genkernel
      genkernel --menuconfig all ;;
  manual_auto)
      emerge --quiet sys-kernel/gentoo-sources
      cd /usr/src/linux
      echo "▶ Unattended kernel build (defconfig)…"
      make defconfig
      make -j\$(nproc)
      make modules_install install ;;
  manual)
      emerge --quiet sys-kernel/gentoo-sources
      echo "‼  MANUAL KERNEL SELECTED ‼"
      echo "   Compile & install your kernel before rebooting." ;;
esac

### firmware ###
[[ -n "${MICROCODE_PLACEHOLDER}" ]] && emerge --quiet "${MICROCODE_PLACEHOLDER}"
[[ -n "$(grep -E 'AMD|Intel' /proc/cpuinfo | head -1)" ]] && emerge --quiet sys-kernel/linux-firmware

### desktop ###
case "${DESKTOP_PLACEHOLDER}" in
  xfce)
    emerge --quiet xorg-server xfce-base/xfce4 xfce4-meta \
      lightdm lightdm-gtk-greeter \ 
      pipewire wireplumber firefox
    rc-update add lightdm default ;;
  lxqt)
    emerge --quiet xorg-server lxqt-meta lxqt-session \
      lxdm pipewire wireplumber firefox
    rc-update add lxdm default ;;
esac

### network ###
emerge --quiet networkmanager dhcpcd
rc-update add NetworkManager default

### users ###
echo "root:${ROOTPW_PLACEHOLDER}" | chpasswd -e
useradd -m -G wheel,audio,video ${USER_PLACEHOLDER}
echo "${USER_PLACEHOLDER}:${USERPW_PLACEHOLDER}" | chpasswd -e
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

### fstab ###
cat > /etc/fstab <<FSTAB
LABEL=gentoo      /      ${FSTYPE_PLACEHOLDER}  noatime     0 1
PARTUUID=${ESP_UUID_PLACEHOLDER} /boot  vfat   defaults    0 2
UUID=${SWP_UUID_PLACEHOLDER}     none   swap   sw          0 0
FSTAB

### bootloader ###
emerge --quiet grub efibootmgr
if [[ "${GRUBTARGET_PLACEHOLDER}" == x86_64-efi ]]; then
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo
else
  grub-install --target=i386-pc ${DISK}
fi
grub-mkconfig  -o /boot/grub/grub.cfg

emerge --depclean --quiet

echo "🎉  Done inside chroot."
EOS
chmod +x /mnt/gentoo/root/inside.sh

########################  substitute vars  ############################
fh=/mnt/gentoo/root/inside.sh
sed -i "s|TZVAL|$TZ|"                       "$fh"
sed -i "s|LOCALEVAL|$LOCALE|"               "$fh"
sed -i "s|HOSTVAL|$HOSTNAME|"               "$fh"
sed -i "s|USERVAL|$USERNAME|"               "$fh"
sed -i "s|VIDEOSTR|$VC|"                    "$fh"
sed -i "s|ESP_UUID|$ESP_UUID|"              "$fh"
sed -i "s|SWP_UUID|$SWP_UUID|"              "$fh"
sed -i "s|MCPKG|$MCPKG|"                    "$fh"
case $KMETHOD in
  1) kval="genkernel" ;; 2) kval="manual" ;; 3) kval="manual_auto" ;;
esac
sed -i "s|KVAL|$kval|"                      "$fh"
[[ $DESKTOP == 1 ]] && dval="xfce" || dval="lxqt"
sed -i "s|DVAL|$dval|"                      "$fh"
[[ $UEFI == yes ]] && grubtgt="x86_64-efi" || grubtgt="i386-pc"
sed -i "s|GRUBTGT|$grubtgt|"                "$fh"
sed -i "s|FSTYPE|$FSTYPE|"                  "$fh"
sed -i "s|ROOTPW|$(openssl passwd -6 "$ROOT_PASS")|" "$fh"
sed -i "s|USERPW|$(openssl passwd -6 "$USER_PASS")|" "$fh"
MAKEOPTS="-j$(nproc)"
sed -i "s|MAKEOPTS|$MAKEOPTS|"              "$fh"
unset ROOT_PASS USER_PASS

########################  chroot  #####################################
log "Entering chroot …"
chroot /mnt/gentoo /root/inside.sh

########################  cleanup  ####################################
log "Cleaning up …"
umount -l /mnt/gentoo/{dev,proc,sys} || true
umount -R /mnt/gentoo
swapoff "$SWP"

[[ $KMETHOD == 2 ]] && warn "You chose MANUAL-interactive kernel. Compile it before reboot!"
log "Installation finished - remove the USB stick and reboot."
