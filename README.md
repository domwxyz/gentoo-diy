# Gentoo dot DIY - One-Curl Gentoo Installer

A streamlined Gentoo Linux installer wizard for Intel/AMD64 systems that prioritizes simplicity. **This is not an official Gentoo project.**

## Features

- **Single command installation** with sensible defaults
- **Auto-detection** of hardware: UEFI/BIOS, CPU, GPU, disk types
- **Kernel flexibility**: genkernel, manual, or unattended build
- **Filesystem choice**: Ext4 or Btrfs
- **Network support**: Automatic Wi-Fi fallback with iwd/wpa
- **Hardware-specific optimizations** for ThinkPad, Dell, and HP laptops
- **Virtualization support** for VirtualBox and QEMU/KVM environments
- **NVMe suffix handling**, dynamic swap sizing, and proper partition detection
- **Security** with UFW firewall enabled by default

## Quick Install

```bash
curl -L https://gentoo.diy/install.sh -o install.sh
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
   - Hardware options (swap size)
   - System type (kernel method, filesystem)
   - X server support (optional)
5. **Wait** for installation to complete
6. **Reboot** when finished

## System Requirements

- **CPU**: 64-bit Intel or AMD processor
- **RAM**: Minimum 2GB (4GB+ recommended)
- **Storage**: 20GB+ free disk space
- **Boot Media**: Gentoo LiveCD/USB with working internet access
- **Internet**: Wired connection recommended; Wi-Fi supported with fallback setup
- **Graphics**: Compatible GPU if X server option is selected

## Included Software

- **Networking**: NetworkManager with iwd for Wi-Fi management
- **Power Management**: TLP and powertop for laptops
- **Security**: UFW firewall, sudo configuration
- **System**: OpenSSH server, sysklogd
- **Optional**: Basic X server support (if selected)

## Options

**Kernel Methods:**
- genkernel: Guided configuration with menuconfig
- manual-interactive: DIY kernel compilation
- manual-AUTO: Unattended build with defconfig

**Filesystems:**
- Ext4: Standard Linux filesystem (default)
- Btrfs: Advanced filesystem with snapshots

**X Server:**
- Optional minimal X server installation

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
- Laptop users: Power management is pre-configured for optimal battery life
- System security: UFW firewall is enabled by default
- Wi-Fi users: Special drivers are auto-installed for Intel and Broadcom chipsets

Happy Gentoo! For more information about Gentoo Linux, visit the [official Gentoo website](https://www.gentoo.org/).

## Troubleshooting

- **No network**: Use NetworkManager tools to configure (`nmtui` or `nmcli`)
- **Missing firmware/drivers**: If hardware isn't working, you may need additional firmware packages: `emerge --ask sys-kernel/linux-firmware`
- **Virtualization issues**: Guest additions are automatically installed for VirtualBox/QEMU

## License

GNU General Public License v3.0

## Acknowledgements

This project aims to make Gentoo more accessible while still maintaining the flexibility and educational value that makes Gentoo special. Thanks to the Gentoo community for creating such a powerful distribution.

**Note**: This is an independent project and not affiliated with or endorsed by the official Gentoo Linux project.
