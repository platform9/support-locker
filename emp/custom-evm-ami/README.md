# EVM AMI Builder

This directory contains a Packer template and related configuration files to create pre-configured Amazon Machine Images (AMIs) compatible with the EMP product. The resulting AMIs are optimized for running the EVMs with pre-installed dependencies and utilities.

---

## Getting Started

### Prerequisites

1. **Install Packer**:
   - Download and install Packer from [Packer Downloads](https://www.packer.io/downloads).

2. **Install Packer Amazon EBS Plugin**:
   - The Packer Amazon EBS builder requires the Amazon and Ansible plugins. Install them by running:
     ```bash
     packer plugins install github.com/hashicorp/amazon
     packer plugins install github.com/hashicorp/ansible
     ```
   - These commands ensure all required plugins are installed and ready for use.

3. **AWS Credentials**:
   - Ensure your AWS credentials (`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`) are configured.

4. **Required Permissions**:
   - The IAM user or role must have the following permissions to create and manage AMIs:

     ```json
     [
       "ec2:DescribeInstances",
       "ec2:RunInstances",
       "ec2:StopInstances",
       "ec2:TerminateInstances",
       "ec2:CreateImage",
       "ec2:CopyImage",
       "ec2:DescribeImages",
       "ec2:DeregisterImage",
       "ec2:CreateSnapshot",
       "ec2:DeleteSnapshot",
       "ec2:DescribeSnapshots",
       "ec2:DescribeTags",
       "ec2:CreateTags",
       "ec2:DeleteTags",
       "ec2:ModifyImageAttribute",
       "ec2:DescribeVpcs",
       "ec2:DescribeSubnets",
       "ec2:DescribeSecurityGroups",
       "ec2:DescribeRegions",
       "ec2:DescribeVolumes",
       "ec2:CreateKeyPair",
       "ec2:DeleteKeyPair",
       "ec2:ModifySnapshotAttribute"
     ]
     ```
---

### Usage

#### Clone the Repository
```bash
git clone https://github.com/platform9/support-locker.git
cd emp/custom-evm-ami
```

#### Define Environment Variables
Fill the `packer-vars.json` file to define variables specific to your environment. Below is an example:

```json
{
  "source_ami": "ami-1234567890abcdef0",
  "region": "us-west-1",
  "ami_region": "us-east-1,us-east-2",
  "kubelet_version": "1.30",
  "subnet_id": "subnet-0123456789abcdef0",
  "security_group_id": "sg-0123456789abcdef0",
  "associate_public_ip_address": true,
  "source_os_flavor": "ubuntu",
  "source_os_version": "22.04",
  "ami_groups": "all",
  "snapshot_groups": "all"
}
```

For `source_ami` you can find lastest ubuntu ami owned by amazon(`099720109477`) with aws describe-image cli utility. Below is an example:

```bash
aws ec2 describe-images --region us-west-1 \
  --filters Name="name",Values="ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64*"  Name="owner-id",Values="099720109477" \
  --query 'Images[*].[ImageId,CreationDate]' --output text \
  | sort -k2 -r | head -n1 | awk '{print $1}'
```

#### Validate the Configuration
Validate the Packer template before building the AMI:

```bash
packer validate -var-file=packer-vars.json evm-image-template.json
```

#### Build the AMI
Run the following command to build the AMI:

```bash
packer build -var-file=packer-vars.json evm-image-template.json
```

## Customization

This repository is designed to be customizable to meet your specific requirements.

### Packer Variables

The Packer variables are defined in the `packer-vars.json` file. Below is a description of the variables you can customize:


| Variable            | Description                                                                                      | Required | Example                    |
| ------------------- | ------------------------------------------------------------------------------------------------ | -------- | -------------------------- |
| `source_ami`        | The base AMI ID to use for building.                                                             | Yes      | `ami-1234567890abcdef0`    |
| `region`                  | The AWS region where EC2 instance will be lunched and the AMI will be built.                                                     | Yes      | `us-west-2`                |
| `ami_region`        | The AWS region(s) to distribute the AMI.                                                         | Yes      | `us-west-1`                |
| `kubelet_version`   | The Kubernetes kubelet version to install.                                                       | Yes      | `1.30`                   |
| `subnet_id`         | The subnet in which the EC2 instance will be launched. **Note:** The machine from where the Packer build command is run should be able to connect to the EC2 instance launched by Packer. If not, consider enabling `associate_public_ip_address=true`.                                           | Yes      | `subnet-0123456789abcdef0` |
| `security_group_id` | The security group ID for the EC2 instance. **Note:** The machine from where the Packer build command is run should be able to communicate with the EC2 instance launched by Packer over SSH on port `22`.                                                   | Yes      | `sg-0123456789abcdef0`     |
| `associate_public_ip_address` | Whether to associate a public IP address with the EC2 instance. (`true` or `false`)             | Yes      | `true`                     |
| `source_os_flavor`        | The operating system flavor of the source AMI. Currently, we only support `ubuntu`.                                                | Yes      | `ubuntu`                   |
| `source_os_version`       | The version of the source operating system. Currently, we only support `20.04` and `22.04`.                                                     | Yes      | `22.04`                    |
| `ami_groups`        | AMI permissions (`all` for public or account IDs for private). Leave blank for private AMI.      | No       | `all`                      |
| `snapshot_groups`   | Snapshot permissions (`all` for public or account IDs for private). Leave blank for private AMI. | No       | `all`                      |

### Ansible Playbook

The Ansible playbook (`./ansible-stack/evm-image.yml`) is included to pre-configure the AMI. You can modify this playbook to:

- Install additional software.
- Apply custom configurations.
- Set up services or dependencies required for your environment.

For example, you can add roles, tasks, or handlers to include more utilities in the AMI.

### Cleanup Script

The cleanup script (`scripts/cleanup.sh`) is executed at the end of the provisioning process to optimize the AMI size by:

- Removing unnecessary files.
- Cleaning up temporary directories.
- Clearing logs.

You can customize this script to add further cleanup steps specific to your environment.

## Generated Artifacts

After a successful build, the following artifacts will be generated:

### AMI

The created AMI will have the following characteristics:

- **Name**: The AMI name will follow the format:
  ```plaintext
  evm-image-<timestamp>-<kubelet_version>

- **Tags**: The AMI will be tagged with:
  ```plaintext
  Name: evm-image-<timestamp>-<kubelet_version>
  CreatedBy: Packer
  Timestamp: <timestamp>,
  emp.pf9.io/evm-custom-ami: true,
  emp.pf9.io/evm-custom-ami/k8s-version: <kubelet_version>,
  emp.pf9.io/evm-custom-ami/os-flavor: ubuntu,
  emp.pf9.io/evm-custom-ami/os-version: <source_ami_os_version>
  ```

- **Regions**: The AMI can be distributed to multiple regions as specified in the `packer-vars.json` file.

- **Permissions**:
    - **Public**: If snapshot_groups and ami groups are set to all.
    - **Private**: To your account if snapshot_groups and ami groups are left blank.

### Manifest File:
A JSON manifest file will be generated, containing metadata about the AMI. Example filename:
```plaintext
evm-image-<kubelet_version>-manifest.json
```
The manifest includes details such as the AMI name, ID, and other relevant properties.

## Support

If you encounter any issues or have questions, please open an issue on GitHub or contact support@platform9.com
