#!/usr/bin/env bash
# =====================================================================
#  Gentoo “one‑curl” installer
#  Built for business class Intel/AMD64 laptops.
#  • Desktop: XFCE/LightDM  |  LXQt/LXDM |  Headless
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
ask_pw() {
  local var="$1" msg="$2" val confirm
  while true; do
    read -rsp "${msg}: " val
    echo
    read -rsp "Confirm ${msg}: " confirm
    echo
    if [[ "$val" == "$confirm" ]]; then
      printf -v "$var" '%s' "$val"
      break
    else
      echo "Passwords don't match. Please try again."
    fi
  done
}

########################  required tools  #############################
for bin in curl wget sgdisk lsblk lspci lscpu awk openssl; do need "$bin"; done

exec < /dev/tty

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

echo "Available disks:"
for i in "${!DISKS[@]}"; do
  echo "$((i+1)). ${DISKS[$i]}"
done

while true; do
  read -rp "Enter disk number: " choice
  if [[ $choice =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#DISKS[@]} ]]; then
    disk_line="${DISKS[$((choice-1))]}"
    DISK=$(echo "$disk_line" | grep -o 'NAME="[^"]*"' | cut -d'"' -f2)
    echo "Selected disk: $DISK"
    break
  else
    echo "Invalid selection. Please enter a number between 1 and ${#DISKS[@]}."
  fi
done

[[ $DISK =~ nvme ]] && P='p' || P=''   # NVMe partition suffix

########################  locale/timezone selection  ###########################
select_locale() {
  local locales=(
    "en_US.UTF-8"    "English (US)"
    "en_GB.UTF-8"    "English (UK)"
    "de_DE.UTF-8"    "German"
    "fr_FR.UTF-8"    "French"
    "es_ES.UTF-8"    "Spanish"
    "it_IT.UTF-8"    "Italian"
    "pt_BR.UTF-8"    "Portuguese (Brazil)"
    "ru_RU.UTF-8"    "Russian"
    "ja_JP.UTF-8"    "Japanese"
    "zh_CN.UTF-8"    "Chinese (Simplified)"
    "pl_PL.UTF-8"    "Polish"
    "nl_NL.UTF-8"    "Dutch"
    "sv_SE.UTF-8"    "Swedish"
    "ko_KR.UTF-8"    "Korean"
    "fi_FI.UTF-8"    "Finnish"
    "no_NO.UTF-8"    "Norwegian"
    "da_DK.UTF-8"    "Danish"
    "cs_CZ.UTF-8"    "Czech"
    "hu_HU.UTF-8"    "Hungarian"
    "tr_TR.UTF-8"    "Turkish"
  )

  echo "Select your preferred locale:"
  PS3="Locale #: "
  
  # Create a temporary array with just the descriptions
  local descriptions=()
  for ((i=1; i<${#locales[@]}; i+=2)); do
    descriptions+=("${locales[i]}")
  done
  
  select choice in "${descriptions[@]}" "Other (manual entry)"; do
    if [[ $REPLY -gt 0 && $REPLY -le ${#descriptions[@]} ]]; then
      # Convert reply to array index (accounting for 0-based indexing and pairs)
      local idx=$(( (REPLY-1) * 2 ))
      LOCALE="${locales[idx]}"
      log "Selected locale: $LOCALE"
      break
    elif [[ "$choice" == "Other (manual entry)" ]]; then
      ask LOCALE "Enter your locale (e.g. en_US.UTF-8)" "en_US.UTF-8"
      break
    else
      echo "Invalid selection. Please try again."
    fi
  done
}

select_timezone() {
  echo "Enter your timezone (e.g. America/New_York, Europe/London):"
  read -rp "Timezone: " TZ
  
  if [[ -z "$TZ" ]]; then
    # Default to UTC if nothing entered
    TZ="UTC"
  fi
  
  log "Selected timezone: $TZ"
}

########################  gather generic answers  #####################
ask HOSTNAME "Hostname"                 "gentoobox"
ask_pw ROOT_PASS "Root password"
select_timezone
select_locale
ask USERNAME "Regular user name"        "user"
ask_pw USER_PASS "Password for $USERNAME"

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
ask DESKTOP "Desktop:      [1] XFCE + LightDM       [2] LXQt + LXDM       [3] Headless (no Desktop)" "3"

GPU_LINE=$(lspci -nnk | grep -Ei 'VGA|3D')
case "$GPU_LINE" in
  *Intel*)  VC="intel i965 iris" ;;
  *AMD*|*ATI*) VC="amdgpu radeonsi" ;;
  *NVIDIA*) VC="nouveau" ;;
  *) VC="" ;;
esac

if [[ $DESKTOP == 3 ]]; then
  VC=""
  log "Headless server selected - VIDEO_CARDS set to empty"
fi

ask VC "Detected GPU ($GPU_LINE). VIDEO_CARDS string" "$VC"

########################  kernel choices  ###################
ask KMETHOD "Kernel: [1] genkernel(menuconfig)  [2] manual-interactive  [3] manual-AUTO" "1"

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

log "Ensuring partitions are recognized..."
partprobe "$DISK"
sleep 3

# Double-check the partitions exist
if [[ $UEFI == yes ]]; then
  if [[ ! -e "${DISK}${P}3" ]]; then
    log "Waiting for partitions to become available..."
    for i in {1..10}; do
      sleep 1
      [[ -e "${DISK}${P}3" ]] && break
      [[ $i -eq 10 ]] && die "Partition ${DISK}${P}3 not found after 10 seconds. Aborting."
    done
  fi
else
  if [[ ! -e "${DISK}${P}2" ]]; then
    log "Waiting for partitions to become available..."
    for i in {1..10}; do
      sleep 1
      [[ -e "${DISK}${P}2" ]] && break
      [[ $i -eq 10 ]] && die "Partition ${DISK}${P}2 not found after 10 seconds. Aborting."
    done
  fi
fi

ESP="${DISK}${P}1"
SWP="${DISK}${P}2"
ROOT="${DISK}${P}3"

# For MBR partitioning where partitions start at 1 instead of 0
if [[ $UEFI != yes ]]; then
  SWP="${DISK}${P}1"
  ROOT="${DISK}${P}2"
fi

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
DISK_PLACEHOLDER="DISKVAL"
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
  headless)
    echo "▶ Headless server selected - skipping desktop environment"
    emerge --quiet net-misc/openssh
    rc-update add sshd default ;;
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
  grub-install --target=i386-pc ${DISK_PLACEHOLDER}
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
sed -i "s|DISKVAL|$DISK|" "$fh"
case $KMETHOD in
  1) kval="genkernel" ;; 2) kval="manual" ;; 3) kval="manual_auto" ;;
esac
sed -i "s|KVAL|$kval|"                      "$fh"
case $DESKTOP in
  1) dval="xfce" ;;
  2) dval="lxqt" ;;
  3) dval="headless" ;;
  *) dval="headless" ;; # Default fallback
esac
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
