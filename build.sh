#!/bin/bash
set -xe

export DEBIAN_FRONTEND=noninteractive

BUILD_TYPE="$1"
ROOTFS="rootfs"
TARGET_DEVICE=23-x1e80100
ARCH="arm64"
ISO_NAME="deepin-$TARGET_DEVICE.iso"
ISO_DIR="deepin-iso"
KERNEL_VERSION="6.12.9-arm64-desktop-rolling"

IMAGE_SIZE=$( [ "$BUILD_TYPE" == "desktop" ] && echo 12288 || echo 4096 )
readarray -t REPOS < ./profiles/sources.list
PACKAGES=$(cat ./profiles/packages.txt | grep -v "^-" | xargs | sed -e 's/ /,/g')

function run_command_in_chroot()
{
    rootfs="$1"
    command="$2"
    sudo chroot "$rootfs" /usr/bin/env bash -e -o pipefail -c "export DEBIAN_FRONTEND=noninteractive && $command"
}

function setup_chroot_environment() {
    local TMP="$1"
    sudo mount --bind /dev "$TMP/dev"
    sudo mount -t proc chproc "$TMP/proc"
    sudo mount -t sysfs chsys "$TMP/sys"
    sudo mount -t tmpfs -o "size=99%" tmpfs "$TMP/tmp"
    sudo mount -t tmpfs -o "size=99%" tmpfs "$TMP/var/tmp"
    sudo mount -t devpts devpts "$TMP/dev/pts"
}

sudo apt update -y
case $(uname -m) in
x86_64)
    sudo apt-get install -y qemu-user-static binfmt-support mmdebstrap arch-test usrmerge usr-is-merged qemu-system-misc systemd-container grub-efi-amd64-bin xorriso
    sudo systemctl restart systemd-binfmt
    ;;
aarch64)
    sudo apt-get install -y mmdebstrap usrmerge usr-is-merged systemd-container grub-common grub-efi-arm64-signed grub-efi-arm64-unsigned arm64-efi grub-efi-arm64-bin  efibootmgr xorriso
    ;;
esac

if [ ! -d "$ROOTFS" ]; then
    mkdir -p $ROOTFS
    sudo mmdebstrap \
        --hook-dir=/usr/share/mmdebstrap/hooks/merged-usr \
        --skip=check/empty \
        --include=$PACKAGES \
        --components="main,commercial,community" \
        --architectures=${ARCH} \
        beige \
        $ROOTFS \
        "${REPOS[@]}"

    if [[ "$BUILD_TYPE" == "desktop" ]] && [[ "$(uname -m)" == "aarch64" ]]; then
        setup_chroot_environment $ROOTFS
        run_command_in_chroot $ROOTFS "apt update -y && apt install -y \
            deepin-desktop-environment-core \
            deepin-desktop-environment-base \
            deepin-desktop-environment-cli \
            deepin-desktop-environment-extras \
            firefox \
            ddm \
            treeland"

        run_command_in_chroot $ROOTFS "
        systemctl disable lightdm
        systemctl enable ddm"
        umount -l $ROOTFS
    else
        echo "Need to build the image using Raspberry Pi"
    fi
fi

echo "deepin-$TARGET_DEVICE" | sudo tee $ROOTFS/etc/hostname > /dev/null

sudo rm -rf "$ISO_DIR"
mkdir -p "$ISO_DIR/EFI/boot"
mkdir -p "$ISO_DIR/boot/grub"

sudo cp -a $ROOTFS/* $ISO_DIR

# Fix DNS
sudo rm -f $ISO_DIR/etc/resolv.conf
sudo cp /etc/resolv.conf $ISO_DIR/etc/resolv.conf

# Install only the kernel (skip Debian-specific packages)
run_command_in_chroot $ISO_DIR "apt update -y && apt install -y \
    linux-image-$KERNEL_VERSION"

# Create GRUB config
cat <<EOF | sudo tee $ISO_DIR/boot/grub/grub.cfg
set timeout=5
set default=0

menuentry "Deepin ARM64" {
    linux /boot/vmlinuz-$KERNEL_VERSION root=/dev/sr0 rootfstype=iso9660 rw quiet splash
    initrd /boot/initrd.img-$KERNEL_VERSION
}
EOF

# Build GRUB EFI

GRUB_DEB="grub-efi-arm64-bin_2.12-7_arm64.deb"
GRUB_URL="http://ftp.us.debian.org/debian/pool/main/g/grub2/$GRUB_DEB"
GRUB_DIR="grub-extract"

mkdir -p "$GRUB_DIR"
wget -q --show-progress "$GRUB_URL"
dpkg-deb -x "$GRUB_DEB" "$GRUB_DIR"

sudo chmod 644 $ISO_DIR/etc/shadow
sudo chmod 644 $ISO_DIR/etc/sudoers.d/README
sudo chmod 644 $ISO_DIR/etc/credstore.encrypted
sudo chmod -R a+rX "$ISO_DIR"

# Build GRUB EFI using extracted modules
grub-mkimage \
  -O arm64-efi \
  -d "$GRUB_DIR/usr/lib/grub/arm64-efi" \
  -o "$ISO_DIR/EFI/boot/bootaa64.efi" \
  -p /boot/grub \
  ext2 fat iso9660 part_gpt part_msdos normal efi_gop linux configfile search search_label


# Make the ISO
xorriso -as mkisofs \
    -R -J -joliet-long \
    -eltorito-alt-boot \
    -e EFI/boot/bootaa64.efi \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -o $ISO_NAME \
    $ISO_DIR

echo "✅ ISO created: $ISO_NAME"
