#!/bin/bash
# Run this script from the same folder where the installation script was executed.

print_error() {
    echo -e "\e[91m$1\e[0m"
}

print_success() {
    echo -e "\e[92m$1\e[0m"
}

uninstall_aws_load_balancer_controller() {
    kubectl delete --ignore-not-found=true -f v2_5_4_full.yaml
    if [ $? -ne 0 ]; then
        print_error "An error occurred while deleting the AWS Load Balancer Controller."
        exit 1
    fi

    print_success "AWS Load Balancer Controller uninstalled successfully."
}

delete_ingress_class() {
    kubectl delete --ignore-not-found=true -f v2_5_4_ingclass.yaml
    if [ $? -ne 0 ]; then
        print_error "An error occurred while deleting IngressClass and IngressClassParams."
        exit 1
    fi

    print_success "IngressClass and IngressClassParams deleted successfully."
}

detach_iam_policy() {
    policy_arn=$(aws iam list-policies --query "Policies[?PolicyName=='"${cluster_name}_LBPolicy"'].Arn" --output text)

    if [ -n "$policy_arn" ]; then
        role_name=$(aws iam list-entities-for-policy --policy-arn "$policy_arn" --query "PolicyRoles[].RoleName" --output text)
        if [ -n "$role_name" ]; then
            aws iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn"
            if [ $? -ne 0 ]; then
                print_error "An error occurred while detaching the IAM policy from the role."
                exit 1
            fi
        fi
    fi

    print_success "IAM policy detached from the AWS Load Balancer Controller service account."
}

delete_iam_service_account() {
    eksctl delete iamserviceaccount --cluster="$cluster_name" --namespace="kube-system" --name="aws-load-balancer-controller"
    if [ $? -ne 0 ]; then
        print_error "An error occurred while deleting the IAM service account."
        exit 1
    fi

    print_success "IAM service account deleted successfully."
}

delete_iam_policy() {
    policy_arn=$(aws iam list-policies --query "Policies[?PolicyName=='"${cluster_name}_LBPolicy"'].Arn" --output text)

    if [ -n "$policy_arn" ]; then
        aws iam delete-policy --policy-arn "$policy_arn"
        if [ $? -ne 0 ]; then
            print_error "An error occurred while deleting the IAM policy."
            exit 1
        fi
    fi

    print_success "IAM policy deleted successfully."
}

echo "Uninstalling AWS Load Balancer Controller and related resources"

# Check for eksctl
if ! command -v eksctl &> /dev/null; then
    print_error "eksctl is not installed. Please install eksctl and try again."
    exit 1
fi

# Check for kubectl
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed. Please install kubectl and try again."
    exit 1
fi

read -p "Enter the EKS cluster name: " cluster_name
read -p "Enter the AWS region: " region

# Delete the AWSLoadBalancerController
read -p "Do you want to delete the AWSLoadBalancerController? (y/n): " delete_awsLBController
if [[ "$delete_awsLBController" =~ ^[Yy]$ ]]; then
    uninstall_aws_load_balancer_controller
fi

# Delete the IngressClass and IngressClassParams (if installed)
read -p "Do you want to delete the IngressClass and IngressClassParams? (y/n): " delete_ingress_class

if [[ "$delete_ingress_class" =~ ^[Yy]$ ]]; then
    delete_ingress_class
fi

detach_iam_policy
delete_iam_service_account
delete_iam_policy

echo "AWS Load Balancer Controller and related resources uninstalled successfully."