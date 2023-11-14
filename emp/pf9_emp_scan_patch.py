
# Platform9 AWS CloudFormation Deployment Script for System Patch Manager & Amazon Inspector Classic
# 
# Description:
# This Python script performs the following tasks:
# 1. Finds the default patch baseline for Ubuntu OS in an AWS region using AWS Systems Manager (SSM).
# 2. Downloads a AWS CloudFormation template from Platform9 GitHub repository. 
# 3. Deploys the CloudFormation template in an AWS region, using the found patch baseline as a parameter. 
#    
# Note:
# An S3 bucket in same AWS region is required to upload the Cloudformation template as it is larger than 51200 bytes
#
# Usage:
# python3 script_name.py --region <your_aws_region> --s3-bucket <your_s3_bucket>
# 
# Replace "script_name.py" with the actual name of your Python script, 
# "your_aws_region" with the desired AWS region code (e.g., us-east-1, us-west-2), 
# and "your_s3_bucket" with the name of the S3 bucket in "your_aws_region" to upload the CloudFormation template.
#
# Note: Ensure that you have the necessary AWS credentials and permissions configured. Ensure S3 bucket is accessible.

import boto3
import subprocess
import os
import json
import sys
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('--region', required=True, help='AWS region')
parser.add_argument('--s3-bucket', required=True, help='S3 bucket to store CloudFormation template')
args = parser.parse_args()

# Define the GitHub repository URL and CloudFormation template path
github_repo_url = 'https://raw.githubusercontent.com/platform9'
template_path_on_github = 'support-locker/master/emp/emp_scan_patch_cftemplate.yml'

# Download the CloudFormation template from GitHub
template_url = f"{github_repo_url}/{template_path_on_github}"
template_path = 'pf9-cf-template.yaml'
subprocess.check_call(['curl', '-o', template_path, '-L', template_url])

# Define the Operating System
# Supported Operating Systems: UBUNTU, CENTOS, WINDOWS, ROCKY_LINUX, DEBIAN, REDHAT_ENTERPRISE_LINUX, SUSE
# ORACLE_LINUX, ALMA_LINUX, RASPBIAN, AMAZON_LINUX, AMAZON_LINUX_2, AMAZON_LINUX_2022, AMAZON_LINUX_2023
os_type = 'UBUNTU'

# Initialize the AWS SSM client
ssm_client = boto3.client('ssm', region_name=args.region)

try:
    # Describe available patch baselines
    response = ssm_client.describe_patch_baselines()

    # Filter for the default Ubuntu patch baseline
    for baseline in response['BaselineIdentities']:
        if baseline.get('OperatingSystem') == os_type:
            baseline_id = baseline.get('BaselineId')
            baseline_name = baseline.get('BaselineName')
            baseline_description = baseline.get('BaselineDescription')
            data = {
                os_type: {
                    "value": baseline_id,
                    "label": baseline_name,
                    "description": baseline_description,
                    "disabled": False
                }
            }
            json_string = json.dumps(data)
            PatchBaselines = json_string
    try:
        PatchBaselines
        print(f"Default patch baseline found for {os_type} in selected AWS region\n{PatchBaselines}")
    except NameError:
        raise ValueError(f"No default patch baseline found for {os_type} in selected AWS region")
    
    # Create a variable for patch baseline key Value to pass as Cloudformation Stack Parameter    
    parameter_key_value = 'SelectedPatchBaselines=%s' % PatchBaselines

    # Deploy the CloudFormation stack using the template and passing parameters
    cfn_stack_name = 'pf9-emp-scan-patch-%s' % args.region

    # Deploy the stack with parameters using the AWS CLI
    subprocess.check_call(['aws', 'cloudformation', 'deploy', '--stack-name', cfn_stack_name, '--template-file', template_path, '--region', args.region, '--parameter-overrides', parameter_key_value, '--s3-bucket', args.s3_bucket, '--capabilities', 'CAPABILITY_NAMED_IAM'])

    print(f"Stack '{cfn_stack_name}' has been deployed.")

except Exception as e:
    print(f"Error: {e}")

# Clean up: Delete the modified CloudFormation template
os.remove(template_path)