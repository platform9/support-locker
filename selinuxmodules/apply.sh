#!/bin/bash

# This used to be done in a for loop, but converted to explicit commands so that
# CS and others can easily uncomment / change files / edit things as needed.  We don't expect more
# then 10 or 15 policies so, in the long run, there isn't much value in making it dynamic.

pushd policies

# Container certs
checkmodule -M -m -o ./container_cert.mod ./container_cert.te
semodule_package -o container_cert.pp -m container_cert.mod
semodule -i container_cert.pp

# Platform9 user
checkmodule -M -m -o ./pf9.mod ./pf9.te
semodule_package -o pf9.pp -m pf9.mod
semodule -i pf9.pp

popd
