#!/usr/bin/env bash
# =====================================================================
#  Gentoo "one‑curl" installer
#  • Built for a simple, barebones Gentoo install
# =====================================================================
set -euo pipefail
LOG_FILE="gentoo_install_$(date +%Y%m%d_%H%M%S).log"
echo "=== Gentoo dot DIY Installer Log - $(date) ===" > "$LOG_FILE"

########################  CONFIGURATION  ##############################
# User can override with:  MIRROR=https://some.mirror ./install.sh
GENTOO_MIRROR="${MIRROR:-https://distfiles.gentoo.org}"

########################  SETUP & UTILITIES  ##########################
# Terminal colors for feedback
if [[ -t 1 ]]; then
  nc='\e[0m'; red='\e[31m'; grn='\e[32m'; ylw='\e[33m'; blu='\e[34m'; mag='\e[35m'; cyn='\e[36m'
else
  nc=''; red=''; grn=''; ylw=''; blu=''; mag=''; cyn='';
fi

trap 'printf "${red}❌ Error on line %d - exiting\n" "$LINENO" >&2; echo "❌ Error on line $LINENO - exiting" >> "$LOG_FILE"; exit 1' ERR
IFS=$'\n\t'

# Feedback functions
log()  { printf "${grn}▶ %s${nc}\n" "$*"; echo "▶ $*" >> "$LOG_FILE"; }
info() { printf "${cyn}ℹ %s${nc}\n" "$*"; echo "ℹ $*" >> "$LOG_FILE"; }
warn() { printf "${ylw}⚠ %s${nc}\n" "$*"; echo "⚠ $*" >> "$LOG_FILE"; }
die()  { printf "${red}❌ %s${nc}\n" "$*"; echo "❌ $*" >> "$LOG_FILE"; exit 1; }
hr()   { local line=$(printf '%*s\n' "${1:-$(tput cols)}" '' | tr ' ' '─'); echo "$line"; echo "$line" >> "$LOG_FILE"; }

cleanup() {
  ec=$? # save the status that triggered EXIT
  log "Running filesystem cleanup…"

  for mp in /mnt/gentoo/dev /mnt/gentoo/proc /mnt/gentoo/sys; do
    mountpoint -q "$mp" && umount -l "$mp"
  done
  mountpoint -q /mnt/gentoo && umount -R /mnt/gentoo
  [[ -n ${SWP:-} ]] && swapoff "$SWP" 2>/dev/null || true
  [[ -n ${CRYPT_NAME:-} ]] && cryptsetup close "$CRYPT_NAME" 2>/dev/null || true

  if (( ec != 0 )); then
    warn "Aborted with exit $ec; environment cleaned."
  else
    log  "Cleanup complete - install finished successfully."
  fi
  exit "$ec"
}
trap cleanup EXIT INT TERM

# Command helpers
need() { command -v "$1" &>/dev/null || die "Missing tool: $1"; }

# Input helpers
ask() { # ask VAR "Prompt" "default"
  local var="$1" msg="$2" def="${3-}" val
  printf "${mag}? %s${nc}${def:+ [${def}]}: " "$msg"
  read -r val
  printf -v "$var" '%s' "${val:-$def}"
}

ask_pw() {
  local var="$1" msg="$2" val confirm
  while true; do
    printf "${mag}? %s${nc}: " "$msg"
    read -rs val
    echo
    printf "${mag}? Confirm %s${nc}: " "$msg"
    read -rs confirm
    echo
    if [[ "$val" == "$confirm" ]]; then
      printf -v "$var" '%s' "$val"
      break
    else
      echo "Passwords don't match. Please try again."
    fi
  done
}

section() {
  echo
  hr
  printf "${cyn}  %s  ${nc}\n" "$*"
  hr
  echo
}

# Select from menu helper
select_from_menu() {
  local var="$1" prompt="$2" 
  shift 2
  local options=("$@")
  local option_count=${#options[@]}
  
  echo -e "${cyn}$prompt:${nc}"
  for i in $(seq 0 $((option_count - 1))); do
    echo "  $((i + 1)). ${options[$i]}"
  done
  
  local selection
  while true; do
    read -rp "Enter selection [1-$option_count]: " selection
    if [[ "$selection" =~ ^[0-9]+$ && "$selection" -ge 1 && "$selection" -le "$option_count" ]]; then
      printf -v "$var" '%s' "${options[$((selection - 1))]}"
      break
    else
      echo "Invalid selection. Please enter a number between 1 and $option_count."
    fi
  done
}

safe_replace() {
  local placeholder="$1"
  local value="$2"
  local file="$3"
  
  local escaped_value=$(printf '%s\n' "$value" | sed 's/\\/\\\\/g; s/\//\\\//g; s/&/\\&/g')
  
  sed -i "s|$placeholder|$escaped_value|g" "$file"
}

########################  UI FUNCTIONS  ##############################
welcome_banner() {
  local width=60  # Width of the content area (excluding asterisks)
  local title="G E N T O O   D O T   D I Y"
  local subtitle="One-Curl Gentoo Installer Wizard"
  local loading_msg="Setting up user preference selection..."
  
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
}

########################  SYSTEM CHECKS  ############################
check_requirements() {
  section "System requirements"
  
  log "Verifying required tools..."
  for bin in curl wget sgdisk lsblk lspci lscpu awk openssl; do 
    need "$bin"
  done
  
  # Ensure we're reading from terminal
  exec < /dev/tty
  
  # Sync clock
  log "Synchronising clock..."
  (ntpd -q -g || chronyd -q) &>/dev/null || warn "NTP sync failed (continuing)"
}

########################  NETWORK SETUP  ############################
check_network() {
  section "Network connectivity"
  
  log "Checking internet connection..."
  if ping -c1 -W2 1.1.1.1 &>/dev/null; then
    log "Network is connected and working."
    return 0
  fi
  
  warn "No network connectivity detected."
  setup_wifi
}

setup_wifi() {
  info "Setting up wireless connection..."
  
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
    log "Launching interactive Wi-Fi setup via iwd..."
    wifi_with_iwd
  elif command -v wpa_cli &>/dev/null; then
    log "iwd not present → falling back to wpa_cli"
    wifi_with_wpa
  else
    die "Neither iwctl nor wpa_cli present - aborting."
  fi

  if ping -c1 -W4 1.1.1.1 &>/dev/null; then
    log "Network connection established successfully."
  else
    die "Still offline after Wi-Fi attempt."
  fi
}

########################  HARDWARE DETECTION  #######################
detect_keyboard_layout() {
  log "Detecting keyboard layout..."
  
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
  
  info "Keyboard layout: $KEYBOARD_LAYOUT${KEYBOARD_VARIANT:+ variant: $KEYBOARD_VARIANT}"
}

detect_hardware() {
  section "Hardware detection"
  
  log "Detecting CPU..."
  CPU_VENDOR=$(lscpu | awk -F': *' '/Vendor ID/{print $2}')
  case "$CPU_VENDOR" in
    GenuineIntel) 
      MCPKG="sys-firmware/intel-microcode" 
      CPU_TYPE="Intel"
      ;;
    AuthenticAMD) 
      MCPKG="sys-kernel/linux-firmware"
      CPU_TYPE="AMD"
      ;;
    *)            
      MCPKG="" 
      CPU_TYPE="Unknown"
      ;;
  esac
  info "CPU detected: $CPU_TYPE"
  
  log "Detecting GPU..."
  GPU_LINE=$(lspci -nnk | grep -Ei 'VGA|3D')
  case "$GPU_LINE" in
    *Intel*)  
      VC="intel i965 iris" 
      GPU_TYPE="Intel"
      ;;
    *AMD*|*ATI*) 
      VC="amdgpu radeonsi" 
      GPU_TYPE="AMD"
      ;;
    *NVIDIA*) 
      VC="nouveau" 
      GPU_TYPE="NVIDIA"
      ;;
    *) 
      VC="" 
      GPU_TYPE="Unknown"
      ;;
  esac
  info "GPU detected: $GPU_TYPE"
  
  log "Detecting firmware type..."
  if [[ -d /sys/firmware/efi ]]; then
    UEFI="yes"
    info "Firmware: UEFI"
  else
    UEFI="no"
    info "Firmware: Legacy BIOS"
  fi
  
  log "Detecting available RAM..."
  RAM_GB=$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo)
  info "RAM detected: ${RAM_GB}GB"
  
  detect_keyboard_layout
}

########################  CONFIGURATION WIZARD  #######################
select_locale() {
  log "Configuring system locale..."
  
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

  echo -e "${cyn}Select your preferred locale:${nc}"
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
  log "Configuring timezone..."
  
  local timezones=(
    "Africa/Cairo"           "Egypt"
    "America/Chicago"        "US Central"
    "America/Denver"         "US Mountain"
    "America/Los_Angeles"    "US Pacific"
    "America/New_York"       "US Eastern"
    "America/Mexico_City"    "Mexico"
    "Asia/Hong_Kong"         "Hong Kong"
    "Asia/Shanghai"          "China"
    "Asia/Tokyo"             "Japan"
    "Australia/Melbourne"    "Australia Eastern"
    "Australia/Perth"        "Australia Western"
    "Australia/Sydney"       "Australia (NSW)"
    "Europe/Dublin"          "Ireland"
    "Europe/London"          "United Kingdom"
    "Europe/Madrid"          "Spain"
    "Europe/Moscow"          "Russia"
    "Europe/Paris"           "France"
    "Pacific/Auckland"       "New Zealand"
    "UTC"                    "Universal Time"
  )

  echo -e "${cyn}Select your timezone:${nc}"
  PS3="Timezone #: "
  
  local descriptions=()
  for ((i=1; i<${#timezones[@]}; i+=2)); do
    descriptions+=("${timezones[i]} (${timezones[i-1]})")
  done
  
  select choice in "${descriptions[@]}" "Other (manual entry)"; do
    if [[ $REPLY -gt 0 && $REPLY -le ${#descriptions[@]} ]]; then
      # Convert reply to array index (accounting for 0-based indexing and pairs)
      local idx=$(( (REPLY-1) * 2 ))
      TZ="${timezones[idx]}"
      log "Selected timezone: $TZ"
      break
    elif [[ "$choice" == "Other (manual entry)" ]]; then
      ask TZ "Enter your timezone (e.g. America/New_York)" "UTC"
      break
    else
      echo "Invalid selection. Please try again."
    fi
  done
}

configure_accounts() {
  log "Setting up system accounts..."
  
  ask HOSTNAME "Hostname" "gentoobox"
  ask_pw ROOT_PASS "Root password"
  echo # Blank line for spacing
  ask USERNAME "Regular user name" "user"
  ask_pw USER_PASS "Password for $USERNAME"
}

configure_system() {
  log "Configuring system options..."
  
  echo -e "\n${cyn}X Server Configuration${nc}"
  ask X_SERVER "Install minimal X server support? (y/n)" "n"
  
  if [[ $X_SERVER != [Yy]* ]]; then
    VC=""
    info "X server not selected - VIDEO_CARDS will be empty"
  else
    info "X server will be installed with VIDEO_CARDS=\"$VC\""
  fi
  
  echo -e "\n${cyn}Kernel Configuration${nc}"
  echo "1) genkernel (menuconfig) - Automated kernel build with manual customization"
  echo "2) manual-interactive    - Completely manual kernel configuration"
  echo "3) manual-AUTO          - Automated kernel build with defaults"
  ask KMETHOD "Select kernel option (1-3)" "1"
  
  echo -e "\n${cyn}Swap Configuration${nc}"
  def_swap=$(( RAM_GB < 8 ? 2 : 4 ))
  ask SWAPSIZE "Swap size in GiB" "$def_swap"
  
  echo -e "\n${cyn}Filesystem Selection${nc}"
  echo "1) ext4 - Standard Linux filesystem (recommended for most users)"
  echo "2) btrfs - Advanced filesystem with snapshots and other features"
  ask FS "Root filesystem (1-2)" "1"
  [[ $FS == 1 ]] && FSTYPE="ext4" || FSTYPE="btrfs"
}

configuration_wizard() {
  section "System configuration"
  
  select_locale
  echo
  select_timezone
  echo
  configure_accounts
  echo
  configure_system
}

display_config_summary() {
  section "Configuration summary"
  
  echo -e "${blu}System locale:${nc}    ${ylw}$LOCALE${nc}"
  echo -e "${blu}Timezone:${nc}         ${ylw}$TZ${nc}"
  echo -e "${blu}Hostname:${nc}         ${ylw}$HOSTNAME${nc}"
  echo -e "${blu}Username:${nc}         ${ylw}$USERNAME${nc}"
  echo -e "${blu}X Server:${nc}         ${ylw}$([[ $X_SERVER == [Yy]* ]] && echo "Yes" || echo "No")${nc}"
  echo -e "${blu}Kernel method:${nc}    ${ylw}$(case $KMETHOD in 1) echo "genkernel";; 2) echo "manual";; *) echo "automated";; esac)${nc}"
  echo -e "${blu}Swap Size:${nc}        ${ylw}${SWAPSIZE}GB${nc}"
  echo -e "${blu}Root Filesystem:${nc}  ${ylw}$FSTYPE${nc}"
  echo -e "${blu}CPU:${nc}              ${ylw}$CPU_TYPE${nc}"
  echo -e "${blu}GPU:${nc}              ${ylw}$GPU_TYPE${nc}"
  echo -e "${blu}Firmware:${nc}         ${ylw}$([[ $UEFI == "yes" ]] && echo "UEFI" || echo "BIOS")${nc}"
  
  echo
  ask CONFIRM "Does this configuration look correct? (y/n)" "y"
  if [[ $CONFIRM != [Yy]* ]]; then
    die "Installation aborted. Please restart the script to try again."
  fi
}

########################  DISK SELECTION  #############################
select_disk() {
  section "Disk selection"
  
  log "Detecting installable disks..."
  mapfile -t DISKS < <(lsblk -dpn -o NAME,SIZE,MODEL -x SIZE | grep -E '/dev/(sd|nvme|vd)')
  [[ ${#DISKS[@]} -gt 0 ]] || die "No suitable block devices found."
  
  # Extract just the device paths for the menu (first column)
  local disk_options=()
  local disk_descriptions=()
  for disk_line in "${DISKS[@]}"; do
    local device=$(echo "$disk_line" | awk '{print $1}')
    local size=$(echo "$disk_line" | awk '{print $2}')
    local model=$(echo "$disk_line" | awk '{$1=$2=""; print substr($0,3)}' | sed 's/^ *//')
    
    disk_options+=("$device")
    if [[ -n "$model" ]]; then
      disk_descriptions+=("$device ($size - $model)")
    else
      disk_descriptions+=("$device ($size)")
    fi
  done
  
  # Default to first disk if there's only one
  local default_disk=""
  [[ ${#disk_options[@]} -eq 1 ]] && default_disk="${disk_options[0]}"
  
  echo -e "${cyn}Available disks:${nc}"
  for i in "${!disk_descriptions[@]}"; do
    echo "  $((i+1))) ${disk_descriptions[$i]}"
  done
  echo
  
  ask DISK_CHOICE "Enter disk number" "${default_disk:+1}"
  
  # Validate and process the choice
  if [[ "$DISK_CHOICE" =~ ^[0-9]+$ && "$DISK_CHOICE" -ge 1 && "$DISK_CHOICE" -le ${#disk_options[@]} ]]; then
    DISK="${disk_options[$((DISK_CHOICE-1))]}"
    
    # Get details for the selected disk
    for disk_line in "${DISKS[@]}"; do
      if [[ "$disk_line" == "$DISK"* ]]; then
        DISK_SIZE=$(echo "$disk_line" | awk '{print $2}')
        DISK_MODEL=$(echo "$disk_line" | awk '{$1=$2=""; print substr($0,3)}' | sed 's/^ *//')
        break
      fi
    done
    
    echo -e "\n${ylw}Selected disk:${nc} $DISK"
    echo -e "${ylw}Size:${nc} $DISK_SIZE"
    [[ -n "$DISK_MODEL" ]] && echo -e "${ylw}Model:${nc} $DISK_MODEL"
  else
    die "Invalid disk selection: $DISK_CHOICE"
  fi

  [[ $DISK =~ nvme ]] && P='p' || P=''   # NVMe partition suffix
  log "Set partition suffix: '$P' for disk $DISK"
  
  # Confirmation prompt with explicit warning
  echo
  echo -e "${red}WARNING:${nc} This will ${red}ERASE ALL DATA${nc} on ${ylw}${DISK}${nc}"
  echo -e "         All existing partitions and data will be permanently deleted."
  echo

  ask DISK_CONFIRM "Proceed with erasing all data on this disk? (y/n)" "n"

  if [[ $DISK_CONFIRM == [Yy]* ]]; then
    log "Disk confirmed for partitioning."
  else
    die "Installation aborted by user"
  fi
}

partition_disk() {
  section "Disk partitioning"
  
  log "Partitioning $DISK..."
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

  log "Disk partitioning complete:"
  [[ $UEFI == yes ]] && printf "  ${ylw}%-15s${nc} %-10s %s\\n" "$ESP" "(FAT32)" "/boot (EFI System Partition)"
  printf "  ${ylw}%-15s${nc} %-10s %s\\n" "$SWP" "(swap)"   "[SWAP]"
  printf "  ${ylw}%-15s${nc} %-10s %s\\n" "$ROOT" "($FSTYPE)" "/ (Root Filesystem)"
  echo # Blank line for separation

  if [[ ! -d /sys/firmware/efi ]] && [[ $(lsblk -no PTTYPE "$DISK") == dos ]]; then
    log "Marking root partition (index 2 on $DISK) as active"
    parted -s "$DISK" set 2 boot on
  fi

  # Format partitions
  log "Formatting partitions..."
  [[ $UEFI == yes ]] && mkfs.fat -F32 "$ESP"

  mkswap "$SWP"
  case $FSTYPE in
    ext4)  mkfs.ext4  -L gentoo "$ROOT" ;;
    btrfs) mkfs.btrfs -L gentoo "$ROOT" ;;
  esac

  if [[ $UEFI == yes ]]; then
    ESP_UUID="$(blkid -s PARTUUID -o value "$ESP" 2>/dev/null || true)"
  else
    ESP_UUID=""  # Empty for non-UEFI systems
  fi
  SWP_UUID="$(blkid -s UUID -o value "$SWP")"
  
  log "Mounting filesystems..."
  mkdir -p /mnt/gentoo
  mount "$ROOT" /mnt/gentoo
  [[ $FSTYPE == btrfs ]] && btrfs subvolume create /mnt/gentoo/@ && umount /mnt/gentoo && mount -o subvol=@ "$ROOT" /mnt/gentoo

  mkdir -p /mnt/gentoo/boot
  [[ $UEFI == yes ]] && mount "$ESP" /mnt/gentoo/boot
  swapon "$SWP"
}

########################  STAGE3 DOWNLOAD  #############################
download_stage3() {
  section "Stage 3 tarball download"
  
  log "Fetching stage3 manifest..."
  local stage3_url
  stage3_url=$(curl -fsSL "${GENTOO_MIRROR}/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt" \
               | grep -E '^[0-9]+T[0-9]+Z/stage3-.*\.tar\.xz' | awk '{print $1}') \
               || die "Unable to parse stage3 manifest"
  
  local stage3_base_url="${GENTOO_MIRROR}/releases/amd64/autobuilds/${stage3_url}"
  local stage3_base_path="/mnt/gentoo/stage3"
  
  log "Downloading latest stage3: ${stage3_url}"
  wget -q --show-progress -O "${stage3_base_path}.tar.xz" "${stage3_base_url}" \
      || die "Failed to download stage3 tarball"
      
  # Download DIGESTS file
  log "Downloading verification files..."
  wget -q -O "${stage3_base_path}.tar.xz.DIGESTS" "${stage3_base_url}.DIGESTS" \
      || die "Failed to download DIGESTS file"
      
  # Download GPG signature
  wget -q -O "${stage3_base_path}.tar.xz.asc" "${stage3_base_url}.asc" \
      || die "Failed to download GPG signature"
  
  # Import Gentoo release keys
  log "Importing Gentoo release keys..."
  wget -q -O /tmp/gentoo-keys.asc "${GENTOO_MIRROR}/releases/gentoo-keys.asc" \
      || die "Failed to download Gentoo release keys"
  gpg --import /tmp/gentoo-keys.asc 2>/dev/null \
      || warn "GPG key import failed (continuing with caution)"
      
  # Verify SHA256 checksum
  log "Verifying SHA256 checksum..."
  cd /mnt/gentoo
  if grep -A1 SHA256 "${stage3_base_path}.tar.xz.DIGESTS" | grep -v SHA256 | \
     grep "$(sha256sum "$(basename ${stage3_base_path}.tar.xz)" | awk '{print $1}')" > /dev/null; then
    log "SHA256 checksum verified successfully"
  else
    die "SHA256 checksum verification failed!"
  fi
  
  # Verify GPG signature
  log "Verifying GPG signature..."
  if gpg --verify "${stage3_base_path}.tar.xz.asc" "${stage3_base_path}.tar.xz" 2>/dev/null; then
    log "GPG signature verified successfully"
  else
    warn "GPG signature verification failed (continuing with caution)"
  fi
  
  log "Extracting stage3 tarball..."
  tar xpf "${stage3_base_path}.tar.xz" -C /mnt/gentoo \
      --xattrs-include='*.*' --numeric-owner
  
  # Copy resolv.conf for network connectivity inside chroot
  cp -L /etc/resolv.conf /mnt/gentoo/etc/
}

########################  CHROOT PREPARATION  ##########################
prepare_chroot() {
  section "Chroot environment preparation"
  
  log "Setting up bind mounts..."
  for fs in proc sys dev; do 
    mount --rbind /$fs /mnt/gentoo/$fs
    mount --make-rslave /mnt/gentoo/$fs
  done
  
  log "Creating chroot installation script..."
  create_chroot_script
  
  # Handle passwords securely
  log "Securely storing credentials for chroot environment..."
  openssl passwd -6 "$ROOT_PASS" > /mnt/gentoo/root/root_hash.txt
  openssl passwd -6 "$USER_PASS" > /mnt/gentoo/root/user_hash.txt
  
  unset ROOT_PASS USER_PASS
}

########################  CHROOT SCRIPT CREATION  ######################
create_chroot_script() {
  local chroot_script="/mnt/gentoo/root/inside.sh"
  
  cat > "$chroot_script" <<'EOS'
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
X_SERVER_PLACEHOLDER="@@XVAL@@"
GRUBTARGET_PLACEHOLDER="@@GRUBTGT@@"
FSTYPE_PLACEHOLDER="@@FSTYPE@@"
ESP_UUID_PLACEHOLDER="@@ESP_UUID@@"
SWP_UUID_PLACEHOLDER="@@SWP_UUID@@"
MAKEOPTS_PLACEHOLDER="@@MAKEOPTS@@"
# -----------------------------------------------------

echo "▶ Starting Gentoo installation inside chroot environment..."

###############################################################
#                      PORTAGE SETUP                          #
###############################################################
portage_configuration() {
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

  if [[ "${X_SERVER_PLACEHOLDER}" == "yes" ]]; then
    cat >> /etc/portage/make.conf <<EOF
# X server USE flags
USE="\${USE} X elogind acpi alsa"
EOF
  fi

  # Add package-specific USE flags
  mkdir -p /etc/portage/package.use
  echo "net-wireless/wpa_supplicant dbus" > /etc/portage/package.use/networkmanager
  echo "net-misc/networkmanager -wext" > /etc/portage/package.use/networkmanager
  echo "app-text/xmlto text" > /etc/portage/package.use/xmlto
}

setup_repositories() {
  echo "▶ Setting up Gentoo repositories..."
  # Copy the Gentoo repository configuration
  cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf/gentoo.conf

  # Sync the repository using webrsync (most reliable method per handbook)
  echo "▶ Syncing repository..."
  emerge-webrsync
}

select_profile() {
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
}

###############################################################
#                    SYSTEM CONFIGURATION                     #
###############################################################
configure_base_system() {
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
}

###############################################################
#                     KERNEL INSTALLATION                     #
###############################################################
install_kernel() {
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
}

###############################################################
#                    FIRMWARE INSTALLATION                    #
###############################################################
install_firmware() {
  echo "▶ Installing firmware packages..."
  # Install microcode for CPU
  if [[ -n "${MICROCODE_PLACEHOLDER}" ]]; then
    echo "▶ Installing CPU microcode: ${MICROCODE_PLACEHOLDER}"
    emerge --quiet "${MICROCODE_PLACEHOLDER}"
  fi

  # Always install linux-firmware for general hardware
  echo "▶ Installing system firmware..."
  emerge --quiet sys-kernel/linux-firmware
}

###############################################################
#              HARDWARE DETECTION & OPTIMIZATION              #
###############################################################
detect_and_configure_hardware() {
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
  setup_virtualization

  # Wi-Fi hardware detection and setup
  configure_wifi
}

setup_virtualization() {
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
}

configure_wifi() {
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
}

###############################################################
#                     SYSTEM TOOLS SETUP                      #
###############################################################
install_system_tools() {
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
}

###############################################################
#                    BOOTLOADER INSTALLATION                  #
###############################################################
install_bootloader() {
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
}

###############################################################
#                   FILESYSTEM CONFIGURATION                  #
###############################################################
configure_filesystem() {
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
}

###############################################################
#                     USER ACCOUNT SETUP                      #
###############################################################
setup_user_accounts() {
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
}

###############################################################
#                     X SERVER INSTALLATION                   #
###############################################################
install_x_server() {
  if [[ "${X_SERVER_PLACEHOLDER}" == "yes" ]]; then
    echo "▶ Installing minimal X server..."
    emerge --quiet x11-base/xorg-server x11-base/xorg-drivers 
    
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
    
    # Basic terminal and utilities for X
    emerge --quiet x11-terms/xterm x11-apps/xinit
  fi
}

###############################################################
#                        FINALIZATION                         #
###############################################################
perform_final_steps() {
  # Common applications
  echo "▶ Installing text editor..."
  emerge --quiet app-editors/nano

  echo "▶ Checking for important Gentoo news items..."
  eselect news read new

  echo "▶ Performing final cleanup..."
  emerge --depclean --quiet

  echo "🎉 Installation completed successfully!"
  echo "🔄 You can now reboot into your new Gentoo system."
}

###############################################################
#                      MAIN EXECUTION                         #
###############################################################
# Execute all installation steps in sequence
main() {
  # Portage setup
  portage_configuration
  setup_repositories
  select_profile
  
  # Basic system configuration
  configure_base_system
  
  # Kernel installation
  install_kernel
  
  # Firmware installation
  install_firmware
  
  # Hardware detection and configuration
  detect_and_configure_hardware
  
  # System tools installation
  install_system_tools
  
  # Bootloader installation
  install_bootloader
  
  # Filesystem configuration
  configure_filesystem
  
  # User account setup
  setup_user_accounts
  
  # X server installation (if selected)
  install_x_server
  
  # Final steps
  perform_final_steps
}

# Start the installation process
main
EOS

  # Make the script executable
  chmod +x "$chroot_script"
}

########################  CHROOT EXECUTION  ##########################
execute_chroot() {
  section "Chroot execution"
  
  log "Preparing variables for chroot environment..."
  local chroot_script="/mnt/gentoo/root/inside.sh"
  
  # System settings
  safe_replace "@@TZVAL@@" "$TZ" "$chroot_script"
  safe_replace "@@LOCALEVAL@@" "$LOCALE" "$chroot_script"
  safe_replace "@@KBLAYOUT@@" "$KEYBOARD_LAYOUT" "$chroot_script"
  safe_replace "@@KBVARIANT@@" "$KEYBOARD_VARIANT" "$chroot_script"
  safe_replace "@@HOSTVAL@@" "$HOSTNAME" "$chroot_script"
  safe_replace "@@USERVAL@@" "$USERNAME" "$chroot_script"
  
  # Hardware settings
  safe_replace "@@VIDEOSTR@@" "$VC" "$chroot_script"
  safe_replace "@@MCPKG@@" "$MCPKG" "$chroot_script"
  
  # Partition settings
  safe_replace "@@ESP_UUID@@" "$ESP_UUID" "$chroot_script"
  safe_replace "@@SWP_UUID@@" "$SWP_UUID" "$chroot_script"
  safe_replace "@@DISKVAL@@" "$DISK" "$chroot_script"
  
  # Installation options
  local kval
  case $KMETHOD in
    1) kval="genkernel" ;; 
    2) kval="manual" ;; 
    3) kval="manual_auto" ;;
  esac
  safe_replace "@@KVAL@@" "$kval" "$chroot_script"
  
  local xval
  [[ $X_SERVER == [Yy]* ]] && xval="yes" || xval="no"
  safe_replace "@@XVAL@@" "$xval" "$chroot_script"
  
  local grubtgt
  [[ $UEFI == yes ]] && grubtgt="x86_64-efi" || grubtgt="i386-pc"
  safe_replace "@@GRUBTGT@@" "$grubtgt" "$chroot_script"
  
  safe_replace "@@FSTYPE@@" "$FSTYPE" "$chroot_script"
  
  # Compilation settings
  local makeopts="-j$(nproc)"
  safe_replace "@@MAKEOPTS@@" "$makeopts" "$chroot_script"
  
  log "Entering chroot environment..."
  chroot /mnt/gentoo /bin/bash /root/inside.sh
}

########################  CLEANUP AND FINALIZATION  ###################
cleanup_and_finalize() {
  section "Cleanup and finalization"
  
  log "Unmounting filesystems..."
  umount -l /mnt/gentoo/{dev,proc,sys} 2>/dev/null || true
  umount -R /mnt/gentoo 2>/dev/null || true
  swapoff "$SWP" 2>/dev/null || true
  
  if [[ $KMETHOD == 2 ]]; then
    warn "You chose MANUAL-interactive kernel. Compile it before reboot!"
  fi
  
  log "Installation complete!"
  info "Remove the installation media and reboot to start using your new Gentoo system."
  hr
  echo "Thank you for using Gentoo dot DIY installer! 🚀"
}

########################  MAIN EXECUTION  #############################
main() {
  # Check requirements and display welcome
  welcome_banner
  
  # Check and setup network
  check_requirements
  check_network
  
  # Hardware detection
  detect_hardware
  
  # User configuration
  configuration_wizard
  display_config_summary

  # Partition and format disk
  select_disk
  partition_disk
  
  # Download and extract stage3
  download_stage3
  
  # Prepare chroot environment
  prepare_chroot
  execute_chroot
  
  # Cleanup and finalize
  cleanup_and_finalize
}

# Start the installation
main
