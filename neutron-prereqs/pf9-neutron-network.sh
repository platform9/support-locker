#!/bin/bash

# Bash Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'

## Validate VLAN ID range
# Validates whether supplied input (integer) is within the valid VLAN ID range
# 2 - 4095
# $1: int
function validVlan() {
	[[ $1 =~ ^[0-9]{1,4}$ ]] && [[ $1 -gt 1 && $1 -lt 4096 ]]
}

# Validate input is an integer
function validInt() {
	[[ $1 =~ ^-?[0-9]+$ ]]
}

function validIp() {
	grep -E -q '^(25[0-4]|2[0-4][0-9]|1[0-9][0-9]|[1]?[1-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$' <<< "$1"
}

function validNetMask() {
	grep -E -q '^(254|252|248|240|224|192|128)\.0\.0\.0|255\.(254|252|248|240|224|192|128|0)\.0\.0|255\.255\.(254|252|248|240|224|192|128|0)\.0|255\.255\.255\.(254|252|248|240|224|192|128|0)' <<< "$1"
}

## Validate interface MTU
# Validates whether supplied input (integer) is within the valid MTU range
# 1600 - 9000
# $1: int
function validMtu() {
	[[ $1 =~ ^[0-9]{1,4}$ ]] && [[ $1 -ge 1600 && $1 -le 9000 ]]
}

function validYesNo() {
	[[ $1 =~ ^[YyNn]$ ]]
}

function getValidInput() {
	local errMessage
	local prompt

	if [[ $2 == 'yesNo' ]]; then
		prompt="${1} (yes/no)? "
	else
		prompt="${1}"
	fi

	while true; do
		read -p "$prompt" getInput

		if [ "$2" == "vlan" ]; then
			errMessage="Please enter a valid VLAN between 1-4095!"
			validVlan $getInput
		elif [ "$2" == "ipAddress" ]; then
			errMessage="Please enter a valid IP Address!"
			validIp $getInput
		elif [ "$2" == "netMask" ]; then
			errMessage="Please enter a valid Subnet Mask!"
			validNetMask $getInput
		elif [ "$2" == "yesNo" ]; then
			getInput=$(echo ${getInput:0:1} | awk '{ print tolower($0) }')
			errMessage="Please answer yes or no."
			validYesNo $getInput
		elif [ "$2" == "mtu" ]; then
			errMessage="Please enter a valid MTU between 1600-9000!"
			validMtu $getInput
		elif [ "$2" == "freeText" ]; then
			RC=0
		else
			printf "${RED}!!! Invalid Paramaters sent to getValidInput Fuction !!!${NC}\n" >&2
		fi

		# Check return code for last command ran
		if [[ $? -eq 0 ]]; then
		 break
		else
		 printf "${RED}Invalid Input. $errMessage${NC}\n" >&2
		fi
	done

	echo $getInput
}

# Add line to file if it does not exist
function putLineInFile() {
	if ! grep -Fxq "$1" $2; then
		echo "$1" >> $2
	fi
}

function whichOS() {
	if [ -f /etc/redhat-release ]; then
		echo 'Enterprise Linux'
	elif [ -f /etc/lsb-release ]; then
		echo 'Ubuntu'
	else
		echo 'Unknown Operating System'
	fi
}

function printBanner() {
	printf '\033[1;34m       __________\033[0m.__          __    _____                    \033[1;34m________         \n' >&2
	printf '\033[1;34m       \______   \\\033[0m  | _____ _/  |__/ ____\___________  _____\033[1;34m/   __   \        \n' >&2
	printf '\033[1;34m        |     ___/\033[0m  | \__  \\\   __\   __\/  _ \_  __ \/     \033[1;34m\____    /        \n' >&2
	printf '\033[1;34m        |    |\033[0m   |  |__/ __ \|  |  |  | (  <_> )  | \/  Y Y  \\\033[1;34m /    /         \n' >&2
	printf '\033[1;34m        |____|\033[0m   |____(______/__|  |__|  \____/|__|  |__|_|__/\033[1;34m/____/          \n' >&2
	printf '\033[1;34m _______\033[0m          __                       __     \033[1;34m___________\033[0m           .__   \n' >&2
	printf '\033[1;34m \      \\\033[0m   _____/  |___  _  _____________|  | __ \033[1;34m\__    ___/\033[0m___   ____ |  |  \n' >&2
	printf '\033[1;34m /   |   \\\033[0m / __ \   __\ \/ \/ /  _ \_  __ \  |/ / \033[1;34m  |    |\033[0m /  _ \ /  _ \|  |  \n' >&2
	printf '\033[1;34m/    |    \\\033[0m  ___/|  |  \     (  <_> )  | \/    <  \033[1;34m  |    |\033[0m(  <_> |  <_> )  |__\n' >&2
	printf '\033[1;34m\____|____/\033[0m\_____>__|   \/\_/ \____/|__|  |__|__\  \033[1;34m |____|\033[0m \____/ \____/|____/\n' >&2
}
$(printBanner)

OS=$(whichOS)

configNetworking=$(getValidInput "Would you like for this script to walk you through configuring networking" "yesNo")
bondingInts=()

if [ $configNetworking == "y" ]; then
	if [[ ! -d /sys/class/net ]]; then
		printf "${RED}No network interfaces found!\n"
		exit 1
	fi

	phyInts=($(ls -l /sys/class/net/ | grep -i 'pci' | awk '{print $9}'))

	# Exit if no interfaces were found
	if [[ ${#phyInts[@]} -eq 0 ]]; then
		printf "${RED}No network interfaces found!\n"
		exit 1
	fi

	if [ ${#phyInts[@]} -eq 1 ]; then
		phyInt=${phyInts[0]}
	else

		printf "${GREEN}Multiple physical interfaces were detected${NC}\n"
		configureBonding=$(getValidInput "Would you like to configure bonding" "yesNo")
		if [ $configureBonding == "y" ]; then
			bondingModes=("0) balance-rr" "1) active-backup" "2) balance-xor" "3) broadcast" "4) 802.3ad" "5) balance-tlb" "6) balance-alb")
			while true; do
				for i in "${bondingModes[@]}"; do
					echo "$i"
				done
				read -p "Choose the bonding mode you would like to use: " pickBondingMode

				validInt $pickBondingMode

				if [ $? -ne 0 ] || [ $pickBondingMode -gt 6 ] || [ $pickBondingMode -lt 0 ]; then
					printf "${RED}Invalid Input! Please pick a bonding mode from the list.${NC}\n"
				else
					bondingMode=$pickBondingMode
					break
				fi
			done
			while true; do
				n=0
				for i in "${phyInts[@]}"; do
					((n++))
					echo "$n) $i"
				done
				read -p "Pick a physical interface to add to the bond: " pickPhyInt

				validInt $pickPhyInt

				if [ $? -ne 0 ] || [ $pickPhyInt -gt ${#phyInts[@]} ] || [ $pickPhyInt -lt 1 ]; then
					printf "${RED}Invalid Input! Please pick an interface from the list.${NC}\n"
				else
					pickBondSlave=${phyInts[$pickPhyInt-1]}
					bondingInts=("${bondingInts[@]}" $pickBondSlave)
					# Bash magic to remove object from array
					phyInts=($(for phyInt in ${phyInts[@]}; do [ "$phyInt" != "$pickBondSlave" ] && echo $phyInt; done ))
					printf "${GREEN}$pickBondSlave added to the bond!${NC}\n"
					echo "Ints in Bond:  ${#bondingInts[@]}"
					echo "Ints out of Bond:  ${#phyInts[@]}"

					if [ ${#bondingInts[@]} -gt 1 ] && [ ${#bondingInts[@]} -lt 4 ] && [ ${#phyInts[@]} != 0 ]; then
						addAnother=$(getValidInput "Would you like to add another interface" "yesNo")
						if [ $addAnother == "n" ]; then
							break
						fi
					elif [ ${#phyInts[@]} == 0 ]; then
						break
					elif [ ${#bondingInts[@]} == 4 ]; then
						break
					fi
				fi
			done
			phyInt='bond0'
			# I need to be adding bonds to an array in the future in case they want to configure more than one.
		else
			while true; do
				n=0
				for i in "${phyInts[@]}"; do
					((n++))
					echo "$n) $i"
				done
				read -p "Select host management interface #: " pickPhyInt

				# Validate input
				validInt $pickPhyInt

				if [[ ! $? -eq 0 ]] || [[ $pickPhyInt -gt ${#phyInts[@]} ]] || [[ $pickPhyInt -lt 1 ]]; then
					printf "${RED}Invalid Input! Please pick an interface from the list.${NC}\n"
				else
					phyInt=${phyInts[$pickPhyInt-1]}
					break
				fi
			done
		fi
	fi
	printf "${GREEN}Using Interface: $phyInt${NC}\n"

	# Management Interface Variables
	mgmtVlan=$(getValidInput "Management VLAN ID: " "vlan")
	mgmtIp=$(getValidInput "Management IP Address: " "ipAddress")
	mgmtSubnet=$(getValidInput "Management Subnet Mask: " "netMask")
	mgmtGateway=$(getValidInput "Management Gateway: " "ipAddress")
	mgmtDns1=$(getValidInput "DNS Server 1: " "ipAddress")
	mgmtDns2=$(getValidInput "DNS Server 2: " "ipAddress")
	mgmtSearchDomain=$(getValidInput "DNS Search Domain: " "freeText")

	# External Interface Variables
	extVlan=$(getValidInput "External VLAN ID: " "vlan")

	# VXLAN or GRE?
	tunnelTrue=$(getValidInput "Do you plan on using VXLAN, or GRE tunneling" "yesNo")

	# VXLAN Variables
	if [ "$tunnelTrue" == "y" ]; then
		printf "${YELLOW}\n# Tunneling requires a minimum MTU of 1600 bytes.\n"
		printf "# Ensure your switches are configured to handle this MTU${NC}\n"
		mtuSize=$(getValidInput "Please enter an MTU size between 1600-9000: " "mtu")

		separateTunnel=$(getValidInput "Are you using a separate VLAN for tunneling" "yesNo")
		if [ "$separateTunnel" == "y" ]; then
			tunnelVlanId=$(getValidInput "Tunnel VLAN ID: " "vlan")
			tunnelIp=$(getValidInput "Tunnel IP Address: " "ipAddress")
			tunnelSubnet=$(getValidInput "Tunnel Subnet Mask: " "netMask")
		fi
	fi

	vlanTrue=$(getValidInput "Are you using VLAN segmentation, or planning to have provider networks" "yesNo")

	printf "${GREEN}You have cooperated nicely by answering the questions asked of you!${NC}\n\n"
	printf "${CYAN}"
	printf "Physical Interface: $phyInt\n"
	if [ "$configureBonding" == "y" ]; then
		printf "Configure Bonding? $configureBonding\n"
		printf "Bonding Mode: $bondingMode\n"
		i=0
		for slaveInt in "${bondingInts[@]}"; do
			((i++))
			printf "Slave 0$i:  $slaveInt\n"
		done
	fi
	cat <<-EOF
	Management VLAN ID: $mgmtVlan
	Management IP Address: $mgmtIp
	Management Subnet Mask: $mgmtSubnet
	Management Gateway: $mgmtGateway
	DNS Server 1: $mgmtDns1
	DNS Server 2: $mgmtDns2
	DNS Search Domain: $mgmtSearchDomain
	External VLAN ID: $extVlan
	Are you using a separate VLAN for tunneling? $tunnelTrue
	EOF
	if [ "$separateTunnel" == "y" ]; then
		cat <<-EOF
		Tunnel VLAN ID: $tunnelVlanId
		Tunnel IP Address: $tunnelIp
		Tunnel Subnet Mask: $tunnelSubnet
		Please choose an MTU size between 1600-9000: $mtuSize
		EOF
	fi
	printf "Are you using VLAN segmentation? $vlanTrue\n"
	printf "${NC}\n"
	finalAnswer=$(getValidInput "Are these your final answers" "yesNo")
	if [ "$finalAnswer" == "n" ]; then
		printf "\n${RED}!!! We are aborting, No changes have been made !!!${NC}\n"
		exit
	fi
fi

hostProfileScriptName='./hostProfile.sh'

head -115 $0 > $hostProfileScriptName
echo "configNetworking=${configNetworking}" >> $hostProfileScriptName
if [ $configNetworking == "y" ]; then
	echo 'mgmtIp=$(getValidInput "Management IP Address: " "ipAddress")' >> $hostProfileScriptName
	cat <<-EOF >> $hostProfileScriptName
	phyInt=$phyInt
	mgmtVlan=$mgmtVlan
	mgmtSubnet=$mgmtSubnet
	mgmtGateway=$mgmtGateway
	mgmtDns1=$mgmtDns1
	mgmtDns2=$mgmtDns2
	mgmtSearchDomain=$mgmtSearchDomain
	extVlan=$extVlan
	tunnelTrue=$tunnelTrue
	separateTunnel=$separateTunnel
	EOF
	if [ "$separateTunnel" == "y" ]; then
		echo 'tunnelIp=$(getValidInput "Tunnel IP Address: " "ipAddress")' >> $hostProfileScriptName
		echo 'tunnelVlanId='$tunnelVlanId >> $hostProfileScriptName
		echo 'tunnelSubnet='$tunnelSubnet >> $hostProfileScriptName
	fi
	if [ "$tunnelTrue" == "y" ]; then
		echo 'mtuSize='$mtuSize >> $hostProfileScriptName
	fi
fi
tail -338 $0 >> $hostProfileScriptName

echo "Installing Neutron prerequisites..."

if [[ -n $OS && $OS == 'Enterprise Linux' ]]; then

	# Disable SELinux
	printf "\n${RED}!!! We are setting SELINUX to permisive !!!\n!!! This is required for Software Definded Networks !!!${NC}\n"
	sed -i s/SELINUX=enforcing/SELINUX=permissive/g /etc/selinux/config
	setenforce 0

	# Disable firewalld
	printf "\n${RED}!!! We are disabling FIREWALLD !!!\n!!! Neutron and KVM will use IPTABLES directly !!!${NC}\n"
	systemctl disable firewalld
	systemctl stop firewalld

	# Load modules needed for Neutron
	modprobe bridge
	modprobe 8021q
	modprobe bonding

	# Setup sysctl vairables
	putLineInFile '# Needed for neutron networking' '/etc/sysctl.conf'
	putLineInFile 'net.ipv4.conf.all.rp_filter=0' '/etc/sysctl.conf'
	putLineInFile 'net.ipv4.conf.default.rp_filter=0' '/etc/sysctl.conf'
	putLineInFile 'net.bridge.bridge-nf-call-iptables=1' '/etc/sysctl.conf'
	putLineInFile 'net.ipv4.ip_forward=1' '/etc/sysctl.conf'

	# Reload sysctl
	sysctl -q -p

	# Add PF9 Yum Repo
	yum -q -y install https://s3-us-west-1.amazonaws.com/platform9-neutron/noarch/platform9-neutron-repo-1-0.noarch.rpm

	# Install Open vSwitch
	yum -q -y install --disablerepo="*" --enablerepo="platform9-neutron-el7-repo" openvswitch

	# Enable and start the openvswitch service
	systemctl enable openvswitch
	systemctl start openvswitch
	if [ $configNetworking == "y" ]; then
		# Backup all old network config files
		cp /etc/sysconfig/network-scripts/ifcfg-* ~/
		# Create Sub-Interface for Management
		cat <<-EOF > /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan
		DEVICE=$phyInt.$mgmtVlan
		ONBOOT=yes
		BOOTPROTO=none
		TYPE=Vlan
		VLAN=yes
		IPADDR=$mgmtIp
		NETMASK=$mgmtSubnet
		GATEWAY=$mgmtGateway
		DNS1=$mgmtDns1
		DNS2=$mgmtDns2
		EOF
		# Add larger MTU to the physical interface
		if [[ "$tunnelTrue" == "y" ]]; then
			echo MTU=$mtuSize >> /etc/sysconfig/network-scripts/ifcfg-$phyInt
			if [[ "$separateTunnel" == "n" ]]; then
				echo MTU=$mtuSize >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan
			fi
		fi

		# Setup External Network
		## Create Bridge for External Network
		cat <<-EOF > /etc/sysconfig/network-scripts/ifcfg-br-ext
		DEVICE=br-ext
		BOOTPROTO=none
		ONBOOT=yes
		TYPE=OVSBridge
		DEVICETYPE=ovs
		EOF

		## Create and Slave External Sub-Interface to External Bridge
		cat <<-EOF > /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan
		DEVICE=$phyInt.$extVlan
		ONBOOT=yes
		TYPE=OVSPort
		VLAN=yes
		DEVICETYPE=ovs
		OVS_BRIDGE=br-ext
		EOF

		## Slave Physical Interface to VLAN Bridge
		cat <<-EOF > /etc/sysconfig/network-scripts/ifcfg-$phyInt
		DEVICE=$phyInt
		BOOTPROTO=none
		ONBOOT=yes
		EOF

		if [ "$configureBonding" == "y" ]; then
			cat <<-EOF > /etc/sysconfig/network-scripts/ifcfg-$phyInt
			BONDING_MASTER=yes >> /etc/sysconfig/network-scripts/ifcfg-$phyInt
			BONDING_OPTS="mode=$bondingMode"
			EOF
			if [ "$vlanTrue" != "y" ]; then
				echo TYPE=Bond >> /etc/sysconfig/network-scripts/ifcfg-$phyInt
			fi
			for slaveInt in "${bondingInts[@]}"; do
				cat <<-EOF > /etc/sysconfig/network-scripts/ifcfg-$slaveInt
				DEVICE=$slaveInt
				BOOTPROTO=none
				ONBOOT=yes
				TYPE=Ethernet
				MASTER=bond0
				SLAVE=yes
				EOF
			done
		fi

		if [ "$vlanTrue" == "y" ]; then
			## Setup Bridge for VLAN Trunk
			cat <<-EOF > /etc/sysconfig/network-scripts/ifcfg-br-vlan
			DEVICE=br-vlan
			BOOTPROTO=none
			ONBOOT=yes
			TYPE=OVSBridge
			DEVICETYPE=ovs
			EOF

			cat <<-EOF >> /etc/sysconfig/network-scripts/ifcfg-$phyInt
			OVS_BRIDGE=br-vlan
			TYPE=OVSPort
			DEVICETYPE=ovs
			EOF
		fi

		if [ "$separateTunnel" == "y" ]; then
			# Create Sub-Interface for tunneling
			cat <<-EOF > /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlanId
			DEVICE=$phyInt.$tunnelVlanId
			IPADDR=$tunnelIp
			NETMASK=$tunnelSubnet
			ONBOOT=yes
			BOOTPROTO=none
			VLAN=yes
			TYPE=Vlan
			MTU=$mtuSize
			EOF
		fi

		printf "\n${GREEN}Network config complete!${NC}"
		printf "\n${YELLOW}Please review the following config files:${NC}\n"

		printf "\n${GREEN}Management Interface: /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan${NC}\n"
		printf "${YELLOW}"
		cat /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan
		printf "${NC}"

		printf "\n${GREEN}External Bridge: /etc/sysconfig/network-scripts/ifcfg-br-ext${NC}\n"
		printf "${YELLOW}"
		cat /etc/sysconfig/network-scripts/ifcfg-br-ext
		printf "${NC}"

		printf "\n${GREEN}External Interface: /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan${NC}\n"
		printf "${YELLOW}"
		cat /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan
		printf "${NC}"

		if [ "$vlanTrue" == "y" ]; then
			printf "\n${GREEN}LAN Bridge: /etc/sysconfig/network-scripts/ifcfg-br-vlan${NC}\n"
			printf "${YELLOW}"
			cat /etc/sysconfig/network-scripts/ifcfg-br-vlan
			printf "${NC}"
		fi

		if [ "$separateTunnel" == "y" ]; then
			printf "\n${GREEN}VXLAN Interface: /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlanId${NC}\n"
			printf "${YELLOW}"
			cat /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlanId
			printf "${NC}"
		fi

		printf "${RED}\n"
		read -p "!!! Only if all of the above look correct, type yes to restart networking !!! " yn
		printf "${NC}"
		case $yn in
			[Yy]* ) systemctl restart network.service;;
		esac
	fi
	printf "\n${GREEN}DONE!!!${NC}\n"
elif [[ -n $OS && $OS == 'Ubuntu' ]]; then
	# Install the VLAN package
	apt-get -y -q=2 install vlan ifenslave

	# Add required modules
	modprobe br_netfilter
	modprobe 8021q
	modprobe bonding

	# Make modules persistent
	putLineInFile br_netfilter '/etc/modules'
	putLineInFile 8021q '/etc/modules'
	putLineInFile bonding '/etc/modules'

	# Setup sysctl vairables
	putLineInFile '# Needed for neutron networking' '/etc/sysctl.conf'
	putLineInFile 'net.ipv4.conf.all.rp_filter=0' '/etc/sysctl.conf'
	putLineInFile 'net.ipv4.conf.default.rp_filter=0' '/etc/sysctl.conf'
	putLineInFile 'net.bridge.bridge-nf-call-iptables=1' '/etc/sysctl.conf'
	putLineInFile 'net.ipv4.ip_forward=1' '/etc/sysctl.conf'

	# Reload sysctl
	sysctl -q -p

	# Add PF9 APT source repository
	echo 'deb http://platform9-neutron.s3-website-us-west-1.amazonaws.com ubuntu/' > /etc/apt/sources.list.d/platform9-neutron-ubuntu.list

	# Update APT Source
	apt-get update -q=2

	# Install Open vSwitch
	apt-get -y --force-yes -q=2 install openvswitch-switch

	if [ $configNetworking == "y" ]; then
		# Backup old interfaces file
		cp /etc/network/interfaces ~/

		# Create interfaces header
		cat <<-EOF > /etc/network/interfaces
		# This file describes the network interfaces available on your system
		# and how to activate them. For more information, see interfaces(5).

		# The loopback network interface
		auto lo
		iface lo inet loopback

		# Management sub-interface
		auto $phyInt.$mgmtVlan
		iface $phyInt.$mgmtVlan inet static
		  address $mgmtIp
		  netmask $mgmtSubnet
		  gateway $mgmtGateway
		  dns-nameservers $mgmtDns1 $mgmtDns2
		  dns-search $mgmtSearchDomain
		EOF
		if [ "$tunnelTrue" == "y" ]; then
			if [ "$separateTunnel" == "n" ]; then
				# Add larger MTU to the physical interface
				cat <<-EOF >> /etc/network/interfaces
				  post-up ifconfig $phyInt mtu $mtuSize
				  post-up ifconfig $phyInt.$mgmtVlan mtu $mtuSize
				EOF
			elif [ "$separateTunnel" == "y" ]; then
				cat <<-EOF >> /etc/network/interfaces

				# Tunneling sub-interface
				auto $phyInt.$tunnelVlanId
				iface $phyInt.$tunnelVlanId inet static
				  address $tunnelIp
				  netmask $tunnelSubnet
				  post-up ifconfig $phyInt mtu $mtuSize
				  post-up ifconfig $phyInt.$tunnelVlanId mtu $mtuSize
				EOF
			fi
		fi
		printf "\n" >> /etc/network/interfaces

		## Create sub-interface for external network
		cat <<-EOF >> /etc/network/interfaces
		# External Sub-Interface
		allow-br-ext $phyInt.$extVlan
		iface $phyInt.$extVlan inet manual
		  ovs_type OVSPort
		  ovs_bridge br-ext

		EOF

		## Create External Bridge
		cat <<-EOF >> /etc/network/interfaces
		# External Bridge
		allow-ovs br-ext
		iface br-ext inet manual
		  ovs_type OVSBridge
		  ovs_ports $phyInt.$extVlan

		EOF

		if [ "$vlanTrue" == "y" ]; then
			## Setup Bridge for VLAN Trunk
			cat <<-EOF >> /etc/network/interfaces
			# Physical interface
			allow-br-vlan $phyInt
			iface $phyInt inet manual
			  ovs_bridge br-vlan
			  ovs_type OVSPort

			EOF

			# Setup VLAN Trunk for provider and tenant networks.
			cat <<-EOF >> /etc/network/interfaces
			# VLAN Bridge
			allow-ovs br-vlan
			iface br-vlan inet manual
			  ovs_type OVSBridge
			  ovs_ports $phyInt
			EOF
		else
			cat <<-EOF >> /etc/network/interfaces
			# Physical Interface
			auto $phyInt
			iface $phyInt inet manual
			EOF
		fi

		if [ "$configureBonding" == "y" ]; then
			printf "  bond-mode ${bondingMode}\n\n" >> /etc/network/interfaces

			for slaveInt in "${bondingInts[@]}"; do
				cat <<-EOF >> /etc/network/interfaces
				# Slaving $slaveInt to Master $phyInt
				auto $slaveInt
				iface $slaveInt inet manual
				  bond-master $phyInt

				EOF
			done
		fi

		printf "\n${GREEN}Network config complete!${NC}"
		printf "\n${YELLOW}Please review the following config file:${NC}"

		printf "\n${GREEN}Interfaces File: /etc/network/interfaces${NC}\n"
		printf "${YELLOW}"
		cat /etc/network/interfaces
		printf "${NC}\n\n"

		printf "${RED}"
		read -p "!!! Only if all of the above looks correct, type yes to reboot your host !!! " yn
		printf "${NC}"
		case $yn in
			[Yy]* ) reboot;;
		esac
	fi
	printf "\n${GREEN}DONE!!!${NC}\n"
else
	printf "${RED}!!! Unable to determine OS / unsupported OS !!!${NC}\n"
fi
