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

welcome_banner() {
  local width=60  # Width of the content area (excluding asterisks)
  local title="G E N T O O   D O T   D I Y"
  local subtitle="One-Curl Gentoo Installer Wizard"
  local loading_msg="Auto-detecting hardware for optimal install..."
  
  local border_line=$(printf '%*s' "$((width + 4))" '' | tr ' ' '*')
  
  print_centered_line() {
    local text="$1"
    local color="${2:-$nc}"
    local text_length=${#text}
    local padding=$(( (width - text_length) / 2 ))
    local left_pad=$(printf '%*s' "$padding" '')
    local right_pad=$(printf '%*s' "$((width - text_length - padding))" '')
    
    printf "**%s${color}%s${nc}%s**\n" "$left_pad" "$text" "$right_pad"
  }
  
  # Print the banner with pauses
  clear
  echo
  sleep 0.3
  echo "$border_line"
  sleep 0.1
  print_centered_line ""
  sleep 0.1
  print_centered_line "$title" "${grn}"
  sleep 0.1
  print_centered_line "$subtitle" "${grn}"
  sleep 0.1
  print_centered_line ""
  sleep 0.1
  echo "$border_line"
  sleep 0.5
  echo
  printf "   %s\n" "$loading_msg"
  sleep 0.8
  echo
}

########################  helpers  ####################################
need() { command -v "$1" &>/dev/null || die "Missing tool: $1"; }
ask() { # ask VAR "Prompt" "default"
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

########################  welcome  ####################################

welcome_banner
log "Starting Gentoo dot DIY installer..."

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
echo # Blank line for spacing

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
select_locale
echo # Blank line for spacing
select_timezone
echo # Blank line for spacing
ask HOSTNAME "Hostname"                 "gentoobox"
ask_pw ROOT_PASS "Root password"
echo # Blank line for spacing
ask USERNAME "Regular user name"        "user"
ask_pw USER_PASS "Password for $USERNAME"
echo # Blank line for spacing

########################  detect CPU / microcode  #####################
CPU_VENDOR=$(lscpu | awk -F': *' '/Vendor ID/{print $2}')
case "$CPU_VENDOR" in
  GenuineIntel) MCPKG="sys-firmware/intel-microcode" ;;
  AuthenticAMD) MCPKG="sys-kernel/linux-firmware"   ;;
  *)            MCPKG="" ;;
esac

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

echo # Blank line for spacing

########################  kernel choices  ###################
ask KMETHOD "Kernel: [1] genkernel(menuconfig)  [2] manual-interactive  [3] manual-AUTO" "1"

########################  swap size (GiB)  ############################
RAM_GB=$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo)
def_swap=$(( RAM_GB < 8 ? 2 : 4 ))
ask SWAPSIZE "Swap size in GiB" "$def_swap"

########################  firmware type  ################################
if [[ -d /sys/firmware/efi ]]; then
  UEFI="yes"
  log "UEFI firmware detected."
else
  UEFI="no"
  log "Legacy BIOS detected."
fi

########################  filesystem choice  ##########################
ask FS "Root filesystem: [1] ext4  [2] btrfs" "1"
[[ $FS == 1 ]] && FSTYPE="ext4" || FSTYPE="btrfs"

########################  detect disks  ###############################
echo # Blank line for spacing
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

########################  partition  ##################################

log "Ready to partition ${DISK}"
echo "WARNING: This will ERASE ALL DATA on ${DISK}"
echo "         Size: $(lsblk -dn -o SIZE "${DISK}")"
echo "         Model: $(lsblk -dn -o MODEL "${DISK}" 2>/dev/null || echo "unknown")"

# Confirmation prompt with explicit warning
while true; do
    read -rp "Proceed with erasing all data on this disk? (yes/no): " disk_confirm
    case $disk_confirm in
        yes) break ;;
        no) die "Installation aborted by user" ;;
        *) echo "Please type 'yes' or 'no'" ;;
    esac
done

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

log "Disk partitioning and formatting complete:"
[[ $UEFI == yes ]] && printf "  ${ylw}%-15s${nc} %-10s %s\\n" "$ESP" "(FAT32)" "/boot (EFI System Partition)"
printf "  ${ylw}%-15s${nc} %-10s %s\\n" "$SWP" "(swap)"   "[SWAP]"
printf "  ${ylw}%-15s${nc} %-10s %s\\n" "$ROOT" "($FSTYPE)" "/ (Root Filesystem)"
echo # Blank line for separation

[[ $UEFI == yes ]] && mkfs.fat -F32 "$ESP"

mkswap       "$SWP"
if [[ $FSTYPE == ext4 ]]; then
  mkfs.ext4 -L gentoo "$ROOT"
else
  mkfs.btrfs -L gentoo "$ROOT"
fi

if [[ $UEFI == yes ]]; then
  ESP_UUID="$(blkid -s PARTUUID -o value "$ESP" 2>/dev/null || true)"
else
  ESP_UUID=""  # Empty for non-UEFI systems
fi
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

if command -v gpg &>/dev/null; then
    ask VERIFY_STAGE3 "Verify stage3 tarball integrity? (y/n)" "n"
    if [[ $VERIFY_STAGE3 == [Yy]* ]]; then
        log "Verifying stage3 tarball integrity..."
        
        # Extract directory path from the stage3 path
        STAGE_DIR=$(dirname "${STAGE}")
        STAGE_FILE=$(basename "${STAGE}")
        
        # Download the DIGESTS file
        wget -q --show-progress -O /mnt/gentoo/DIGESTS \
             "${GENTOO_MIRROR}/releases/amd64/autobuilds/${STAGE_DIR}/DIGESTS"
        
        # Simple checksum verification
        log "Verifying stage3 checksum..."
        SHA512_EXPECTED=$(grep -A1 -E "${STAGE_FILE}" /mnt/gentoo/DIGESTS | grep -E "SHA512" | head -n1 | awk '{print $1}')
        SHA512_ACTUAL=$(sha512sum /mnt/gentoo/stage3.tar.xz | awk '{print $1}')
        
        if [[ "$SHA512_EXPECTED" == "$SHA512_ACTUAL" ]]; then
            log "✅ Stage3 tarball checksum verified"
        else
            warn "❌ Checksum verification failed!"
            read -rp "Continue anyway? (y/n): " checksum_continue
            [[ $checksum_continue != [Yy]* ]] && die "Installation aborted due to checksum mismatch"
        fi
    else
        log "Skipping stage3 verification"
    fi
else
    log "GPG not available - skipping stage3 verification"
fi

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

### PORTAGE CONFIGURATION - STEP 1 ###
# Following Handbook Chapter 5 - Configuring Portage

echo "▶ Configuring Portage..."
# Create necessary directories for Portage configuration
mkdir -p /etc/portage/package.use
mkdir -p /etc/portage/package.license
mkdir -p /etc/portage/package.accept_keywords
mkdir -p /etc/portage/repos.conf
mkdir -p /var/db/repos/gentoo

# Set up firmware license acceptance
echo "sys-kernel/linux-firmware linux-fw-redistributable" > /etc/portage/package.license/firmware
echo "sys-kernel/linux-firmware ~amd64" > /etc/portage/package.accept_keywords/firmware

# Configure make.conf with detected hardware
cat >> /etc/portage/make.conf <<EOF
# Compiler options
MAKEOPTS="${MAKEOPTS_PLACEHOLDER}"

# Hardware-specific settings
VIDEO_CARDS="${VIDEO_PLACEHOLDER}"

# Base USE flags
USE="dbus udev ssl unicode usb -systemd"
EOF

if [[ "${DESKTOP_PLACEHOLDER}" != "headless" ]]; then
  cat >> /etc/portage/make.conf <<EOF
# Desktop environment USE flags
USE="\${USE} X elogind acpi alsa bluetooth cups policykit pipewire wifi"
EOF
fi

# Add package-specific USE flags
mkdir -p /etc/portage/package.use
echo "net-wireless/wpa_supplicant dbus" > /etc/portage/package.use/networkmanager
echo "net-misc/networkmanager -wext" > /etc/portage/package.use/networkmanager
echo "app-text/xmlto text" > /etc/portage/package.use/xmlto

### REPOSITORY SETUP - STEP 2 ###
# Following Handbook Chapter 5 - Installing the Gentoo repository

echo "▶ Setting up Gentoo repositories..."
# Copy the Gentoo repository configuration
cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf/gentoo.conf

# Sync the repository using webrsync (most reliable method per handbook)
echo "▶ Syncing repository..."
emerge-webrsync

### PROFILE SELECTION - STEP 3 ###
# Following Handbook Chapter 6 - Choosing the right profile

echo "▶ Selecting profile..."
eselect profile list
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

### BASIC SYSTEM CONFIGURATION - STEP 4 ###
# Following Handbook Chapter 8 - Configuring the system

echo "▶ Configuring timezone to ${TZ_PLACEHOLDER}..."
echo "${TZ_PLACEHOLDER}" > /etc/timezone
emerge --config sys-libs/timezone-data

echo "▶ Configuring locale to ${LOCALE_PLACEHOLDER}..."
echo "${LOCALE_PLACEHOLDER} UTF-8" > /etc/locale.gen
locale-gen
eselect locale set ${LOCALE_PLACEHOLDER}
env-update && source /etc/profile

echo "▶ Setting hostname to ${HOST_PLACEHOLDER}..."
echo "hostname=\"${HOST_PLACEHOLDER}\"" > /etc/conf.d/hostname

### KERNEL INSTALLATION - STEP 5 ###
# Following Handbook Chapter 7 - Configuring the kernel

echo "▶ Installing kernel sources..."
emerge --quiet sys-kernel/gentoo-sources
eselect kernel set 1

case "${KERNEL_PLACEHOLDER}" in
    genkernel)
        echo "▶ Installing genkernel and required tools..."
        emerge --quiet sys-kernel/genkernel sys-apps/pciutils
        echo "▶ Running genkernel with menuconfig..."
        genkernel --menuconfig all
        ;;
    manual_auto)
        echo "▶ Building kernel with default configuration..."
        cd /usr/src/linux
        make defconfig
        make -j$(nproc)
        make modules_install install
        ;;
    manual)
        echo "⚠ MANUAL KERNEL CONFIGURATION SELECTED"
        echo "⚠ You must compile and install the kernel before rebooting"
        echo "⚠ For reference:"
        echo "⚠   cd /usr/src/linux"
        echo "⚠   make menuconfig"
        echo "⚠   make -j$(nproc)"
        echo "⚠   make modules_install install"
        ;;
esac

### FIRMWARE INSTALLATION - STEP 6 ###
# Following Handbook Chapter 7 - Firmware

echo "▶ Installing firmware packages..."
# Install microcode for CPU
if [[ -n "${MICROCODE_PLACEHOLDER}" ]]; then
    echo "▶ Installing CPU microcode: ${MICROCODE_PLACEHOLDER}"
    emerge --quiet "${MICROCODE_PLACEHOLDER}"
fi

# Always install linux-firmware for general hardware
echo "▶ Installing system firmware..."
emerge --quiet sys-kernel/linux-firmware

### HARDWARE DETECTION AND OPTIMIZATION - STEP 6.5 ###

# Laptop-specific tools and optimizations
if [ -d /sys/class/power_supply/BAT* ]; then
    echo "▶ Laptop detected, installing power management..."
    emerge --quiet sys-power/tlp sys-power/powertop
    rc-update add tlp default
    
    # Get system information for brand detection
    emerge --quiet sys-apps/dmidecode
    SYSTEM_VENDOR=$(dmidecode -s system-manufacturer 2>/dev/null | tr '[:lower:]' '[:upper:]')
    SYSTEM_PRODUCT=$(dmidecode -s system-product-name 2>/dev/null)
    
    # ThinkPad-specific configuration
    if echo "$SYSTEM_VENDOR $SYSTEM_PRODUCT" | grep -q "THINKPAD" || echo "$SYSTEM_PRODUCT" | grep -q "ThinkPad"; then
        echo "▶ ThinkPad detected, installing additional tools..."
        emerge --quiet app-laptop/thinkfan app-laptop/tp_smapi
        
        # Basic thinkfan config
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
elif dmesg | grep -qi "qemu\|kvm"; then
    echo "▶ QEMU/KVM virtual machine detected, installing guest tools..."
    emerge --quiet app-emulation/qemu-guest-agent
    rc-update add qemu-guest-agent default
fi

# Wi-Fi hardware detection and setup
if lspci | grep -q -i 'network\|wireless'; then
    echo "▶ Wi-Fi hardware detected, installing drivers..."
    emerge --quiet net-wireless/iw net-wireless/wpa_supplicant net-wireless/iwd
    
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
    
    # Configure NetworkManager to use iwd for Wi-Fi
    mkdir -p /etc/NetworkManager/conf.d/
    echo "[device]
wifi.backend=iwd" > /etc/NetworkManager/conf.d/wifi_backend.conf
fi

### SYSTEM TOOLS - STEP 7 ###
# Following Handbook Chapter 8 - System tools

echo "▶ Installing essential system tools..."
emerge --quiet app-admin/sudo app-admin/sysklogd net-misc/dhcpcd
rc-update add sysklogd default

# Configure keyboard in console
echo "▶ Configuring keyboard layout to ${KEYBOARD_LAYOUT_PLACEHOLDER}..."
echo "KEYMAP=\"${KEYBOARD_LAYOUT_PLACEHOLDER}\"" > /etc/conf.d/keymaps
rc-update add keymaps boot

# For network management
echo "▶ Installing NetworkManager..."
emerge --quiet net-misc/networkmanager
rc-update add NetworkManager default

# Create a default NetworkManager connection config directory
mkdir -p /etc/NetworkManager/system-connections
chmod 700 /etc/NetworkManager/system-connections

# Install and enable SSH
emerge --quiet net-misc/openssh
rc-update add sshd default

# Simple firewall config
emerge --quiet net-firewall/ufw
rc-update add ufw default

### BOOTLOADER INSTALLATION - STEP 8 ###
# Following Handbook Chapter 10 - Configuring the bootloader

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

### FILESYSTEM CONFIGURATION - STEP 9 ###
# Following Handbook Chapter 8 - Filesystem

echo "▶ Configuring filesystem..."
# Set up fstab
if [[ "${GRUBTARGET_PLACEHOLDER}" == "x86_64-efi" ]]; then
  cat > /etc/fstab <<FSTAB
# <fs>                                  <mountpoint>    <type>    <opts>                  <dump/pass>
LABEL=gentoo                            /               ${FSTYPE_PLACEHOLDER}    noatime         0 1
PARTUUID=${ESP_UUID_PLACEHOLDER}        /boot           vfat      defaults                0 2
UUID=${SWP_UUID_PLACEHOLDER}            none            swap      sw                      0 0
FSTAB
else
  cat > /etc/fstab <<FSTAB
# <fs>                                  <mountpoint>    <type>    <opts>                  <dump/pass>
LABEL=gentoo                            /               ${FSTYPE_PLACEHOLDER}    noatime         0 1
UUID=${SWP_UUID_PLACEHOLDER}            none            swap      sw                      0 0
FSTAB
fi

### USER ACCOUNTS - STEP 10 ###
# Following Handbook Chapter 11 - User administration

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

if dmesg | grep -qi "virtualbox"; then
    usermod -aG vboxguest "${USER_PLACEHOLDER}"
fi

### DESKTOP ENVIRONMENT (if selected) - STEP 11 ###
# Only after core system is set up

if [[ "${DESKTOP_PLACEHOLDER}" != "headless" ]]; then
    echo "▶ Installing X.Org Server..."
    emerge --quiet x11-base/xorg-server x11-base/xorg-drivers x11-apps/xinit
    
    # Configure keyboard in X11
    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section "InputClass"
    Identifier "keyboard-all"
    Driver "libinput"
    Option "XkbLayout" "${KEYBOARD_LAYOUT_PLACEHOLDER}"
EOF

    # Add variant if present
    if [ -n "${KEYBOARD_VARIANT_PLACEHOLDER}" ]; then
        echo "    Option \"XkbVariant\" \"${KEYBOARD_VARIANT_PLACEHOLDER}\"" >> /etc/X11/xorg.conf.d/00-keyboard.conf
    fi
    
    echo "    MatchIsKeyboard \"on\"" >> /etc/X11/xorg.conf.d/00-keyboard.conf
    echo "EndSection" >> /etc/X11/xorg.conf.d/00-keyboard.conf
    
    # Audio
    emerge --quiet media-video/pipewire media-video/wireplumber
    
    # Desktop Environment
    case "${DESKTOP_PLACEHOLDER}" in
        xfce)
            echo "▶ Installing XFCE desktop environment..."
            emerge --quiet xfce-base/xfce4-meta x11-misc/lightdm x11-misc/lightdm-gtk-greeter
            rc-update add lightdm default
            ;;
        lxqt)
            echo "▶ Installing LXQt desktop environment..."
            emerge --quiet lxqt-base/lxqt-meta lxde-base/lxdm
            rc-update add lxdm default
            ;;
    esac
    
    # Basic terminal fallback
    emerge --quiet x11-terms/xterm

    # Text editor
    emerge --quiet app-editors/nano

    # Common applications
    # emerge --quiet www-client/firefox

fi

### FINAL TOUCHES - STEP 12 ###

echo "▶ Checking for important Gentoo news items..."
eselect news read new

echo "▶ Performing final cleanup..."
emerge --depclean --quiet

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
