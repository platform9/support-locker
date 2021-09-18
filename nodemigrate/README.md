# nodemigrate

Creates a new K8s node resource based off existing Node resource, copying over the Labels and Spec.Config

## To compile

go build -o nodemigrate main.go

## To use
```
Usage of ./nodemigrate:
  -src string
    	Name of Source Node to replicate (required)
  -interface string
    	Name of interface to use for k8s. By default will use first found IP on interface
  -dst string
    	Name/IP to use for new node. Useful if interface has multiple IPs (optional)
  -ipVersion string
    	IP version to look for (default "4")
  -kubeconfig string
    	(optional) absolute path to the kubeconfig file (default "<HOMEDIR>/.kube/config")
```

--src and --interface are always required

By default it will find 1st IP on interface to use as nodename. If --dst is set, it will take whatever that is, as precedence. This is in case the interface has multiple IPs configured or you want to use a different nodename than first found IP.

## Limitations

1. It is not supported to change the VIP on the masters. This requires much more enhancements to change certs, VIP keepalived and subnet configuration. It is not a trivial change. Therefore on master nodes, be careful if changing interfaces would require a change to VIP.

2. This does not cleanup the old Node resource out of precaution, as it is still active at the time this script is run. Once you have rebooted/upgraded, and the new Node has come up and is in Ready state, you may delete the old Node resource. 
