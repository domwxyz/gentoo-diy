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
trap 'printf "${red}❌  Error on line %d - exiting\n" "$LINENO" >&2' ERR
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

########################  mirror selector  ############################
# User can override with:  MIRROR=https://some.mirror ./install.sh
GENTOO_MIRROR="${MIRROR:-https://distfiles.gentoo.org}"

########################  required tools  #############################
for bin in curl wget sgdisk lsblk lspci lscpu awk openssl; do need "$bin"; done

exec < /dev/tty

########################  sync clock  #################################
log "Synchronising clock …"
(ntpd -q -g || chronyd -q) &>/dev/null || warn "NTP sync failed (continuing)"

########################  keyboard check  #############################
detect_keyboard_layout() {
  KEYBOARD_LAYOUT="us"
  KEYBOARD_VARIANT=""
  
  if [ -f /etc/conf.d/keymaps ]; then
    KEYMAP=$(grep "^KEYMAP=" /etc/conf.d/keymaps | cut -d'"' -f2 | cut -d'=' -f2 || echo "us")
  elif [ -f /etc/vconsole.conf ]; then
    KEYMAP=$(grep "^KEYMAP=" /etc/vconsole.conf | cut -d'=' -f2 || echo "us")
  else
    KEYMAP="us"
  fi
  
  if [ -f /etc/X11/xorg.conf.d/00-keyboard.conf ]; then
    XKBLAYOUT=$(grep "XkbLayout" /etc/X11/xorg.conf.d/00-keyboard.conf | awk '{print $2}' | tr -d '"' || echo "$KEYMAP")
    XKBVARIANT=$(grep "XkbVariant" /etc/X11/xorg.conf.d/00-keyboard.conf | awk '{print $2}' | tr -d '"' || echo "")
  elif type setxkbmap >/dev/null 2>&1; then
    XKBLAYOUT=$(setxkbmap -query 2>/dev/null | grep layout | awk '{print $2}' || echo "$KEYMAP")
    XKBVARIANT=$(setxkbmap -query 2>/dev/null | grep variant | awk '{print $2}' || echo "")
  else
    XKBLAYOUT="$KEYMAP"
    XKBVARIANT=""
  fi
  
  KEYBOARD_LAYOUT="${XKBLAYOUT:-$KEYMAP}"
  KEYBOARD_VARIANT="${XKBVARIANT:-}"
  
  log "Detected keyboard layout: $KEYBOARD_LAYOUT${KEYBOARD_VARIANT:+ variant: $KEYBOARD_VARIANT}"
}

detect_keyboard_layout

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
  AuthenticAMD) MCPKG="sys-kernel/linux-firmware"   ;;
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
log "Fetching stage3 manifest …"
STAGE=$(curl -fsSL "${GENTOO_MIRROR}/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt" \
        | grep -E '^[0-9]+T[0-9]+Z/stage3-.*\.tar\.xz' | awk '{print $1}') \
        || die "Unable to parse stage3 manifest"

log "Downloading latest stage3: ${STAGE}"
wget -q --show-progress -O /mnt/gentoo/stage3.tar.xz \
     "${GENTOO_MIRROR}/releases/amd64/autobuilds/${STAGE}"

tar xpf /mnt/gentoo/stage3.tar.xz -C /mnt/gentoo \
    --xattrs-include='*.*' --numeric-owner
cp -L /etc/resolv.conf /mnt/gentoo/etc/

########################  bind mounts  ################################
for fs in proc sys dev; do mount --rbind /$fs /mnt/gentoo/$fs; mount --make-rslave /mnt/gentoo/$fs; done

########################  second‑stage (inside chroot)  ###############
cat > /mnt/gentoo/root/inside.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
source /etc/profile

export FEATURES="-collision-protect -protect-owned -collision-detect"

mkdir -p /etc/portage/package.license
echo "sys-kernel/linux-firmware linux-fw-redistributable" > /etc/portage/package.license/firmware
mkdir -p /etc/portage/package.accept_keywords
echo "sys-kernel/linux-firmware ~amd64" > /etc/portage/package.accept_keywords/firmware

# -------- placeholders filled by outer script --------
TZ_PLACEHOLDER="@@TZVAL@@"
LOCALE_PLACEHOLDER="@@LOCALEVAL@@"
KEYBOARD_LAYOUT_PLACEHOLDER="@@KBLAYOUT@@"
KEYBOARD_VARIANT_PLACEHOLDER="@@KBVARIANT@@"
HOST_PLACEHOLDER="@@HOSTVAL@@"
USER_PLACEHOLDER="@@USERVAL@@"
ROOT_HASH=$(cat /root/root_hash.txt)
USER_HASH=$(cat /root/user_hash.txt)
MICROCODE_PLACEHOLDER="@@MCPKG@@"
VIDEO_PLACEHOLDER="@@VIDEOSTR@@"
DISK_PLACEHOLDER="@@DISKVAL@@"
KERNEL_PLACEHOLDER="@@KVAL@@"
DESKTOP_PLACEHOLDER="@@DVAL@@"
GRUBTARGET_PLACEHOLDER="@@GRUBTGT@@"
FSTYPE_PLACEHOLDER="@@FSTYPE@@"
ESP_UUID_PLACEHOLDER="@@ESP_UUID@@"
SWP_UUID_PLACEHOLDER="@@SWP_UUID@@"
MAKEOPTS_PLACEHOLDER="@@MAKEOPTS@@"
# -----------------------------------------------------

echo "▶ Starting Gentoo installation inside chroot environment..."

### REPOSITORY SETUP ###

echo "▶ Setting up Gentoo repositories..."
mkdir -p /var/db/repos/gentoo
emerge-webrsync

echo "▶ Selecting profile..."
if profile_num=$(eselect profile list | grep -i "default/linux/amd64" | grep -v "systemd" | head -1 | grep -o '^\s*\[\s*[0-9]\+\s*\]' | grep -o '[0-9]\+'); then
  echo "Found standard AMD64 OpenRC profile #$profile_num"
  eselect profile set "$profile_num"
else
  if profile_num=$(eselect profile list | grep -i "amd64" | head -1 | grep -o '^\s*\[\s*[0-9]\+\s*\]' | grep -o '[0-9]\+'); then
    echo "Found AMD64 profile #$profile_num"
    eselect profile set "$profile_num"
  else
    echo "No AMD64 profile found automatically. Please check profiles and set manually after install."
    eselect profile list
  fi
fi

### SYSTEM CONFIGURATION ###

echo "▶ Configuring timezone to ${TZ_PLACEHOLDER}..."
echo "${TZ_PLACEHOLDER}" > /etc/timezone
emerge --config sys-libs/timezone-data --quiet

echo "▶ Configuring locale to ${LOCALE_PLACEHOLDER}..."
echo "${LOCALE_PLACEHOLDER} UTF-8" > /etc/locale.gen
locale-gen
eselect locale set ${LOCALE_PLACEHOLDER}
env-update && source /etc/profile

echo "▶ Configuring keyboard layout to ${KEYBOARD_LAYOUT_PLACEHOLDER}..."
echo "KEYMAP=\"${KEYBOARD_LAYOUT_PLACEHOLDER}\"" > /etc/conf.d/keymaps
rc-update add keymaps boot

if [[ "$DESKTOP_PLACEHOLDER" != "headless" ]]; then
  mkdir -p /etc/X11/xorg.conf.d
  cat > /etc/X11/xorg.conf.d/10-keyboard.conf <<EOF
Section "InputClass"
    Identifier "keyboard-all"
    Driver "libinput"
    Option "XkbLayout" "${KEYBOARD_LAYOUT_PLACEHOLDER}"
    MatchIsKeyboard "on"
EOF

  # Add variant if present
  if [ -n "${KEYBOARD_VARIANT_PLACEHOLDER}" ]; then
    echo "    Option \"XkbVariant\" \"${KEYBOARD_VARIANT_PLACEHOLDER}\"" >> /etc/X11/xorg.conf.d/10-keyboard.conf
  fi
  
  echo "EndSection" >> /etc/X11/xorg.conf.d/10-keyboard.conf
fi

echo "▶ Setting hostname to ${HOST_PLACEHOLDER}..."
echo "HOSTNAME=\"${HOST_PLACEHOLDER}\"" > /etc/conf.d/hostname

echo "▶ Configuring make.conf with detected hardware..."
cat >> /etc/portage/make.conf <<EOF
USE="bluetooth pulseaudio"
VIDEO_CARDS="${VIDEO_PLACEHOLDER}"
MAKEOPTS="${MAKEOPTS_PLACEHOLDER}"
EOF

### SYNC AND UPDATE ###

echo "▶ Syncing repositories..."
if ! emerge --sync --quiet; then
    echo "▶ Standard sync failed, trying metadata-only sync..."
    emerge --metadata
    
    if [ $? -ne 0 ]; then
        echo "▶ Trying emaint sync as fallback..."
        emaint sync -r gentoo
    fi
fi

echo "▶ Checking for important Gentoo news items..."
eselect news read all

echo "▶ Updating @world set..."
emerge -uDN @world --quiet

### KERNEL INSTALLATION ###

echo "▶ Installing and configuring kernel..."
case "${KERNEL_PLACEHOLDER}" in
    genkernel)
        echo "▶ Installing genkernel, kernel sources, and required tools..."
        emerge --quiet sys-kernel/gentoo-sources sys-kernel/genkernel sys-apps/pciutils
        eselect kernel set 1
        echo "▶ Running genkernel with menuconfig..."
        genkernel --menuconfig all
        ;;
    manual_auto)
        echo "▶ Installing kernel sources for manual-automatic build..."
        emerge --quiet sys-kernel/gentoo-sources
        eselect kernel set 1
        cd /usr/src/linux
        echo "▶ Building kernel with default configuration..."
        make defconfig
        make -j$(nproc)
        make modules_install install
        ;;
    manual)
        echo "▶ Installing kernel sources for manual build..."
        emerge --quiet sys-kernel/gentoo-sources
        eselect kernel set 1
        echo "⚠ MANUAL KERNEL CONFIGURATION SELECTED"
        echo "⚠ You must compile and install the kernel before rebooting"
        echo "⚠ For reference:"
        echo "⚠   cd /usr/src/linux"
        echo "⚠   make menuconfig"
        echo "⚠   make -j$(nproc)"
        echo "⚠   make modules_install install"
        ;;
esac

### FIRMWARE INSTALLATION ###

echo "▶ Installing firmware packages..."
# Install microcode for CPU
if [[ -n "${MICROCODE_PLACEHOLDER}" ]]; then
    echo "▶ Installing CPU microcode: ${MICROCODE_PLACEHOLDER}"
    emerge --quiet "${MICROCODE_PLACEHOLDER}"
fi

# Always install linux-firmware for general hardware
echo "▶ Installing system firmware..."
emerge --quiet sys-kernel/linux-firmware

### HARDWARE DETECTION ###

# Laptop-specific tools
if [ -d /sys/class/power_supply/BAT* ]; then
    echo "▶ Laptop detected, installing power management..."
    emerge --quiet sys-power/tlp sys-power/powertop
    rc-update add tlp default
    
    # Get system information for brand detection
    SYSTEM_VENDOR=$(dmidecode -s system-manufacturer 2>/dev/null | tr '[:lower:]' '[:upper:]')
    SYSTEM_PRODUCT=$(dmidecode -s system-product-name 2>/dev/null)
    
    # ThinkPad-specific configuration
    if echo "$SYSTEM_VENDOR $SYSTEM_PRODUCT" | grep -q "THINKPAD" || echo "$SYSTEM_PRODUCT" | grep -q "ThinkPad"; then
        echo "▶ ThinkPad detected, installing additional tools..."
        emerge --quiet app-laptop/thinkfan app-laptop/tp_smapi
        
        # Basic thinkfan config if it doesn't exist
        if [ ! -f /etc/thinkfan.conf ]; then
            cat > /etc/thinkfan.conf <<THINKFAN
tp_fan /proc/acpi/ibm/fan
hwmon /sys/class/thermal/thermal_zone0/temp

(0,     0,      55)
(1,     48,     65)
(2,     50,     70)
(3,     52,     75)
(4,     56,     80)
(5,     63,     85)
(7,     68,     95)
THINKFAN
        fi
        
        rc-update add thinkfan default
        
        # Enable tp_smapi
        echo "tp_smapi" > /etc/modules-load.d/tp_smapi.conf
    fi
    
    # Dell Latitude/Precision configuration
    if echo "$SYSTEM_VENDOR" | grep -q "DELL" && echo "$SYSTEM_PRODUCT" | grep -q -E "Latitude|Precision"; then
        echo "▶ Dell Latitude/Precision detected, installing additional tools..."
        emerge --quiet sys-power/thermald
        rc-update add thermald default
        
        # Dell-specific power management
        mkdir -p /etc/tlp.d/
        echo "# Dell-specific power management settings
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=powersave
CPU_ENERGY_PERF_POLICY_ON_AC=performance
CPU_ENERGY_PERF_POLICY_ON_BAT=power
" > /etc/tlp.d/00-dell.conf
    fi
    
    # HP EliteBook/ProBook configuration
    if echo "$SYSTEM_VENDOR" | grep -q "HP" && echo "$SYSTEM_PRODUCT" | grep -q -E "EliteBook|ProBook"; then
        echo "▶ HP EliteBook/ProBook detected, installing additional tools..."
        emerge --quiet sys-power/thermald
        rc-update add thermald default
        
        # HP-specific power management
        mkdir -p /etc/tlp.d/
        echo "# HP-specific power management settings
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=powersave
PCIE_ASPM_ON_BAT=powersupersave
" > /etc/tlp.d/00-hp.conf
    fi
    
    # Lenovo (non-ThinkPad) configuration
    if echo "$SYSTEM_VENDOR" | grep -q "LENOVO" && ! echo "$SYSTEM_PRODUCT" | grep -q "ThinkPad"; then
        echo "▶ Lenovo laptop detected, installing additional tools..."
        emerge --quiet sys-power/thermald
        rc-update add thermald default
    fi
    
    echo "▶ Power management tools installed"
fi

# Check for virtualization environments
echo "▶ Checking for virtualization environment..."
if dmesg | grep -qi "virtualbox"; then
    echo "▶ VirtualBox detected, installing guest additions..."
    emerge --quiet app-emulation/virtualbox-guest-additions
    rc-update add virtualbox-guest-additions default
    
    # Add user to the vboxguest group
    usermod -aG vboxguest "${USER_PLACEHOLDER}"
elif dmesg | grep -qi "qemu\|kvm"; then
    echo "▶ QEMU/KVM virtual machine detected, installing guest tools..."
    emerge --quiet app-emulation/qemu-guest-agent
    rc-update add qemu-guest-agent default
fi

# Wi-Fi setup
if lspci | grep -q -i 'network\|wireless'; then
    echo "▶ Wi-Fi hardware detected, installing drivers..."
    emerge --quiet net-wireless/iw net-wireless/wpa_supplicant
    
    # Intel Wi-Fi
    if lspci | grep -i -E 'intel.*wifi|wireless.*intel' >/dev/null; then
        echo "▶ Intel Wi-Fi detected..."
        emerge --quiet sys-firmware/iwlwifi-firmware
    fi
    
    # Broadcom Wi-Fi
    if lspci | grep -i -E 'broadcom' >/dev/null; then
        echo "▶ Broadcom Wi-Fi detected..."
        emerge --quiet net-wireless/broadcom-sta
        echo "wl" >> /etc/modules-load.d/broadcom.conf
    fi
    
    # Realtek Wi-Fi - handled by linux-firmware
    if lspci | grep -i -E 'realtek.*wireless|rtl8' >/dev/null; then
        echo "▶ Realtek Wi-Fi detected..."
    fi
    
    # Atheros Wi-Fi - handled by linux-firmware
    if lspci | grep -i -E 'atheros|qualcomm.*wireless' >/dev/null; then
        echo "▶ Atheros/Qualcomm Wi-Fi detected..."
    fi
fi

### DESKTOP ENVIRONMENT ###

echo "▶ Configuring system environment: ${DESKTOP_PLACEHOLDER}"
case "${DESKTOP_PLACEHOLDER}" in
    xfce)
        echo "▶ Installing XFCE desktop environment..."
        # Install X.org server and basic drivers
        emerge --quiet x11-base/xorg-server x11-base/xorg-drivers x11-apps/xinit
        
        # Install XFCE and display manager
        emerge --quiet xfce-base/xfce4-meta x11-misc/lightdm x11-misc/lightdm-gtk-greeter
        
        # Install audio and common applications
        emerge --quiet media-sound/pipewire media-video/wireplumber www-client/firefox
        
        # Configure keyboard in X11
        mkdir -p /etc/X11/xorg.conf.d
        cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<KEYBOARD
Section "InputClass"
    Identifier "keyboard-all"
    Driver "libinput"
    Option "XkbLayout" "${KEYBOARD_LAYOUT_PLACEHOLDER}"
KEYBOARD

        # Add variant if specified
        if [ -n "${KEYBOARD_VARIANT_PLACEHOLDER}" ]; then
            echo "    Option \"XkbVariant\" \"${KEYBOARD_VARIANT_PLACEHOLDER}\"" >> /etc/X11/xorg.conf.d/00-keyboard.conf
        fi
        
        echo "    MatchIsKeyboard \"on\"" >> /etc/X11/xorg.conf.d/00-keyboard.conf
        echo "EndSection" >> /etc/X11/xorg.conf.d/00-keyboard.conf
        
        # Enable touchpad if present
        if [ -d /sys/class/input/mouse* ] || [ -d /sys/class/input/event* ]; then
            cat > /etc/X11/xorg.conf.d/30-touchpad.conf <<TOUCHPAD
Section "InputClass"
    Identifier "touchpad"
    Driver "libinput"
    MatchIsTouchpad "on"
    Option "Tapping" "on"
    Option "NaturalScrolling" "true"
    Option "DisableWhileTyping" "true"
EndSection
TOUCHPAD
        fi
        
        # Enable display manager
        rc-update add lightdm default
        ;;
        
    lxqt)
        echo "▶ Installing LXQt desktop environment..."
        # Install X.org server and basic drivers
        emerge --quiet x11-base/xorg-server x11-base/xorg-drivers x11-apps/xinit
        
        # Install LXQt and display manager
        emerge --quiet lxqt-base/lxqt-meta lxde-base/lxdm
        
        # Install audio and common applications
        emerge --quiet media-sound/pipewire media-video/wireplumber www-client/firefox
        
        # Configure keyboard in X11
        mkdir -p /etc/X11/xorg.conf.d
        cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<KEYBOARD
Section "InputClass"
    Identifier "keyboard-all"
    Driver "libinput"
    Option "XkbLayout" "${KEYBOARD_LAYOUT_PLACEHOLDER}"
KEYBOARD

        # Add variant if specified
        if [ -n "${KEYBOARD_VARIANT_PLACEHOLDER}" ]; then
            echo "    Option \"XkbVariant\" \"${KEYBOARD_VARIANT_PLACEHOLDER}\"" >> /etc/X11/xorg.conf.d/00-keyboard.conf
        fi
        
        echo "    MatchIsKeyboard \"on\"" >> /etc/X11/xorg.conf.d/00-keyboard.conf
        echo "EndSection" >> /etc/X11/xorg.conf.d/00-keyboard.conf
        
        # Enable touchpad if present
        if [ -d /sys/class/input/mouse* ] || [ -d /sys/class/input/event* ]; then
            cat > /etc/X11/xorg.conf.d/30-touchpad.conf <<TOUCHPAD
Section "InputClass"
    Identifier "touchpad"
    Driver "libinput"
    MatchIsTouchpad "on"
    Option "Tapping" "on"
    Option "NaturalScrolling" "true"
    Option "DisableWhileTyping" "true"
EndSection
TOUCHPAD
        fi
        
        # Enable display manager
        rc-update add lxdm default
        ;;
        
    headless|*)
        echo "▶ Setting up headless server configuration..."
        emerge --quiet net-misc/openssh app-admin/sudo
        rc-update add sshd default
        ;;
esac

### NETWORK CONFIGURATION ###

echo "▶ Setting up network management..."
emerge --quiet net-misc/networkmanager net-misc/dhcpcd

rc-update add NetworkManager default

# Create a default NetworkManager connection config directory with proper permissions
mkdir -p /etc/NetworkManager/system-connections
chmod 700 /etc/NetworkManager/system-connections

# Configure NetworkManager to use dhcpcd
mkdir -p /etc/NetworkManager/conf.d/
echo "[main]
dhcp=dhcpcd" > /etc/NetworkManager/conf.d/dhclient.conf

# For Wi-Fi management
emerge --quiet net-wireless/iwd
if lspci | grep -q -i 'network\|wireless'; then
    echo "▶ Ensuring NetworkManager can manage Wi-Fi connections..."
    mkdir -p /etc/NetworkManager/conf.d/
    echo "[device]
wifi.backend=iwd" > /etc/NetworkManager/conf.d/wifi_backend.conf
fi

### USER ACCOUNTS ###

echo "▶ Setting up user accounts..."
# Set root password
echo "root:${ROOT_HASH}" | chpasswd -e

# Create regular user
useradd -m -G users,wheel,audio,video,usb,cdrom,portage "${USER_PLACEHOLDER}"
echo "${USER_PLACEHOLDER}:${USER_HASH}" | chpasswd -e

# Configure sudo access
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

### FILESYSTEM CONFIGURATION ###

echo "▶ Configuring filesystem..."
# Set up fstab
cat > /etc/fstab <<FSTAB
# <fs>                                  <mountpoint>    <type>    <opts>                  <dump/pass>
LABEL=gentoo                            /               ${FSTYPE_PLACEHOLDER}    noatime         0 1
PARTUUID=${ESP_UUID_PLACEHOLDER}        /boot           vfat      defaults                0 2
UUID=${SWP_UUID_PLACEHOLDER}            none            swap      sw                      0 0
FSTAB

### BOOTLOADER INSTALLATION ###

echo "▶ Installing and configuring bootloader..."
emerge --quiet sys-boot/grub:2

# Install GRUB bootloader
if [[ "${GRUBTARGET_PLACEHOLDER}" == "x86_64-efi" ]]; then
    emerge --quiet sys-boot/efibootmgr
    echo "▶ Installing GRUB for UEFI system..."
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo
else
    echo "▶ Installing GRUB for BIOS system..."
    grub-install --target=i386-pc "${DISK_PLACEHOLDER}"
fi

# Generate GRUB configuration
echo "▶ Generating GRUB configuration..."
echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
echo 'GRUB_TIMEOUT=5' >> /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

### FINAL CLEANUP ###

echo "▶ Performing final cleanup..."
emerge --depclean --quiet

### POST-INSTALLATION NOTES ###

echo "▶ Important notes for after first boot:"
echo "  • Network is configured using NetworkManager"
echo "  • Use 'nmtui' for a text-based network configuration interface"
echo "  • Use 'nmcli con show' to list available connections"
echo "  • Use 'nmcli dev wifi list' to scan for wireless networks"
echo "  • Use 'nmcli dev wifi connect SSID password PASSWORD' to connect to a wireless network"
echo "  • For more advanced configuration, edit files in /etc/NetworkManager/system-connections/"

echo "🎉 Installation completed successfully!"
echo "🔄 You can now reboot into your new Gentoo system."
EOS
chmod +x /mnt/gentoo/root/inside.sh

########################  substitute vars  ############################
fh=/mnt/gentoo/root/inside.sh
sed -i "s|@@TZVAL@@|$TZ|" "$fh"
sed -i "s|@@LOCALEVAL@@|$LOCALE|" "$fh"
sed -i "s|@@KBLAYOUT@@|$KEYBOARD_LAYOUT|" "$fh"
sed -i "s|@@KBVARIANT@@|$KEYBOARD_VARIANT|" "$fh"
sed -i "s|@@HOSTVAL@@|$HOSTNAME|" "$fh"
sed -i "s|@@USERVAL@@|$USERNAME|" "$fh"
sed -i "s|@@VIDEOSTR@@|$VC|" "$fh"
sed -i "s|@@ESP_UUID@@|$ESP_UUID|" "$fh"
sed -i "s|@@SWP_UUID@@|$SWP_UUID|" "$fh"
sed -i "s|@@MCPKG@@|$MCPKG|" "$fh"
sed -i "s|@@DISKVAL@@|$DISK|" "$fh"
case $KMETHOD in
  1) kval="genkernel" ;; 2) kval="manual" ;; 3) kval="manual_auto" ;;
esac
sed -i "s|@@KVAL@@|$kval|" "$fh"
case $DESKTOP in
  1) dval="xfce" ;;
  2) dval="lxqt" ;;
  3) dval="headless" ;;
  *) dval="headless" ;; # Default fallback
esac
sed -i "s|@@DVAL@@|$dval|" "$fh"
[[ $UEFI == yes ]] && grubtgt="x86_64-efi" || grubtgt="i386-pc"
sed -i "s|@@GRUBTGT@@|$grubtgt|" "$fh"
sed -i "s|@@FSTYPE@@|$FSTYPE|" "$fh"
MAKEOPTS="-j$(nproc)"
sed -i "s|@@MAKEOPTS@@|$MAKEOPTS|" "$fh"

openssl passwd -6 "$ROOT_PASS" > /mnt/gentoo/root/root_hash.txt
openssl passwd -6 "$USER_PASS" > /mnt/gentoo/root/user_hash.txt
unset ROOT_PASS USER_PASS

########################  chroot  #####################################
log "Entering chroot …"
chroot /mnt/gentoo /bin/bash -x /root/inside.sh

########################  cleanup  ####################################
log "Cleaning up …"
umount -l /mnt/gentoo/{dev,proc,sys} || true
umount -R /mnt/gentoo
swapoff "$SWP"

[[ $KMETHOD == 2 ]] && warn "You chose MANUAL-interactive kernel. Compile it before reboot!"
log "Installation finished - remove the USB stick and reboot."
