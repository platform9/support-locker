# Upgrade Checker
The upgrade checker is read-only, safe to run on your Platform9 hosts, and does not require escalated privileges. The upgrade checker validates that the critical OS packages meet the Platform9 4.0 release requirements as specified in the [4.0 Release Notes](https://docs.platform9.com/support/platform9-4-0-release-notes/).

## 4.0 Procedure
### Upgrade Checker Steps
1. Log into an admin / jumpbox machine that has connectivity to all your hosts deployed in Platform9 and has the following packages installed: `ansible`, `git`.

2. Change the current working directory to the location where you want the cloned directory to be made.

3. Run this from the machine: `git clone https://github.com/platform9/cs-tools.git`

4. The upgrade checker command below identifies your Platform9 host inventory and will validate the OS package versions.
```
ansible-playbook \
        playbook_get_hosts_check_upgrade.yml \
        -u your_username_on_host \
        --private-key=~/your_private_sshkey \
        -e "pf9_du=https://example.platform9.net \
            pmo_token=xxxxYOUR_KEYSTONE_TOKENxxx"
```
- The upgrade checker runs an ansible playbook named: `playbook_get_hosts_check_upgrade.yml`

- “-u”: username you use to log into the host

- “--private-key”: private SSH key you use to log into your hosts

- “-e”: extra variables the upgrade checker will use. "pf9_du" is the URL of your Platform9 management plane and “pmo_token” is the Keystone token from your Platform9 management plane (in order to get the PMO Token, you will need the [Openstack CLI](https://docs.platform9.com/support/getting-started-with-the-openstack-command-line/) and run the command `openstack token issue -c id -f value` to get the value of the Token)

5. View the Results file which will determine what hosts need their OS packages upgraded. Results are provided in json format in a file named: `RESULTS_*your-platform9-management-plane-url*.json`. Example below: 
```
$jq '.' RESULTS_example.platform9.net.json
[
  [
    "host: pf9-opnstk-01.example.net",
    "id: 65f0c7b7-c93c-4b3f-bb26-d32b98ce32cb",
    "IP: 172.16.0.21",
    {
      "libvirt": {
        "result": "FAIL",
        "installed": "1.3.1",
        "required": "3.10"
      }
    },
    {
      "qemu": {
        "result": "FAIL",
        "installed": "2.5.0",
        "required": "2.10"
      }
    },
    {
      "ovs": {
        "result": "PASS",
        "installed": "2.5.8",
        "required": "2.5.8"
      }
    }
  ]
]
```
**Please note: The results shown above need to be within these version ranges. If you see any results that PASS which are not within these version ranges, please notify your TAM accordingly**

- Openvswitch - 2.5.8 to 2.11.1
- QEMU - 2.10 to 2.12
- libvirt - 3.10 to 6.0

### OS Package Upgrade Steps

1. Log into the host and run individual update commands:
```
Ubuntu: 
- add-apt-repository -y cloud-archive:queens
- apt update -y
#For the libvirt upgrade, you will hit "Enter" and accept the defaults to the questions
- apt-get install --only-upgrade \*libvirt\*
- apt-get install --only-upgrade \*qemu\*
- apt-get install --only-upgrade pf9-neutron-ovs-agent

RHEL/CentOS:
- yum update \*libvirt\*
- yum update \*qemu\*
- yum update pf9-neutron-ovs-agent
```
2. Once the OS packages are updated, perform the following steps to reload the services with the new binaries:
```
libvirt/QEMU (Note: You can avoid VM downtime by migrating them to hosts that already have the updated OS packages):
- Either reboot the host or perform a hard reboot of VM's which involves fully stopping VM's and starting them back up

OVS:
- restart OVS on the host
- For RHEL/CentOS: "systemctl restart openvswitch"
- For Ubuntu: "systemctl restart openvswitch-switch"
```
3. To verify all is well, run the upgrade checker again against your hosts:
```
ansible-playbook \
        playbook_get_hosts_check_upgrade.yml \
        -u your_username_on_host \
        --private-key=~/your_private_sshkey \
        -e "pf9_du=https://example.platform9.net \
            pmo_token=xxxxYOUR_KEYSTONE_TOKENxxx"
```
4. Once you verify that the results have "PASSED" with the proper versions, then you are ready to move forward with the Platform9 4.0 upgrade 


## Miscellaneous Upgrade Checker Information
### Quick Start Upgrade Checker Command:
```
ansible-playbook \
        playbook_get_hosts_check_upgrade.yml \
        -u your_uname_on_host \
        --private-key=~/your_priv_sshkey \
        -e "pf9_du=https://example.platform9.net \
            pmo_token=xxxxYOUR_KEYSTONE_TOKENxxx"
```

### Query Host Inventory Upgrade Checker Command:
```
ansible-playbook \
        get_hosts.yml \
        -e "pf9_du=https://example.platform9.net \
            pmo_token=xxxxYOURxxTOKENxxxHERExxxx"
```

### Upgrade Checker Command:
If you already have an inventory file built by get_hosts.yaml and want to check the upgrade status of hosts (The inventory must have been generated from role/get_hosts):
```
ansible-playbook \
        check_upgrade.yml \
        -u example \
        --private-key=~/.ssh/example-pf9 \
        -i inventory_your.pf9-mgmt-plane.address_hosts
```

### Providing Variables:
Variables can be provided in vars.yaml or as command line arguments at runtime. 

### Filtering Hosts against roles:
Within var.yaml the filter logic is comprised of two variables, the filter_logic and pf9_roles.
filter_logic allows you to specify `any` or `all`. This will determine the logic applied when filtering the host contained in resmgr.
- ALL:
    A host must have ALL of the roles provided in pf9_roles assigned to it in order to be selected
- ANY:
    A host will be select if it has ANY roles in pf9_roles assigned to it.

Only uncommented roles are included in the filter.
```
filter_logic:
  "any"

pf9_roles:
  - 'pf9-neutron-ovs-agent'
  - 'pf9-cindervolume-base'
  - 'pf9-neutron-base'
  - 'pf9-ceilometer'
  - 'pf9-glance-role'
  - 'pf9-ostackhost-neutron'
  - 'pf9-cindervolume-lvm'
  - 'pf9-neutron-ovs-agent'
  - 'pf9-neutron-l3-agent'
  - 'pf9-neutron-metadata-agent'
  - 'pf9-neutron-dhcp-agent'
  - 'pf9-kube'
```
