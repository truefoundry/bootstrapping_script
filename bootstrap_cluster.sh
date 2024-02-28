#!/bin/bash
set -e

tfy_agent_namespace='tfy-agent'
istio_namespace='istio-system'
argocd_version='5.52.1'

print_green() {
    echo "$(tput setaf 2)$1$(tput sgr0)"
}

print_yellow() {
    echo "$(tput setaf 3)$1$(tput sgr0)"
}

print_red() {
    echo "$(tput setaf 1)$1$(tput sgr0)"
}

# Function to check if Helm is installed
check_helm_installed() {
    if ! [ -x "$(command -v helm)" ]; then
        print_red "Helm is not installed. Please install Helm first."
        exit 1
    fi
}

# Function to check if a Kubernetes cluster is reachable
check_kubernetes_cluster() {
    if ! kubectl cluster-info > /dev/null 2>&1; then
        print_red "Kubernetes cluster is not reachable. Please ensure you have a working cluster."
        exit 1
    fi
}

# Function to check if a kubectl context is set
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

# Function to check if the ArgoCD CRDs are installed
check_argocd_crds_installed() {
    if kubectl get crd | grep -q 'argoproj.io'; then
        print_yellow "At least one ArgoCD CRD is already installed."
        return 0
    fi
    
    return 1
}

check_istio_crds_installed() {
    if kubectl get crd | grep -q 'istio.io'; then
        print_yellow "At least one Istio CRD is already installed."
        return 0
    fi
    
    return 1
}

check_tfy_agent() {
    local skip_test=$1
    counter=0
    if [[ $skip_test == "false" ]]
    then
        while :
        do
            agent_pods=$(kubectl get pods -n $tfy_agent_namespace -l app.kubernetes.io/name=tfy-agent -o custom-columns=:.metadata.name,.:.status.phase --no-headers | grep 'Running' | wc -l)
            if [[ $agent_pods -ge 1 ]]
            then
                print_green "Agent installed successfully"
                break
            elif [[ $counter -ge 30 ]]
            then
                print_red "Agent is not in the running state yet. Exiting"
                exit 1
            else
                print_yellow "Waiting for agent pods to come up ..."
            fi
            ((counter+=1))
            sleep 5
        done
    fi
}

install_helm_chart_with_values() {
    local chart_repo=$1
    local chart_name=$2
    local chart_namespace=$3
    local chart_version=$4
    local values=$5
    echo "$values" > values_file.yaml
    
    print_green "Installing '$chart_name' chart in the '$chart_namespace' namespace..."
    helm install "$chart_name" -n "$chart_namespace" --version "$chart_version" "$chart_repo"/"$chart_name" --values "values_file.yaml" --create-namespace
    print_green "The '$chart_name' chart has been successfully installed."
    rm -f "values_file.yaml"
}


install_argocd_helm_chart() {

    if [[ $cluster_type == "azure-aks" ]]
    then
        helm install argocd argo/argo-cd --version "$argocd_version" \
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
        helm install argocd argo/argo-cd --version "$argocd_version" \
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

    print_yellow "Applying tfy-apps AppProject..."
    kubectl apply -f -<<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: tfy-apps
  namespace: argocd
spec:
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
  destinations:
    - namespace: '*'
      server: '*'
  sourceNamespaces:
    - '*'
  sourceRepos:
    - '*'
EOF
}

install_argo_charts() {
    local cluster_type=$1
    local argo_charts=('argocd' 'argo-rollouts' 'argo-workflows')

    for argo_chart in "${argo_charts[@]}"; do
        response=$(curl --silent "https://catalogue.truefoundry.com/$cluster_type/templates/$argo_chart.yaml")
        echo "$response" > /tmp/application.yaml
        namespace_exists=$(kubectl get namespaces | grep $argo_chart | wc -l)
        if [[ "$namespace_exists" -eq 0 ]]
        then
            kubectl create namespace $argo_chart
        fi
        kubectl apply -f /tmp/application.yaml -n $argo_chart
        rm -f /tmp/application.yaml
    done
}

restart_argocd_if_needed() {
    output=$(kubectl get app -A | grep -e "Unknown" -e "Missing"| wc -l)
    if [[ ${output} -ge 1 ]]
    then
        print_yellow "Restarting Argocd ..."
        kubectl rollout restart sts/argocd-application-controller -n argocd
    fi
}

install_istio_dependencies() {
    local cluster_type=$1
    local skip_test=$2
    local istio_dependencies=('istio-base' 'istio-discovery' 'tfy-istio-ingress');

    for istio_dependency in "${istio_dependencies[@]}"; do
        print_yellow "Installing ${istio_dependency}..."
        response=$(curl --silent "https://catalogue.truefoundry.com/$cluster_type/templates/istio/$istio_dependency.yaml")
        echo "$response" > /tmp/application.yaml

        namespace_exists=$(kubectl get namespaces | grep $istio_namespace | wc -l)
        if [[ "$namespace_exists" -eq 0 ]]
        then
            kubectl create namespace $istio_namespace
        fi        
        
        kubectl apply -f /tmp/application.yaml -n $istio_namespace
        sleep 1
        if [[ $istio_dependency == 'istio-discovery' && $skip_test == "false" ]]
        then
            counter=0
            while : 
            do
                istio_pods=$(kubectl get pods -n $istio_namespace -l app=istiod -o custom-columns=:.metadata.name,.:.status.phase --no-headers | grep Running | wc -l)
                if [[ $istio_pods -ge 2 ]]
                then
                    sleep 5
                    print_green "istio-discovery is installed successfully"
                    break
                elif [[ $counter -ge 10 ]]
                then
                    print_green "istio-discovery not installed yet"
                    break
                else
                    print_yellow "Waiting for istio-discovery pods to come up ..."
                fi
                ((counter+=1))
                sleep 5
            done
        fi

        rm -f /tmp/application.yaml
    done
}

install_tfy_agent() {
    local cluster_type=$1
    local tenant_name=$2
    local cluster_token=$3
    local control_plane_url=$4

    response=$(curl --silent "https://catalogue.truefoundry.com/$cluster_type/templates/tfy-agent.yaml")
    echo "$response" > /tmp/application.yaml

    if [ "$(uname)" == "Darwin" ]; then
        sed -i "" "s#\(\s*clusterToken:\s*\).*#\1 $cluster_token#" /tmp/application.yaml
        sed -i "" "s#\(\s*tenantName:\s*\).*#\1 $tenant_name#" /tmp/application.yaml
        sed -i "" "s#\(\s*controlPlaneURL:\s*\).*#\1 $control_plane_url#" /tmp/application.yaml
    else
        sed -i "s#\(\s*clusterToken:\s*\).*#\1 $cluster_token#" /tmp/application.yaml
        sed -i "s#\(\s*tenantName:\s*\).*#\1 $tenant_name#" /tmp/application.yaml
        sed -i "s#\(\s*controlPlaneURL:\s*\).*#\1 $control_plane_url#" /tmp/application.yaml
    fi
    
    namespace_exists=$(kubectl get namespaces | grep $tfy_agent_namespace | wc -l)
    if [[ "$namespace_exists" -eq 0 ]]
    then
        kubectl create namespace $tfy_agent_namespace
    fi 

    kubectl apply -f /tmp/application.yaml -n $tfy_agent_namespace

    rm -f /tmp/application.yaml
}

# Function to guide the user through the installation process
installation_guide() {
    local tenant_name=$1
    local cluster_type=$2
    local cluster_token=$3
    local control_plane_url=$4
    local skip_test=$5

    print_yellow "Starting TrueFoundry agent installation..."
    
    # Check if Helm is installed
    check_helm_installed
    
    # Check if Kubernetes cluster is reachable
    check_kubernetes_cluster
    
    # Check if kubectl context is set and confirm with the user
    check_kubectl_context
    
    # Guide the user through installing Argocd chart if not already installed
    print_yellow "Let's start by installing argocd..."
    
    if check_argocd_crds_installed; then
        # ArgoCD CRDs are already installed, skip the entire ArgoCD installation
        print_yellow "Skipping argocd installation."
    else
        helm repo add argo https://argoproj.github.io/argo-helm
        install_argocd_helm_chart "$cluster_type"
        install_argo_charts "$cluster_type"
        sleep 2
    fi

    install_istio_dependencies "$cluster_type" "$skip_test"

    # Guide the user through installing Tfy-agent chart
    print_yellow "Next, we'll install the tfy-agent chart..."
    helm repo add truefoundry https://truefoundry.github.io/infra-charts/
    install_tfy_agent "$cluster_type" "$tenant_name" "$cluster_token" "$control_plane_url"

    check_tfy_agent "$skip_test"

    restart_argocd_if_needed
    # Completion message
    print_green "The installation process is complete."
}

# Start the installation guide with tenantName and clusterToken as arguments
if [ $# -lt 3 ]; then
    print_red "Error: Insufficient arguments. Please provide the tenantName, clusterType and clusterToken."
    print_red "Usage: $0 <tenantName> <clusterType> <clusterToken>"
    print_red "Warning: User can optionally pass control plane url as 4th argument" 
    exit 1
fi

control_plane_url=""
if [ $# == 3 ]; then
    control_plane_url="https://$1.truefoundry.cloud"
    print_yellow "Control plane URL inferred as $control_plane_url"
fi

if [ $# == 4 ]; then
    control_plane_url="$4"
    if [[ ! $control_plane_url =~ ^(https?://).* ]]; then
        control_plane_url="https://$control_plane_url"
    fi
fi

installation_guide "$1" "$2" "$3" "$control_plane_url" "${5:-"false"}"
