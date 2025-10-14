# Cluster Sandbox

This is just a place for some config (mostly shell scripts) that stands up a simple little dev management cluster of sorts for playing around with Kubernetes Orchestration, GitOps, etc.

## Getting Started

I've been testing with `kind` just for the speed but these configs would feasibly work with minimal modification for any cluster.

To create a kind cluster for our purposes, consider the following. 

Install KIND if you don't have it already, for macOS:

```shell
brew install kind
```

Now create a cluster with ingress support.

```shell
cat <<EOF | kind create cluster --name rancher-management --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
kubeadmConfigPatches:
- |
    kind: InitConfiguration
    nodeRegistration:
    kubeletExtraArgs:
        node-labels: "ingress-ready=true"
extraPortMappings:
- containerPort: 80
    hostPort: 80
    protocol: TCP
- containerPort: 443
    hostPort: 443
    protocol: TCP
EOF
```

> Alternatively you may use the above manifest from file `manifests/kind/cluster.yaml`

You are now ready to initialize the cluster and install our applications. 

Simply run `cluster_install.sh` with this cluster as your current `KUBECONFIG` context.
