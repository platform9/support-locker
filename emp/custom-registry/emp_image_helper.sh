#!/usr/bin/env bash

# Detect shell and set appropriate options
if [ -n "$ZSH_VERSION" ]; then
    # Zsh-specific settings
    setopt SH_WORD_SPLIT  # Ensure word splitting behavior similar to sh/bash
    setopt NULLGLOB       # Allow empty globs
    setopt POSIX_BUILTINS # Use POSIX standard for builtins
elif [ -n "$BASH_VERSION" ]; then
    # Bash-specific settings
    set -o pipefail
    export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
fi

# Strict error handling
set -eu

IMAGES=""
#Upstream Images
IMAGES="$IMAGES public.ecr.aws/platform9/pause:3.6"
IMAGES="$IMAGES public.ecr.aws/platform9/tigera/operator:v1.32.12"
IMAGES="$IMAGES public.ecr.aws/platform9/calico/apiserver:v3.27.5"
IMAGES="$IMAGES public.ecr.aws/platform9/calico/kube-controllers:v3.27.5"
IMAGES="$IMAGES public.ecr.aws/platform9/calico/node:v3.27.5"
IMAGES="$IMAGES public.ecr.aws/platform9/calico/pod2daemon-flexvol:v3.27.5"
IMAGES="$IMAGES public.ecr.aws/platform9/calico/cni:v3.27.5"
IMAGES="$IMAGES public.ecr.aws/platform9/calico/typha:v3.27.5"
IMAGES="$IMAGES public.ecr.aws/platform9/kubevirt/cdi-importer:v1.59.1"
IMAGES="$IMAGES public.ecr.aws/platform9/kubevirt/cdi-cloner:v1.59.1"
IMAGES="$IMAGES public.ecr.aws/platform9/kubevirt/cdi-uploadserver:v1.59.1"
IMAGES="$IMAGES public.ecr.aws/platform9/kubevirt/cdi-apiserver:v1.59.1"
IMAGES="$IMAGES public.ecr.aws/platform9/kubevirt/cdi-controller:v1.59.1"
IMAGES="$IMAGES public.ecr.aws/platform9/kubevirt/cdi-operator:v1.59.1"
IMAGES="$IMAGES public.ecr.aws/platform9/kubevirt/cdi-uploadproxy:v1.59.1"
IMAGES="$IMAGES public.ecr.aws/platform9/jetstack/cert-manager-controller:v1.15.0"
IMAGES="$IMAGES public.ecr.aws/platform9/jetstack/cert-manager-cainjector:v1.15.0"
IMAGES="$IMAGES public.ecr.aws/platform9/jetstack/cert-manager-webhook:v1.15.0"
IMAGES="$IMAGES public.ecr.aws/platform9/provider-aws/cloud-controller-manager:v1.27.1"
IMAGES="$IMAGES public.ecr.aws/platform9/coredns/coredns:v1.11.1"
IMAGES="$IMAGES public.ecr.aws/platform9/kas-network-proxy/proxy-agent:v0.0.32"
IMAGES="$IMAGES public.ecr.aws/platform9/metrics-server/metrics-server:v0.6.4"
IMAGES="$IMAGES public.ecr.aws/platform9/autoscaling/addon-resizer:1.8.14"
IMAGES="$IMAGES public.ecr.aws/platform9/kube-proxy:v1.26.6"
IMAGES="$IMAGES public.ecr.aws/platform9/envoyproxy/envoy:v1.26.1"
IMAGES="$IMAGES public.ecr.aws/platform9/platform9/virtvnc:v1"
IMAGES="$IMAGES public.ecr.aws/platform9/platform9/multus:v3.7.2-pmk-2644970"
IMAGES="$IMAGES public.ecr.aws/platform9/kubebuilder/kube-rbac-proxy:v0.11.0"
IMAGES="$IMAGES public.ecr.aws/platform9/platform9/luigi-plugins:v0.5.5"
IMAGES="$IMAGES public.ecr.aws/platform9/eks-distro/kubernetes-csi/external-attacher:v4.5.0-eks-1-29-7"
IMAGES="$IMAGES public.ecr.aws/platform9/eks-distro/kubernetes-csi/external-provisioner:v4.0.0-eks-1-29-7"
IMAGES="$IMAGES public.ecr.aws/platform9/eks-distro/kubernetes-csi/external-resizer:v1.10.0-eks-1-29-7"
IMAGES="$IMAGES public.ecr.aws/platform9/ebs-csi-driver/aws-ebs-csi-driver:v1.29.1"
IMAGES="$IMAGES public.ecr.aws/platform9/eks-distro/kubernetes-csi/livenessprobe:v2.12.0-eks-1-29-7"
IMAGES="$IMAGES public.ecr.aws/platform9/eks-distro/kubernetes-csi/node-driver-registrar:v2.10.0-eks-1-29-7"
IMAGES="$IMAGES public.ecr.aws/platform9/amazon/aws-efs-csi-driver:v1.5.5"
IMAGES="$IMAGES public.ecr.aws/platform9/eks-distro/kubernetes-csi/livenessprobe:v2.9.0-eks-1-27-latest"
IMAGES="$IMAGES public.ecr.aws/platform9/kube-state-metrics/kube-state-metrics:v2.12.0"
IMAGES="$IMAGES public.ecr.aws/platform9/prometheus/node-exporter:v1.8.0"
IMAGES="$IMAGES public.ecr.aws/platform9/prometheus/prometheus:v2.52.0"
IMAGES="$IMAGES public.ecr.aws/platform9/prometheus-operator/prometheus-config-reloader:v0.73.2"
IMAGES="$IMAGES public.ecr.aws/platform9/eks-distro/kubernetes-csi/external-provisioner:v3.4.0-eks-1-27-latest"
IMAGES="$IMAGES public.ecr.aws/platform9/eks-distro/kubernetes-csi/node-driver-registrar:v2.7.0-eks-1-27-latest"
IMAGES="$IMAGES public.ecr.aws/platform9/pause:3.1"
IMAGES="$IMAGES public.ecr.aws/platform9/kubevirt/cdi-apiserver:v1.59.1"
IMAGES="$IMAGES public.ecr.aws/platform9/eks-distro/kubernetes-csi/external-provisioner:v3.4.0-eks-1-27-latest"
IMAGES="$IMAGES public.ecr.aws/platform9/sig-storage/snapshot-controller:v8.0.1"
IMAGES="$IMAGES public.ecr.aws/platform9/eks-distro/kubernetes-csi/external-snapshotter/csi-snapshotter:v7.0.1-eks-1-29-7"
IMAGES="$IMAGES public.ecr.aws/platform9/aws-ebs-csi-driver:0.2.0"

#Builder changes
#Kubevirt images
IMAGES="$IMAGES public.ecr.aws/platform9/virt-exportproxy:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/fedora-with-test-tooling-container-disk:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/disks-images-provider:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/network-slirp-binding:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/virt-controller:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/virt-handler:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/virt-exportserver:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/pr-helper:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/example-cloudinit-hook-sidecar:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/cirros-custom-container-disk-demo:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/virtio-container-disk:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/alpine-ext-kernel-boot-demo:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/alpine-with-test-tooling-container-disk:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/libguestfs-tools:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/example-hook-sidecar:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/example-disk-mutation-hook-sidecar:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/alpine-container-disk-demo:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/cirros-container-disk-demo:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/vm-killer:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/winrmcli:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/sidecar-shim:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/network-passt-binding:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/virt-operator:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/virt-api:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/virt-launcher:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/conformance:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/fedora-realtime-container-disk:1.1.189"
IMAGES="$IMAGES public.ecr.aws/platform9/nfs-server:1.1.189"

IMAGES="$IMAGES public.ecr.aws/platform9/evm-stack-controller-manager:1.0.376"
IMAGES="$IMAGES public.ecr.aws/platform9/pmk-vpc-cni:1.1.152"
IMAGES="$IMAGES public.ecr.aws/platform9/emp-pmk-init:1.1.190"
IMAGES="$IMAGES public.ecr.aws/platform9/cni-metrics-helper:1.1.152"
IMAGES="$IMAGES public.ecr.aws/platform9/emp-pod-webhook:1.1.223"
IMAGES="$IMAGES public.ecr.aws/platform9/pmk-vpc-cni-init:1.1.152"

#EKS images
IMAGES="$IMAGES public.ecr.aws/platform9/jetstack/cert-manager-controller:v1.14.4"
IMAGES="$IMAGES public.ecr.aws/platform9/jetstack/cert-manager-webhook:v1.14.4"
IMAGES="$IMAGES public.ecr.aws/platform9/jetstack/cert-manager-cainjector:v1.14.4"
IMAGES="$IMAGES public.ecr.aws/platform9/emp-webhook-eks:1.1.22"
IMAGES="$IMAGES public.ecr.aws/platform9/evm-autoscaler:1.1.132"
IMAGES="$IMAGES public.ecr.aws/platform9/evm-vpc-cni:1.1.81"
IMAGES="$IMAGES public.ecr.aws/platform9/evm-vpc-cni-init:1.1.81"
IMAGES="$IMAGES public.ecr.aws/platform9/eks-vol-watcher:1.0.376"
IMAGES="$IMAGES public.ecr.aws/platform9/grafana/promtail:2.9.3"

#Charts
IMAGES="$IMAGES public.ecr.aws/platform9/emp-helm-charts/eks-cluster-chart:1.1.742"
IMAGES="$IMAGES public.ecr.aws/platform9/emp-helm-charts/baremetal-chart:1.1.855"
IMAGES="$IMAGES public.ecr.aws/platform9/emp-helm-charts/cert-manager:1.14.4"
IMAGES="$IMAGES public.ecr.aws/platform9/emp-helm-charts/promtail:6.15.5"
IMAGES="$IMAGES public.ecr.aws/platform9/emp-helm-charts/promtail-temp:6.15.5"

READ_REPO=""
profile=""
region=""
n=""
CHART_NAME=""
CHART=""
VERSION=""
rflag=""
VERBOSE=0
K8S_CMD=kubectl
K8SSECRET=emp-secret
DRYRUN=0
CNT_CMD=docker
IMG_FILE=$(mktemp)

# Colors init via tput
Cg="$(tput bold 2>/dev/null && tput setaf 0 2>/dev/null || /bin/true)"                    # Gray
Cb="$(tput bold 2>/dev/null && tput setaf 7 2>/dev/null && tput setab 4 2>/dev/null || /bin/true)"    # White on Blue
Cy="$(tput bold 2>/dev/null && tput setaf 3 2>/dev/null && tput setab 0 2>/dev/null || /bin/true)"    # Yellow on Black
Cr="$(tput bold 2>/dev/null && tput setab 1 2>/dev/null || /bin/true)"    # Red
Cgr="$(tput bold 2>/dev/null && tput setaf 2 2>/dev/null || /bin/true)"                    # Green
CR="$(tput sgr0 2>/dev/null || /bin/true)"                                                # RESET

# Spinner animation
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    local temp=""
    local image=""

    if [ -f "$IMG_FILE" ]; then
        debug "File $IMG_FILE exists."
        image=`cat $IMG_FILE`
    else
        image=$IMG_FILE
    fi
    last_word_length=0
    max=0
    while kill -0 "$pid" 2>/dev/null; do
        temp="${spinstr#?}"
        spinstr=$temp${spinstr%"$temp"}
        if [ -f "$IMG_FILE" ]; then
            image=$(cat "$IMG_FILE")
        fi
        printf "\r\033[K${Cb} ⋯ %s  ${Cy}Processing: %s${CR}" "${spinstr:0:1}" "$image" >&2
        last_word_length=${#IMG_FILE}
        if (( last_word_length > max )); then
            max=$last_word_length
        fi
        sleep "$delay"
    done
    max=$(expr $max + 32)
    printf "\r\033[K${Cgr}%s ✓ Completed %*s${CR}\n" "$(date +'%F %T')" "$max" >&2
}

# debug - prints a DEBUG message (normally gray on black)
debug() {
    [ $VERBOSE -le 0 ] || echo "$(date +'%F %T') $Cg DEBUG: $* $CR" >&2
}

# info - prints an INFO message (normally white on blue)
info() {
    echo "$(date +'%F %T') $Cb INFO: $* $CR" >&2
}

# warn - prints a WARN message (normally yellow on black)
warn() {
    echo "$(date +'%F %T') $Cy WARN: $* $CR" >&2
}

# fail - prints a FATAL message (yellow on red) and exits the script
fail() {
    local args=${*:-error}
    echo "$(date +'%F %T') $Cr FATAL $args $CR" >&2
    trap - EXIT
    exit 2
}

# SUPPORTING FUNCTIONS

exit_trap() {
    local rc=$?
    if [ $rc -eq 0 ]; then
        debug "END"
    else
        echo "$0 FAILED (rc=$rc)" >&2
    fi
    exit $rc
}
#trap exit_trap EXIT

# dummy_cmd - replacement for docker/kubelet to display parameters/output
dummy_cmd() {
    if echo "$*" | grep -q -- '-$'; then
        echo "DRY-RUN: $* << EOF" >&2
        cat >&2
        echo EOF >&2
    else
        echo "DRY-RUN: $*" 2>&1
    fi
}

# num_images returns a number of images
num_images() {
    # shellcheck disable=SC2086
    echo $IMAGES | wc -w
}

trim_space() {
    local str=$1
    # Trim leading and trailing spaces using parameter expansion
    trimmed_str="${str#"${str%%[![:space:]]*}"}"  # Trim leading spaces
    trimmed_str="${trimmed_str%"${trimmed_str##*[![:space:]]}"}"  # Trim trailing spaces
    echo "$trimmed_str"
}

name_split() {
    local iimg="$1"
    #debug "$1"
    local chartn="${iimg#*/}"     
    CHART_NAME="${chartn#*/}"   
    CHART_NAME="${CHART_NAME%%:*}"
    #debug "$CHART_NAME" 
}

aws_create_repo() {
    local profile="$1"
    local region="$2"
    if [[ -z "$4" ]]; then
            repo_name="$CHART_NAME"
        else
		    repo_name="$4/$CHART_NAME"
    fi 
    if [[ "$3" == *public* ]]; then
    # Try to create the repository, suppressing output and errors
    if ! aws ecr-public create-repository --repository-name "$repo_name" --region "$region" --profile "$profile" >> $tmpfile 2>&1; then
        # Check if the error is 'repository already exists' or 'already exists' in the error message
        if ! grep -q "already exists" "$tmpfile"; then
            echo "Error creating repository: $repo_name. Exiting."
            exit 1
        else
            echo "Repository $repo_name already exists. Continuing..."
        fi
    fi
else
    # Try to create the repository, suppressing output and errors
    if ! aws ecr create-repository --repository-name "$repo_name" --region "$region" --profile "$profile" >> $tmpfile 2>&1; then
        # Check if the error is 'repository already exists' or 'already exists' in the error message
        if ! grep -q "already exists" "$tmpfile"; then
            echo "Error creating repository: $repo_name. Exiting."
            exit 1
        else
            echo "Repository $CHART_NAME already exists. Continuing..."
        fi
    fi
fi

}

helm_pull() {
	if [[ -z "$CHART" || -z "$VERSION" ]]; then
		fail "helm_pull: Chart name and version are required"
	fi

	info "Pulling Helm chart: $CHART@$VERSION"
	helm pull oci://"$CHART" --version "$VERSION" || fail "Failed to pull Helm image:"
	debug "Pulled Helm Chart $CHART@$VERSION"
}

# pull_images - pulls container images with spinner
pull_images() {
    local num_img    
    num_imgs=$(num_images)
    num_img=$(trim_space "$num_imgs")
    info "Pulling $num_img images for Elastic Machine Pool by Platform9"

    if ! $CNT_CMD info > /dev/null 2>&1; then
        fail "Docker is not running. Please start Docker and try again."
        exit 1
    fi
    # Temporary file for output
    local tmpfile
    tmpfile=$(mktemp)
    debug "Logs are in $tmpfile"

    # Async pull with spinner
    {
        for img in $IMAGES; do
            debug "$img" > $IMG_FILE
            info "Getting $img"
            # Suppress verbose logs, redirect them to the temporary file
            if [[ "$img" == *chart* || "$img" == *charts* ]]; then
		        #debug "here1"
                VERSION="${img##*:}" # Extract version after the colon
                CHART="${img%:*}"
		        name_split "$img"	
                helm_pull 
            else
                $CNT_CMD pull "$img" --platform linux/amd64 >> "$tmpfile" 2>&1 || debug "Failed to pull $img" >> "$tmpfile"
                info "Pulled $img locally"
            fi
        done
    } &

    # Capture PID of background process
    local pull_pid=$!

    # Show spinner while pulling
    spinner "$pull_pid"

    # Check pull results
    if wait "$pull_pid"; then
        info "Successfully pulled $num_img images"
    else
        warn "Some images failed to pull. Check the log:"
        cat "$tmpfile" >&2
    fi

    # Clean up temp file
    rm "$tmpfile"
}

# helm_push - Pushes Helm chart to the specified registry
helm_push() { 
    local pbs="${CHART_NAME%%/*}"
    local filename="${CHART_NAME#*/}"
    local chart_tgz="$filename-$VERSION.tgz"
    local registry="$1"
    if [[ -z "$2" ]]; then
        repo_name="$registry/$pbs"
    else
		repo_name="$registry/$2/$pbs"
    fi
    if [[ -z "$chart_tgz" || -z "$registry" ]]; then
        fail "helm_push: Chart tarball and target registry are required"
    fi
    info "Pushing Helm chart: $chart_tgz to $repo_name"
    helm push "$chart_tgz" oci://"$repo_name" || fail "Failed to push Helm chart $chart_tgz to $registry"
    info "Pushed Helm chart $chart_tgz to $registry"
}

# push_images_registry - loads container images into given registry
push_images_registry() {
    #[ $# -eq 1 ] || fail "push: Please provide registry url"
    local reg=${1%%/}
    #echo "$1,$2,$3,$4"
    local num_img
    num_imgs=$(num_images)
    num_img=$(trim_space $num_imgs)
    info "Pushing $num_img images into $reg container registry/repository..."
    
    # Temporary file for output
    local tmpfile
    tmpfile=$(mktemp)
    
    # Async push with spinner
    {
        # Transformation function for image names
        local trans
        if echo "$reg" | grep -q /; then
            trans() {
                echo "$reg/$(basename "$1")"
            }
        else
            trans() {
                local i2="${1##docker.io/}" #remove docker.io
                local i3="${i2##registry.k8s.io/}" #remove registry.k8s.io from i2
                echo "$reg/${i3##quay.io/}" #remove quay.io from i3
            }
        fi
        
        # Push images
        for img in $IMAGES; do
            local tg
            name_split "$img"
            VERSION="${img##*:}"
            echo "$VERSION"
            if [[ "$rflag" == 1 ]]; then
		        aws_create_repo "$3" "$4" "$1" "$2"
	        else
		        debug "here in jfrog"
		        #debug "tagging:$tg"
	        fi
            sleep 3
            if [[ -z "$2" ]]; then
                tg="$1/$CHART_NAME:$VERSION"
            else
		        tg="$1/$2/$CHART_NAME:$VERSION"
            fi
            debug "tagging:$tg"
            if [[ "$img" == *chart* || "$img" == *charts* ]]; then
                CHART="${img%:*}"
		        helm_push "$reg" "$2"
            else
                echo "$img" > $IMG_FILE
                #tg=$(trans "$img")
                debug "$tg"
                $CNT_CMD tag "$img" "$tg"
                $CNT_CMD push "$tg"
                $CNT_CMD rmi "$tg"
                debug "Pushed $tg into $reg"
            fi
        done
    } > "$tmpfile" 2>&1 &
    
    # Capture PID of background process
    local push_pid=$!
    
    # Show spinner while pushing
    spinner "$push_pid"
    
    # Check push results
    if wait "$push_pid"; then
        info "Finished pushing $num_img images into $reg"
    else
        warn "Some images failed to push. Check the log:"
        cat "$tmpfile" >&2
    fi
    
    # Clean up temp file
    rm "$tmpfile"
}

# import_secrets creates the YAML that can be applied
# on k8s using the current docker/podman configuration
import_secrets() {
    local f
    if echo "$CNT_CMD" | grep -qw podman; then
        f=/run/user/0/containers/auth.json
        [ -f "$f" ] || f=/run/containers/0/auth.json
    else
        f=$HOME/.docker/config.json
    fi
    [ -f "$f" ] || fail "Registry secrets file $f not available"

    # Use base64 with appropriate flag for both GNU and BSD base64
    local B64CONTENT
    B64CONTENT=$(base64 -w0 "$f" 2>/dev/null || base64 "$f")

    $K8S_CMD apply -f - << EOF
apiVersion: v1
data:
   .dockerconfigjson: $B64CONTENT
kind: Secret
metadata:
   name: $K8SSECRET
   namespace: kube-system
type: kubernetes.io/dockerconfigjson
EOF
    info "Registry secrets kube-system/$K8SSECRET imported from $f"
}

# usage - prints usage
usage() {
    local rc=${1:-0}
    local SELF
    SELF=$(readlink -f "$0")
    [ ! -f "$SELF" ] && SELF='curl -fsSL https://raw.githubusercontent.com/platform9/support-locker/refs/heads/master/emp/custom-registry/emp_image_helper.sh | sh -s --'
    cat << _EOF >&2
Usage: $SELF <options> <commands>

IMAGE-COMMANDS:
    pull                      pulls the Elastic Machine Pool by Platform9 container images locally
    push <registry[/repo]>    pushes the Elastic Machine Pool by Platform9 images into remote container registry server
    load node1 [node2 [...]]  loads the images tarball to remote nodes  (note: ssh-access required)

OPTIONS:
    -n|--dry-run              show commands instead of running
    -V|--version              print version of the script
    -v                        verbose output

EXAMPLES:

    # Pull images from default container registries, push them to custom registry server (default repositories)
    $SELF pull push your-registry.company.com:5000

    # Pull images from default container registries, push them to custom registry server and Elastic Machine Pool by Platform9 repository
    $SELF pull
    $SELF push your-registry.company.com:5000/emp-pf9

    #Push Images to ECR
    $SELF push you-registry --type ecr --profile [profile_to_be_used] --region [aws_region] --n [namespace_name_if_needed]
    #In ecr the namespace is there for better grouping

    #Push Images to artifactory
    $SELF push your-registry --type artifactory --n [namespace_if_required]
    #In artifactory the namespace is the repository in which you want all the images if it is not specified create neccesary repositories for it

    # Push images to password-protected remote registry, then import docker/podman configuration as kubernetes secret
    $CNT_CMD login your-registry.company.com:5000
    $SELF pull
    $SELF push your-registry.company.com:5000/emp-pf9
    $SELF import-secrets

_EOF
    exit "$rc"
}

# Argument parsing with zsh and bash compatibility
[ $# -gt 0 ] || usage

while [ $# -gt 0 ]; do
    case "$1" in
        pull)
            info "Using '$CNT_CMD' to handle container images"
            pull_images
            ;;
        push)
            shift  
            registry_url="$1"
            shift
            info "Registry URL: $registry_url"  # Debugging
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --type)
                        if [[ -z "${2:-}" ]]; then
                            fail "Please specify a type"
                            exit 1
                        fi
                        READ_REPO="$2"
                        info "Registry Type: $READ_REPO"  # Debugging
                        if [[ "$READ_REPO" != "ecr" && "$READ_REPO" != "artifactory" ]]; then
                            fail "Please specify a correct registry type (ecr/artifactory)"
                            exit 1
                        fi
                        shift 2
                        ;;
                    --profile)
                        if [[ -z "${2:-}" ]]; then
                            fail "Please specify a profile"
                            exit 1
                        fi
                        profile="$2"
                        debug "AWS Profile: $profile"  # Debugging
                        shift 2
                        ;;
                    --region)
                        if [[ -z "${2:-}" ]]; then
                            fail "Please specify a region"
                            exit 1
                        fi
                        region="$2"
                        debug "AWS Region: $region"  # Debugging
                        shift 2
                        ;;
                    --n)
                        if [[ -z "${2:-}" ]]; then
                            fail "Please specify namespace"
                            exit 1
                        fi
                        n="$2"
                        debug "Nmps $n"
                        shift 2
                        ;;
                    *)
                        debug "Unknown option: $1"
                        #usage
                        exit 1
                        ;;
                esac
            done

            # Validate inputs based on type
            if [[ -z "$READ_REPO" ]]; then
                fail "Please specify the registry type (--type ecr/artifactory)"
                exit 1
            fi

            if [[ "$READ_REPO" == "ecr" ]]; then
                rflag=1
                info "Type is ECR, validating inputs..."  # Debugging
                if [[ -z "$profile" || -z "$region" ]]; then
                    fail "For ECR, please provide --profile and --region"
                    exit 1
                fi
                if [[ -z "$n" ]]; then
                    warn "Namespace not given"
                fi
                info "Using '$CNT_CMD' to handle container images"
                push_images_registry "$registry_url" "$n" "$profile" "$region"
                info "ECR inputs validated: Profile=$profile, Region=$region"  # Debugging
            elif [[ "$READ_REPO" == "artifactory" ]]; then
                rflag=0
                info "Using '$CNT_CMD' to handle container images"
                if [[ -z "$n" ]]; then
                    warn "Namespace not given"
                fi
                push_images_registry "$registry_url" "$n"
            fi
        ;;
        import-secrets)
            import_secrets
            ;;
        -n|--dry-run)
            # dry-run mode
            CNT_CMD="dummy_cmd $CNT_CMD"
            K8S_CMD="dummy_cmd $K8S_CMD"
            LOAD='cat > /dev/null'
            DRYRUN=1
            ;;
        -v)
            VERBOSE=$((VERBOSE+1))
            ;;
        -V|--version)
            echo "Elastic Machine Pool by Platform9 v1.2"
            shift "$#"
            break ;;
        -h|--help)
            usage
            break ;;
        --)
            shift
            break ;;
        *)
            usage
            break ;;
    esac
    shift
done

[ $# -eq 0 ] || fail "Unknown argument(s): $*"