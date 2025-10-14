#!/bin/bash

# cluster_install.sh

install_nginx(){
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

    # Wait for it to be ready
    kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=90s
}

install_certmanager(){
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.crds.yaml

    helm repo add jetstack https://charts.jetstack.io
    helm repo update

    helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace
}

install_rancher(){
    helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
    helm repo update

    helm install rancher rancher-stable/rancher \
    --namespace cattle-system \
    --create-namespace \
    --set hostname=rancher.localhost \
    --set bootstrapPassword=admin \
    --set replicas=1 \
    --set ingress.ingressClassName=nginx    

    helm install rancher-monitoring rancher-charts/rancher-monitoring \
    --namespace cattle-monitoring-system \
    --create-namespace
}

install_argocd(){
    local argo_passwd

    kubectl create namespace argocd

    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    # Wait for it to be ready
    kubectl wait --namespace argocd \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/name=argocd-server \
    --timeout=180s

    # Get the admin password
    argo_passwd=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)

    # Expose via ingress
    kubectl apply -f manifests/argocd/ingress.yaml

    echo "Access ArgoCD at: http://argocd.localhost"
    echo "Username: admin"
    echo "Password: $argo_passwd"
}

