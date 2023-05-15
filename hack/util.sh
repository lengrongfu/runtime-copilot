#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# This script holds common bash variables and utility functions.

ETCD_POD_LABEL="etcd"
KUBE_CONTROLLER_POD_LABEL="kube-controller-manager"

MIN_Go_VERSION=go1.16.0

# This function installs a Go tools by 'go get' command.
# Parameters:
#  - $1: package name, such as "sigs.k8s.io/controller-tools/cmd/controller-gen"
#  - $2: package version, such as "v0.4.1"
# Note:
#   Since 'go get' command will resolve and add dependencies to current module, that may update 'go.mod' and 'go.sum' file.
#   So we use a temporary directory to install the tools.
function util::install_tools() {
	local package="$1"
	local version="$2"

	temp_path=$(mktemp -d)
	pushd "${temp_path}" >/dev/null
	GO111MODULE=on go install "${package}"@"${version}"
	GOPATH=$(go env GOPATH | awk -F ':' '{print $1}')
	export PATH=$PATH:$GOPATH/bin
	popd >/dev/null
	rm -rf "${temp_path}"
}

function util::cmd_exist {
	local CMD=$(command -v ${1})
	if [[ ! -x ${CMD} ]]; then
    	return 1
	fi
	return 0
}

# util::cmd_must_exist check whether command is installed.
function util::cmd_must_exist {
    local CMD=$(command -v ${1})
    if [[ ! -x ${CMD} ]]; then
    	echo "Please install ${1} and verify they are in \$PATH."
    	exit 1
    fi
}

function util::verify_go_version {
    local go_version
    IFS=" " read -ra go_version <<< "$(GOFLAGS='' go version)"
    if [[ "${MIN_Go_VERSION}" != $(echo -e "${MIN_Go_VERSION}\n${go_version[2]}" | sort -s -t. -k 1,1 -k 2,2n -k 3,3n | head -n1) && "${go_version[2]}" != "devel" ]]; then
      echo "Detected go version: ${go_version[*]}."
      echo "runtime-copilot requires ${MIN_Go_VERSION} or greater."
      echo "Please install ${MIN_Go_VERSION} or later."
      exit 1
    fi
}

# util::install_environment_check will check OS and ARCH before installing
# ARCH support list: amd64,arm64
# OS support list: linux,darwin
function util::install_environment_check {
    local ARCH=${1:-}
    local OS=${2:-}
    if [[ "$ARCH" =~ ^(amd64|arm64)$ ]]; then
        if [[ "$OS" =~ ^(linux|darwin)$ ]]; then
            return 0
        fi
    fi
    echo "Sorry, Kpanda installation does not support $ARCH/$OS at the moment"
    exit 1
}

# util::install_kubectl will install the given version kubectl
function util::install_kubectl {
    local KUBECTL_VERSION=${1}
    local ARCH=${2}
    local OS=${3:-linux}
    if [ -z "$KUBECTL_VERSION" ]; then
    	KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    fi
    echo "Installing 'kubectl ${KUBECTL_VERSION}' for you"
    curl --retry 5 -sSLo ./kubectl -w "%{http_code}" https://dl.k8s.io/release/"$KUBECTL_VERSION"/bin/"$OS"/"$ARCH"/kubectl | grep '200' > /dev/null
    ret=$?
    if [ ${ret} -eq 0 ]; then
        chmod +x ./kubectl
        mkdir -p ~/.local/bin/
        mv ./kubectl ~/.local/bin/kubectl

        export PATH=$PATH:~/.local/bin
    else
        echo "Failed to install kubectl, can not download the binary file at https://dl.k8s.io/release/$KUBECTL_VERSION/bin/$OS/$ARCH/kubectl"
        exit 1
    fi
}

# util::install_kind will install the given version kind
function util::install_kind {
	local kind_version=${1}
	echo "Installing 'kind ${kind_version}' for you"
	local os_name
	os_name=$(go env GOOS)
	local arch_name
	arch_name=$(go env GOARCH)
	curl --retry 5 -sSLo ./kind -w "%{http_code}" "https://qiniu-download-public.daocloud.io/Kind/${kind_version}/kind-${os_name:-linux}-${arch_name:-amd64}" | grep '200' > /dev/null
	ret=$?
	if [ ${ret} -eq 0 ]; then
    	chmod +x ./kind
    	mkdir -p ~/.local/bin/
    	mv ./kind ~/.local/bin/kind

    	export PATH=$PATH:~/.local/bin
	else
    	echo "Failed to install kind, can not download the binary file at https://qiniu-download-public.daocloud.io/Kind/${kind_version}/kind-${os_name:-linux}-${arch_name:-amd64}"
    	exit 1
	fi
}

# util::wait_for_condition blocks until the provided condition becomes true
# Arguments:
#  - 1: message indicating what conditions is being waited for (e.g. 'ok')
#  - 2: a string representing an eval'able condition.  When eval'd it should not output
#       anything to stdout or stderr.
#  - 3: optional timeout in seconds. If not provided, waits forever.
# Returns:
#  1 if the condition is not met before the timeout
function util::wait_for_condition() {
  local msg=$1
  # condition should be a string that can be eval'd.
  local condition=$2
  local timeout=${3:-}

  local start_msg="Waiting for ${msg}"
  local error_msg="[ERROR] Timeout waiting for ${msg}"

  local counter=0
  while ! eval ${condition}; do
    if [[ "${counter}" = "0" ]]; then
      echo -n "${start_msg}"
    fi

    if [[ -z "${timeout}" || "${counter}" -lt "${timeout}" ]]; then
      counter=$((counter + 1))
      if [[ -n "${timeout}" ]]; then
        echo -n '.'
      fi
      sleep 1
    else
      echo -e "\n${error_msg}"
      return 1
    fi
  done

  if [[ "${counter}" != "0" && -n "${timeout}" ]]; then
    echo ' done'
  fi
}

# util::wait_file_exist checks if a file exists, if not, wait until timeout
function util::wait_file_exist() {
    local file_path=${1}
    local timeout=${2}
    for ((time=0; time<${timeout}; time++)); do
        if [[ -e ${file_path} ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# util::wait_pod_ready waits for pod state becomes ready until timeout.
# Parmeters:
#  - $1: pod label, such as "app=etcd"
#  - $2: pod namespace, such as "runtime-copilot-system"
#  - $3: time out, such as "200s"
function util::wait_pod_ready() {
    local pod_label_key=$1
    local pod_label=$2
    local pod_namespace=$3
    local timeout=$4

    echo "wait the $pod_label ready..."
    util::wait_resource_created "pods" ${pod_label_key}=${pod_label} ${pod_namespace}
    set +e
    util::kubectl_with_retry wait --for=condition=Ready --timeout=${timeout} pods -l ${pod_label_key}=${pod_label} -n ${pod_namespace}
    ret=$?
    set -e
    if [ $ret -ne 0 ];then
      echo "kubectl describe info: $(kubectl describe pod -l ${pod_label_key}=${pod_label} -n ${pod_namespace})"
    fi
    return ${ret}
}

function util::wait_resource_created() {
    local resource_type=$1
    local label_selector=$2
    local namespace=$3

    local resource_exists=0
    local timeout=300
    local start_time=$(date +%s)
    local end_time=0

    # Use a while loop to check if a resource exists until it times out or until it is found
    while [ $resource_exists -eq 0 ]; do
        # Use the kubectl get command to get the number of resources
        local resource_count=$(kubectl get $resource_type -l $label_selector -n $namespace --no-headers | wc -l)
        # If the number of resources is greater than zero, the resource already exists, set the flag to 1, and exit the loop
        if [ $resource_count -gt 0 ]; then
            echo "$resource_type with label $label_selector is created."
            resource_exists=1
            break
        fi
        # If the number of resources is equal to zero, the resource does not exist,
        # calculate the difference between the current time and the start time, and determine whether the timeout occurs
        end_time=$(date +%s)
        local elapsed_time=$((end_time - start_time))
        # If the timeout occurs, an error message is printed and the loop exits
        # else there is no timeout, print the wait message and wait for some time before continuing the loop
        if [ $elapsed_time -ge $timeout ]; then
            echo "Error: timeout waiting for $resource_type with label $label_selector"
            break
        fi
        echo "Waiting for $resource_type with label $label_selector to be created..."
        sleep 5
    done
}


# util::kubectl_with_retry will retry if execute kubectl command failed
# tolerate kubectl command failure that may happen before the pod is created by StatefulSet/Deployment.
function util::kubectl_with_retry() {
    local ret=0
    local count=0
    for i in {1..20}; do
        kubectl "$@"
        ret=$?
        if [[ ${ret} -ne 0 ]]; then
            echo "kubectl $@ failed, retrying(${i} times)"
            sleep 1
            continue
        else
          ((count++))
          # sometimes pod status is from running to error to running
          # so we need check it more times
          if [[ ${count} -ge 3 ]];then
            return 0
          fi
          sleep 5
          continue
        fi
    done

    echo "kubectl $@ failed"
    kubectl "$@"
    return ${ret}
}

# util::create_cluster creates a kubernetes cluster
# util::create_cluster creates a kind cluster and don't wait for control plane node to be ready.
# Parmeters:
#  - $1: cluster name, such as "host"
#  - $2: KUBECONFIG file, such as "/var/run/host.config"
#  - $3: node docker image to use for booting the cluster, such as "kindest/node:v1.19.1"
#  - $4: log file path, such as "/tmp/logs/"
function util::create_cluster() {
	local cluster_name=${1}
	local kubeconfig=${2}
	local kind_image=${3}
	local cluster_config=${4:-}

  for i in {1..20}; do
    	rm -f "${kubeconfig}"
      util::delete_cluster "${cluster_name}"
      sleep 10
      kind create cluster --name "${cluster_name}" --kubeconfig="${kubeconfig}" --image="${kind_image}" --config="${cluster_config}" || true
      # Judge whether the creation of kind is completed through docker
      dockername=$(docker ps | grep "${cluster_name}" || true)
      if [[ -z ${dockername} ]]; then
        echo "kind create cluster failed, retrying(${i} times)"
        util::delete_cluster "${cluster_name}"
        sleep 10
        continue
      else
        echo "cluster ${cluster_name} created successfully"
        return 0
      fi
  done
}

# util::delete_cluster deletes kind cluster by name
# Parmeters:
# - $1: cluster name, such as "host"
function util::delete_cluster() {
  local cluster_name=${1}
  for i in {1..10}; do
      kind delete cluster --name="${cluster_name}" || true
      dockername=$(docker ps | grep "${cluster_name}" || true)
      if [[ -z ${dockername} ]]; then
          echo "kind delete cluster successfully"
          return 0
      fi
  done
}
# This function returns the IP address of a docker instance
# Parameters:
#  - $1: docker instance name

function util::get_docker_native_ipaddress(){
  local container_name=$1
  docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${container_name}"
}

# This function returns the IP address and port of a specific docker instance's host IP
# Parameters:
#  - $1: docker instance name
# Note:
#   Use for getting host IP and port for cluster
#   "6443/tcp" assumes that API server port is 6443 and protocol is TCP

function util::get_docker_host_ip_port(){
  local container_name=$1
  docker inspect --format='{{range $key, $value := index .NetworkSettings.Ports "6443/tcp"}}{{if eq $key 0}}{{$value.HostIp}}:{{$value.HostPort}}{{end}}{{end}}' "${container_name}"
}

# util::check_clusters_ready checks if a cluster is ready, if not, wait until timeout
function util::check_clusters_ready() {
	local kubeconfig_path=${1}
	local context_name=${2}

	echo "Waiting for kubeconfig file ${kubeconfig_path} and clusters ${context_name} to be ready..."
	util::wait_file_exist "${kubeconfig_path}" 300
	util::wait_for_condition 'running' "docker inspect --format='{{.State.Status}}' ${context_name}-control-plane &> /dev/null" 300

	kubectl config rename-context "kind-${context_name}" "${context_name}" --kubeconfig="${kubeconfig_path}"

	local os_name
	os_name=$(go env GOOS)
	local container_ip_port
	case $os_name in
    	linux) container_ip_port=$(util::get_docker_native_ipaddress "${context_name}-control-plane")":6443"
    	;;
    	darwin) container_ip_port=$(util::get_docker_host_ip_port "${context_name}-control-plane")
    	;;
   		*)
			echo "OS ${os_name} does NOT support for getting container ip in installation script"
			exit 1
	esac
	kubectl config set-cluster "kind-${context_name}" --server="https://${container_ip_port}" --kubeconfig="${kubeconfig_path}"

	util::wait_for_condition 'ok' "kubectl --kubeconfig ${kubeconfig_path} --context ${context_name} get --raw=/healthz &> /dev/null" 300
	util::wait_for_condition 'ok' "kubectl --kubeconfig ${kubeconfig_path} wait --for=condition=ready pod --all -n kube-system &> /dev/null" 300
}

# util::get_macos_ipaddress will get ip address on macos interactively, store to 'MAC_NIC_IPADDRESS' if available
MAC_NIC_IPADDRESS=''
function util::get_macos_ipaddress() {
	if [[ $(go env GOOS) = "darwin" ]]; then
		tmp_ip=$(ipconfig getifaddr en0 || true)
		echo ""
		echo " Detected that you are installing Kpanda on macOS "
		echo ""
		echo "It needs a Macintosh IP address to bind Kpanda API Server(port 5443),"
		echo "so that member clusters can access it from docker containers, please"
		echo -n "input an available IP, "
		if [[ -z ${tmp_ip} ]]; then
			echo "you can use the command 'ifconfig' to look for one"
			tips_msg="[Enter IP address]:"
		else
			echo "default IP will be en0 inet addr if exists"
			tips_msg="[Enter for default ${tmp_ip}]:"
		fi
		read -r -p "${tips_msg}" MAC_NIC_IPADDRESS
		MAC_NIC_IPADDRESS=${MAC_NIC_IPADDRESS:-$tmp_ip}
		if [[ "${MAC_NIC_IPADDRESS}" =~ ^(([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))\.){3}([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))$ ]]; then
			echo "Using IP address: ${MAC_NIC_IPADDRESS}"
		else
			echo -e "\nError: you input an invalid IP address"
			exit 1
		fi
	else # non-macOS
		MAC_NIC_IPADDRESS=${MAC_NIC_IPADDRESS:-}
	fi
}

function util::sync_offline_pakage() {
  local PROJECT_PATH=${1}
  local HELM_REPO=${2}
  local REGISTRY_PASSWORD=${3}
  local HELM_VERSION=${4}
  local REGISTRY_IP_PORT=${5}
  local BUNDLE_PATH=${6}

  # charts-syncer package
  yq -i ".source.repo.url = \"${HELM_REPO}\"" ${PROJECT_PATH}/test/artifacts/offline-e2e/sync_offline_package.yaml
  yq -i ".source.repo.auth.password = \"${REGISTRY_PASSWORD}\"" ${PROJECT_PATH}/test/artifacts/offline-e2e/sync_offline_package.yaml
  yq -i ".target.intermediateBundlesPath = \"${BUNDLE_PATH}\"" ${PROJECT_PATH}/test/artifacts/offline-e2e/sync_offline_package.yaml
  yq -i ".charts[0].versions[0] = \"${HELM_VERSION}\"" ${PROJECT_PATH}/test/artifacts/offline-e2e/sync_offline_package.yaml

  charts-syncer sync --config ${PROJECT_PATH}/test/artifacts/offline-e2e/sync_offline_package.yaml

  # start docker registry
  docker run -d -p 5011:5000 --restart=always --name registry-runtime-copilot release-ci.daocloud.io/ghippo/registry
  container_id=$(docker ps | grep -E 'runtime-copilot.*host-control-plane' | awk '{print $1}')
  sed -i 's/xx.x.xxx.xx:xxxx/'${REGISTRY_IP_PORT}'/g' "${PROJECT_PATH}"/test/artifacts/offline-e2e/config.toml
  docker cp "${PROJECT_PATH}"/test/artifacts/offline-e2e/config.toml "${container_id}":/etc/containerd/
  docker exec -i $container_id bash -c "systemctl restart containerd"

  # charts-syncer load image
  yq -i ".source.intermediateBundlesPath = \"${BUNDLE_PATH}\"" ${PROJECT_PATH}/test/artifacts/offline-e2e/load-image.yaml
  yq -i ".target.containerRegistry = \"${REGISTRY_IP_PORT}\"" ${PROJECT_PATH}/test/artifacts/offline-e2e/load-image.yaml
  yq -i ".target.containerRepository = \"offline.test.runtime-copilot/runtime-copilot\"" ${PROJECT_PATH}/test/artifacts/offline-e2e/load-image.yaml
  cd "${PROJECT_PATH}"
  charts-syncer sync --config ${PROJECT_PATH}/test/artifacts/offline-e2e/load-image.yaml

  # unpack runtime-copilot.bundle.tar
  cd "${BUNDLE_PATH}"
  tar -xvf runtime-copilot_${HELM_VERSION}.bundle.tar
}

function util::cleanup_registry_runtime-copilot() {
    registry_containerid=$(docker ps | grep "registry-runtime-copilot" | awk '{print $1}' || true)
    if [ -n "${registry_containerid}" ] ;then
      docker rm -f "${registry_containerid}"
    fi
}

function util::install_charts-sync() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local sync_version=0.0.5

    if [ -z "$(which charts-syncer)" ]; then
        tmp=$(mktemp -d)
        pushd "${tmp}" >/dev/null
        wget https://github.com/DaoCloud/charts-syncer/releases/download/v${sync_version}/charts-syncer_${sync_version}_${os}_x86_64.tar.gz
        tar -xvf charts-syncer_${sync_version}_${os}_x86_64.tar.gz
        sudo cp -rf charts-syncer /usr/local/bin/charts-syncer
        chmod +x /usr/local/bin/charts-syncer
        popd >/dev/null
        rm -rf "${tmp}"
    fi
}

function util::install_yq() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local yq_version=v4.25.3

    if [ -z "$(which yq)" ]; then
        tmp=$(mktemp -d)
        pushd "${tmp}" >/dev/null
        wget https://github.com/mikefarah/yq/releases/download/${yq_version}/yq_${os}_amd64
        sudo cp -rf yq_${os}_amd64 /usr/local/bin/yq
        chmod +x /usr/local/bin/yq
        popd >/dev/null
        rm -rf "${tmp}"
    fi
}
