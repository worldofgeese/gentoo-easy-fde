#!/bin/bash
set -e
#This code is licensed under (CC BY-SA 4.0)
#This script is created to automate the process for the Full-Disk-Encryption of the root drive as well of the /boot (GRUB) with LUKS

################################################################################
# Help
Help()
{
   echo "ToDo"
}
################################################################################
# main

while getopts ":h" option; do
  case $option in
    h)
      Help
      exit;;
   esac
done

#default variables
encrypt_boot="FALSE"
default_boot_iter_time="42"       #Iteration time in ms for the encrypted /boot partition, will be much slower due bad implementation in GRUB
default_swap_size="64Gb"          #Swap size
default_root_size="100%FREE"			#100% of the available disk space will be used by LCM
keyfile_to_boot="FALSE"
default_boot_size="1024M"         #size of /boot
default_grub_size="128M"           #size of bios boot partition
default_efi_size="256M"           #size of EFI partition
crypt_pw=""

#check if script is run by root
if (( $EUID != 0 )); then
    echo "Please run the script as root"
		echo "use sudo -i"
    exit
fi

#check if the live system booted from EFI mode
echo "Please check if the live system booted from EFI mode!"
echo "Output should look something like this:"
echo "efivarfs on /sys/firmware/efi/efivars type efivarfs (rw,nosuid,nodev,noexec,relatime)"
echo ""
mount | grep efivars

while true
do
	read -r -p "Is the system in EFI mode? [Y/n] " input
	case $input in
		[yY][eE][sS]|[yY]|"")
		break
		;;
		[nN][oO]|[nN])
		echo "Please try again after booted with EFI mode."
		exit
		;;
		*)
		echo "Invalid input..."
		;;
	esac
done

while true
do
	echo "If Secure Boot is available, an encrypted /boot partition will not gain much security."
	read -r -p "Do you want to encrypt the /boot partition? [y/N] " input
	case $input in
		[yY][eE][sS]|[yY])
		echo "/boot will be encrypted."
		encrypt_boot="TRUE"
		break
		;;
		[nN][oO]|[nN]|"")
		echo "/boot will be NOT encrypted."
		encrypt_boot="FALSE"
		break
		;;
		*)
		echo "Invalid input..."
		;;
	esac
done

#choose the boot drive
lsblk | awk 'NR==1'
lsblk | grep disk

choose_bootdisk_grep=( $(lsblk -o Name,TYPE | grep disk) )
echo "${#choose_bootdisk_grep[@]}"
for (( i=0; i<${#choose_bootdisk_grep[@]}; i++ ))
do
  if (( $i % 2))
    then
      continue
    else
      choose_bootdisk+=( ${choose_bootdisk_grep[i]} )
  fi
done
select opt_boot in "Cancel" "${choose_bootdisk[@]}"; do
  if (( $REPLY > ${#choose_bootdisk[@]} + 1 ))
    then
      echo "Invalid Option!"
    else
			if (( $REPLY == 1 ))
				then
					echo "You canceled the script."
					exit
				else
      		echo "Selected boot-drive: $opt_boot"
      		break
			fi
  fi
done

export DEV="/dev/"$opt_boot
export DM=$opt_boot
export DM="${DM}$( if [[ "$DM" =~ "nvme" ]]; then echo "p"; fi )"

sgdisk --print $DEV

while true
do
	read -r -p "Deleting all partitions on $DEV [Y/n] " input
	case $input in
		[yY][eE][sS]|[yY]|"")
		echo "Deleting all partitions..."
		#deleting all partitions
		sgdisk --zap-all $DEV
		#making partitions
		sgdisk --new=1:0:+$default_boot_size $DEV
		sgdisk --new=2:0:+$default_grub_size $DEV
		sgdisk --new=3:0:+$default_efi_size $DEV
		sgdisk --new=5:0:0 $DEV
		sgdisk --typecode=1:8301 --typecode=2:ef02 --typecode=3:ef00 --typecode=5:8301 $DEV
		sgdisk --change-name=1:/boot --change-name=2:GRUB --change-name=3:EFI-SP --change-name=5:rootfs $DEV
		sgdisk --hybrid 1:2:3 $DEV
		break
		;;
		[nN][oO]|[nN])
		echo "Use GParted to create your partitions."
		read -p "Press enter to continue after you created the partitions."
		break
		;;
		*)
		echo "Invalid input..."
		;;
	esac
done

while true
do
	sgdisk --print $DEV
	read -r -p "All partitions correct? [Y/n] " input
	case $input in
		[yY][eE][sS]|[yY]|"")
		break
		;;
		[nN][oO]|[nN])
		read -p "Press enter to continue after you created the partitions."
		;;
		*)
		echo "Invalid input..."
		;;
	esac
done

if [[ $encrypt_boot == "TRUE" ]]
	then
		echo "Due to the bad implementation of encryption in GRUB, a low iter-time should be set, so it doesn't take for ages to boot from GRUB."
		echo "Normal iter-time is 2000ms."
		echo "GRUB reduced default iter-time is 42ms."
		while true
		do
		read -r -p "Press enter for the default 42 (ms) or specify a different time: " input
			case $input in
				"")
				break
				;;
				*)
					if ! [[ "$input" =~ ^[0-9]+$ ]]
		    		then
		        	echo "Please enter only numbers!"
						else
							default_boot_iter_time=$input
							break
					fi
				;;
			esac
		done
		echo "The boot Partition will be now encrypted. Pleas bear in mind that the boot encryption may be weaker as the /root encryption."
		echo "So it may be good practice to choose a different passphrase for each encrypted partition."
		read -r -s -p "Choose a password for /boot: " crypt_pw
		echo -n $crypt_pw | cryptsetup luksFormat --type=luks1 --iter-time $default_boot_iter_time /dev/${DM}1 -d -
		echo -n $crypt_pw | cryptsetup open /dev/${DM}1 LUKS_BOOT -d -
fi

read -r -s -p "Choose a password for /dev/${DM}5 (/root): " crypt_pw
echo -n $crypt_pw | cryptsetup luksFormat /dev/${DM}5 -d -
echo -n $crypt_pw | cryptsetup open /dev/${DM}5 ${DM}5_crypt -d -

if [[ $encrypt_boot == "TRUE" ]]
	then
		mkfs.ext4 -L boot /dev/mapper/LUKS_BOOT
	else
		mkfs.ext4 -L boot /dev/${DM}1
fi

mkfs.vfat -F 32 -n EFI-SP /dev/${DM}3

pvcreate /dev/mapper/${DM}5_crypt
vgcreate vg0 /dev/mapper/${DM}5_crypt
while true
do
read -r -p "How big should the swap be? Default is 12Gb: " input
	case $input in
		"")
		;;
		*)
			default_swap_size=$input
		;;
	esac
	if lvcreate -L $default_swap_size -n swap vg0
		then
			break
		else
			echo "Please try again select a swap size."
	fi
done

while true
do
read -r -p "How big should the rest be? Default is 100%FREE of the available space: " input
	case $input in
		"")
		;;
		*)
			default_root_size=$input
		;;
	esac
	if lvcreate -l ${default_root_size} -n root vg0
		then
			break
		else
			echo "Please try again select a root size."
	fi
done

#read -p "After installation has finished press enter to continue"
wait $pid

mkfs.ext4 /dev/mapper/vg0-root
mkswap /dev/mapper/vg0-swap
swapon -v /dev/mapper/vg0-swap
#mkdir /mnt/gentoo
#mount /dev/mapper/${DM}5-root /mnt/gentoo
#cd /mnt/gentoo
#pacman -Sy wget
#wget https://bouncer.gentoo.org/fetch/root/all/releases/amd64/autobuilds/20230326T170209Z/stage3-amd64-desktop-systemd-20230326T170209Z.tar.xz
#tar xvJpf stage3-amd64-desktop-systemd-20220102T170545Z.tar.xz --xattrs --numeric-owner
#cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
#mount --types proc /proc /mnt/gentoo/proc
#mount --rbind /sys /mnt/gentoo/sys
#mount --make-rslave /mnt/gentoo/sys
#mount --rbind /dev /mnt/gentoo/dev
#mount --make-rslave /mnt/gentoo/dev
#mount --bind /run /mnt/gentoo/run
#mount --make-slave /mnt/gentoo/run
#test -L /dev/shm && rm /dev/shm && mkdir /dev/shm 
#mount -t tmpfs -o nosuid,nodev,noexec shm /dev/shm 
#chmod 1777 /dev/shm 
#chroot /mnt/gentoo /bin/bash
#source /etc/profile 
#export PS1="(chroot) ${PS1}"
#mount /dev/nvme0n1p1 /boot
#emerge-webrsync
#eselect profile set 11 #for a merged-usr Plasma desktop profile https://groups.google.com/g/linux.gentoo.dev/c/xqZYsMmCoME/m/XlplgAnTAwAJ
#ln -sf ../usr/share/zoneinfo/Europe/Copenhagen /etc/localtime
#nano -w /etc/locale.gen
#eselect locale set 4 # set locale to en_US
#env-update && source /etc/profile && export PS1="(chroot) ${PS1}"

echo "Finished successfully. You can now reboot your system."
exit
