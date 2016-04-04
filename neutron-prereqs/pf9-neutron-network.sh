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

# External Interface Variables
extVlan=$(getValidInput "External vLan ID: " "vlan")

# VXLan Variables
tunnelTrue=$(getValidInput "Are you using a separate vlan for tunneling? " "yesNo")

if [ "$tunnelTrue" == "y" ]; then
  tunnelVlanId=$(getValidInput "Tunnel Lan ID: " "vlan")
  tunnelIp=$(getValidInput "Tunnel IP Address: " "ipAddress")
  tunnelSubnet=$(getValidInput "Tunnel Subnet Mask: " "netMask")
  mtuSize=$(getValidInput "Tunneling requires a minimum MTU of 1600. Please choose an MTU size between 1600-9000: " "mtu")
fi

neutronNodeTrue=$(getValidInput "Are you running this script on the network node? " "yesNo")

nfsTrue=$(getValidInput "Are you using NFS for Instances, Images, or Block Storage? " "yesNo")

#vlanTrue=$(getValidInput "Are you using vLan segmentation? " "yesNo")

printf "${GREEN}You have cooperated nicely by answering the questions asked of you!${NC}\n\n"
printf "${CYAN}"
printf "Physical Interface: $phyInt\n"
printf "Management vLan ID: $mgmtVlan\n"
printf "Management IP Address: $mgmtIp\n"
printf "Management Subnet Mask: $mgmtSubnet\n"
printf "Management Gateway: $mgmtGateway\n"
printf "DNS Server 1: $mgmtDns1\n"
printf "DNS Server 2: $mgmtDns2\n"
printf "External vLan ID: $extVlan\n"
printf "Are you using a separate vlan for tunneling? $tunnelTrue\n"
if [ "$tunnelTrue" == "y" ]; then
  printf "Tunnel Lan ID: $tunnelVlanId\n"
  printf "Tunnel IP Address: $tunnelIp\n"
  printf "Tunnel Subnet Mask: $tunnelSubnet\n"
  printf "Plese choose an MTU size between 1600-9000: $mtuSize\n"
fi
printf "Are you running this script on the network node? $neutronNodeTrue\n"
printf "Are you using NFS for Instances, Images, or Block Storage? $nfsTrue\n"
#printf "Are you using vLan segmentation? $vlanTrue\n"
printf "${NC}\n"
finalAnswer=$(getValidInput "Are these your final answers?! " "yesNo")
if [ "$finalAnswer" == "n" ]; then 
  printf "\n${RED}!!! We are aborting, No changes have been made !!!${NC}\n"
  exit
fi

hostProfileScriptName='./hostProfile.sh'

head -74 $0 > $hostProfileScriptName 

echo 'phyInt='$phyInt >> $hostProfileScriptName
echo 'mgmtIp=$(getValidInput "Management IP Address: " "ipAddress")' >> $hostProfileScriptName
echo 'mgmtVlan='$mgmtVlan >> $hostProfileScriptName
echo 'mgmtSubnet='$mgmtSubnet >> $hostProfileScriptName
echo 'mgmtGateway='$mgmtGateway >> $hostProfileScriptName
echo 'mgmtDns1='$mgmtDns1 >> $hostProfileScriptName
echo 'mgmtDns2='$mgmtDns2 >> $hostProfileScriptName
echo 'extVlan='$extVlan >> $hostProfileScriptName
echo 'tunnelTrue='$tunnelTrue >> $hostProfileScriptName
if [ "$tunnelTrue" == "y" ]; then
  echo 'tunnelIp=$(getValidInput "Tunnel IP Address: " "ipAddress")' >> $hostProfileScriptName
  echo 'tunnelVlanId='$tunnelVlanId >> $hostProfileScriptName
  echo 'tunnelSubnet='$tunnelSubnet >> $hostProfileScriptName
  echo 'mtuSize='$mtuSize >> $hostProfileScriptName
fi
if [ "$neutronNodeTrue" == "y" ]; then
  echo 'neutronNodeTrue=n' >> $hostProfileScriptName
else
  echo 'neutronNodeTrue=$(getValidInput "Are you running this script on the network node? " "yesNo")' >> $hostProfileScriptName
fi
echo 'nfsTrue='$nfsTrue >> $hostProfileScriptName

tail -145 $0 >> $hostProfileScriptName





# Disable SELinux
printf "\n${RED}!!! We are setting SELINUX to permisive !!!\n!!! This is required for Software Definded Networks !!!${NC}\n"
sed -i s/SELINUX=enforcing/SELINUX=permissive/g /etc/selinux/config
setenforce 0

# Load modules needed for neutron
modprobe bridge
modprobe 8021q

# Setup sysctl vairables
putLineInFile '# Needed for neutron networking' '/etc/sysctl.conf'
putLineInFile 'net.ipv4.conf.all.rp_filter=0' '/etc/sysctl.conf'
putLineInFile 'net.ipv4.conf.default.rp_filter=0' '/etc/sysctl.conf'
putLineInFile 'net.bridge.bridge-nf-call-iptables=1' '/etc/sysctl.conf'
if [ "$neutronNodeTrue" == "y" ]; then
  putLineInFile 'net.ipv4.ip_forward=1' '/etc/sysctl.conf'
fi

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
  # Create Sub-Interface for tunneling
  echo DEVICE=$phyInt.$tunnelVlan > /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlan
  echo IPADDR=$tunnelIp >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlan
  echo NETMASK=$tunnelSubnet >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlan
  echo ONBOOT=yes >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlan
  echo BOOTPROTO=none >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlan
  echo VLAN=yes >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlan
  echo TYPE=Vlan >> /etc/sysconfig/network-scripts/ifcfg-$phyInt.$tunnelVlan
fi

echo ""
echo ""
echo "Network config complete!"
echo "Please review the following config files:"
echo ""

echo "Management Interface:  /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan"
echo ""
cat /etc/sysconfig/network-scripts/ifcfg-$phyInt.$mgmtVlan

echo ""
echo ""
echo "External Bridge:  /etc/sysconfig/network-scripts/ifcfg-br-ext"
echo ""
cat /etc/sysconfig/network-scripts/ifcfg-br-ext

echo ""
echo ""
echo "External Interface:  /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan"
echo ""
cat /etc/sysconfig/network-scripts/ifcfg-$phyInt.$extVlan

if [ "$vlanTrue" == "y" ]; then
  echo ""
  echo ""
  echo "vLan Bridge: /etc/sysconfig/network-scripts/ifcfg-br-vlan"
  echo ""
  cat /etc/sysconfig/network-scripts/ifcfg-br-vlan
  
  echo ""
  echo ""
  echo "Physical Interface:  /etc/sysconfig/network-scripts/ifcfg-br-vlan"
  echo ""
  cat /etc/sysconfig/network-scripts/ifcfg-br-vlan
fi

if [ "$vxlanTrue" == "y" ]; then
  echo ""
  echo ""
  echo "VXLan Interface:  /etc/sysconfig/network-scripts/ifcfg-$phyInt.$vxlanVlan"
  echo ""
  cat /etc/sysconfig/network-scripts/ifcfg-$phyInt.$vxlanVlan
fi

read -p "!!! Only if all of the above look correct, type yes to restart networking!  " yn
case $yn in
  [Yy]* ) systemctl restart network.service;;
esac
echo ""
echo ""
echo "DONE!!!"
