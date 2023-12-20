#!/bin/bash
set -e

print_green() {
    echo "$(tput setaf 2)$1$(tput sgr0)"
}

print_yellow() {
    echo "$(tput setaf 3)$1$(tput sgr0)"
}

print_red() {
    echo "$(tput setaf 1)$1$(tput sgr0)"
}

check_helm_installed() {
    if ! [ -x "$(command -v helm)" ]; then
        print_red "Helm is not installed. Please install Helm first."
        exit 1
    fi
}

check_kubernetes_cluster() {
    if ! kubectl cluster-info > /dev/null 2>&1; then
        print_red "Kubernetes cluster is not reachable. Please ensure you have a working cluster."
        exit 1
    fi
}

check_kubectl_context() {
    local current_context
    
    current_context=$(kubectl config current-context)
    
    if [ -z "$current_context" ]; then
        print_yellow "No kubectl context is set."
        read -rp "Please set the desired kubectl context and press Enter to continue: " _unused
    else
        print_yellow "Current kubectl context: $current_context"
        read -rp "Is this the correct cluster you want to proceed with? (y/N): " confirm
        
        if [[ "$confirm" != [Yy] || -z "$confirm" ]]; then
            print_red "Aborting installation."
            exit 1
        fi
    fi
}

check_argocd_crds_installed() {
    if kubectl get crd | grep -q 'argoproj.io'; then
        print_yellow "At least one ArgoCD CRD is already installed."
        return 0
    fi
    
    return 1
}

install_argocd_helm_chart() {

    if [[ $cluster_type == "azure-aks" ]]
    then
        helm install argocd argo/argo-cd --version 5.16.13 \
        --namespace argocd --create-namespace --wait \
        --set controller.tolerations[0].key="CriticalAddonsOnly" \
        --set-string controller.tolerations[0].value=true \
        --set controller.tolerations[0].effect=NoSchedule \
        --set controller.tolerations[0].operator=Equal \
        --set redis.tolerations[0].key="CriticalAddonsOnly" \
        --set-string redis.tolerations[0].value=true \
        --set redis.tolerations[0].effect=NoSchedule \
        --set redis.tolerations[0].operator=Equal \
        --set server.tolerations[0].key="kubernetes.azure.com/scalesetpriority" \
        --set-string server.tolerations[0].value=spot \
        --set server.tolerations[0].effect=NoSchedule \
        --set server.tolerations[0].operator=Equal \
        --set repoServer.tolerations[0].key="kubernetes.azure.com/scalesetpriority" \
        --set-string repoServer.tolerations[0].value=spot \
        --set repoServer.tolerations[0].effect=NoSchedule \
        --set repoServer.tolerations[0].operator=Equal \
        --set applicationSet.tolerations[0].key="CriticalAddonsOnly" \
        --set-string applicationSet.tolerations[0].value=true \
        --set applicationSet.tolerations[0].effect=NoSchedule \
        --set applicationSet.tolerations[0].operator=Equal \
        --set applicationSet.enabled=false \
        --set notifications.enabled=false \
        --set dex.enabled=false \
        --set server.extraArgs[0]="--insecure" \
        --set server.extraArgs[1]='--application-namespaces="*"' \
        --set controller.extraArgs[0]='--application-namespaces="*"'
    else
        helm install argocd argo/argo-cd --version 5.16.13 \
        --namespace argocd --create-namespace --wait \
        --set applicationSet.enabled=false \
        --set notifications.enabled=false \
        --set dex.enabled=false \
        --set server.extraArgs[0]="--insecure" \
        --set server.extraArgs[1]='--application-namespaces="*"' \
        --set controller.extraArgs[0]='--application-namespaces="*"'
    fi
    if [[ ${?} -eq 0 ]]
    then
        print_green "Argocd Installed successfully. Continuing ..."
        sleep 5
    else
        print_red "Argocd failed to install"
        exit 2
    fi
}

install_argo_charts() {
    local cluster_type=$1
    local argo_charts=('argocd' 'argo-rollouts')

    for argo_chart in "${argo_charts[@]}"; do
        response=$(curl --silent "https://catalogue.truefoundry.com/$cluster_type/templates/$argo_chart.yaml")
        echo "$response" > /tmp/application.yaml
        
        kubectl apply -f /tmp/application.yaml -n argocd
        rm -f /tmp/application.yaml
    done
}

create_loki_workspace(){
    local tenant_name=$1
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: loki
  labels:
    truefoundry.com/tenant: $tenant_name
    truefoundry.com/managed-by: servicefoundry
    pod-security.kubernetes.io/enforce: privileged
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  finalizers:
    - kubernetes
EOF
}

create_prometheus_workspace(){
    local tenant_name=$1
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: prometheus
  labels:
    truefoundry.com/tenant: $tenant_name
    truefoundry.com/managed-by: servicefoundry
    pod-security.kubernetes.io/enforce: privileged
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  finalizers:
    - kubernetes
EOF
}

create_tfy_gpu_operator_workspace(){
    local tenant_name=$1
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: tfy-gpu-operator
  labels:
    truefoundry.com/tenant: $tenant_name
    truefoundry.com/managed-by: servicefoundry
    pod-security.kubernetes.io/enforce: privileged
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  finalizers:
    - kubernetes
EOF
}

install_loki(){
    local cluster_type=$1

    print_yellow "Installing Loki...."
    response=$(curl --silent "https://catalogue.truefoundry.com/$cluster_type/templates/loki.yaml")
    echo "$response" > /tmp/loki.yaml
    kubectl apply -f /tmp/loki.yaml -n loki
    rm -f /tmp/loki.yaml
    print_green "Loki Installed Successfully."
}

install_prometheus(){
    local cluster_type=$1

    print_yellow "Installing prometheus...."
    response=$(curl --silent "https://catalogue.truefoundry.com/$cluster_type/templates/prometheus.yaml")
    echo "$response" > /tmp/prometheus.yaml
    kubectl apply -f /tmp/prometheus.yaml -n prometheus
    rm -f /tmp/prometheus.yaml
    print_green "prometheus Installed Successfully."
}

install_tfy_gpu_operator(){
    local cluster_type=$1

    print_yellow "Installing tfy-gpu-operator...."
    response=$(curl --silent "https://catalogue.truefoundry.com/$cluster_type/templates/tfy-gpu-operator.yaml")
    echo "$response" > /tmp/tfy-gpu-operator.yaml
    kubectl apply -f /tmp/tfy-gpu-operator.yaml -n tfy-gpu-operator
    rm -f /tmp/tfy-gpu-operator.yaml
    print_green "tfy-gpu-operator Installed Successfully."
}

install_plugins(){
    local tenant_name=$1
    local cluster_type=$2

    print_yellow "Starting Plugins installation..."

    check_helm_installed
    
    check_kubernetes_cluster

    check_kubectl_context

    if check_argocd_crds_installed; then
        # ArgoCD CRDs are already installed, skip the entire ArgoCD installation
        print_yellow "Skipping argocd installation."
    else
    helm repo add argo https://argoproj.github.io/argo-helm
    install_argocd_helm_chart "$cluster_type"
    install_argo_charts "$cluster_type"
    sleep 2
    fi

    create_loki_workspace "$tenant_name"
    install_loki "$cluster_type"

    create_prometheus_workspace "$tenant_name"
    install_prometheus "$cluster_type"

    create_tfy_gpu_operator_workspace "$tenant_name"
    install_tfy_gpu_operator "$cluster_type"

    print_green "All Plugins Installed Successfully"
}

install_plugins "$1" "$2"