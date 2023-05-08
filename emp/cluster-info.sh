#!/usr/bin/env bash

# This is a simple bash script that intended to be used to help Platform9
# get the details about a clsuter.
# Ths script relies on bash, kubectl, awk, tail, sort, head utilities to be present

set -e
# Initialize variables with default values
kubeconfig=""
output_dir=""
KUBECTL_BIN="/Users/rparikh/Downloads/kubectl"
files_to_tar=()

usage() { echo "cluster-info: -k <kubeconfig> -o <output directory> " 1>&2; exit 1; }

# Parse command line arguments
while getopts ":k:o:" opt; do
  case $opt in
    k)
      kubeconfig="$OPTARG"
      ;;
    o)
      output_dir="$OPTARG"
      ;;
    *)
      usage
      ;;
  esac
done

function check_prereqs() {
  if ! command -v kubectl > /dev/null ; then
    echo "Error: kubectl command is not installed."
    exit 1
  fi

  if ! command -v sort > /dev/null ; then
    echo "Error: sort command is not installed."
    exit 1
  fi


  if [ -z "$kubeconfig" ]; then
    echo "Error: The kubeconfig file must be specified with the -k option."
    exit 1
  fi

  if [ -z "$output_dir" ]; then
    echo "Error: The output directory must be specified with the -o option."
    exit 1
  fi
  
  echo "All required commands are installed."
}

check_prereqs
mkdir -p $output_dir/nodes/
echo "Using kubeconfig $kubeconfig"
echo "Using output_dir $output_dir"


KUBECTL="$KUBECTL_BIN --kubeconfig $kubeconfig"

function getNodesDetails() {
  echo "Getting node details"
  # Get list of nodes in the cluster
  node_list=$($KUBECTL get nodes --no-headers | awk '{print $1}')

  # Loop through each node
  for node in $node_list
  do
    local node_file=$output_dir/nodes/$node.yaml
    # Get the describe output for the node and print it to console
    echo "Saving to  $node_file"
    $KUBECTL describe node $node > $node_file
    files_to_tar+=($node_file)
  done
}

function getPVCs() {
  local out_file=$output_dir/pvcs.json
  echo "Getting pvcs saving to $out_file"
  files_to_tar+=($out_file)
  $KUBECTL get pvc -A -o json > $out_file

}

function getPods() {
  local out_file=$output_dir/pods.json
  echo "Getting pods saving to $out_file"
  files_to_tar+=($out_file)
  $KUBECTL get pods -A -o json > $out_file
}

function getTop() {
  local out_file=$output_dir/top_container_list.txt
  echo "Getting top pods"
  # Get list of containers sorted by CPU usage
  container_list=$($KUBECTL top pods --all-namespaces | sort --reverse --key 3)

  # Print the list of containers to console
  files_to_tar+=($out_file)
  echo "$container_list" > $out_file
}

function tarAll() {
  local tarfile=$output_dir/cluster-info.tgz
  echo "Creating tar file $tarfile"
  tar -cvzf $tarfile "${files_to_tar[@]}"
  echo "Upload tar file $tarfile to Platform9"
}

getNodesDetails
getPVCs
getPods
getTop
tarAll
echo "Done"