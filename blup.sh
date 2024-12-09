#!/bin/sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VERSION=2.0

MMCDEV=/dev/mmcblk3
UBOOT_ENV_FILE=/mnt/env/uboot.env

fetch () {
    echo "fetching $1 from $2 ....."
    curl -L -O $2/$1
    if [ $? -ne 0 ]; then
        echo -e "${RED}curl download error, stopping script ${NC}"
        exit 1
    fi
    echo -e "${GREEN}OK${NC}"
    echo -e "curl -O $2$1"

}

wait_user (){
	echo -e "${YELLOW}$1"
	echo -e "Press [ENTER] to continue...${NC}"
	read -p " " 
}

test_partitions(){	
	if test x`echo p q |fdisk ${MMCDEV}|grep ${MMCDEV}p3|cut -d' ' -f1` == "x${MMCDEV}p3"; then
		echo -e "${GREEN}Found partitionset B linux partition ${NC}"
		if test x`echo p q |fdisk ${MMCDEV}|grep ${MMCDEV}p5|cut -d' ' -f1` == "x${MMCDEV}p5"; then
			echo -e "${GREEN}Found partitionset B rootfs partition ${NC}"
			return 2
		else
			echo -e "${RED}Found partitionset B linux partition but not the rootfs partition ${NC}"
			return 1
		fi
	else
		echo -e "${GREEN}Could not find partitionset B ${NC}"
		return 0
	fi
}

save_mac(){
	if ! test -e /sys/fsl_otp/HW_OCOTP_MAC1; then
		echo -e "${GREEN}allready updated to new Linux version, not storing mac address in OTP ${NC}"
		return
	fi
	ADDRESS=`cat /sys/fsl_otp/HW_OCOTP_MAC1`
	 
	if [ ${ADDRESS} == 0x25 ]; then
		echo "Mac address already set in OTP"
		return 0
	fi
	if ! test -e /mnt/boot/uboot.env; then
		echo -e "${RED}no environment found can't store MAC address${NC}"
		return 0
	fi
	 
	mac_addr=`fw_printenv ethaddr| cut -d= -f2`

	# get each byte of MAC address 0
	mac_byte0=`echo ${mac_addr} | cut -d: -f6`
	mac_byte1=`echo ${mac_addr} | cut -d: -f5`
	mac_byte2=`echo ${mac_addr} | cut -d: -f4`
	mac_byte3=`echo ${mac_addr} | cut -d: -f3`
	mac_byte4=`echo ${mac_addr} | cut -d: -f2`
	mac_byte5=`echo ${mac_addr} | cut -d: -f1`

	echo testing $mac_byte5
	if [ $mac_byte5 != 00 ] ; then
		echo Not a valid VBZ mac address
		exit 1
	fi

	echo testing $mac_byte4
	if [ $mac_byte4 != 25 ] ; then
		echo Not a valid VBZ mac address
		exit 1
	fi

	echo testing $mac_byte3
	if [ 0x$mac_byte3 -ne 0x6E ] ; then
		echo Not a valid VBZ mac address
		exit 1
	fi

	echo -e "${YELLOW} writing mac address ${mac_addr} to OTP${NC}"

	# mash it all together into 3 32-bit values
	MAC0=${mac_byte3}${mac_byte2}${mac_byte1}${mac_byte0}
	MAC1=${mac_byte4}
	 

	echo -n 0X$MAC0 > /sys/fsl_otp/HW_OCOTP_MAC0
	echo -n 0X$MAC1 > /sys/fsl_otp/HW_OCOTP_MAC1	

}

#compare dot separted versions returns:
#0 if equal
#1 if $1 > $2
#2 if $1 < $2
vercomp () {
    if [[ $1 == $2 ]]
    then
        return 0
    fi


	ORDERED=`printf "$1 \n $2" |sort -t '.' -k 1,1 -k 2,2 -k 3,3 -g`
	
	BIGGEST=`echo $ORDERED|awk '{print $2}'`
	
	if [[ ${BIGGEST} == $2 ]]
	then
		return 2
	else
		return 1
	fi
}


# all the magic takes place in the root directory

if test -e "$MMCDEV"; then
	echo -e "${GREEN}upgrading imx kernel${NC}"
else
	echo -e "${GREEN}upgrading fslc kernel${NC}"
	MMCDEV=/dev/mmcblk0
fi

ROOTFS_PARTITION=${MMCDEV}p5
ENVIRONMENT_PARTITION=${MMCDEV}p3
BOOTCHAIN=A

echo -e "Bootloader and rootfs update version ${VERSION}"
if test x`cat /proc/cpuinfo |grep model|cut -d' ' -f3` == "xARMv7"; then
	echo -e "${GREEN}This an Albireo G3${NC}"
else
	echo -e "${RED}This not an Albireo G3${NC}"
	exit 1
fi



if test x`cat /proc/cmdline |cut -d' ' -f2` == "xroot=${MMCDEV}p2"; then
	echo -e "${GREEN}We have booted from partition set A, updating partition set B${NC}"
else
	echo -e "${GREEN}We have booted from partition set B, updating partition set A${NC}"
	ROOTFS_PARTITION=${MMCDEV}p2		
	BOOTCHAIN=B
fi

mkdir -p /root/tmp
#Set the ftp parameters in to env. PoE Watchdog has just put this file here.. ;)
if test -e /root/tmp/serverparams.conf; then
	. /root/tmp/serverparams.conf
else
	if test -e /tmp/serverparams.conf; then
		. /tmp/serverparams.conf	
	else
		if test -e /mnt/tmp/serverparams.conf; then
			. /mnt/tmp/serverparams.conf	
		else
			echo -e "${RED}Could not find serverparams.conf${NC}"
			exit 1
		fi
	fi
fi
save_mac



test_partitions
RES=$?
if test ${RES} -eq 0; then
	echo -e "${GREEN}ready to partition the rest of the flash${NC}"
	#first create secondary Linux partition
	echo -e "n\np\n3\n66593\n67616\nt\n3\n83\nw"|fdisk ${MMCDEV}
	echo -e "n\ne\n67617\n215232\nt\n4\n85\nw"|fdisk ${MMCDEV}
	echo -e "n\n67649\n133184\nw"|fdisk ${MMCDEV}
	echo -e "n\n133217\n165984\nw"|fdisk ${MMCDEV}
	echo -e "n\n166017\n198784\nw"|fdisk ${MMCDEV}
	echo -e "n\n198817\n207008\nw"|fdisk ${MMCDEV}
	echo -e "n\n207041\n215232\nw"|fdisk ${MMCDEV}	
	#wait_user "Written partition table, reboot to make it effective"
	echo -e "${YELLOW}Partition table written. Albireo must reboot now in order to continue.${NC}"
	echo -e "${YELLOW}Wait 60 seconds AFTER rebooting and update the bootloader again (in PoE Watchdog).${NC}" 
	exit 1
else
	if test ${RES} -eq 2; then
		echo -e "${GREEN}partitions allready exists continue${NC}"
	else
		echo -e "${RED}unrecoverable error in partition table ${NC}"
		exit 1
	fi	
fi

#TODO only if not already in use
if ! test -e /mnt/env/uboot.env; then
	echo "Formatting Environment partition"	
	umount ${ENVIRONMENT_PARTITION} 2&>/dev/null
	echo -e "t\n3\n83\nw"|fdisk ${MMCDEV}
	mkfs.ext4 -O ^metadata_csum -E discard -F ${ENVIRONMENT_PARTITION}
	if test $? -eq 1; then
		echo -e "${RED}Could not format environment partition,reboot and try again${NC}"
		exit 1
	fi
fi

echo "Formatting Rootfs partition"
umount ${ROOTFS_PARTITION} 2&>/dev/null
mkfs.ext4 -E discard -F ${ROOTFS_PARTITION}
if test $? -eq 1; then
	echo -e "${RED}Could not format Rootfs partition,reboot and try again${NC}"
	exit 1
fi


if ! test -e /mnt/tmp/core-image-base-albireo.ext4.gz; then	
	echo -e "${YELLOW}Getting files from $tftphost ${NC}"	
	echo -e "${YELLOW}Large file transfers will take a while. You can follow the progress in Hanewin TFTP monitor"	
	echo -e "${YELLOW}All files should be downloaded, installing linux and rootfs to destination ${NC}"

	#We're running through PoE Watchdog, format and mount tmp directory from tmp partition
	umount ${MMCDEV}p6
	mkfs.ext4 -E discard -F ${MMCDEV}p6
	mkdir -p /mnt/tmp/
	mount ${MMCDEV}p6 /mnt/tmp
	cd /mnt/tmp

	#this script is called by the PoE watchdog, update everything
	#fetch "filename.txt" "https://github.com/ienovbz/AIP/raw/refs/heads/main/"	
	fetch "core-image-base-albireo.ext4.gz" "https://github.com/ienovbz/AIP/raw/refs/heads/main/"
	fetch "SPL-albireo" "https://github.com/ienovbz/AIP/raw/refs/heads/main/"
	fetch "u-boot-albireo.img" "https://github.com/ienovbz/AIP/raw/refs/heads/main/"
	fetch "uboot_version.txt" "https://github.com/ienovbz/AIP/raw/refs/heads/main/"

	fetch "pv" "https://github.com/ienovbz/AIP/raw/refs/heads/main/"
	fetch "resize2fs" "https://github.com/ienovbz/AIP/raw/refs/heads/main/"
	fetch "e2fsck" "https://github.com/ienovbz/AIP/raw/refs/heads/main/"
	fetch "checksums.md5" "https://github.com/ienovbz/AIP/raw/refs/heads/main/"
fi

cd /mnt/tmp
chmod +x pv	
chmod +x resize2fs	
chmod +x e2fsck

echo -e "${GREEN}Checking dowloaded files${NC}" 
md5sum -c checksums.md5
RES=$?	
if test ${RES} -ne 0; then
	echo -e "${RED}Error while testing the downloaded files, one or more files was not transfered properly, please try again${NC}" 
	echo -e "${GREEN}Erasing downloaded files${NC}" 
	rm -fr /mnt/tmp/*
	exit 1
fi


#wait_user "Install linux and rootfs to destination "
#tar -jxvf  core-image-base-albireo.tar.bz2 -C /mnt/rootfs
echo -e "${GREEN}Decompressing disk image${NC}" 
gunzip core-image-base-albireo.ext4.gz
RES=$?	
if test ${RES} -ne 0; then
	echo -e "${RED}Error while Decompressing disk image${NC}" 
	exit 1
fi


echo -e "${GREEN}Writing disk image to flash${NC}" 
./pv core-image-base-albireo.ext4 > ${ROOTFS_PARTITION}
RES=$?	
if test ${RES} -ne 0; then
	echo -e "${RED}Error while writing disk image${NC}" 
	exit 1
fi


echo -e "${GREEN}Checking filesystem${NC}" 
./e2fsck -p ${ROOTFS_PARTITION}
RES=$?	
if test ${RES} -ne 0; then
	echo -e "${RED}Error while testing destination filesystem${NC}" 
	exit 1
fi


echo -e "${GREEN}Resizing filesystem to partition size${NC}" 
./resize2fs ${ROOTFS_PARTITION} 1024M
RES=$?	
if test ${RES} -ne 0; then
	echo -e "${RED}Error while expanding filesystem${NC}" 
	exit 1
fi

mkdir -p /mnt/rootfs
mount ${ROOTFS_PARTITION} /mnt/rootfs
RES=$?
if test ${RES} -ne 0; then
	echo -e "${RED}Error while mounting filesystem${NC}" 
	exit 1
fi
mkdir -p /mnt/rootfs/root/configs/
cp /etc/wpa_supplicant.conf /mnt/rootfs/root/configs/
RES=$?
if test ${RES} -ne 0; then
	echo -e "${RED}Error while copying WiFi configuration${NC}" 
	exit 1
fi
cp /etc/wpa_supplicant.conf /mnt/rootfs/etc/
RES=$?
if test ${RES} -ne 0; then
	echo -e "${RED}Error while copying WiFi configuration${NC}" 
	exit 1
fi



UPDATE=true
current_bl=`fw_printenv -n version`
RES=$?	
if test ${RES} -ne 0; then
	echo -e "${YELLOW}Error while reading bootloader version, updating bootloader just to be sure${NC}" 
	UPDATE=true
else		
	new_bl=`cat ./uboot_version.txt|awk '{print $2}'`

	vercomp  $current_bl $new_bl
	case $? in
	    0) UPDATE=false;;
	    1) UPDATE=false;;
	    2) UPDATE=true;;
	esac
fi


if test $UPDATE == "false"; then
	echo -e "${GREEN}The current bootloader is $current_bl the new bootloader is $new_bl. Not updating bootloader${NC}"
	fw_setenv bootcount 0
	touch /mnt/boot/switch	
	rm /mnt/boot/upgrade

else
	echo -e "${GREEN}The current bootloader is $current_bl the new bootloader is $new_bl. Updating bootloader${NC}"
	#removing write protect lock from bootloader
	if test -e /sys/block/mmcblk0boot1/force_ro; then
		echo 0 > /sys/block/mmcblk0boot1/force_ro
	else
		echo 0 > /sys/block/mmcblk3boot1/force_ro
	fi

	#writing SPL part of the bootloader
	dd if=SPL-albireo of=${MMCDEV}boot1 bs=512 seek=2
	if test $? -eq 1; then
		echo -e "${RED}Could not write SPL${NC}"
		exit 1
	fi
	
	#writing U-boot image of the bootloader
	dd if=u-boot-albireo.img of=${MMCDEV}boot1 bs=512 seek=138
	if test $? -eq 1; then
		echo -e "${RED}Could not write u-boot${NC}"
		exit 1
	fi
	sync

	#setting write protect lock for the bootloader
	if test -e /sys/block/mmcblk0boot1/force_ro; then
		echo 1 > /sys/block/mmcblk0boot1/force_ro
	else
		echo 1 > /sys/block/mmcblk3boot1/force_ro
	fi
	
	#Testing if the correct boot partition for the bootloader is selected
	boot_partition=`mmc extcsd read ${MMCDEV}|grep "Boot Partition"|awk '{print $3}'`
	if test $boot_partition -ne 2; then
		echo -e "${GREEN}The boot_partition is set to $boot_partition, swithing it to 2${NC}" 
		mmc bootpart enable 2 1 ${MMCDEV}
		RES=$?	
		if test ${RES} -eq 0; then
			echo -e "${RED}Error while swithing boot partition${NC}"
		fi
		boot_partition=`mmc extcsd read ${MMCDEV}|grep "Boot Partition"|awk '{print $3}'`
		if test $boot_partition -ne 2; then
			echo -e "${YELLOW}The boot_partition is not set to 2, retrying to force switch${NC}" 
			mmc bootpart enable 2 1 ${MMCDEV}
			RES=$?	
			if test ${RES} -eq 0; then
				echo -e "${RED}Error while switching boot partition${NC}"
				exit 1
			fi
			boot_partition=`mmc extcsd read ${MMCDEV}|grep "Boot Partition"|awk '{print $3}'`
			if test $boot_partition -ne 2; then
				echo -e "${RED}Error while switching boot partition${NC}"
				exit 1
			fi
		fi	
	fi
	rm -f /mnt/env/uboot.env
	rm -f /mnt/boot/uboot.env
	if [ ${BOOTCHAIN} == A ] ; then
		touch /mnt/boot/switch	
		rm  /mnt/boot/upgrade	
	else
		touch /mnt/boot/upgrade	
		rm  /mnt/boot/switch	
	fi
fi
rm -fr /mnt/tmp/*
cd /		
umount ${MMCDEV}p6
echo -e "${GREEN}Update succesful, The system will now reboot ${NC}"
reboot
