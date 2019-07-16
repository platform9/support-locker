Note: This repository is currently in alpha status, and being tested for viability with different products on different SELinux platforms.  In any case, it should be a good resource for anyone that wants to create fine grained selinux policies for running
pf9 software on.

# SETENFORCE 1 !

Platform9 products and services can run in secure environments, as long as security
portals are opened up for certain core functionality.  

This repository is a utility for bootstrapping and documenting any SELinux related portals.  

You can apply one, or many of these at any time before your platform9 installation.

In addition to containing the actual SELinux policy files for specific features which
need to be enabled, this repostiroy also has an AVCs file, where we maintain example
AVCs that might occur while you install CSI, CNI, or other security sensitive services.

# Whats in here? 

- AVCS : A file where we log notable AVCs used to generate selinux policies.
- Policy files: A set of policies which, if enabled, will allow platform9 components to run with SELinux enabled.
- apply.sh : A script which applies the policies in this repo
- Vagrantfile : A VM recipe that spins up a local virtualbox instance that can be used to test these recipes.

# Using this repo

- `git clone https://github.com/platform9/selinuxmodules`
- (optional) Edit or remove any policies in these  shell scripts.  
- `./apply.sh`

# Developing and adding to this repo

To monitor these AVCs to build new policy's, just run:

- `tail -f /var/log/audit.log` and look for avc denials or failures.

To fix such failures and create new policies, just cat them into audit2allow, like so:

- `audit2allow -a -M pf9user <  /var/log/audit.log`

This will result in a new pf9user.pp policy file which you can apply, or pull request to this 
repository.

# Selinux policies for platform9

This repository contains a list of policies which can be applied to
enable Enforcing status for the PMK and PMO products.  Use it in concert
with your system administrator (or platform9's customer success team).


