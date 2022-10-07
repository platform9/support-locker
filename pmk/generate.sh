#!/bin/bash

clusterawsadm bootstrap iam print-cloudformation-template --config bootstrap-config.yaml > aws-capi-cloudformation.template
