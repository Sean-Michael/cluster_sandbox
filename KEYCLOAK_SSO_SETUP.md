# Keycloak SSO Setup Guide

This guide walks you through setting up Single Sign-On (SSO) with Keycloak Operator for Rancher and ArgoCD.

## Overview

- **Keycloak**: Identity Provider (IdP) running at `https://keycloak.localhost`
- **Rancher**: Configured with OIDC authentication
- **ArgoCD**: Configured with OIDC authentication
- **TLS**: All services use HTTPS with a self-signed CA

## Installation

### 1. Install the cluster with Keycloak

```bash
./cluster-install.sh --all
```

This will install:
- NGINX Ingress Controller
- cert-manager with a self-signed CA
- Rancher
- ArgoCD
- Keycloak with PostgreSQL database

### 2. Trust the CA Certificate

The installation script generates a CA certificate at `./certs/ca.crt`.
#### macOS
```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keycloaks/System.keychain ./certs/ca.crt
```

#### Linux
```bash
sudo cp ./certs/ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

#### Windows
1. Double-click `ca.crt`
2. Click "Install Certificate"
3. Select "Local Machine"
4. Select "Place all certificates in the following store"
5. Browse and select "Trusted Root Certification Authorities"

## Keycloak Operator Configuration

### Default Credentials
- **URL**: https://keycloak.localhost
- **Username**: admin
- **Password**: admin (check the install script output or k8s secret)

### Realm Setup

The `cluster` realm is automatically created with:
- **Two groups**:
  - `admins`: Full administrative access
  - `viewers`: Read-only access
- **Two OIDC clients**:
  - `rancher`: For Rancher authentication
  - `argocd`: For ArgoCD authentication
- **Example users**:
  - `admin` (password: `hunter22`) - in `admins` group
  - `viewer` (password: `hunter22`) - in `viewers` group

### Getting Client Secrets

You'll need the client secrets to configure Rancher and ArgoCD:

1. Log into Keycloak admin console
2. Select the `cluster` realm
3. Go to **Clients** → Click on `rancher`
4. Go to **Credentials** tab
5. Copy the **Client Secret**
6. Repeat for the `argocd` client

## Rancher OIDC Configuration

### Configure Rancher Authentication

1. Log into Rancher at `https://rancher.localhost` with the bootstrap admin account
2. Go to **☰ → Users & Authentication → Auth Provider**
3. Select **Keycloak (OIDC)**
4. Fill in the following:

   - **Display Name**: `Keycloak`
   - **Client ID**: `rancher`
   - **Client Secret**: (paste the secret from Keycloak)
   - **Keycloak URL**: `https://keycloak.localhost`
   - **Realm**: `cluster`
   - **Endpoints**:
     - Authorization Endpoint: `https://keycloak.localhost/realms/cluster/protocol/openid-connect/auth`
     - Token Endpoint: `https://keycloak.localhost/realms/cluster/protocol/openid-connect/token`
     - User Info Endpoint: `https://keycloak.localhost/realms/cluster/protocol/openid-connect/userinfo`

5. Click **Enable**
6. Test by logging in with a Keycloak user

### Configure Rancher RBAC

After enabling OIDC, configure group-based permissions:

1. Go to **☰ → Users & Authentication → Groups**
2. Create groups that match Keycloak groups:
   - **admins** → Assign "Cluster Owner" or "Administrator" role
   - **viewers** → Assign "Read-Only" or "Cluster Member" role

## ArgoCD OIDC Configuration

### Get ArgoCD Client Secret

First, retrieve the client secret from Keycloak (as described above).

### Create ArgoCD Secret

```bash
# Replace YOUR_CLIENT_SECRET with the actual secret from Keycloak
kubectl -n argocd create secret generic argocd-secret \
  --from-literal=oidc.keycloak.clientSecret=YOUR_CLIENT_SECRET \
  --dry-run=client -o yaml | kubectl apply -f -
```

Or patch the existing secret:

```bash
kubectl -n argocd patch secret argocd-secret \
  -p "{\"stringData\":{\"oidc.keycloak.clientSecret\":\"YOUR_CLIENT_SECRET\"}}"
```

### Apply OIDC Configuration

```bash
kubectl apply -f manifests/argocd/oidc-config.yaml
```

### Restart ArgoCD

```bash
kubectl -n argocd rollout restart deployment argocd-server
```

### Test Login

1. Go to `https://argocd.localhost`
2. Click **"LOG IN VIA KEYCLOAK"**
3. Log in with a Keycloak user (e.g., `admin` / `changeme`)

## User Management

### Adding New Users

1. Log into Keycloak admin console
2. Go to **Users** → **Add user**
3. Fill in user details and click **Save**
4. Go to **Credentials** tab → Set password
5. Go to **Groups** tab → Join the appropriate group (`admins` or `viewers`)

### Managing Groups

- **admins**: Full access to Rancher and ArgoCD
  - Can create/modify/delete resources
  - Can manage other users (in Rancher)
  - Full admin privileges

- **viewers**: Read-only access
  - Can view resources in Rancher and ArgoCD
  - Cannot make changes
  - Good for teammates who need visibility but not control

### Preventing Teammates from Breaking Your Stuff

Want to give people access but not let them break stuff too badly?

Consider adding teammates to the viewers group by default:

1. They can see what's going on
2. They can monitor deployments
3. They **cannot** modify or delete anything
4. They **cannot** create new resources

Only add trusted teammates to the `admins` group.

## Troubleshooting

### "Certificate not trusted" errors

Make sure all team members have imported and trusted the CA certificate (`./certs/ca.crt`).

### Can't log in to Keycloak

Check the Keycloak pod logs:
```bash
kubectl logs -n keycloak -l app=keycloak --tail=100
```

Check if PostgreSQL is running:
```bash
kubectl get pods -n keycloak
```

### Rancher OIDC not working

1. Verify the client secret is correct
2. Check Rancher logs:
   ```bash
   kubectl logs -n cattle-system -l app=rancher --tail=100
   ```
3. Verify redirect URIs in Keycloak match your Rancher hostname

### ArgoCD OIDC not working

1. Verify the client secret is in the `argocd-secret`:
   ```bash
   kubectl get secret -n argocd argocd-secret -o yaml
   ```
2. Check ArgoCD server logs:
   ```bash
   kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=100
   ```
3. Verify the OIDC config is applied:
   ```bash
   kubectl get cm -n argocd argocd-cm -o yaml
   ```

## DNS Configuration

For this to work on your VPN, you'll need to set up DNS records or add entries to `/etc/hosts`:

```
<YOUR_CLUSTER_IP>  rancher.localhost
<YOUR_CLUSTER_IP>  argocd.localhost
<YOUR_CLUSTER_IP>  keycloak.localhost
```

For production, replace `.localhost` with your actual domain names.

## Security Best Practices

1. **Change default passwords** immediately after setup
2. **Use strong passwords** for all Keycloak admin accounts
3. **Enable MFA** in Keycloak for admin accounts (Optional but recommended)
4. **Regularly review** user access and group memberships
5. **Rotate client secrets** periodically
6. **Use proper DNS names** instead of `.localhost` for production
7. **Back up Keycloak database** regularly (PostgreSQL in `keycloak` namespace)

## Backup and Recovery

### Backup Keycloak Database

```bash
kubectl exec -n keycloak postgresql-0 -- pg_dump -U keycloak keycloak > keycloak-backup.sql
```

### Backup CA Certificate

The CA certificate is stored in:
- Kubernetes secret: `ca-key-pair` in `cert-manager` namespace
- Local file: `./certs/ca.crt`

**Keep the CA certificate safe!** If you lose it, you'll need to regenerate and redistribute to all users.

### Export Realm Configuration

```bash
# Get the realm export from Keycloak UI
# Keycloak Admin Console → Realm Settings → Action → Partial Export
```

## TODO

- [ ] Set up more granular roles for 'contributors' who can create/destroy
- [ ] Set up proper DNS entries for VPN
- [ ] Configure session timeouts and token lifespans in Keycloak
- [ ] Set up Keycloak backup automation
- [ ] Configure additional OIDC clients for other services
- [ ] Enable audit logging in Keycloak
