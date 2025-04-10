#!/bin/bash

set -xe
# 不进行交互安装
export DEBIAN_FRONTEND=noninteractive
BUILD_TYPE="$1"
ROOTFS="rootfs"
TARGET_DEVICE=23-x1e80100
ARCH="arm64"
DISKIMG="deepin-$TARGET_DEVICE.img"
IMAGE_SIZE=$( [ "$BUILD_TYPE" == "desktop" ] && echo 12288 || echo 4096 )
readarray -t REPOS < ./profiles/sources.list
PACKAGES=$(cat ./profiles/packages.txt | grep -v "^-" | xargs | sed -e 's/ /,/g')

function run_command_in_chroot()
{
    rootfs="$1"
    command="$2"
    sudo chroot "$rootfs" /usr/bin/env bash -e -o pipefail -c "export DEBIAN_FRONTEND=noninteractive && $command"
}

# 设置 chroot 环境
function setup_chroot_environment() {
    local TMP="$1" # 假设 $TMP 是目标chroot环境的根目录

    # 挂载 /dev 目录，允许在 chroot 环境中访问设备文件
    sudo mount --bind /dev "$TMP/dev"

    # 挂载 proc 文件系统提供了一个接口来访问内核状态信息，如进程列表等
    sudo mount -t proc chproc "$TMP/proc"

    # 挂载 sysfs 提供了访问内核模块、硬件设备和其他系统级别的信息
    sudo mount -t sysfs chsys "$TMP/sys"

    # 挂载临时文件系统
    sudo mount -t tmpfs -o "size=99%" tmpfs "$TMP/tmp"
    sudo mount -t tmpfs -o "size=99%" tmpfs "$TMP/var/tmp"

    # 挂载 devpts 文件系统负责为伪终端提供设备节点，支持文本用户界面和shell会话
    sudo mount -t devpts devpts "$TMP/dev/pts"
}

sudo apt update -y
case $(uname -m) in
x86_64)
    # 在 x86 上构建，需要利用 qemu 并开启 binfmt 异架构支持
    sudo apt-get install -y qemu-user-static binfmt-support mmdebstrap arch-test usrmerge usr-is-merged qemu-system-misc systemd-container fdisk dosfstools
    sudo systemctl restart systemd-binfmt
    ;;
aarch64)
    # arm64 上构建
    sudo apt-get install -y mmdebstrap usrmerge usr-is-merged systemd-container fdisk dosfstools
    ;;
esac

if [ ! -d "$ROOTFS" ]; then
    mkdir -p $ROOTFS
    # 创建根文件系统
    sudo mmdebstrap \
        --hook-dir=/usr/share/mmdebstrap/hooks/merged-usr \
        --skip=check/empty \
        --include=$PACKAGES \
        --components="main,commercial,community" \
        --architectures=${ARCH} \
        beige \
        $ROOTFS \
        "${REPOS[@]}"

    if [[ "$BUILD_TYPE" == "desktop" ]] && [[ "$(uname -m)" == "aarch64" ]];
    then
        setup_chroot_environment $ROOTFS
        # 安装桌面环境，添加火狐浏览器，另外安装 treeland 窗管
        run_command_in_chroot $ROOTFS "apt update -y && apt install -y \
            deepin-desktop-environment-core \
            deepin-desktop-environment-base \
            deepin-desktop-environment-cli \
            deepin-desktop-environment-extras \
            firefox \
            ddm \
            treeland"
        # 默认启用的 lightdm 窗管，这里禁用 lightdm，使用 ddm。
        run_command_in_chroot $ROOTFS "
        systemctl disable lightdm
        systemctl enable ddm"
        umount -l $ROOTFS
    else
        # 需要使用树莓派构建带桌面的镜像，dkms 模块依赖内核，使用 qemu 无法正确编译。
        echo "Need to build the image using Raspberry Pi"
    fi
fi


sudo echo "deepin-$TARGET_DEVICE" | sudo tee $ROOTFS/etc/hostname > /dev/null

# 创建磁盘文件
dd if=/dev/zero of=$DISKIMG bs=1M count=$IMAGE_SIZE
sudo fdisk deepin-raspberrypi.img << EOF
n
p
1

+300M
t
c
n
p
2


w
EOF

# 格式化
LOOP=$(sudo losetup -Pf --show $DISKIMG)
sudo mkfs.fat -F32 "${LOOP}p1"
sudo dosfslabel "${LOOP}p1" bootfs
sudo mkfs.ext4 "${LOOP}p2" # 根分区 (/)
sudo e2label "${LOOP}p2" rootfs

TMP=`mktemp -d`
sudo mount "${LOOP}p2" $TMP
sudo cp -a $ROOTFS/* $TMP

sudo mkdir $TMP/boot/firmware
sudo mount "${LOOP}p1" $TMP/boot/firmware

# 拷贝引导加载程序GPU 固件等, 从 https://github.com/raspberrypi/firmware/tree/master/boot 官方仓库中拷贝，另外放入了 cmdline.txt 和 config.txt 配置
sudo cp -r firmware/* $TMP/boot/firmware

# 配置 config.txt
sudo tee $TMP/boot/firmware/config.txt <<EOF
# For more options and information see
# http://rptl.io/configtxt
# Some settings may impact device functionality. See link above for details

# Uncomment some or all of these to enable the optional hardware interfaces
#dtparam=i2c_arm=on
#dtparam=i2s=on
#dtparam=spi=on

# Enable audio (loads snd_bcm2835)
dtparam=audio=on

# Additional overlays and parameters are documented
# /boot/firmware/overlays/README

# Automatically load overlays for detected cameras
camera_auto_detect=1

# Automatically load overlays for detected DSI displays
display_auto_detect=1

# Automatically load initramfs files, if found
auto_initramfs=1

# Enable DRM VC4 V3D driver
dtoverlay=vc4-kms-v3d
max_framebuffers=2

# Don't have the firmware create an initial video= setting in cmdline.txt.
# Use the kernel's default instead.
disable_fw_kms_setup=1

# Run in 64-bit mode
arm_64bit=1

# Disable compensation for displays with overscan
disable_overscan=1

# Run as fast as firmware / board allows
arm_boost=1

[cm4]
# Enable host mode on the 2711 built-in XHCI USB controller.
# This line should be removed if the legacy DWC2 controller is required
# (e.g. for USB device mode) or if USB support is not required.
otg_mode=1

[cm5]
dtoverlay=dwc2,dr_mode=host

[all]
EOF

setup_chroot_environment $TMP

sudo rm -f $TMP/etc/resolv.conf
sudo cp /etc/resolv.conf $TMP/etc/resolv.conf
# 安装树莓派的 raspi-config
mkdir -p $TMP/etc/apt/sources.list.d
#MOD echo "deb [trusted=yes] http://archive.raspberrypi.org/debian/ bookworm main" | sudo tee $TMP/etc/apt/sources.list.d/raspberrypi.list

# deepin 源里没 libfmt9，已经到 libfmt10 了，从 debian 下载 deb 包
curl -L http://ftp.cn.debian.org/debian/pool/main/f/fmtlib/libfmt9_9.1.0+ds1-2_arm64.deb -o $TMP/tmp/libfmt9.deb
curl -L http://ftp.cn.debian.org/debian/pool/main/d/device-tree-compiler/libfdt1_1.6.1-4+b1_arm64.deb -o $TMP/tmp/libfdt1.deb
run_command_in_chroot $TMP "apt update -y && apt install -y \
    /tmp/libfmt9.deb \
    /tmp/libfdt1.deb"

# raspi-config是树莓派的配置工具，firmware-brcm80211 包含无线网卡驱动
run_command_in_chroot $TMP "apt install -y raspi-config raspberrypi-sys-mods firmware-brcm80211 raspi-firmware bluez-firmware"

#MOD # 安装内核
# MODrun_command_in_chroot $TMP "apt install -y \
# MOD    linux-image-rpi-v8 \
# MOD    linux-image-rpi-2712 \
#MOD     linux-headers-rpi-v8 \
# MOD    linux-headers-rpi-2712"
# Install the kernel
run_command_in_chroot $TMP "apt install -y linux-image-6.12.9-arm64-desktop-rolling"

# 在物理设备上需要添加 cmdline.txt 定义 Linux内核启动时的命令行参数
echo "console=serial0,115200 console=tty1 root=LABEL=rootfs rootfstype=ext4 fsck.repair=yes rootwait quiet init=/usr/lib/raspberrypi-sys-mods/firstboot splash plymouth.ignore-serial-consoles" | sudo tee $TMP/boot/firmware/cmdline.txt
# 编辑分区表
sudo tee $TMP/etc/fstab << EOF
proc          /proc           proc    defaults          0       0
LABEL=bootfs  /boot/firmware  vfat    defaults          0       2
LABEL=rootfs  /               ext4    defaults,rw,errors=remount-ro,x-systemd.growfs  0       1
EOF

run_command_in_chroot $TMP "sed -i -E 's/#[[:space:]]?(en_US.UTF-8[[:space:]]+UTF-8)/\1/g' /etc/locale.gen
sed -i -E 's/#[[:space:]]?(zh_CN.UTF-8[[:space:]]+UTF-8)/\1/g' /etc/locale.gen
"

run_command_in_chroot $TMP "useradd -m -g users deepin && usermod -a -G sudo deepin
chsh -s /bin/bash deepin
echo deepin:deepin | chpasswd"

# 删除 root 的密码
sudo sed -i 's/^root:[^:]*:/root::/' $TMP/etc/shadow

run_command_in_chroot $TMP "locale-gen"

# 清理缓存
run_command_in_chroot $TMP "apt clean
rm -rf /var/cache/apt/archives/*
rm /etc/apt/sources.list.d/raspberrypi.list
"
sudo umount -l $TMP

# 会强制检查指定的文件系统
sudo e2fsck -f "${LOOP}p2"
# 收缩文件系统，使其刚好容纳现有的数据
sudo resize2fs -M "${LOOP}p2"

sudo losetup -D $LOOP
sudo rm -rf $TMP
