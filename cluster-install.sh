#!/bin/bash

set -euo pipefail

RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-rancher.localhost}"
RANCHER_PASSWORD="${RANCHER_PASSWORD:-admin}"
ARGOCD_HOSTNAME="${ARGOCD_HOSTNAME:-argocd.localhost}"
CLUSTER_NAME="${CLUSTER_NAME:-rancher-management}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_NGINX=true
INSTALL_CERTMANAGER=true
INSTALL_RANCHER=true
INSTALL_MONITORING=false
INSTALL_LOKI=false
INSTALL_ARGOCD=false

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Install and configure Kubernetes management cluster components.

OPTIONS:
    -h, --help              Show this help message
    --skip-nginx            Skip NGINX ingress controller installation
    --skip-certmanager      Skip cert-manager installation
    --skip-rancher          Skip Rancher installation
    --with-monitoring       Install Rancher monitoring stack
    --with-loki             Install Loki logging stack
    --with-argocd           Install ArgoCD
    --all                   Install all available components

ENVIRONMENT VARIABLES:
    RANCHER_HOSTNAME        Rancher hostname (default: rancher.localhost)
    RANCHER_PASSWORD        Rancher admin password (default: admin)
    ARGOCD_HOSTNAME         ArgoCD hostname (default: argocd.localhost)
    CLUSTER_NAME            Cluster name (default: rancher-management)

EXAMPLES:
    $0                      Install core components only
    $0 --all                Install everything
    $0 --with-monitoring    Install core + monitoring
    $0 --skip-rancher       Install nginx and cert-manager only

EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                ;;
            --skip-nginx)
                INSTALL_NGINX=false
                shift
                ;;
            --skip-certmanager)
                INSTALL_CERTMANAGER=false
                shift
                ;;
            --skip-rancher)
                INSTALL_RANCHER=false
                shift
                ;;
            --with-monitoring)
                INSTALL_MONITORING=true
                shift
                ;;
            --with-loki)
                INSTALL_LOKI=true
                shift
                ;;
            --with-argocd)
                INSTALL_ARGOCD=true
                shift
                ;;
            --all)
                INSTALL_MONITORING=true
                INSTALL_LOKI=true
                INSTALL_ARGOCD=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
}

wait_for_rollout(){
    local namespace=$1
    local deployment=$2
    local timeout=${3:-300}

    log_info "Waiting for ${namespace}/${deployment} to be ready..."
    kubectl -n "${namespace}" rollout status deploy/"${deployment}" --timeout="${timeout}s" || {
        log_error "Rollout failed for ${namespace}/${deployment}"
        return 1
    }
}

is_deployed() {
    local namespace=$1
    local resource_type=$2
    local resource_name=$3

    kubectl get "${resource_type}" -n "${namespace}" "${resource_name}" &>/dev/null
}

install_nginx(){
    if is_deployed ingress-nginx deployment ingress-nginx-controller; then
        log_warn "NGINX Ingress Controller already installed, skipping"
        return 0
    fi

    log_info "Installing NGINX Ingress Controller..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml || {
        log_error "Failed to apply NGINX manifests"
        return 1
    }

    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=90s || {
        log_error "NGINX pods failed to become ready"
        return 1
    }

    log_info "NGINX Ingress installed"
}

install_certmanager(){
    if is_deployed cert-manager deployment cert-manager; then
        log_warn "cert-manager already installed, skipping"
        return 0
    fi

    log_info "Installing cert-manager..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.crds.yaml || {
        log_error "Failed to apply cert-manager CRDs"
        return 1
    }

    helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
    helm repo update || {
        log_error "Failed to update helm repos"
        return 1
    }

    helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace || {
        log_error "Failed to install cert-manager"
        return 1
    }

    log_info "cert-manager installed"
}

install_rancher(){
    if is_deployed cattle-system deployment rancher; then
        log_warn "Rancher already installed, skipping"
        return 0
    fi

    log_info "Installing Rancher..."
    helm repo add rancher-stable https://releases.rancher.com/server-charts/stable 2>/dev/null || true
    helm repo update || {
        log_error "Failed to update helm repos"
        return 1
    }

    helm install rancher rancher-stable/rancher \
        --namespace cattle-system \
        --create-namespace \
        --set hostname="${RANCHER_HOSTNAME}" \
        --set bootstrapPassword="${RANCHER_PASSWORD}" \
        --set replicas=1 \
        --set ingress.ingressClassName=nginx || {
        log_error "Failed to install Rancher"
        return 1
    }

    wait_for_rollout cattle-system rancher || return 1

    log_info "Rancher installed at http://${RANCHER_HOSTNAME}"
    log_info "  Username: admin"
    log_info "  Password: ${RANCHER_PASSWORD}"
}

install_rancher_monitoring() {
    if is_deployed cattle-monitoring-system deployment rancher-monitoring-grafana; then
        log_warn "Rancher Monitoring already installed, skipping"
        return 0
    fi

    log_info "Installing Rancher Monitoring..."

    helm repo add rancher-charts https://charts.rancher.io 2>/dev/null || true
    helm repo update || {
        log_error "Failed to update helm repos"
        return 1
    }

    helm install rancher-monitoring rancher-charts/rancher-monitoring \
        --namespace cattle-monitoring-system \
        --create-namespace \
        --set prometheus.prometheusSpec.retention=7d \
        --set prometheus.prometheusSpec.resources.requests.cpu=500m \
        --set prometheus.prometheusSpec.resources.requests.memory=1Gi \
        --wait || {
        log_error "Failed to install Rancher Monitoring"
        return 1
    }

    log_info "Rancher Monitoring installed"

    local grafana_password
    grafana_password=$(kubectl get secret -n cattle-monitoring-system rancher-monitoring-grafana \
        -o jsonpath="{.data.admin-password}" | base64 -d 2>/dev/null) || {
        log_warn "Could not retrieve Grafana password"
        return 0
    }

    log_info "  Grafana: http://$RANCHER_HOSTNAME/api/v1/namespaces/cattle-monitoring-system/services/http:rancher-monitoring-grafana:80/proxy/"
    log_info "  Username: admin"
    log_info "  Password: $grafana_password"
}

install_loki() {
    if is_deployed cattle-logging-system statefulset loki; then
        log_warn "Loki already installed, skipping"
        return 0
    fi

    log_info "Installing Loki..."

    helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
    helm repo update || {
        log_error "Failed to update helm repos"
        return 1
    }

    helm install loki grafana/loki-stack \
        --namespace cattle-logging-system \
        --create-namespace \
        --set loki.persistence.enabled=true \
        --set loki.persistence.size=10Gi \
        --set promtail.enabled=true \
        --set grafana.enabled=false \
        --wait || {
        log_error "Failed to install Loki"
        return 1
    }

    log_info "Loki installed"

    if [[ -f manifests/rancher/loki-datasource.yaml ]]; then
        kubectl apply -f manifests/rancher/loki-datasource.yaml || {
            log_warn "Failed to apply Loki datasource config"
        }

        if is_deployed cattle-monitoring-system deployment rancher-monitoring-grafana; then
            kubectl rollout restart deployment/rancher-monitoring-grafana -n cattle-monitoring-system || {
                log_warn "Failed to restart Grafana"
            }
            log_info "Loki datasource added to Grafana"
        fi
    else
        log_warn "Loki datasource manifest not found at manifests/rancher/loki-datasource.yaml"
    fi
}

install_argocd(){
    if is_deployed argocd deployment argocd-server; then
        log_warn "ArgoCD already installed, skipping"
        return 0
    fi

    log_info "Installing ArgoCD..."

    kubectl create namespace argocd 2>/dev/null || true

    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml || {
        log_error "Failed to apply ArgoCD manifests"
        return 1
    }

    kubectl wait --namespace argocd \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/name=argocd-server \
        --timeout=180s || {
        log_error "ArgoCD pods failed to become ready"
        return 1
    }

    local argo_passwd
    argo_passwd=$(kubectl -n argocd get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" | base64 -d 2>/dev/null) || {
        log_warn "Could not retrieve ArgoCD password"
        argo_passwd="<check cluster secret>"
    }

    if [[ -f manifests/argocd/ingress.yaml ]]; then
        kubectl apply -f manifests/argocd/ingress.yaml || {
            log_warn "Failed to apply ArgoCD ingress"
        }
    else
        log_warn "ArgoCD ingress manifest not found at manifests/argocd/ingress.yaml"
    fi

    log_info "ArgoCD installed at http://${ARGOCD_HOSTNAME}"
    log_info "  Username: admin"
    log_info "  Password: $argo_passwd"
}

main() {
    parse_args "$@"

    log_info "Starting Management Cluster Installation..."
    log_info "Cluster Name: $CLUSTER_NAME"
    log_info "Rancher Hostname: $RANCHER_HOSTNAME"
    log_info "ArgoCD Hostname: $ARGOCD_HOSTNAME"
    echo ""

    local failed=0

    if [[ "$INSTALL_NGINX" == "true" ]]; then
        install_nginx || failed=1
    fi

    if [[ "$INSTALL_CERTMANAGER" == "true" ]]; then
        install_certmanager || failed=1
    fi

    if [[ "$INSTALL_RANCHER" == "true" ]]; then
        install_rancher || failed=1
    fi

    if [[ "$INSTALL_MONITORING" == "true" ]]; then
        install_rancher_monitoring || failed=1
    fi

    if [[ "$INSTALL_LOKI" == "true" ]]; then
        install_loki || failed=1
    fi

    if [[ "$INSTALL_ARGOCD" == "true" ]]; then
        install_argocd || failed=1
    fi

    echo ""
    if [[ $failed -eq 0 ]]; then
        log_info "Installation complete!"
        echo ""
        [[ "$INSTALL_RANCHER" == "true" ]] && log_info "Rancher:  http://$RANCHER_HOSTNAME (admin/$RANCHER_PASSWORD)"
        [[ "$INSTALL_ARGOCD" == "true" ]] && log_info "ArgoCD:   http://$ARGOCD_HOSTNAME"
        [[ "$INSTALL_MONITORING" == "true" ]] && log_info "Grafana:  Access via Rancher UI"
    else
        log_error "Installation completed with errors"
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi