#!/bin/bash
set -e -x
SECRET=$1
VERSION=$2

function usage
{
  echo "download.sh <secret> <version"
  echo "where secret is the secret user agent, ask Platform9 team for the secret word"
  echo "Version is for v-5.2.0-1558488
"
  exit 1
}

if [ -z "$SECRET" ]
then
      usage
fi

if [ -z "$VERSION" ]
then
      usage
fi

curl --user-agent ${SECRET}  https://pf9-airctl.s3-accelerate.amazonaws.com/${VERSION}/index.txt | awk  -v version=${VERSION} -v secret=${SECRET} '{ print "curl --user-agent "secret"  https://pf9-airctl.s3-accelerate.amazonaws.com/"version"/"$4 " > " $4}'| bash