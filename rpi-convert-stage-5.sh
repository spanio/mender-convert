#!/bin/bash

#    Copyright 2018 Northern.tech AS
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

application_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
files_dir=${application_dir}/files
output_dir=${application_dir}/output
uboot_dir=${output_dir}/uboot-mender
bin_base_dir=${output_dir}/bin
bin_dir_pi=${bin_base_dir}/raspberrypi
sdimg_base_dir=$output_dir/sdimg
build_log=${output_dir}/build.log

declare -a mender_disk_mappings
declare -a mender_partitions_regular=("boot" "primary" "secondary" "data")

# Takes following arguments:
#
#  $1 - ARM toolchain
#  $2 - RPI machine (raspberrypi3 or raspberrypi0w)
build_uboot_files() {
  local CROSS_COMPILE=${1}-
  local ARCH=arm
  local branch="mender-rpi-2018.07"
  local commit="b9e738cc23"
  local uboot_repo_vc_dir=$uboot_dir/.git
  local defconfig="rpi_3_32b_defconfig"

  if [ "$2" == "raspberrypi0w" ]; then
    defconfig="rpi_0_w_defconfig"
  fi

  export CROSS_COMPILE=$CROSS_COMPILE
  export ARCH=$ARCH

  mkdir -p $bin_dir_pi

  log "\tBuilding U-Boot related files."

  if [ ! -d $uboot_repo_vc_dir ]; then
    git clone https://github.com/spanio/uboot-mender.git -b $branch >> "$build_log" 2>&1
  fi

  cd $uboot_dir

  git checkout $commit >> "$build_log" 2>&1

  make --quiet distclean >> "$build_log"
  make --quiet $defconfig >> "$build_log" 2>&1
  make --quiet >> "$build_log" 2>&1
  make --quiet envtools >> "$build_log" 2>&1

  cat<<-'EOF' >boot.cmd
	fdt addr ${fdt_addr} && fdt get value bootargs /chosen bootargs
	run mender_setup
	mmc dev ${mender_uboot_dev}
	if load ${mender_uboot_root} ${kernel_addr_r} /boot/zImage; then
	    bootz ${kernel_addr_r} - ${fdt_addr}
	elif load ${mender_uboot_root} ${kernel_addr_r} /boot/uImage; then
	    bootm ${kernel_addr_r} - ${fdt_addr}
	else
	    echo "No bootable Kernel found."
	fi
	run mender_try_to_recover
	EOF

  if [ ! -e $uboot_dir/tools/mkimage ]; then
    log "Error: cannot build U-Boot. Aborting"
    return 1
  fi

  $uboot_dir/tools/mkimage -A arm -T script -C none -n "Boot script" -d "boot.cmd" boot.scr >> "$build_log" 2>&1
  cp -t $bin_dir_pi $uboot_dir/boot.scr $uboot_dir/tools/env/fw_printenv $uboot_dir/u-boot.bin

  return 0
}

# Takes following arguments:
#
#  $1 - boot partition mountpoint
#  $2 - primary partition mountpoint
install_files() {
  local boot_dir=$1
  local rootfs_dir=$2
  local kernel_img="kernel7.img"

  if [ "${device_type}" == "raspberrypi0w" ]; then
    kernel_img="kernel.img"
  fi

  log "\tInstalling U-Boot related files."

  # Make a copy of Linux kernel arguments and modify.
  sudo cp ${boot_dir}/cmdline.txt ${output_dir}/cmdline.txt

  sed -i 's/\b[ ]root=[^ ]*/ root=\${mender_kernel_root}/' ${output_dir}/cmdline.txt

  # Original Raspberry Pi image run once will have init_resize.sh script removed
  # from the init argument from the cmdline.
  #
  # On the other hand in Mender image we want to retain a mechanism of last
  # partition resizing. Check the cmdline.txt file and add it back if necessary.
  if ! grep -q "init=/usr/lib/raspi-config/init_resize.sh" ${output_dir}/cmdline.txt; then
    cmdline=$(cat ${output_dir}/cmdline.txt)
    sh -c -e "echo '${cmdline} init=/usr/lib/raspi-config/init_resize.sh' > ${output_dir}/cmdline.txt";
  fi

  # Update Linux kernel command arguments with our custom configuration
  sudo cp ${output_dir}/cmdline.txt ${boot_dir}

  # Mask udisks2.service, otherwise it will mount the inactive part and we
  # might write an update while it is mounted which often result in
  # corruptions.
  #
  # TODO: Find a way to only blacklist mmcblk0pX devices instead of masking
  # the service.
  sudo ln -sf /dev/null ${rootfs_dir}/etc/systemd/system/udisks2.service

  # Extract Linux kernel and install to /boot directory on rootfs
  sudo cp ${boot_dir}/${kernel_img} ${rootfs_dir}/boot/zImage

  # Replace kernel with U-boot and add boot script
  sudo mkdir -p ${rootfs_dir}/uboot

  sudo cp ${bin_dir_pi}/u-boot.bin ${boot_dir}/${kernel_img}

  sudo cp ${bin_dir_pi}/boot.scr ${boot_dir}

  # Raspberry Pi configuration files, applications expect to find this on
  # the device and in some cases parse the options to determinate
  # functionality.
  sudo ln -fs /uboot/config.txt ${rootfs_dir}/boot/config.txt

  sudo install -m 755 ${bin_dir_pi}/fw_printenv ${rootfs_dir}/sbin/fw_printenv
  sudo ln -fs /sbin/fw_printenv ${rootfs_dir}/sbin/fw_setenv

  # Override init script to expand the data partition instead of rootfs, which it
  # normally expands in standard Raspberry Pi distributions.
  sudo install -m 755 ${files_dir}/init_resize.sh \
      ${rootfs_dir}/usr/lib/raspi-config/init_resize.sh

  # As the whole process must be conducted in two steps, i.e. resize partition
  # during first boot and resize the partition's file system on system's first
  # start-up add systemd service file and script.
  sudo install -m 644 ${files_dir}/resizefs.service \
      ${rootfs_dir}/lib/systemd/system/resizefs.service
  sudo ln -sf /lib/systemd/system/resizefs.service \
      ${rootfs_dir}/etc/systemd/system/multi-user.target.wants/resizefs.service
  sudo install -m 755 ${files_dir}/resizefs.sh \
      ${rootfs_dir}/usr/sbin/resizefs.sh

  # Remove original 'resize2fs_once' script and its symbolic link.
  sudo unlink ${rootfs_dir}/etc/rc3.d/S01resize2fs_once
  sudo rm ${rootfs_dir}/etc/init.d/resize2fs_once
}

do_install_bootloader() {
  if [ -z "${mender_disk_image}" ]; then
    log "Mender raw disk image file not set. Aborting."
    exit 1
  fi

  if [ -z "${bootloader_toolchain}" ]; then
    log "ARM GCC toolchain not set. Aborting."
    exit 1
  fi

  if ! [ -x "$(command -v ${bootloader_toolchain}-gcc)" ]; then
    log "Error: ARM GCC not found in PATH. Aborting."
    exit 1
  fi

  [ ! -f $mender_disk_image ] && \
      { log "$mender_disk_image - file not found. Aborting."; exit 1; }

  # Map & mount Mender compliant image.
  create_device_maps $mender_disk_image mender_disk_mappings

  # Change current directory to 'output' directory.
  cd $output_dir

  # Build patched U-Boot files.
  build_uboot_files $bootloader_toolchain $device_type
  rc=$?
  cd $output_dir

  if [ $rc -eq 0 ]; then
    mount_mender_disk ${mender_disk_mappings[@]}
    install_files ${output_dir}/sdimg/boot ${output_dir}/sdimg/primary
  fi

  detach_device_maps ${mender_disk_mappings[@]}
  rm -rf $sdimg_base_dir

  [[ $keep -eq 0 ]] && { rm -f ${output_dir}/config.txt ${output_dir}/cmdline.txt;
     rm -rf $uboot_dir $bin_base_dir; }

  [[ "$rc" -ne 0 ]] && { exit 1; } || { log "\tDone."; }
}

# Conditional once we support other boards
PARAMS=""

while (( "$#" )); do
  case "$1" in
    -m | --mender-disk-image)
      mender_disk_image=$2
      shift 2
      ;;
    -b | --bootloader-toolchain)
      bootloader_toolchain=$2
      shift 2
      ;;
    -d | --device-type)
      device_type=$2
      shift 2
      ;;
    -k | --keep)
      keep=1
      shift 1
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      log "Error: unsupported option $1"
      exit 1
      ;;
    *)
      PARAMS="$PARAMS $1"
      shift
      ;;
  esac
done

eval set -- "$PARAMS"

# Some commands expect elevated privileges.
sudo true

do_install_bootloader
