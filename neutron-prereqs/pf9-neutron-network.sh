#!/bin/bash

# Bash Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'

function validVlan() {
  grep -E -q '^([1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-3][0-9][0-9][0-9]|40[0-9][0-5])$' <<< "$1" && echo "Valid" || echo "Invalid"
}

function validIp() {
  grep -E -q '^(25[0-4]|2[0-4][0-9]|1[0-9][0-9]|[1]?[1-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)' <<< "$1" && echo "Valid" || echo "Invalid"
}

function validNetMask() {
  grep -E -q '^(254|252|248|240|224|192|128)\.0\.0\.0|255\.(254|252|248|240|224|192|128|0)\.0\.0|255\.255\.(254|252|248|240|224|192|128|0)\.0|255\.255\.255\.(254|252|248|240|224|192|128|0)' <<< "$1" && echo "Valid" || echo "Invalid"
}

function validMtu() {
  grep -E -q '^(1[6-9][0-9][0-9]|[2-8][0-9][0-9][0-9]|9000)$' <<< "$1" && echo "Valid" || echo "Invalid"
}

function validYesNo() {
  case $1 in
    [Yy]* ) echo "Valid";;
    [Nn]* ) echo "Valid";;
    * ) echo "Invalid";;
  esac
}

function getValidInput() {
  while true; do
    read -p "$1" getInput
    if [ "$2" == "vlan" ]; then
      errMessage="Please enter a valid vLan between 1-4095!"
      checkValid=$(validVlan $getInput)
    elif [ "$2" == "ipAddress" ]; then
      errMessage="Please enter a valid IP Address!"
      checkValid=$(validIp $getInput)
    elif [ "$2" == "netMask" ]; then
      errMessage="Please enter a valid Subnet Mask!"
      checkValid=$(validNetMask $getInput)
    elif [ "$2" == "yesNo" ]; then
      getInput=`echo ${getInput:0:1} | awk '{print tolower($0)}'`
      errMessage="Please answer yes or no!"
      checkValid=$(validYesNo $getInput)
    elif [ "$2" == "mtu" ]; then
      errMessage="Please enter a valid MTU between 1600-9000!"
      checkValid=$(validMtu $getInput)
    elif [ "$2" == "freeText" ]; then
      checkValid="Valid"
    else
      printf "${RED}!!! Invalid Paramaters sent to getValidInput Fuction !!!${NC}\n" >&2
    fi
    if [ "$checkValid" == "Valid" ]; then
     break
    else
     printf "${RED}Invalid Input! $errMessage${NC}\n" >&2
    fi
  done
  echo $getInput
}

function putLineInFile() {
  if grep -Fxq "$1" $2; then
    printf "${CYAN}'$2' ${GREEN}already contains${CYAN} '$1'${NC}\n" >&2
  else
    echo "$1" >> $2
  fi
}

function whichOS() {
  if [ -f /etc/redhat-release ]; then
    echo 'Enterprise Linux'
  elif [ -f /etc/lsb-release]; then
    echo 'Ubuntu'
  else
    echo 'Unknown Operating System'
  fi
}

OS=$(whichOS)

phyInts=($(ls -l /sys/class/net/ | grep -i 'pci\|bond'  | awk -F' ' '{print $9}'))

if [ ${#phyInts[@]} -eq 1 ]; then
  phyInt=${phyInts[0]}
else
  n=0
  for i in "${phyInts[@]}"; do
    ((n++)) 
    echo "$n) $i"
  done
  while true; do
    read -p "Pick your physical interface from the list: " pickPhyInt
    if [ $pickPhyInt -gt ${#phyInts[@]} ] || [ $pickPhyInt -lt 1 ]; then
      printf "${RED}Invalid Input! Please pick an interface from the list.${NC}\n"
    else
      phyInt=${phyInts[$pickPhyInt-1]}
      break
    fi  
  done
fi
printf "${GREEN}Using Interface: $phyInt${NC}\n"

# Management Interface Variables
mgmtVlan=$(getValidInput "Management vLan ID: " "vlan")
mgmtIp=$(getValidInput "Management IP Address: " "ipAddress")
mgmtSubnet=$(getValidInput "Management Subnet Mask: " "netMask")
mgmtGateway=$(getValidInput "Management Gateway: " "ipAddress")
mgmtDns1=$(getValidInput "DNS Server 1: " "ipAddress")
mgmtDns2=$(getValidInput "DNS Server 2: " "ipAddress")
mgmtSearchDomain=$(getValidInput "DNS Search Domain: " "freeText")

# External Interface Variables
extVlan=$(getValidInput "External vLan ID: " "vlan")

# vxLan or GRE?
tunnelTrue=$(getValidInput "Do you plan on using vxLan or GRE tunneling? " "yesNo")

# VXLan Variables
seperateTunnel=$(getValidInput "Are you using a separate vlan for tunneling? " "yesNo")

if [ "$seperateTunnel" == "y" ]; then
  tunnelVlanId=$(getValidInput "Tunnel Lan ID: " "vlan")
  tunnelIp=$(getValidInput "Tunnel IP Address: " "ipAddress")
  tunnelSubnet=$(getValidInput "Tunnel Subnet Mask: " "netMask")
fi
if [ "$tunnelTrue" == "y" ]; then  
  printf "${RED} !!! Ensure your switches are configured to handle this MTU !!!${NC}\n"
  mtuSize=$(getValidInput "Tunneling requires a minimum MTU of 1600. Please choose an MTU size between 1600-9000: " "mtu")
fi

nfsTrue=$(getValidInput "Are you using NFS for Instances, Images, or Block Storage? " "yesNo")

vlanTrue=$(getValidInput "Are you using vLan segmentation? Or planning to have provider networks?" "yesNo")

printf "${GREEN}You have cooperated nicely by answering the questions asked of you!${NC}\n\n"
printf "${CYAN}"
printf "Physical Interface: $phyInt\n"
printf "Management vLan ID: $mgmtVlan\n"
printf "Management IP Address: $mgmtIp\n"
printf "Management Subnet Mask: $mgmtSubnet\n"
printf "Management Gateway: $mgmtGateway\n"
printf "DNS Server 1: $mgmtDns1\n"
printf "DNS Server 2: $mgmtDns2\n"
printf "DNS Search Domain: $mgmtSearchDomain\n"
printf "External vLan ID: $extVlan\n"
printf "Are you using a separate vlan for tunneling? $tunnelTrue\n"
if [ "$tunnelTrue" == "y" ]; then
  printf "Tunnel Lan ID: $tunnelVlanId\n"
  printf "Tunnel IP Address: $tunnelIp\n"
  printf "Tunnel Subnet Mask: $tunnelSubnet\n"
  printf "Please choose an MTU size between 1600-9000: $mtuSize\n"
fi
printf "Are you using NFS for Instances, Images, or Block Storage? $nfsTrue\n"
printf "Are you using vLan segmentation? $vlanTrue\n"
printf "${NC}\n"
finalAnswer=$(getValidInput "Are these your final answers?! " "yesNo")
if [ "$finalAnswer" == "n" ]; then 
  printf "\n${RED}!!! We are aborting, No changes have been made !!!${NC}\n"
  exit
fi

hostProfileScriptName='./hostProfile.sh'

head -88 $0 > $hostProfileScriptName 
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
echo 'nfsTrue='$nfsTrue >> $hostProfileScriptName

tail -253 $0 >> $hostProfileScriptName





if [$OS == 'Enterprise Linux']; then

  # Disable SELinux
  printf "\n${RED}!!! We are setting SELINUX to permisive !!!\n!!! This is required for Software Definded Networks !!!${NC}\n"
  sed -i s/SELINUX=enforcing/SELINUX=permissive/g /etc/selinux/config
  setenforce 0

  # Disable firewalld
  printf "\n${RED}!!! We are setting disabling FIREWALLD !!!\n!!! Neutron and KVM will use IPTABLES directly !!!${NC}\n"
  systemctl disable firewalld
  systemctl stop firewalld

  # Load modules needed for neutron
  modprobe bridge
  modprobe 8021q

  # Setup sysctl vairables
  putLineInFile '# Needed for neutron networking' '/etc/sysctl.conf'
  putLineInFile 'net.ipv4.conf.all.rp_filter=0' '/etc/sysctl.conf'
  putLineInFile 'net.ipv4.conf.default.rp_filter=0' '/etc/sysctl.conf'
  putLineInFile 'net.bridge.bridge-nf-call-iptables=1' '/etc/sysctl.conf'
  putLineInFile 'net.ipv4.ip_forward=1' '/etc/sysctl.conf'

  # Reload sysctl
  sysctl -p

  if [ "$nfsTrue" == "y" ]; then
    yum -y install nfsutils
  fi

  # Add PF9 Yum Repo
  yum -y install https://s3-us-west-1.amazonaws.com/platform9-neutron/noarch/platform9-neutron-repo-1-0.noarch.rpm

  # Install openvswitch
  yum -y install --disablerepo="*" --enablerepo="platform9-neutron-el7-repo" openvswitch

  # Enable and start the openvswitch service
  systemctl enable openvswitch
  systemctl start openvswitch

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
  echo VLAN=yes >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan
  echo TYPE=OVSPort >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan
  echo DEVICETYPE=ovs >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan
  echo OVS_BRIDGE=br-ext >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan

  ## Setup Bridge for vLan Trunk
  echo DEVICE=br-vlan > /etc/sysconfig/network-scripts/ifcfg-br-vlan
  echo BOOTPROTO=none >> /etc/sysconfig/network-scripts/ifcfg-br-vlan
  echo ONBOOT=yes >> /etc/sysconfig/network-scripts/ifcfg-br-vlan
  echo TYPE=OVSBridge >> /etc/sysconfig/network-scripts/ifcfg-br-vlan
  echo DEVICETYPE=ovs >> /etc/sysconfig/network-scripts/ifcfg-br-vlan

  ## Slave Physical Interface to vLan Bridge
  mv /etc/sysconfig/network-scripts/ifcfg-$phyInt ~/old-ifcfg-$phyInt
  echo DEVICE=$phyInt > /etc/sysconfig/network-scripts/ifcfg-$phyInt
  echo ONBOOT=yes >> /etc/sysconfig/network-scripts/ifcfg-$phyInt
  echo TYPE=OVSPort >> /etc/sysconfig/network-scripts/ifcfg-$phyInt
  echo DEVICETYPE=ovs >> /etc/sysconfig/network-scripts/ifcfg-$phyInt
  echo OVS_BRIDGE=br-vlan >> /etc/sysconfig/network-scripts/ifcfg-$phyInt

  if [ "$tunnelTrue" == "y" ]; then
    # Add larger MTU to the physical interface
    echo MTU=$mtuSize >>/etc/sysconfig/network-scripts/ifcfg-$phyInt
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
  fi

  printf "\n\n${GREEN}Network config complete!${NC}\n"
  printf "${YELLOW}Please review the following config files:${NC}\n\n\n"

  printf "${GREEN}Management Interface:  /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan${NC}\n\n"
  printf "${YELLOW}"
  cat /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan
  printf "${NC}\n\n\n"

  printf "${GREEN}External Bridge:  /etc/sysconfig/network-scripts/ifcfg-br-ext${NC}\n\n"
  printf "${YELLOW}"
  cat /etc/sysconfig/network-scripts/ifcfg-br-ext
  printf "${NC}\n\n\n"

  printf "\n\n${GREEN}External Interface:  /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan${NC}\n\n"
  printf "${YELLOW}"
  cat /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan
  printf "${NC}\n\n\n"

  if [ "$vlanTrue" == "y" ]; then
    printf "${GREEN}Lan Bridge: /etc/sysconfig/network-scripts/ifcfg-br-vlan${NC}\n\n"
    printf "${YELLOW}"
    cat /etc/sysconfig/network-scripts/ifcfg-br-vlan
    printf "${NC}\n\n\n"
  fi

  if [ "$vxlanTrue" == "y" ]; then
    printf "${GREEN}VXLan Interface:  /etc/sysconfig/network-scripts/ifcfg-$phyInt.$vxlanVlan${NC}\n\n"
    printf "${YELLOW}"
    cat /etc/sysconfig/network-scripts/ifcfg-$phyInt.$vxlanVlan
    printf "${NC}\n\n\n"
  fi

  printf "${RED}"
  read -p "!!! Only if all of the above look correct, type yes to restart networking !!! " yn
  printf "${NC}"
  case $yn in
    [Yy]* ) systemctl restart network.service;;
  esac
  echo "\n\n${GREEN}DONE!!!${NC}\n"
elif [$OS == 'Ubuntu']; then
  # Install the vLan package
  apt-get -y install vlan

  # Add required modules
  modprobe br_netfilter
  modprobe 8021q
  
  # Make modules persistent
  echo br_netfilter >> /etc/modules
  echo 8021q >> /etc/modules

  # Setup sysctl vairables
  putLineInFile '# Needed for neutron networking' '/etc/sysctl.conf'
  putLineInFile 'net.ipv4.conf.all.rp_filter=0' '/etc/sysctl.conf'
  putLineInFile 'net.ipv4.conf.default.rp_filter=0' '/etc/sysctl.conf'
  putLineInFile 'net.bridge.bridge-nf-call-iptables=1' '/etc/sysctl.conf'
  putLineInFile 'net.ipv4.ip_forward=1' '/etc/sysctl.conf'

  # Reload sysctl
  sysctl -p

  # Add PF9 Apt Source
  echo 'deb http://platform9-neutron.s3-website-us-west-1.amazonaws.com ubuntu/' > /etc/apt/sources.list.d/platform9-neutron-ubuntu.list

  # Install openvswitch
  apt-get -y --force-yes install openvswitch-switch
  
  # Backup old interfaces file
  cp /etc/network/interfaces ./interfaces.bak
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
  echo "" >> /etc/network/interfaces


  if [ "$seperateTunnel" == "y" ]; then
    # Define Sub-Interface interface for tunneling
    echo "# Tunneling Sub-Interface" >> /etc/network/interfaces
    echo "auto $phyInt.$tunnelVlanId"  >> /etc/network/interfaces
    echo "iface $phyInt.$tunnelVlanId inet static" >> /etc/network/interfaces
    echo "  address $tunnelIp" >> /etc/network/interfaces
    echo "  netmask $tunnelSubnet" >> /etc/network/interfaces
    echo "" >> /etc/network/interfaces
  fi
  # Setup External Network
  ## Create External Bridge
  echo "# External Bridge" >> /etc/network/interfaces
  echo "allow-ovs br-ext" >> /etc/network/interfaces
  echo "iface br-ex inet manual" >> /etc/network/interfaces
  echo "  ovs_type OVSBridge" >> /etc/network/interfaces
  echo "  ovs_ports $phyInt.$extVlan" >> /etc/network/interfaces
  
  ## Create sub-interface for external network
  echo "# External Sub-Interface" >> /etc/network/interfaces
  echo "allow-br-ext $phyInt.$extVlan"  >> /etc/network/interfaces
  echo "iface $phyInt.$extVlan inet manual" >> /etc/network/interfaces
  echo "  ovs_type OVSPort" >> /etc/network/interfaces
  echo "  ovs_bridge br-ext" >> /etc/network/interfaces
  echo "" >> /etc/network/interfaces
  
  # Setup vLan Trunk for provider and tenant networks.
  echo "# vLan Bridge" >> /etc/network/interfaces
  echo "allow-ovs br-vlan" >> /etc/network/interfaces
  echo "iface br-vlan inet static" >> /etc/network/interfaces
  echo "  ovs_type OVSBridge" >> /etc/network/interfaces
  echo "  ovs_ports $phyInt" >> /etc/network/interfaces
  echo "" >> /etc/network/interfaces
  ## Setup Bridge for vLan Trunk
  echo "# Physical Interface" >> /etc/network/interfaces
  echo "allow-br-vlan $phyInt" >> /etc/network/interfaces
  echo "iface $phyInt inet manual" >> /etc/network/interfaces
  echo "  ovs_bridge br-vlan" >> /etc/network/interfaces
  echo "  ovs_type OVSPort" >> /etc/network/interfaces
  if [ "$tunnelTrue" == "y" ]; then
    # Add larger MTU to the physical interface
    echo "  mtu $mtuSize" >> /etc/network/interfaces
  fi
  echo "" >> /etc/network/interfaces

  printf "\n\n${GREEN}Network config complete!${NC}\n"
  printf "${YELLOW}Please review the following config file:${NC}\n\n\n"

  printf "${GREEN}Interfaces File:  /etc/network/interfaces{NC}\n\n"
  printf "${YELLOW}"
  cat /etc/network/interfaces
  printf "${NC}\n\n\n"

  printf "${RED}"
  read -p "!!! Only if all of the above look correct, type yes to reboot your host !!! " yn
  printf "${NC}"
  case $yn in
    [Yy]* ) reboot;;
  esac
  echo "\n\n${GREEN}DONE!!!${NC}\n"
else
  printf "${RED}!!! Somehow we lost which operating system you are using !!!${NC}\n"
  printf "${RED}!!! Ending Script !!!${NC}\n"
fi