# Cluster Sandbox

This is just a place for some config (mostly shell scripts) that stands up a simple little dev management cluster of sorts for playing around with Kubernetes Orchestration, GitOps, etc.

## Getting Started

I've been testing with `kind` just for the speed but these configs would feasibly work with minimal modification for any cluster.

### Setup KIND

Install KIND if you don't have it already, for macOS:

```shell
brew install kind
```

Create a cluster with ingress support:

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

### Install Management Components

The `cluster-install.sh` script sets up the management cluster. By default it installs the core components (NGINX, cert-manager, and Rancher). You can optionally add monitoring, logging, or GitOps tools.

Basic install:

```shell
./cluster-install.sh
```

Install everything:

```shell
./cluster-install.sh --all
```

Install with monitoring:

```shell
./cluster-install.sh --with-monitoring
```

The script is idempotent so you can run it multiple times without issues. It'll skip anything already installed.

Access Rancher at <http://rancher.localhost> with username `admin` and password `admin` (or whatever you set via `RANCHER_PASSWORD`).

### Import Clusters

Use `import-cluster.sh` to bring external clusters into Rancher management.

From kubeconfig context:

```shell
./import-cluster.sh kubeconfig docker-desktop
```

From GKE:

```shell
./import-cluster.sh gke my-project my-cluster us-central1
```

From AKS:

```shell
./import-cluster.sh aks my-resource-group prod-cluster
```

Enable monitoring on imported cluster:

```shell
./import-cluster.sh enable-monitoring c-m-12345678
```

The cluster ID comes from Rancher UI after import.

After installation you should be able to access the web interfaces for Rancher and optionally ArgoCD from their localhost names. You will have to accept the self-signed certificate warning.
