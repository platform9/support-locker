package main

import (
	"context"
	"flag"
	"fmt"
	"io/ioutil"
	"os"
	"path/filepath"

	"github.com/vishvananda/netlink"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/homedir"
)

const (
	VarOptPf9 = "/var/opt/pf9/"
)

func SetKubeInterface(ifName, version string) error {
	kubeIfFile := "kube_interface_v" + version
	ifData := "V" + version + "_INTERFACE " + ifName + "\n"
	ifDataBytes := []byte(ifData)

	if _, err := os.Stat(VarOptPf9); os.IsNotExist(err) {
		os.MkdirAll(VarOptPf9, 0766)
	}

	kubeIfPath := filepath.Join(VarOptPf9, kubeIfFile)
	fd, err := os.OpenFile(kubeIfPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0644)
	defer fd.Close()
	if err != nil {
		fmt.Printf("Failed to open file %s\n", kubeIfPath)
		return err
	}

	err = ioutil.WriteFile(kubeIfPath, ifDataBytes, 0644)
	if err != nil {
		fmt.Printf("Failed to update PF9 kube interface file: %s\n", err)
		return err
	}

	return nil
}

func GetFirstIP(ifName string) (string, error) {
	var ipAddr string
	link, err := netlink.LinkByName(ifName)
	if err != nil {
		fmt.Printf("Could not find interface with name %s\n", ifName)
		return "", err
	}
	ipAddrs, err := netlink.AddrList(link, netlink.FAMILY_V4)
	if err != nil {
		fmt.Printf("Could not find any addresses for interface %s\n", ifName)
		return "", err
	} else {
		for _, addr := range ipAddrs {
			ipAddr = addr.IPNet.IP.String()
			break
		}
	}
	return ipAddr, nil
}

func main() {
	var kubeconfig *string
	if home := homedir.HomeDir(); home != "" {
		kubeconfig = flag.String("kubeconfig", filepath.Join(home, ".kube", "config"), "(optional) absolute path to the kubeconfig file")
	} else {
		kubeconfig = flag.String("kubeconfig", "", "absolute path to the kubeconfig file")
	}

	var srcNode = flag.String("src", "", "Name of Source Node to replicate")
	var dstNode = flag.String("dst", "", "Name/IP to use for new node (optional)")
	var ifName = flag.String("interface", "", "Name of interface to use for k8s")
	var version = flag.String("ipVersion", "4", "IP version to look for")
	flag.Parse()

	var newNodeName string

	// Interface may have multiple IPs. Above logic just selects first IP on interface
	// --dst can be used to specify exact IP (or hostname?) to use as k8s nodename
	if dstNode != nil && *dstNode != "" {
		newNodeName = *dstNode
	} else {
		ipAddr, err := GetFirstIP(*ifName)
		if err != nil {
			return
		}
		newNodeName = ipAddr
	}

	fmt.Printf("Using new nodename as %s\n", newNodeName)

	if err := SetKubeInterface(*ifName, *version); err != nil {
		return
	}

	config, err := clientcmd.BuildConfigFromFlags("", *kubeconfig)
	if err != nil {
		panic(err.Error())
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		panic(err.Error())
	}

	node, err := clientset.CoreV1().Nodes().Get(context.TODO(), *srcNode, metav1.GetOptions{})
	if err != nil {
		fmt.Printf("Error fetching node: %s\n", err)
		return
	}

	newNode := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: newNodeName,
			Labels: node.Labels},
		Spec: node.DeepCopy().Spec,
	}
	newNode.Labels["kubernetes.io/hostname"] = newNodeName

	node, err = clientset.CoreV1().Nodes().Create(context.TODO(), newNode, metav1.CreateOptions{})
	if err != nil {
		fmt.Printf("Failed to create new node %s\n", newNodeName)
	}

	fmt.Printf("NewNode = %+v\n", newNode)
}
