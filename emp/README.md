# cluster-info.sh


Platform9's cluster-info.sh is a simple utility that uses kubectl
and
* Goes through each node and save the describe output
* Gets the list of pods
* Gets the list of PVCs


```
wget https://raw.githubusercontent.com/platform9/support-locker/master/emp/cluster-info.sh
chmod +x cluster-info.sh
# ./cluster-info.sh -k <kubeconfig.yaml> -o <output directory>

./cluster-info.sh -k ~/Downloads/kf-ap1.yaml -o /tmp/kf-ap1/
```
