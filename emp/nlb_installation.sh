#!/bin/bash

print_error() {
    echo -e "\e[91m$1\e[0m"
}

echo "Installing AWS LoadBalancer Controller"
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.7/docs/install/iam_policy.json

# check for awscli
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is not installed. Please install it and try again."
    exit 1
fi

echo "Creating IAM policy"
# check for existing iam policies
policy_arn=$(aws iam list-policies --query "Policies[?PolicyName=='EMPAWSLoadBalancerControllerIAMPolicy'].Arn" --output text)

if [ -z "$policy_arn" ]; then
    aws iam create-policy \
        --policy-name EMPAWSLoadBalancerControllerIAMPolicy \
        --policy-document file://iam_policy.json

    # Error handling
    if [ $? -ne 0 ]; then
        print_error "An error occurred while creating the IAM policy."
        exit 1
    fi

    echo "Please copy the Policy ARN displayed above."
else
    echo "IAM policy AWSLoadBalancerControllerIAMPolicy already exists."
    read -p "Do you want to delete the current policy and create a new one? (y/n): " choice

    # Run the deletion script
    if [[ $choice =~ ^[Yy]$ ]]; then 
        echo "Deleting current IAM policy"
        # delete iam policy
        # Get the policy ARN and versions
        versions=$(aws iam list-policy-versions --policy-arn "$policy_arn" --query "Versions[?IsDefaultVersion==\`false\`].VersionId" --output text)

        # Delete non-default versions
        if [ -n "$versions" ]; then
            for version in $versions; do
                aws iam delete-policy-version --policy-arn "$policy_arn" --version-id "$version"
                if [ $? -ne 0 ]; then
                    echo "An error occurred while deleting policy version $version."
                    exit 1
                fi
            done
        fi

        # Detach the policy from entities (roles, users, and groups)
        entities=$(aws iam list-entities-for-policy --policy-arn "$policy_arn" --query "PolicyRoles[].RoleName" --output text)
        entities+=" $(aws iam list-entities-for-policy --policy-arn "$policy_arn" --query "PolicyUsers[].UserName" --output text)"
        entities+=" $(aws iam list-entities-for-policy --policy-arn "$policy_arn" --query "PolicyGroups[].GroupName" --output text)"

        if [ -n "$entities" ]; then
            for entity in $entities; do
                aws iam detach-role-policy --role-name "$entity" --policy-arn "$policy_arn" 2>/dev/null
                aws iam detach-user-policy --user-name "$entity" --policy-arn "$policy_arn" 2>/dev/null
                aws iam detach-group-policy --group-name "$entity" --policy-arn "$policy_arn" 2>/dev/null
            done
        fi

        # Delete the policy
        aws iam delete-policy --policy-arn "$policy_arn"
        if [ $? -ne 0 ]; then
            echo "An error occurred while deleting the IAM policy."
            exit 1
        fi

        echo "IAM Policy AWSLoadBalancerControllerIAMPolicy deleted successfully."
        

        # Check the exit status of the deletion script
        if [ $? -ne 0 ]; then
            print_error "An error occurred while deleting the current IAM policy."
            exit 1
        fi

        # Create a new policy
        echo "Creating new IAM policy"
        aws iam create-policy \
            --policy-name EMPAWSLoadBalancerControllerIAMPolicy \
            --policy-document file://iam_policy.json

        if [ $? -ne 0 ]; then
            print_error "An error occurred while creating the new IAM policy."
            exit 1
        fi

        echo "Please copy the Policy ARN displayed above."
    else
        echo "Skipping policy creation."
    fi
fi

# check for eksctl
if ! command -v eksctl &> /dev/null; then
    print_error "eksctl is not installed. Please follow the installation instructions at: https://github.com/weaveworks/eksctl/blob/main/README.md#installation"
    exit 1
fi

read -p "Enter the EKS cluster name: " cluster_name
read -p "Enter the AWS region: " region
read -p "Enter the Policy ARN: " policy_arn

eksctl utils associate-iam-oidc-provider --region=$region --cluster=$cluster_name --approve

eksctl create iamserviceaccount --cluster=$cluster_name --namespace=kube-system --name=aws-load-balancer-controller --role-name EMPAmazonEKSLoadBalancerControllerRole --attach-policy-arn=$policy_arn --approve --region=$region --override-existing-serviceaccounts


if [ $? -ne 0 ]; then
    print_error "An error occurred while executing the commands."
    exit 1
fi

read -p "Do you want to install cert-manager? (y/n): " install_cert_manager

if [[ "$install_cert_manager" =~ ^[Yy]$ ]]; then
    curl -Lo cert-manager.yaml https://github.com/jetstack/cert-manager/releases/download/v1.5.4/cert-manager.yaml

    # Adding tolerations
    sed -i '16928i\      tolerations:\n      - effect: NoSchedule\n        key: emp.pf9.io/EMPSchedulable\n        value: "true"' cert-manager.yaml
    sed -i '16986i\      tolerations:\n      - effect: NoSchedule\n        key: emp.pf9.io/EMPSchedulable\n        value: "true"' cert-manager.yaml
    sed -i '17063i\      tolerations:\n      - effect: NoSchedule\n        key: emp.pf9.io/EMPSchedulable\n        value: "true"' cert-manager.yaml

    kubectl apply --validate=false -f cert-manager.yaml

    if [ $? -ne 0 ]; then
        print_error "An error occurred while installing cert-manager."
        read -p "Do you want to rollback cert-manager changes? (y/n): " rollback_cert_manager

        if [[ "$rollback_cert_manager" =~ ^[Yy]$ ]]; then
            kubectl delete --ignore-not-found=true -f cert-manager.yaml

            if [ $? -ne 0 ]; then
                print_error "An error occurred while rolling back cert-manager installation."
                exit 1
            fi

            echo "Cert-manager installation rolled back successfully."
        else
            exit 1
        fi
    fi
    # wait for all pods to be in ready state
    kubectl wait --for=condition=Ready pods --all -n cert-manager
    # adding wait for all resources to get ready
    sleep 10
fi

curl -Lo v2_4_7_full.yaml https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases/download/v2.4.7/v2_4_7_full.yaml
sed -i.bak -e '561,569d' ./v2_4_7_full.yaml
sed -i.bak -e 's|your-cluster-name|'"$cluster_name"'|' ./v2_4_7_full.yaml
kubectl apply -f v2_4_7_full.yaml

if [ $? -ne 0 ]; then
    print_error "An error occurred while applying the controller specification."
    read -p "Do you want to rollback controller specification installation? (y/n): " controller_spec

    if [[ "$controller_spec" =~ ^[Yy]$ ]]; then
        kubectl delete --ignore-not-found=true -f v2_4_7_full.yaml

        if [ $? -ne 0 ]; then
            print_error "An error occurred while rolling back the controller specification installation."
            exit 1
        fi

        echo "controller specification installation rolled back successfully."
    else
        exit 1 
    fi
fi

read -p "Do you want to install ingressclass and ingressclassparams? (y/n): " install_ingress_class

if [[ "$install_ingress_class" =~ ^[Yy]$ ]]; then
    curl -Lo v2_4_7_ingclass.yaml https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases/download/v2.4.7/v2_4_7_ingclass.yaml
    kubectl apply -f v2_4_7_ingclass.yaml

    if [ $? -ne 0 ]; then
        print_error "An error occurred while installing ingressclass and ingressclassparams."
        read -p "Do you want to rollback ingress installation? (y/n): " ingress

        if [[ "$ingress" =~ ^[Yy]$ ]]; then
            kubectl delete --ignore-not-found=true -f v2_4_7_ingclass.yaml

            if [ $? -ne 0 ]; then
                print_error "An error occurred while rolling back the ingress installation."
                exit 1
            fi

            echo "ingress installation rolled back successfully."
        else
            exit 1 
        fi
    fi
fi

echo "AWS load balancer controller and ingressclass installed successfully."
echo "To check the status of the controller, run the following command:"
echo "kubectl get deployment -n kube-system aws-load-balancer-controller"

