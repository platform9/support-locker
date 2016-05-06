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
  grep -E -q '^(25[0-4]|2[0-4][0-9]|1[0-9][0-9]|[1]?[1-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)' <<< "$1"
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

  while true; do
    read -p "$1" getInput

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

configNetworking=$(getValidInput "Would you like for this script to walk you through configuring networking? " "yesNo")
bondingInts=()
if [ $configNetworking == "y" ]; then
  phyInts=($(ls -l /sys/class/net/ | grep -i 'pci'  | awk '{print $9}'))

  if [ ${#phyInts[@]} -eq 1 ]; then
    phyInt=${phyInts[0]}
  else

    printf "${GREEN}Multiple physical interfaces were detected${NC}\n"
    configureBonding=$(getValidInput "Would you like to configure bonding? " "yesNo")
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
            addAnother=$(getValidInput "Would you like to add another interface? " "yesNo")
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
  tunnelTrue=$(getValidInput "Do you plan on using VXLAN or GRE tunneling? " "yesNo")

  # VXLAN Variables
  if [ "$tunnelTrue" == "y" ]; then
    seperateTunnel=$(getValidInput "Are you using a separate VLAN for tunneling? " "yesNo")
    printf "${YELLOW} ### Ensure your switches are configured to handle this MTU ###${NC}\n"
    mtuSize=$(getValidInput "Tunneling requires a minimum MTU of 1600. Please choose an MTU size between 1600-9000: " "mtu")
  fi

  if [ "$seperateTunnel" == "y" ]; then
    tunnelVlanId=$(getValidInput "Tunnel VLAN ID: " "vlan")
    tunnelIp=$(getValidInput "Tunnel IP Address: " "ipAddress")
    tunnelSubnet=$(getValidInput "Tunnel Subnet Mask: " "netMask")
  fi

  vlanTrue=$(getValidInput "Are you using VLAN segmentation? Or planning to have provider networks? " "yesNo")

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
  printf "Management VLAN ID: $mgmtVlan\n"
  printf "Management IP Address: $mgmtIp\n"
  printf "Management Subnet Mask: $mgmtSubnet\n"
  printf "Management Gateway: $mgmtGateway\n"
  printf "DNS Server 1: $mgmtDns1\n"
  printf "DNS Server 2: $mgmtDns2\n"
  printf "DNS Search Domain: $mgmtSearchDomain\n"
  printf "External VLAN ID: $extVlan\n"
  printf "Are you using a separate VLAN for tunneling? $tunnelTrue\n"
  if [ "$tunnelTrue" == "y" ]; then
    printf "Tunnel VLAN ID: $tunnelVlanId\n"
    printf "Tunnel IP Address: $tunnelIp\n"
    printf "Tunnel Subnet Mask: $tunnelSubnet\n"
    printf "Please choose an MTU size between 1600-9000: $mtuSize\n"
  fi
  printf "Are you using VLAN segmentation? $vlanTrue\n"
  printf "${NC}\n"
  finalAnswer=$(getValidInput "Are these your final answers?! " "yesNo")
  if [ "$finalAnswer" == "n" ]; then
    printf "\n${RED}!!! We are aborting, No changes have been made !!!${NC}\n"
    exit
  fi
fi

hostProfileScriptName='./hostProfile.sh'

head -88 $0 > $hostProfileScriptName
echo "configNetworking=${configNetworking}" >> $hostProfileScriptName
if [ $configNetworking == "y" ]; then
  echo 'phyInt='$phyInt >> $hostProfileScriptName
  echo 'mgmtIp=$(getValidInput "Management IP Address: " "ipAddress")' >> $hostProfileScriptName
  echo 'mgmtVlan='$mgmtVlan >> $hostProfileScriptName
  echo 'mgmtSubnet='$mgmtSubnet >> $hostProfileScriptName
  echo 'mgmtGateway='$mgmtGateway >> $hostProfileScriptName
  echo 'mgmtDns1='$mgmtDns1 >> $hostProfileScriptName
  echo 'mgmtDns2='$mgmtDns2 >> $hostProfileScriptName
  echo 'mgmtSearchDomain='$mgmtSearchDomain >> $hostProfileScriptName
  echo 'extVlan='$extVlan >> $hostProfileScriptName
  echo 'tunnelTrue='$tunnelTrue >> $hostProfileScriptName
  echo 'seperateTunnel='$seperateTunnel >> $hostProfileScriptName
  if [ "$seperateTunnel" == "y" ]; then
    echo 'tunnelIp=$(getValidInput "Tunnel IP Address: " "ipAddress")' >> $hostProfileScriptName
    echo 'tunnelVlanId='$tunnelVlanId >> $hostProfileScriptName
    echo 'tunnelSubnet='$tunnelSubnet >> $hostProfileScriptName
  fi
  if [ "$tunnelTrue" == "y" ]; then
    echo 'mtuSize='$mtuSize >> $hostProfileScriptName
  fi
fi
tail -310 $0 >> $hostProfileScriptName

echo "Installing Neutron prerequisites..."

if [ $OS == 'Enterprise Linux' ]; then

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
    echo DEVICE=$phyInt.$mgmtVlan > /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan
    echo ONBOOT=yes >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan
    echo BOOTPROTO=none >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan
    echo TYPE=Vlan >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan
    echo VLAN=yes >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan
    echo IPADDR=$mgmtIp >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan
    echo NETMASK=$mgmtSubnet >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan
    echo GATEWAY=$mgmtGateway >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan
    echo DNS1=$mgmtDns1 >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan
    echo DNS2=$mgmtDns2 >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan
    if [ "$tunnelTrue" == "y" ]; then
      if [ "$seperateTunnel" == "n" ]; then
        # Add larger MTU to the physical interface
        echo MTU=$mtuSize >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan
      fi
    fi

    # Setup External Network
    ## Create Bridge for External Network
    echo DEVICE=br-ext > /etc/sysconfig/network-scripts/ifcfg-br-ext
    echo BOOTPROTO=none >> /etc/sysconfig/network-scripts/ifcfg-br-ext
    echo ONBOOT=yes >> /etc/sysconfig/network-scripts/ifcfg-br-ext
    echo TYPE=OVSBridge >> /etc/sysconfig/network-scripts/ifcfg-br-ext
    echo DEVICETYPE=ovs >> /etc/sysconfig/network-scripts/ifcfg-br-ext

    ## Create and Slave External Sub-Interface to External Bridge
    echo DEVICE=$phyInt.$extVlan > /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan
    echo ONBOOT=yes >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan
    echo TYPE=OVSPort >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan
    echo VLAN=yes >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan
    echo DEVICETYPE=ovs >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan
    echo OVS_BRIDGE=br-ext >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan

    ## Slave Physical Interface to VLAN Bridge
    echo DEVICE=$phyInt > /etc/sysconfig/network-scripts/ifcfg-$phyInt
    echo BOOTPROTO=none >> /etc/sysconfig/network-scripts/ifcfg-$phyInt
    echo ONBOOT=yes >> /etc/sysconfig/network-scripts/ifcfg-$phyInt


    if [ "$configureBonding" == "y" ]; then
      echo BONDING_MASTER=yes >> /etc/sysconfig/network-scripts/ifcfg-$phyInts
      echo 'BONDING_OPTS="mode='$bondingMode'"' >> /etc/sysconfig/network-scripts/ifcfg-$phyInts
      if [ "$vlanTrue" != "y" ]; then
        echo TYPE=Bond >> /etc/sysconfig/network-scripts/ifcfg-$phyInt
      fi
      for slaveInt in "${bondingInts[@]}"; do
        echo DEVICE=$slaveInt > /etc/sysconfig/network-scripts/ifcfg-$slaveInt
        echo BOOTPROTO=none >> /etc/sysconfig/network-scripts/ifcfg-$slaveInt
        echo ONBOOT=yes >> /etc/sysconfig/network-scripts/ifcfg-$slaveInt
        echo TYPE=Ethernet >> /etc/sysconfig/network-scripts/ifcfg-$slaveInt
        echo MASTER=bond0 >> /etc/sysconfig/network-scripts/ifcfg-$slaveInt
        echo SLAVE=yes >> /etc/sysconfig/network-scripts/ifcfg-$slaveInt
      done
    fi

    if [ "$vlanTrue" == "y" ]; then
      ## Setup Bridge for VLAN Trunk
      echo DEVICE=br-vlan > /etc/sysconfig/network-scripts/ifcfg-br-vlan
      echo BOOTPROTO=none >> /etc/sysconfig/network-scripts/ifcfg-br-vlan
      echo ONBOOT=yes >> /etc/sysconfig/network-scripts/ifcfg-br-vlan
      echo TYPE=OVSBridge >> /etc/sysconfig/network-scripts/ifcfg-br-vlan
      echo DEVICETYPE=ovs >> /etc/sysconfig/network-scripts/ifcfg-br-vlan

      echo OVS_BRIDGE=br-vlan >> /etc/sysconfig/network-scripts/ifcfg-$phyInt
      echo TYPE=OVSPort >> /etc/sysconfig/network-scripts/ifcfg-$phyInt
      echo DEVICETYPE=ovs >> /etc/sysconfig/network-scripts/ifcfg-$phyInt
    fi

    if [ "$seperateTunnel" == "y" ]; then
      # Create Sub-Interface for tunneling
      echo DEVICE=$phyInt.$tunnelVlan > /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlan
      echo IPADDR=$tunnelIp >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlan
      echo NETMASK=$tunnelSubnet >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlan
      echo ONBOOT=yes >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlan
      echo BOOTPROTO=none >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlan
      echo VLAN=yes >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlan
      echo TYPE=Vlan >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlan
      echo MTU=$mtuSize >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlan
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

    if [ "$vxlanTrue" == "y" ]; then
      printf "\n${GREEN}VXLAN Interface: /etc/sysconfig/network-scripts/ifcfg-$phyInt.$vxlanVlan${NC}\n"
      printf "${YELLOW}"
      cat /etc/sysconfig/network-scripts/ifcfg-$phyInt.$vxlanVlan
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
elif [ $OS == 'Ubuntu' ]; then
  # Install the VLAN package
  apt-get -y -q=2 install vlan ifenslave

  # Add required modules
  modprobe br_netfilter
  modprobe 8021q
  modprobe bonding

  # Make modules persistent
  echo br_netfilter >> /etc/modules
  echo 8021q >> /etc/modules
  echo bonding >> /etc/modules

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
    echo "# This file describes the network interfaces available on your system" > /etc/network/interfaces
    echo "# and how to activate them. For more information, see interfaces(5)." >> /etc/network/interfaces
    echo "" >> /etc/network/interfaces
    echo "# The loopback network interface" >> /etc/network/interfaces
    echo "auto lo" >> /etc/network/interfaces
    echo "iface lo inet loopback" >> /etc/network/interfaces
    echo "" >> /etc/network/interfaces

    # Define Sub-Interface interface for Management
    echo "# Management Sub-Interface" >> /etc/network/interfaces
    echo "auto $phyInt.$mgmtVlan"  >> /etc/network/interfaces
    echo "iface $phyInt.$mgmtVlan inet static" >> /etc/network/interfaces
    echo "  address $mgmtIp" >> /etc/network/interfaces
    echo "  netmask $mgmtSubnet" >> /etc/network/interfaces
    echo "  gateway $mgmtGateway" >> /etc/network/interfaces
    echo "  dns-nameservers $mgmtDns1 $mgmtDns2" >> /etc/network/interfaces
    echo "  dns-search $mgmtSearchDomain" >> /etc/network/interfaces
    if [ "$tunnelTrue" == "y" ]; then
      if [ "$seperateTunnel" == "n" ]; then
        # Add larger MTU to the physical interface
        echo "  mtu $mtuSize" >> /etc/network/interfaces
      fi
    fi
    echo "" >> /etc/network/interfaces


    if [ "$seperateTunnel" == "y" ]; then
      # Define Sub-Interface interface for tunneling
      echo "# Tunneling Sub-Interface" >> /etc/network/interfaces
      echo "auto $phyInt.$tunnelVlanId"  >> /etc/network/interfaces
      echo "iface $phyInt.$tunnelVlanId inet static" >> /etc/network/interfaces
      echo "  address $tunnelIp" >> /etc/network/interfaces
      echo "  netmask $tunnelSubnet" >> /etc/network/interfaces
      if [ "$tunnelTrue" == "y" ]; then
        # Add larger MTU to the physical interface
        echo "  mtu $mtuSize" >> /etc/network/interfaces
      fi
      echo "" >> /etc/network/interfaces
    fi
    # Setup External Network

    ## Create sub-interface for external network
    echo "# External Sub-Interface" >> /etc/network/interfaces
    echo "allow-br-ext $phyInt.$extVlan"  >> /etc/network/interfaces
    echo "iface $phyInt.$extVlan inet manual" >> /etc/network/interfaces
    echo "  ovs_type OVSPort" >> /etc/network/interfaces
    echo "  ovs_bridge br-ext" >> /etc/network/interfaces
    echo "" >> /etc/network/interfaces

    ## Create External Bridge
    echo "# External Bridge" >> /etc/network/interfaces
    echo "allow-ovs br-ext" >> /etc/network/interfaces
    echo "iface br-ext inet manual" >> /etc/network/interfaces
    echo "  ovs_type OVSBridge" >> /etc/network/interfaces
    echo "  ovs_ports $phyInt.$extVlan" >> /etc/network/interfaces
    echo "" >> /etc/network/interfaces

    if [ "$vlanTrue" == "y" ]; then
      ## Setup Bridge for VLAN Trunk
      echo "# Physical Interface" >> /etc/network/interfaces
      echo "allow-br-vlan $phyInt" >> /etc/network/interfaces
      echo "iface $phyInt inet manual" >> /etc/network/interfaces
      echo "  ovs_bridge br-vlan" >> /etc/network/interfaces
      echo "  ovs_type OVSPort" >> /etc/network/interfaces
      # Setup VLAN Trunk for provider and tenant networks.
      echo "# VLAN Bridge" >> /etc/network/interfaces
      echo "allow-ovs br-vlan" >> /etc/network/interfaces
      echo "iface br-vlan inet manual" >> /etc/network/interfaces
      echo "  ovs_type OVSBridge" >> /etc/network/interfaces
      echo "  ovs_ports $phyInt" >> /etc/network/interfaces
      echo "" >> /etc/network/interfaces
    else
      # Setup Physical Interface
      echo "# Physical Interface" >> /etc/network/interfaces
      echo "auto $phyInt" >> /etc/network/interfaces
      echo "iface $phyInt inet manual" >> /etc/network/interfaces
    fi

    if [ "$configureBonding" == "y" ]; then
      echo "  bond-mode $bondingMode" >> /etc/network/interfaces
      echo "" >> /etc/network/interfaces
      for slaveInt in "${bondingInts[@]}"; do
        echo "# Slaving $slaveInt to Master $phyInt" >> /etc/network/interfaces
        echo "auto $slaveInt" >> /etc/network/interfaces
        echo "iface $slaveInt inet manual" >> /etc/network/interfaces
        echo "  bond-master $phyInt" >> /etc/network/interfaces
        echo "" >> /etc/network/interfaces
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
  printf "${RED}!!! Somehow we lost which operating system you are using !!!${NC}\n"
  printf "${RED}!!! Ending Script !!!${NC}\n"
fi
