#!/bin/bash

set -euo pipefail

RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-rancher.localhost}"
RANCHER_PASSWORD="${RANCHER_PASSWORD:-admin}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat <<EOF
Usage: $0 <COMMAND> [OPTIONS]

Import Kubernetes clusters into Rancher management.

COMMANDS:
    kubeconfig <context> [display-name]
        Import cluster from kubeconfig context

    gke <project-id> <cluster-name> <region> [display-name]
        Import GKE cluster

    aks <resource-group> <cluster-name> [display-name]
        Import AKS cluster

    enable-monitoring <cluster-id>
        Enable monitoring on imported cluster

OPTIONS:
    -h, --help              Show this help message

ENVIRONMENT VARIABLES:
    RANCHER_HOSTNAME        Rancher hostname (default: rancher.localhost)
    RANCHER_PASSWORD        Rancher admin password (default: admin)

EXAMPLES:
    $0 kubeconfig docker-desktop
    $0 gke my-project my-cluster us-central1
    $0 aks my-devops-resource-group prod-cluster "Production AKS"
    $0 enable-monitoring c-m-12345678

EOF
    exit 0
} 

get_rancher_token() {
    local token
    token=$(curl -sk -X POST "https://$RANCHER_HOSTNAME/v3-public/localProviders/local?action=login" \
        -H 'Content-Type: application/json' \
        -d "{
            \"username\": \"admin\",
            \"password\": \"$RANCHER_PASSWORD\"
        }" 2>/dev/null | jq -r '.token' 2>/dev/null) || {
        log_error "Failed to authenticate with Rancher"
        return 1
    }

    if [[ -z "$token" || "$token" == "null" ]]; then
        log_error "Failed to get Rancher API token"
        return 1
    fi

    echo "$token"
}

is_cluster_imported() {
    local cluster_name=$1
    local rancher_token
    rancher_token=$(get_rancher_token) || return 1

    local cluster_id
    cluster_id=$(curl -sk "https://$RANCHER_HOSTNAME/v3/clusters" \
        -H "Authorization: Bearer $rancher_token" 2>/dev/null \
        | jq -r ".data[] | select(.name==\"$cluster_name\") | .id" 2>/dev/null)

    [[ -n "$cluster_id" && "$cluster_id" != "null" ]]
}

import_cluster_from_kubeconfig() {
    local context_name=$1
    local cluster_display_name=${2:-$context_name}

    if ! kubectl config get-contexts "$context_name" &>/dev/null; then
        log_error "Context '$context_name' not found in kubeconfig"
        return 1
    fi

    if is_cluster_imported "$cluster_display_name"; then
        log_warn "Cluster '$cluster_display_name' already imported, skipping"
        return 0
    fi

    log_info "Importing cluster '$cluster_display_name' from context '$context_name'..."

    local rancher_token
    rancher_token=$(get_rancher_token) || return 1

    local import_yaml
    import_yaml=$(curl -sk -X POST "https://$RANCHER_HOSTNAME/v3/clusters" \
        -H "Authorization: Bearer $rancher_token" \
        -H 'Content-Type: application/json' \
        -d "{
            \"type\": \"cluster\",
            \"name\": \"$cluster_display_name\",
            \"description\": \"Imported from kubeconfig context: $context_name\"
        }" 2>/dev/null | jq -r '.actions.generateKubeconfig' 2>/dev/null) || {
        log_error "Failed to create cluster import in Rancher"
        return 1
    }

    if [[ -z "$import_yaml" || "$import_yaml" == "null" ]]; then
        log_error "Failed to get import manifest from Rancher"
        return 1
    fi

    kubectl --context="$context_name" apply -f "$import_yaml" || {
        log_error "Failed to apply import manifest to cluster"
        return 1
    }

    log_info "Cluster import initiated. Check Rancher UI for status."
}

import_gke_cluster() {
    local project_id=$1
    local cluster_name=$2
    local region=$3
    local display_name=${4:-$cluster_name}

    if [[ -z "$project_id" || -z "$cluster_name" || -z "$region" ]]; then
        log_error "Usage: import_gke_cluster <project-id> <cluster-name> <region> [display-name]"
        return 1
    fi

    if ! command -v gcloud &>/dev/null; then
        log_error "gcloud CLI not found. Please install Google Cloud SDK."
        return 1
    fi

    log_info "Importing GKE cluster: $project_id/$region/$cluster_name..."

    gcloud container clusters get-credentials "$cluster_name" \
        --region="$region" \
        --project="$project_id" || {
        log_error "Failed to get GKE credentials"
        return 1
    }

    local context="gke_${project_id}_${region}_${cluster_name}"
    import_cluster_from_kubeconfig "$context" "$display_name"
}

import_aks_cluster() {
    local resource_group=$1
    local cluster_name=$2
    local display_name=${3:-$cluster_name}

    if [[ -z "$resource_group" || -z "$cluster_name" ]]; then
        log_error "Usage: import_aks_cluster <resource-group> <cluster-name> [display-name]"
        return 1
    fi

    if ! command -v az &>/dev/null; then
        log_error "az CLI not found. Please install Azure CLI."
        return 1
    fi

    log_info "Importing AKS cluster: $resource_group/$cluster_name..."

    az aks get-credentials \
        --resource-group "$resource_group" \
        --name "$cluster_name" \
        --overwrite-existing || {
        log_error "Failed to get AKS credentials"
        return 1
    }

    import_cluster_from_kubeconfig "$cluster_name" "$display_name"
}

enable_monitoring_on_cluster() {
    local cluster_id=$1

    if [[ -z "$cluster_id" ]]; then
        log_error "Usage: enable_monitoring_on_cluster <cluster-id>"
        return 1
    fi

    log_info "Enabling monitoring on cluster: $cluster_id..."

    local rancher_token
    rancher_token=$(get_rancher_token) || return 1

    local result
    result=$(curl -sk -w "\n%{http_code}" -X POST \
        "https://$RANCHER_HOSTNAME/v3/clusters/$cluster_id?action=enableMonitoring" \
        -H "Authorization: Bearer $rancher_token" \
        -H 'Content-Type: application/json' 2>/dev/null)

    local http_code
    http_code=$(echo "$result" | tail -n1)

    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        log_info "Monitoring enabled on cluster $cluster_id"
    else
        log_error "Failed to enable monitoring (HTTP $http_code)"
        return 1
    fi
}

main() {
    if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
        usage
    fi

    local command=$1
    shift

    case "$command" in
        kubeconfig)
            import_cluster_from_kubeconfig "$@"
            ;;
        gke)
            import_gke_cluster "$@"
            ;;
        aks)
            import_aks_cluster "$@"
            ;;
        eks)
            import_eks_cluster "$@"
            ;;
        enable-monitoring)
            enable_monitoring_on_cluster "$@"
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi