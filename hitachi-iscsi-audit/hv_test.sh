#!/bin/bash
H="https://192.168.176.64/ConfigurationManager/v1/objects/storages/938000745751"
U="openstack"
P="${HITACHI_PASS:?HITACHI_PASS env var must be set}"

hv() { curl -sk -u "$U:$P" -H "Accept: application/json" -H "Content-Type: application/json" "$H/$1"; }

echo "=== LDEV 105 ==="
hv "ldevs/105"
echo ""

echo "=== LDEV 129 ==="
hv "ldevs/129"
echo ""

echo "=== LDEV 105 ==="
hv "ldevs/105"
echo ""

echo "=== LUNS CL1-D HG6 (pn01) ==="
hv "luns?portId=CL1-D&hostGroupNumber=6&count=20"
echo ""

echo "=== LUNS CL2-D HG5 (pn01) ==="
hv "luns?portId=CL2-D&hostGroupNumber=5&count=20"
