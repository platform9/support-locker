#!/bin/bash

set -e

if [[ "x${KUBECONFIG}" == "x" ]]; then
    echo "KUBECONFIG variable not exported. Exiting."
    exit 1
fi

date=$(date +%s)
tmpdir="/tmp/${date}"

echo "creating $tmpdir for support bundle"

mkdir -p $tmpdir


kubectl get clustersnapshots --all-namespaces -o json > $tmpdir/clustersnapshots.json
kubectl get rebalancerjobs --all-namespaces -o json > $tmpdir/rebalancerjobs.json
kubectl get migrationplans --all-namespaces -o json > $tmpdir/migrationplans.json
kubectl get evmmigration --all-namespaces -o json > $tmpdir/evmmigrations.json
kubectl get virtualmachineinstancemigration --all-namespaces -o json > $tmpdir/vmim.json
kubectl get namespaces > $tmpdir/namespaces.txt
kubectl get nodes -o json > $tmpdir/nodes.json || true
kubectl get pods --all-namespaces -o json > $tmpdir/pods.json || true
org_ns=$(kubectl get namespaces --no-headers | grep 'org-' | awk '{print $1}' | xargs)

echo "Found organization namespace: $org_ns"

kubectl logs --namespace kube-system deploy/pf9-evm-stack > $tmpdir/pf9-evm-stack.log

tar cvzf /tmp/rebalancer-$date.tgz $tmpdir > /dev/null 2>&1

rm -rf $tmpdir

echo "Wrote support bundle at: /tmp/rebalancer-$date.tgz"
