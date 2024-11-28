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
IMAGES="$IMAGES registry.k8s.io/pause:3.1"
IMAGES="$IMAGES registry.k8s.io/kube-controller-manager-amd64:v1.30.2"
IMAGES="$IMAGES registry.k8s.io/kube-scheduler-amd64:v1.30.2"
IMAGES="$IMAGES docker.io/nginxinc/nginx-unprivileged:1.25"
IMAGES="$IMAGES registry.k8s.io/kube-scheduler-amd64:v1.21.4"
IMAGES="$IMAGES registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.9.0"
IMAGES="$IMAGES registry.k8s.io/sig-storage/csi-provisioner:v3.6.1"
IMAGES="$IMAGES registry.k8s.io/sig-storage/csi-resizer:v1.9.1"
IMAGES="$IMAGES registry.k8s.io/sig-storage/csi-snapshotter:v8.0.1"
IMAGES="$IMAGES registry.k8s.io/sig-storage/snapshot-controller:v6.3.1"
IMAGES="$IMAGES quay.io/prometheus/prometheus:v2.48.1"
IMAGES="$IMAGES quay.io/prometheus-operator/prometheus-operator:v0.70.0"
IMAGES="$IMAGES quay.io/prometheus-operator/prometheus-config-reloader:v0.70.0"
IMAGES="$IMAGES quay.io/prometheus/alertmanager:v0.26.0"

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
        image=`cat $IMG_FILE`
        printf "\r${Cb} ⋯ %s  ${Cy}Processing: %*s %s ${CR}" "${spinstr:0:1}" "$last_word_length" "$image" >&2
        last_word_length=${#IMG_FILE}
        if (( last_word_length > max )); then
            max=$last_word_length
        fi
        sleep "$delay"
    done
    max=$(expr $max + 32)
    printf "\r${Cgr}%s ✓ Completed %*s ${CR}\n" "$(date +'%F %T')" "$max" >&2
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
        warn "$0 FAILED (rc=$rc)"
    fi
    exit $rc
}
trap exit_trap EXIT

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

# pull_images - pulls container images with spinner
pull_images() {
    local num_img    
    num_imgs=$(num_images)
    num_img=$(trim_space $num_imgs)
    info "Pulling $num_img images for Elastic Machine Pool by Platform9"
    
    # Temporary file for output
    local tmpfile
    tmpfile=$(mktemp)
    debug "Logs are in $tmpfile"
    # Async pull with spinner
    {
        for img in $IMAGES; do
            echo "$img" > $IMG_FILE
            info "Getting $img"
            $CNT_CMD pull "$img" 2>&1
        done
    } > "$tmpfile" 2>&1 &
    
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

# push_images_registry - loads container images into given registry
push_images_registry() {
    [ $# -eq 1 ] || fail "push: Please provide registry url"
    local reg=${1%%/}

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
            echo "$img" > $IMG_FILE
            tg=$(trans "$img")
            $CNT_CMD tag "$img" "$tg"
            $CNT_CMD push "$tg"
            $CNT_CMD rmi "$tg"
            debug "Pushed $tg into $reg"
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
            info "Using '$CNT_CMD' to handle container images"
            [ $# -eq 2 ] || fail "push: Please provide registry endpoint"
            push_images_registry "$2"
            shift ;;
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
