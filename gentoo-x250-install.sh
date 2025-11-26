#!/bin/bash
set -euo pipefail

##############################################################################
# Gentoo X250 UEFI (unencrypted) auto-install script
# WARNING: This will WIPE the target disk completely.
##############################################################################

DISK="/dev/sda"        # <--- CHANGE THIS IF YOUR DISK IS DIFFERENT
HOSTNAME="gentoo-x250"
TIMEZONE="US/Eastern"
STAGE3_URL="https://bouncer.gentoo.org/fetch/root/all/releases/amd64/autobuilds/current-stage3-amd64-openrc/stage3-amd64-openrc-latest.tar.xz"

echo ">>> WARNING: This will completely ERASE ${DISK}."
echo ">>> Press Ctrl+C within 10 seconds to abort."
sleep 10

# Basic sanity checks
if [ ! -d /sys/firmware/efi ]; then
  echo "ERROR: Not booted in UEFI mode (no /sys/firmware/efi)."
  exit 1
fi

if ! ping -c1 gentoo.org >/dev/null 2>&1; then
  echo "ERROR: No network connectivity. Get online first."
  exit 1
fi

echo ">>> Partitioning ${DISK} (GPT: EFI + swap + root)..."
parted -s "${DISK}" mklabel gpt
parted -s "${DISK}" mkpart ESP fat32 1MiB 513MiB
parted -s "${DISK}" set 1 esp on
parted -s "${DISK}" mkpart primary linux-swap 513MiB 8.5GiB
parted -s "${DISK}" mkpart primary ext4 8.5GiB 100%

EFI_PART="${DISK}1"
SWAP_PART="${DISK}2"
ROOT_PART="${DISK}3"

echo ">>> Creating filesystems..."
mkfs.vfat -F32 "${EFI_PART}"
mkswap "${SWAP_PART}"
swapon "${SWAP_PART}"
mkfs.ext4 -F "${ROOT_PART}"

echo ">>> Mounting target root at /mnt/gentoo..."
mount "${ROOT_PART}" /mnt/gentoo
mkdir -p /mnt/gentoo/boot/efi
mount "${EFI_PART}" /mnt/gentoo/boot/efi

echo ">>> Downloading stage3..."
cd /mnt/gentoo
wget -O stage3.tar.xz "${STAGE3_URL}"
tar xpvf stage3.tar.xz --xattrs-include='*.*' --numeric-owner
rm stage3.tar.xz

echo ">>> Copying DNS configuration..."
cp -L /etc/resolv.conf /mnt/gentoo/etc/

echo ">>> Mounting special filesystems..."
mount -t proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --rbind /run /mnt/gentoo/run || true
mount --make-rslave /mnt/gentoo/run || true

echo ">>> Writing chroot setup script..."
cat > /mnt/gentoo/root/x250-chroot-setup.sh << 'EOF_CHROOT'
#!/bin/bash
set -euo pipefail

HOSTNAME="gentoo-x250"
TIMEZONE="US/Eastern"

echo ">>> emerge-webrsync (initial Portage tree)..."
emerge-webrsync

echo ">>> Setting Gentoo desktop profile (OpenRC)..."
eselect profile set default/linux/amd64/17.1/desktop

echo ">>> Configuring /etc/portage/make.conf for X250 (i7-5600U)..."
cat > /etc/portage/make.conf << 'EOF_MAKECONF'
COMMON_FLAGS="-march=broadwell -O2 -pipe -fomit-frame-pointer"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"

MAKEOPTS="-j4"

ACCEPT_LICENSE="*"
VIDEO_CARDS="intel i965"
INPUT_DEVICES="libinput synaptics"

USE="X alsa pulseaudio opengl wifi bluetooth udev udisks networkmanager icu"
EOF_MAKECONF

echo ">>> Timezone & locale..."
echo "${TIMEZONE}" > /etc/timezone
emerge --config sys-libs/timezone-data

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.utf8
env-update && source /etc/profile

echo ">>> Setting hostname & hosts..."
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts << EOF_HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF_HOSTS

echo ">>> Writing /etc/fstab..."
cat > /etc/fstab << 'EOF_FSTAB'
/dev/sda3   /          ext4    noatime         0 1
/dev/sda2   none       swap    sw              0 0
/dev/sda1   /boot/efi  vfat    umask=0077      0 2
EOF_FSTAB

echo ">>> Installing base system packages..."
emerge --quiet-build=n --jobs=3 \
  sys-kernel/gentoo-sources \
  sys-kernel/genkernel \
  sys-kernel/linux-firmware \
  sys-firmware/intel-microcode \
  sys-boot/grub:2 \
  sys-boot/efibootmgr \
  net-misc/networkmanager \
  net-wireless/iw \
  net-wireless/wpa_supplicant \
  sys-apps/pciutils \
  sys-apps/usbutils \
  app-admin/sudo

echo ">>> Building kernel with genkernel (generic but safe)..."
genkernel all

echo ">>> Enabling NetworkManager at boot..."
rc-update add NetworkManager default

echo ">>> Installing GRUB for UEFI..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Gentoo
grub-mkconfig -o /boot/grub/grub.cfg

echo ">>> Set root password:"
passwd

echo ">>> Creating user 'gentoo' (password 'change_me')..."
useradd -m -G wheel,audio,video gentoo || true
echo "gentoo:change_me" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/01-wheel

echo ">>> Chroot phase complete. You can now exit and reboot after unmounting."
EOF_CHROOT

chmod +x /mnt/gentoo/root/x250-chroot-setup.sh

echo ">>> Entering chroot and running X250 setup..."
chroot /mnt/gentoo /bin/bash -c "/root/x250-chroot-setup.sh"

echo ">>> Cleaning up mounts..."
umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
umount -l /mnt/gentoo/sys 2>/dev/null || true
umount -l /mnt/gentoo/proc 2>/dev/null || true
umount -l /mnt/gentoo/run 2>/dev/null || true
umount -l /mnt/gentoo/boot/efi 2>/dev/null || true
umount -l /mnt/gentoo 2>/dev/null || true

echo ">>> Installation complete. Reboot and boot from the SSD."
echo "    Login as root (with the password you set) or user 'gentoo' / 'change_me'."