# Gentoo Guru - One-Curl Gentoo Installer

A streamlined Gentoo Linux installer wizard for Intel/AMD64 systems. **This is not an official Gentoo project.**

## Features

- **Single command installation** with sensible defaults
- **Auto-detection** of hardware: UEFI/BIOS, CPU, GPU, disk types
- **Multiple desktop options**: XFCE, LXQt, or headless server
- **Kernel flexibility**: genkernel, manual, or unattended build
- **Filesystem choice**: Ext4 or Btrfs
- **Network support**: Automatic Wi-Fi fallback

## Quick Install

```bash
curl -L https://gentoo.guru/install.sh | bash

or 

curl -L https://gentoo.guru/install.sh -o install.sh
chmod +x install.sh
./install.sh
```

## Installation Steps

1. **Boot** from Gentoo LiveCD/USB
2. **Run** the installer command
3. **Select** target disk when prompted
4. **Configure**:
   - Network (automatic or guided Wi-Fi setup)
   - System details (hostname, passwords, timezone, locale)
   - Hardware options (swap size, drivers)
   - System type (kernel method, desktop environment, filesystem)
5. **Wait** for installation to complete
6. **Reboot** when finished

## System Requirements

- **CPU**: 64-bit Intel or AMD processor
- **RAM**: Minimum 2GB (4GB+ recommended for desktop environments)
- **Storage**: 20GB+ free disk space (40GB+ recommended)
- **Boot Media**: Gentoo LiveCD/USB with working internet access
- **Internet**: Wired connection recommended; Wi-Fi supported with fallback setup
- **Graphics**: Compatible GPU for desktop environments (Intel, AMD, or NVIDIA)

## Options

**Desktop Environments:**
- XFCE + LightDM: Full-featured lightweight desktop
- LXQt + LXDM: Ultra-lightweight Qt desktop
- Headless: Server configuration with SSH

**Kernel Methods:**
- genkernel: Guided configuration with menuconfig
- manual-interactive: DIY kernel compilation
- manual-AUTO: Unattended build with defconfig

## Manual Kernel Compilation

If you selected manual kernel configuration, follow these steps after installation:

1. **Access your system**: Either boot to your new system or chroot from LiveCD
   ```bash
   # To chroot from LiveCD:
   mount /dev/sdXY /mnt/gentoo    # Replace with your root partition
   mount /dev/sdXZ /mnt/gentoo/boot  # If separate boot partition
   for fs in proc sys dev; do mount --rbind /$fs /mnt/gentoo/$fs; done
   chroot /mnt/gentoo /bin/bash
   source /etc/profile
   ```

2. **Configure and compile kernel**:
   ```bash
   cd /usr/src/linux
   make menuconfig    # Interactive configuration
   make -j$(nproc)    # Compile the kernel
   make modules_install
   make install       # Automatically installs to /boot
   ```

3. **Update bootloader**:
   ```bash
   grub-mkconfig -o /boot/grub/grub.cfg
   ```

## Post-Install

- Remove installation media and reboot
- If you chose manual kernel, compile it before rebooting
- Use NetworkManager (`nmtui` or `nmcli`) for network setup

Happy Gentoo! For more information about Gentoo Linux, visit the [official Gentoo website](https://www.gentoo.org/).

## Troubleshooting

- **No network**: Use NetworkManager tools to configure
- **Display issues**: Boot to text mode to reconfigure graphics
- **Boot failures**: Chroot from LiveCD to repair
- **Missing firmware/drivers**: If hardware isn't working, you may need additional firmware packages: `emerge --ask sys-kernel/linux-firmware`

## License

GNU General Public License v3.0

## Acknowledgements

This project aims to make Gentoo more accessible while still maintaining the flexibility and educational value that makes Gentoo special. Thanks to the Gentoo community for creating such a powerful distribution.

**Note**: This is an independent project and not affiliated with or endorsed by the official Gentoo Linux project.
