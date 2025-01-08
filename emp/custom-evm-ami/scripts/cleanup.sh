#!/bin/bash

# Update package database and remove unnecessary packages
sudo apt-get remove ansible -y
sudo apt-get autoremove -y
sudo apt-get clean -y
sudo apt-get update -y
sudo apt-get upgrade -y

# Remove old kernels
dpkg --list | grep linux-image | awk '{ print $2 }' | sort -V | sed -n '/'`uname -r`'/q;p' | xargs sudo apt-get -y purge
# Remove authorized_keys files
rm -f ~/.ssh/authorized_keys
sudo rm -f /root/.ssh/authorized_keys

# Remove SSH keys
sudo rm -rf /etc/ssh/*_key*

# Remove cloud-init data and instance information
sudo rm -rf /var/lib/cloud/data/* /var/lib/cloud/instances/*

# Empty space is being zeroed out
sudo dd if=/dev/zero of=/tmp/somefile
sudo rm -f /tmp/somefile

# Remove audit logs, system logs, and secure logs
sudo rm -rf /var/log/audit/* /var/log/syslog /var/log/auth.log


