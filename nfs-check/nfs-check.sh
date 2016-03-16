#!/bin/bash
#
# Run to check if file locking is enabled in a directory
#

if [ $# -ne 1 ]; then
    >&2 echo 'Usage: nfslocker.sh <full path to nfs mount>'
    exit 1
fi

if [ ! -d $1 ]; then
    >&2 echo 'Directory $1 does not exist'
    exit 1
fi

if [ $USER != "root" ]; then
    >&2 echo 'This script must be executed as root'
    exit 1
fi

type nfsstat >/dev/null 2>&1 || { echo >&2 "nfsstat command not found. Please install required package to proceed"; exit 1; }

nfs_flags=`nfsstat -m $1 | grep -i flags`
nfs_flags=`echo $nfs_flags | sed 's/[ \t]//' | sed 's/Flags\://'`

service rpcbind status | grep running >/dev/null 2>&1

if [ $? -ne 0 ]; then
    2>&1 echo 'rpcbind daemon not running'
    exit 1
fi

type flock >/dev/null 2>&1 || { echo >&2 "flock command not found. Please install required package to proceed"; exit 1; }


/bin/bash -c "exec 200>$1/lock.tmp && flock -n 200 2>&1 && rm -f $1/lock.tmp" >/dev/null 2>&1


if [ $? -ne 0 ]; then
    echo 'Cannot get lock on path' $1', please check your NFS settings'
    echo 'NFS volume was mounted with options:'
    echo '-----------------------------------------------------------'
    for opt in `echo $nfs_flags | tr ',' '\n'`; do
	echo $opt
    done
    echo '-----------------------------------------------------------'
    echo 'Please refer to Platform9 KB article on NFS to troubleshoot'
else
    echo 'NFS mount can be used as Platform9 instance store'
fi



