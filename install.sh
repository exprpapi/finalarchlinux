#!/usr/bin/env bash
PS4="\e[34m[$(basename "${0}")"':${FUNCNAME[0]:+${FUNCNAME[0]}():}${LINENO:-}]: \e[0m'
IFS=$'\n\t'
set -euo pipefail
set -x

SHOULD_CLONE='no'
DISK='/dev/sda'
BOOT_PART="${DISK}1"
ROOT_PART="${DISK}2"
BOOT_PART_NAME='Boot Partition'
ROOT_PART_NAME='Root Partition'
BOOT_PART_TYPE_GUID='c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
ROOT_PART_TYPE_GUID='4f68bce3-e8cd-4db1-96e7-fbcaf984b709'
MOUNT_POINT_ROOT='/mnt'
MOUNT_POINT_BOOT="${MOUNT_POINT_ROOT}/boot"
DM_NAME='root_new'
ROOT_DECRYPTED="/dev/mapper/${DM_NAME}"

delete_partitions() {
  sudo sgdisk --zap-all "${DISK}"
}

create_boot_partition() {
  sudo sgdisk \
    --new='0:0:+1GiB' \
    --change-name="0:${BOOT_PART_NAME}" \
    --typecode="0:${BOOT_PART_TYPE_GUID}" \
    "${DISK}"
}

create_root_partition() {
  sudo sgdisk \
    --new='0:0:' \
    --change-name="0:${ROOT_PART_NAME}" \
    --typecode="0:${ROOT_PART_TYPE_GUID}" \
    "${DISK}"
}

format_boot_partition() {
  sudo mkfs.fat -F 32 -s 2 "${BOOT_PART}"
}

format_root_partition() {
  sudo cryptsetup --verify-passphrase --verbose luksFormat "${ROOT_PART}"
  sudo cryptsetup luksOpen "${ROOT_PART}" "${DM_NAME}"
  sudo mkfs.ext4 "${ROOT_DECRYPTED}"
  sudo cryptsetup luksClose "${DM_NAME}"
}

clone_rootfs() {
  local old_rootfs='/'
  local new_rootfs="${MOUNT_POINT_ROOT}"
  local src="${old_rootfs}"
  local dst="${new_rootfs}"
  local opts=(
    --archive
    --hard-links
    --xattrs
    --atimes
    --sparse
    --info=progress2
  )
  if [[ "${src}" == '/' ]]; then
    local excludes_src=''
  else
    local excludes_src="${src}"
  fi
  local excludes=(
    --exclude "${excludes_src}/dev/*"
    --exclude "${excludes_src}/sys/*"
    --exclude "${excludes_src}/proc/*"
    --exclude "${excludes_src}/run/*"
    --exclude "${excludes_src}/media/*"
    --exclude "${excludes_src}/mnt/*"
    --exclude "${excludes_src}/lost+found"
  )
  sudo cryptsetup luksOpen "${ROOT_PART}" "${DM_NAME}"
  sudo mount --mkdir "${ROOT_DECRYPTED}" "${MOUNT_POINT_ROOT}"
  sudo rsync "${opts[@]}" "${excludes[@]}" "${src}" "${dst}"
  sudo umount "${ROOT_DECRYPTED}"
  sudo cryptsetup luksClose "${DM_NAME}"
}

bootstrap_archlinux() {
  local initial_root_passwd='root'
  local initial_user_passwd='u'
  local locale_gen='en_US.UTF-8 UTF-8'
  local locale_conf='LANG=en_US.UTF-8'
  local keymap='us'
  local zone_info='Europe/Berlin'  
  local hostname='h'

  local packages=(
    base
    linux
    linux-firmware
    man-db
    man-pages
    texinfo
    neovim
    ranger
    zsh
    intel-ucode
    openssh
    iwd
  )
  
  local mkinitcpio_conf="$(cat \
<<'EOF'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base systemd block keyboard fsck autodetect modconf kms sd-vconsole sd-encrypt filesystems)
EOF
  )"
  
  local bootloader_conf="$(cat \
<<'EOF'
timeout 0
console-mode max
default arch*
editor 1
EOF
  )"

  local bootloader_entry="$(cat \
<<'EOF'
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options rw lsm=landlock lockdown yama integrity apparmor bpf quiet loglevel=3 rd.udev.log_level=3 systemd.show_status=false i915.fastboot=1 vt.global_cursor_default=0 fbcon=nodefer rd.luks.options=password-echo=no
EOF
  )"

  local iwd_conf="$(cat \
<<'EOF'
[General]
EnableNetworkConfiguration=true
EOF
  )"

  local chroot_commands="$(cat \
<<EOF
ln -sf "/usr/share/zoneinfo/${zone_info}" /etc/localtime
hwclock --systohc
tee &>>/dev/null /etc/locale.gen <<<"${locale_gen}"
tee &>>/dev/null /etc/locale.conf <<<"${locale_conf}"
tee &>>/dev/null /etc/hostname <<<"${hostname}"
tee &>>/dev/null /etc/vconsole.conf <<<"KEYMAP=${keymap}"
tee &>>/dev/null /etc/iwd/main.conf <<<"${iwd_conf}"
locale-gen
bootctl install
tee &>>/dev/null /etc/mkinitcpio.conf <<<"${mkinitcpio_conf}"
tee &>>/dev/null /boot/loader/loader.conf <<<"${bootloader_conf}"
tee &>>/dev/null /boot/loader/entries/arch.conf <<<"${bootloader_entry}"
tee &>>/dev/null /boot/loader/entries/arch.conf <<<"${bootloader_entry}"
mkinitcpio -P
printf '%s\n' "${initial_root_passwd}" "${initial_root_passwd}" | passwd

systemctl enable systemd-networkd systemd-resolved iwd
EOF
  )"
  
  sudo cryptsetup luksOpen "${ROOT_PART}" "${DM_NAME}"
  sudo mount --mkdir "${ROOT_DECRYPTED}" "${MOUNT_POINT_ROOT}"
  sudo mount --mkdir "${BOOT_PART}" "${MOUNT_POINT_BOOT}"
  sudo pacstrap -K "${MOUNT_POINT_ROOT}" "${packages[@]}"
  sudo arch-chroot "${MOUNT_POINT_ROOT}" <<<"${chroot_commands}"
  sudo umount "${ROOT_DECRYPTED}"
  sudo umount "${BOOT_PART}"
  sudo cryptsetup luksClose "${DM_NAME}"
}

prepare() {
  delete_partitions
  create_boot_partition
  create_root_partition
  format_boot_partition
  format_root_partition
}

install() {
  case "${SHOULD_CLONE}" in
    y*) clone_rootfs ;;
    *) bootstrap_archlinux ;;
  esac
}

main() {
  prepare
  install
}

main "$@"
