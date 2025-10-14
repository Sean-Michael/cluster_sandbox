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
kind create cluster --name sandbox-mgmt --config manifests/kind/clustery.yaml
```

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

## SSO with Keycloak

You can enable Keycloak SSO to provide centralized authentication with proper RBAC for Rancher and ArgoCD:

```shell
./cluster-install.sh --with-keycloak --with-argocd
```

This sets up:

- **Keycloak** identity provider with OIDC
- **Self-signed CA** for TLS certificates
- **Pre-configured realm** with admin and viewer groups
- **OIDC clients** for Rancher and ArgoCD

See [KEYCLOAK_SSO_SETUP.md](KEYCLOAK_SSO_SETUP.md) for complete setup instructions, including:

- How to configure Rancher and ArgoCD OIDC authentication
- Distributing the CA certificate
- Managing users and permissions
- Preventing teammates from breaking your stuff (viewers group)

## Installing the CA Certificate

Services use HTTPS with a private CA. Install `./certs/ca.crt` to avoid browser warnings:

**macOS:**

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ./certs/ca.crt
```

**Linux (Ubuntu/Debian):**

```bash
sudo cp ./certs/ca.crt /usr/local/share/ca-certificates/cluster-ca.crt
sudo update-ca-certificates
```

**Linux (RHEL/Fedora):**

```bash
sudo cp ./certs/ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

**Windows (PowerShell as admin):**

```powershell
Import-Certificate -FilePath ".\certs\ca.crt" -CertStoreLocation Cert:\LocalMachine\Root
```

## Accessing Services

After installation you can access:

- **Rancher**: <https://rancher.localhost>
- **ArgoCD**: <https://argocd.localhost> (if installed)
- **Keycloak**: <https://keycloak.localhost> (if installed)
