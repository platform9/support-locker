terraform {
  required_providers {
    emp = {
      source = "platform9/emp"
    }
  }
}

/*
variable "token" {
  description = "The EMP OIDC login token"
  type        = string
}
*/

provider "emp" {
  token = "sample-token"
}

# Sample elasticmachinepool resource tf
resource "emp_elasticmachinepool" "sample-emp" {
  name = "sample-emp"
  bm_security_group_attach_to_eks = "true"
  cloud_provider_ref = "sample-cp"
  cluster_refs = [  "sample-eks-1" ]
}

# Sample ekscluster resource tf
resource "emp_ekscluster" "sample-eks-1" {
  name = "sample-eks-1"
  emp_name = "sample-emp"
  cluster_name = "sample-eks-1"
  cloud_provider_ref = "sample-cp"
  cluster_region = "us-west-2"
  security_groups = [ "sample-sg-1" ]
}

# sample baremetalpool resoruce tf
resource "emp_baremetalpool" "sample-bmpool" {
  name = "sample-bmpool"
  emp_name = "sample-emp"
  pool_template = {
    azs = ["us-west-2a", "us-west-2b"]
    instance_type = "m5.metal"
    max_machines = 3
    min_machines = 1
    region = "us-west-2"
    ssh_key = "sample-aws-sshkey"
    vpc_id = "dummy-vpc"
    subnets_info = [
        {
          az = "us-west-2a"
          id = "subnet-dummy-1"
          is_private = false
        },
        {
          az = "us-west-2b"
          id = "subnet-dummy-2"
          is_private = false
        }
      ]
    # defaults
    container_cidr = "10.20.0.0/16"
    service_cidr =  "10.21.0.0/16"
    vm_network_cidr = "10.0.2.0/24"
    enable_spot = false
    }
}

# Sample evmpool resource tf
resource "emp_evmpool" "sample-evmpool-1" {
  name = "sample-evmpool-1"
  emp_name = "sample-emp"
  eks_cluster_ref = "sample-eks-1"
  instance_type = "m5.4xlarge"
  min_evms = 4
  # Default supported family 
  os_family = "ubuntu"
  overcommit_multipler = {
    cpu = 16
    memory = 1.5
  }
  ssh_key = "sample-public-key"
  root_disk_config = {
    size = "50Gi"
  }
  # default, (efs is also allowed)
  storage_type = "ebs"
}