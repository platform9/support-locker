#!/usr/bin/env bash

function create_thinpool_from_block_device()
{
  local block_dev="$1"
  local vg_name="$2"

  # Create physical volume
  pvcreate "$block_dev"

  # Create volume group
  vgcreate "$vg_name" "$block_dev"

  # Create logical volumes (one for data, another for metadata)
  lvcreate --wipesignatures y -n thinpool "$vg_name" -l 95%VG
  lvcreate --wipesignatures y -n thinpoolmeta "$vg_name" -l 1%VG

  # Convert data volume to a thin volume, using metadata volume for thin volume metadata
  lvconvert -y --zero n -c 512K --thinpool "$vg_name/thinpool" --poolmetadata "$vg_name/thinpoolmeta"

  # Ensure both volumes are extended as necessary
  # 1. Create a profile
  cat > "/etc/lvm/profile/$vg_name-thinpool.profile" <<EOF
activation {
  thin_pool_autoextend_threshold=80
  thin_pool_autoextend_percent=20
}
EOF

  # 2. Link profile to data volume
  lvchange --metadataprofile "$vg_name-thinpool" "$vg_name/thinpool"
  # 3. Enable monitoring of data volume size, so that extension is triggered automatically
  lvs -o+seg_monitor
}

function usage()
{
  cat >&2 <<EOF
Usage:

bd2tp.sh BLOCK_DEV VOL_GRP_NAME

Creates an lvm thin pool in the VOL_GRP_NAME volume group (e.g. docker-vg)
using the BLOCK_DEV block device (e.g. /dev/xvdb).

NOTE: There is a set of rules that determine valid volume group names. This
script does not validate the name. See the lvm manpage for details.
EOF
}

if [ "$#" -ne 2 ]; then
  usage
  exit 1
else
  echo create_thinpool_from_block_device "$1" "$2"
fi
