#!/bin/bash

# 確保在非互動模式下，一旦有指令失敗就立即退出
set -e
# 確保未定義的變數會導致錯誤並退出
set -u

# --- 全局設定變數 ---
MARIADB_OPERATOR_NAMESPACE="test1"
MARIADB_OPERATOR_DEPLOYMENT_NAME="t-operator-v24-mariadb-operator"
MARIADB_OPERATOR_WEBHOOK_DEPLOYMENT_NAME="t-operator-v24-mariadb-operator-webhook"
MARIADB_OPERATOR_HELM_RELEASE_NAME="t-operator-v24" # Helm Release 的名稱
MARIADB_OPERATOR_NEW_IMAGE_NAME="t-operator"
MARIADB_OPERATOR_NEW_IMAGE_TAG="0.24.0"

MARIADB_OPERATOR_OLD_IMAGE_NAME="harbor-devops.devpos-hv.icsd.tsmc.com/computeinframgmt/gcimi/mariadb_day2"
MARIADB_OPERATOR_OLD_IMAGE_TAG="0.24.12.6.2"

MARIADB_OPERATOR_NEW_RESOURCES_PATH="./temp/mariadb-operator-resources-new.yaml"
MARIADB_OPERATOR_OLD_RESOURCES_PATH="./temp/mariadb-operator-resources-old.yaml"

MARIADB_NAMESPACE="db"
MARIADB_NAME="mariadb-repl"

PRIMARY_POD_NAME=""
PRIMARY_POD_INDEX=""
declare -a SLAVE_POD_INDEXES=()
SLAVES_IO_SQL_READY_NUM=0

MARIADB_RESOURCES_130_3_PATH="./mariadb-3"
MARIADB_RESOURCES_140_3_PATH="./temp/mariadb140-3"
MARIADB_RESOURCES_130_1_PATH="./temp/mariadb130-1"
MARIADB_RESOURCES_140_1_PATH="./temp/mariadb140-1"

MAX_RETRIES=6      # 最大重試次數
RETRY_DELAY=30     # 重試間隔秒數 (用於 auto_failover 和 Pod 狀態檢查)

# 檢查 Deployment 是否存在的函數 (不等待 Ready)
# 返回 0 如果存在，返回 1 如果不存在。
check_deployment_exists() {
    local deployment_name=$1
    local namespace=$2
    if kubectl get deployment "${deployment_name}" -n "${namespace}" &> /dev/null; then
        return 0 # 存在
    else
        return 1 # 不存在
    fi
}

# 檢查 Deployment 是否 Ready 的函數
# 返回 0 如果 Ready，返回 1 如果未 Ready。
check_deployment_ready() {
    local deployment_name=$1
    local namespace=$2
    local timeout_seconds=300
    
		echo "⚙️ Checking if Deployment: ${deployment_name} in namespace ${namespace} is Ready..."
    if ! kubectl rollout status deployment/"${deployment_name}" -n "${namespace}" --timeout="${timeout_seconds}s"; then
		    kubectl get deployment/"${deployment_name}" -n "${namespace}"
        echo "❌ ERROR: Deployment ${deployment_name} in namespace ${namespace} did not become Ready within ${timeout_seconds} seconds."
        return 1
    else
        kubectl get deployment/"${deployment_name}" -n "${namespace}"
        echo "✅ Deployment ${deployment_name} in namespace ${namespace} is Ready."
        return 0
    fi
}

# 卸載 MariaDB Operator 的函數
uninstall_mariadb_operator() {
    local resources_path="$1"
    echo -e "\n🗑️ Starting MariaDB Operator uninstallation..."
    local success=true

    # 1. Delete resources using kubectl
    echo "🗑️ Deleting MariaDB Operator related resources in namespace ${MARIADB_OPERATOR_NAMESPACE} from file ${resources_path}..."
    if kubectl -n "${MARIADB_OPERATOR_NAMESPACE}" delete -f "${resources_path}" || true; then
		    echo "✅ MariaDB Operator related resources deleted successfully (or did not exist)."
    else
        echo "⚠️ Warning: Failed to delete MariaDB Operator related resources."
        success=false
    fi
    
    if "$success"; then
        echo "🎉 MariaDB Operator uninstallation process completed."
        return 0
    else
        echo "⚠️ Warning: Errors occurred during MariaDB Operator uninstallation process."
        return 1
    fi
}

# 安裝 MariaDB Operator 的函數
install_mariadb_operator() {
    local resources_path="$1" # 將第一個參數賦值給局部變數 resources_path

    echo -e "\n🚀 Starting MariaDB Operator installation..."

    # 1. Apply resources using kubectl
    echo "🚀 Applying MariaDB Operator related resources to namespace ${MARIADB_OPERATOR_NAMESPACE} from file ${resources_path}..."
    if kubectl -n "${MARIADB_OPERATOR_NAMESPACE}" apply -f "${resources_path}"; then
		    echo "✅ MariaDB Operator related resources applied successfully."
    else
        echo "❌ Error: Failed to apply MariaDB Operator related resources. Script terminated."
        return 1 # Return non-zero to indicate failure
    fi
    
    echo "🎉 MariaDB Operator installation process completed."
    return 0
}

get_pod_info() {
    if [ -n "$PRIMARY_POD_NAME" ] && [ ${#SLAVE_POD_INDEXES[@]} -gt 0 ]; then
        echo "Pod Information Ready."
        return 0 # 已設定，直接返回
    fi

    echo "Geting Pod Information..."
    local mdb_replicas
    mdb_replicas=$(kubectl -n "$MARIADB_NAMESPACE" get mdb "$MARIADB_NAME" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
    if [ $? -ne 0 ] || [ -z "$mdb_replicas" ]; then
		    echo "Error: can't get spec.replicas from mdb '$MARIADB_NAME'"
        return 1
    fi
    
    local curr_primary_pod_index
    curr_primary_pod_index=$(kubectl -n "$MARIADB_NAMESPACE" get mdb "$MARIADB_NAME" -o jsonpath='{.status.currentPrimaryPodIndex}' 2>/dev/null || true)
    if [ $? -ne 0 ] || [ -z "$curr_primary_pod_index" ]; then
		    echo "Error: can't get status.currentPrimaryPodIndex from mdb '$MARIADB_NAME'"
        return 1
    fi
    
    PRIMARY_POD_INDEX=$curr_primary_pod_index
    PRIMARY_POD_NAME="$MARIADB_NAME-$curr_primary_pod_index"
    echo "Primary Pod: $PRIMARY_POD_NAME"
    
    SLAVE_POD_INDEXES=() # 清空舊值
    for i in $(seq 0 $((mdb_replicas - 1))); do
        if [ "$i" -ne "$curr_primary_pod_index" ]; then
            SLAVE_POD_INDEXES+=("$i")
        fi
    done
    echo "Slave Pods: ${SLAVE_POD_INDEXES[@]}"
    return 0
}

# 確認 mariadb Ready conditions / pods replication 都正常
pre_check_mariadb() {
    echo "---⚙️ checking mdb Ready conditions ---"
    # 1. Check if $MARIADB_NAMESPACE and $MARIADB_NAME are empty
    if [ -z "$MARIADB_NAMESPACE" ]; then
		    echo "Error: Variable \$MARIADB_NAMESPACE is not set or is empty. Please provide a namespace."
        return 1
    fi
    
    if [ -z "$MARIADB_NAME" ]; then
        echo "Error: Variable \$MARIADB_NAME is not set or is empty. Please provide an MDB name."
        return 1
    fi
    
    local mdb_status
    mdb_status=$(kubectl -n "$MARIADB_NAMESPACE" get mdb "$MARIADB_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    
    if [ $? -ne 0 ]; then
        echo "Error: Could not get Ready status for mdb '$MARIADB_NAME'. Please check the namespace and resource name."
        return 1
    fi
    
    if [ -z "$mdb_status" ]; then
        echo "Error: The Ready status obtained for mdb '$MARIADB_NAME' is empty. The mdb status might be incorrect or the jsonpath is wrong."
        return 1
    fi
    
    if [ "$mdb_status" != "True" ]; then
        echo "Error: The Ready condition for mdb '$MARIADB_NAME' is not 'True'. Current status: '$mdb_status'."
        return 1
    fi
    
    echo "mdb '$MARIADB_NAME' Ready conditions status is 'True'. Continue checking pod"
    mdb_replicas=$(kubectl -n "$MARIADB_NAMESPACE" get mdb "$MARIADB_NAME" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
    echo "mdb '$MARIADB_NAME' replicas is $mdb_replicas."
    echo
    echo "---⚙️ checking pods ---"
 
    if ! get_pod_info; then # Call helper function to get Pod information
        echo "Error: Could not get Pod information, Step 0 failed."
        return 1
    fi
    
    # Checking Primary
    echo ""
    echo "Now Checking Primary Pod: $PRIMARY_POD_NAME User."
    local RAW_STATUS
    RAW_STATUS=$(kubectl -n "$MARIADB_NAMESPACE" exec "$PRIMARY_POD_NAME" -c mariadb -- bash -c 'mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -e "select user from mysql.user"' 2>/dev/null || true)
    
    if [ -z "$RAW_STATUS" ]; then
        echo "Could not get User for $PRIMARY_POD_NAME."
        return 1
    fi
    
    echo "Raw user output: $RAW_STATUS" 

    local USERS_TO_CHECK=("mariadb" "repl")
    local MISSING_USERS=()
    
		for user in "${USERS_TO_CHECK[@]}"; do
        if ! echo "$RAW_STATUS" | grep -q "$user"; then
            MISSING_USERS+=("$user")
        fi
    done
    
    if [ ${#MISSING_USERS[@]} -gt 0 ]; then
        echo "Error: The following required users are missing from $PRIMARY_POD_NAME: ${MISSING_USERS[*]}."
        return 1
    else
		    echo "All required users (mariadb, metrics, repl, probeuser) are present on $PRIMARY_POD_NAME."
    fi
    echo ""
    
    # Checking Slaves
    for slave_index in "${SLAVE_POD_INDEXES[@]}"; do
        echo "Slave Pod index: $slave_index"
        echo "Now Checking: $MARIADB_NAME"-"$slave_index allow status error"
        
        local RAW_STATUS
        RAW_STATUS=$(kubectl -n "$MARIADB_NAMESPACE" exec "$MARIADB_NAME"-"$slave_index" -c mariadb -- bash -c 'mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -e "show all slaves status\G"' 2>/dev/null || true)
        
        if [ -z "$RAW_STATUS" ]; then
            echo "Could not get status for $MARIADB_NAME-$slave_index. Please check permissions or if this machine is a Slave."
            return 1
        fi
        
        local IO_RUNNING
        local SQL_RUNNING
        IO_RUNNING=$(echo "$RAW_STATUS" | grep "^[[:space:]]*Slave_IO_Running:" | awk -F': ' '{print $2}' | xargs)
        SQL_RUNNING=$(echo "$RAW_STATUS" | grep "^[[:space:]]*Slave_SQL_Running:" | awk -F': ' '{print $2}' | xargs)
        
        echo "DEBUG: IO=[$IO_RUNNING], SQL=[$SQL_RUNNING]"

        if [[ "$IO_RUNNING" == "Yes" && "$SQL_RUNNING" == "Yes" ]]; then
		        echo "✅ Status is normal"
            echo
            SLAVES_IO_SQL_READY_NUM=$(expr $SLAVES_IO_SQL_READY_NUM + 1)
        else
		        echo "❌ Status is abnormal. This Step 0 pre-check allows continuation even with abnormal status."
            echo
        fi
    done
    
    echo "mdb '$MARIADB_NAME' Slave pods status check completed."
    echo
    return 0
}

# 確認 mariadb Ready conditions / pods replication 都正常
pre_check_metrics_deployment() {
    echo "---⚙️ checking metrics deployment Ready conditions ---"
    # 1. Check if $MARIADB_NAMESPACE and $MARIADB_NAME are empty
    if [ -z "$MARIADB_NAMESPACE" ]; then
        echo "Error: Variable \$MARIADB_NAMESPACE is not set or is empty. Please provide a namespace."
        return 1
    fi
    
    if [ -z "$MARIADB_NAME" ]; then
        echo "Error: Variable \$MARIADB_NAME is not set or is empty. Please provide an MDB name."
        return 1
    fi
    
    local replicas
    local ready_replicas
    replicas=$(kubectl -n "$MARIADB_NAMESPACE" get deployment "$MARIADB_NAME-metrics" -o jsonpath='{.status.replicas}' 2>/dev/null || true)
    
    if [ $? -ne 0 ]; then
        echo "Error: Could not get replicas for metrics deployment '$$MARIADB_NAME-metrics'. Please check the namespace and resource name."
        return 1
    fi
    
    if [ -z "$replicas" ]; then
        echo "Error: The replicas obtained for metrics deployment '$$MARIADB_NAME-metrics' is empty. The metrics deployment status might be incorrect or the jsonpath is wrong."
        return 1
    fi
    
    ready_replicas=$(kubectl -n "$MARIADB_NAMESPACE" get deployment "$MARIADB_NAME-metrics" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    if [ $? -ne 0 ]; then
		    echo "Error: Could not get readyReplicas for metrics deployment '$$MARIADB_NAME-metrics'. Please check the namespace and resource name."
        return 1
    fi
    if [ -z "$ready_replicas" ]; then
        echo "Error: The ready_replicas obtained for metrics deployment '$$MARIADB_NAME-metrics' is empty. The metrics deployment status might be incorrect or the jsonpath is wrong."
        return 1
    fi
    
    echo "Total replicas: $replicas"
    echo "Ready replicas: $ready_replicas"
    echo ""
    # Check if the number of replicas and ready replicas are not equal
    if [ "$replicas" -ne "$ready_replicas" ]; then
        echo "All replicas not ready"
        return 0
    else
        echo "All replicas ready!"
        return 1
    fi
}


check_mariadb_pods_restarts() {
    local namespace="$1"
    local mdb_name="$2"
    local primary_idx="$3"
    local slave_indexes="$4" # 使用 nameref 傳遞陣列
    
    echo "--- Checking MariaDB Pod Restarts ---"

    local all_pods_ok=true

    # 檢查 Primary Pod
    local primary_pod_name="${mdb_name}-${primary_idx}"
    echo "檢查 Primary Pod: ${primary_pod_name}"
    if check_single_pod_restarts "$namespace" "$primary_pod_name"; then
        echo "✅ Primary Pod ${primary_pod_name} have not restart."
    else
        echo "❌ Primary Pod ${primary_pod_name} have restart."
        all_pods_ok=false
    fi
    echo

    # 檢查 Slave Pods
    for slave_idx in "${slave_indexes[@]}"; do
        local slave_pod_name="${mdb_name}-${slave_idx}"
        echo "檢查 Slave Pod: ${slave_pod_name}"
        if check_single_pod_restarts "$namespace" "$slave_pod_name"; then
            echo "✅ Slave Pod ${slave_pod_name} have not restart."
        else
            echo "❌ Slave Pod ${slave_pod_name} have restart."
            all_pods_ok=false
        fi
        echo
    done

        if "$all_pods_ok"; then
        echo "All MariaDB Pods have not restarted."
        return 0
    else
        echo "Some MariaDB Pods have restarted."
        return 1
    fi
}


check_single_pod_restarts() {
    local namespace="$1"
    local pod_name="$2"

    local restart_counts
    restart_counts=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.containerStatuses[*].restartCount}' 2>/dev/null)
    
    if [ -z "$restart_counts" ]; then
        echo "Error: can't get Pod '$pod_name'."
        return 1 
    fi

    for count in $restart_counts; do
        if [ "$count" -gt 0 ]; then
            return 1 # Pod 有重啟
        fi
    done
    
    return 0 # Pod 沒有重啟
}

delete_mariadb_resources() {
    local namespace="$1"
    local resource_path="$2"

    if pre_check_mariadb; then
        echo "🚀 Applying MariaDB resources to namespace ${namespace} from file ${resource_path}..."
        if kubectl -n "${namespace}" delete -f "${resource_path}"; then
            echo "✅ MariaDB resources deleted successfully."
        else
            echo "❌ Error: Failed to delete MariaDB resources. Script terminated."
            return 1
        fi

        echo "🚀 Deleting all PVCs in namespace ${namespace}..."
        if kubectl -n "${namespace}" delete pvc --all; then
            echo "✅ PVCs deleted successfully."
        else
		        echo "❌ Error: Failed to delete PVCs. Script terminated."
            return 1
        fi
    else
        echo "ℹ️ MariaDB pre-check failed or condition not met. Skipping deletion."
        return 0
    fi

    return 0
}


# Function to apply MariaDB resources
apply_mariadb_resources() {
    local namespace="$1"
    local resource_path="$2"

    echo "🚀 Applying MariaDB resources to namespace ${namespace} from file ${resource_path}..."
		if kubectl -n "${namespace}" apply -f "${resource_path}"; then
        echo "✅ MariaDB resources applied successfully."
        return 0 # Return 0 for success
    else
		    echo "❌ Error: Failed to apply MariaDB resources. Script terminated."
        return 1 # Return non-zero to indicate failure
    fi
}

# Function to perform pre-check with retries
check_mariadb_with_retries() {
    PRIMARY_POD_NAME=""
    SLAVE_POD_INDEXES=()

    local attempt=1

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "--- Attempting to Check MariaDB (Attempt $attempt of $MAX_RETRIES) ---"
        echo
        
        if pre_check_mariadb; then
            echo "✅ Successfully pre-checked MariaDB."
            echo
            return 0 # Success
        else
            echo "❌ pre-check-mariadb failed."
            if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                echo "Retrying after $RETRY_DELAY seconds..."
                sleep "$RETRY_DELAY"
            else
		            echo "❌ Maximum retry attempts ($MAX_RETRIES) reached. pre-check-mariadb failed."
                echo
                return 1 # Failure after all retries
            fi
        fi
        attempt=$((attempt + 1))
    done
    
    # Should not reach here, but as a safeguard
    return 1
}

# Function to perform pre-check with retries
check_metrics_deployment_with_retries() {
    local attempt=1
    
    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "--- Attempting to Check MariaDB (Attempt $attempt of $MAX_RETRIES) ---"
        echo

        if pre_check_mariadb; then
            echo "✅ Successfully pre-checked MariaDB."
            echo
            return 0 # Success
        else
            echo "❌ pre-check-mariadb failed."
            if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                echo "Retrying after $RETRY_DELAY seconds..."
                sleep "$RETRY_DELAY"
            else
                echo "❌ Maximum retry attempts ($MAX_RETRIES) reached. pre-check-mariadb failed."
                echo
                return 1 # Failure after all retries
            fi
        fi
        attempt=$((attempt + 1))
    done

    # Should not reach here, but as a safeguard
    return 1
}

# --- 測試案例函數 ---

run_test_0() {
    echo -e "✨ 0. Confirm Images Starting...\n"
    echo "Confirming MariaDB Operator image information in local Docker cache and loading to Kind cluster."

    local overall_success=true

    # --- New Version Image Information ---
    echo "--- New Version Image Information ---"
    local new_full_image="${MARIADB_OPERATOR_NEW_IMAGE_NAME}:${MARIADB_OPERATOR_NEW_IMAGE_TAG}"
    echo "Image Name: ${MARIADB_OPERATOR_NEW_IMAGE_NAME}"
    echo "Image Tag: ${MARIADB_OPERATOR_NEW_IMAGE_TAG}"
    echo "Full Image Path: ${new_full_image}"

    echo "Checking for new image in local Docker cache..."
    if [ -n "$(docker images -q "${new_full_image}")" ]; then
		    echo "✅ New version image exists in local Docker cache: ${new_full_image}."
        echo "Attempting to load new image into Kind cluster..."
        if kind load docker-image "${new_full_image}" > /dev/null 2>&1; then
		        echo "✅ New version image successfully loaded into Kind cluster."
        else
            echo "❌ Failed to load new version image into Kind cluster. Is a Kind cluster running?"
            overall_success=false
        fi
    else
        echo "❌ New version image does NOT exist in local Docker cache: ${new_full_image}."
        echo "Skipping loading new image to Kind cluster as it's not found locally."
        overall_success=false
    fi
    echo ""
    
    # --- Old Version Image Information ---
    echo "--- Old Version Image Information ---"
    local old_full_image="${MARIADB_OPERATOR_OLD_IMAGE_NAME}:${MARIADB_OPERATOR_OLD_IMAGE_TAG}"
    echo "Image Name: ${MARIADB_OPERATOR_OLD_IMAGE_NAME}"
    echo "Image Tag: ${MARIADB_OPERATOR_OLD_IMAGE_TAG}"
    echo "Full Image Path: ${old_full_image}"

    echo "Checking for old image in local Docker cache..."
    if [ -n "$(docker images -q "${old_full_image}")" ]; then
		    echo "✅ Old version image exists in local Docker cache: ${old_full_image}."
        echo "Attempting to load old image into Kind cluster..."
        if kind load docker-image "${old_full_image}" > /dev/null 2>&1; then
		        echo "✅ Old version image successfully loaded into Kind cluster."
        else
            echo "❌ Failed to load old version image into Kind cluster. Is a Kind cluster running?"
            overall_success=false
        fi
    else
		    echo "❌ Old version image does NOT exist in local Docker cache: ${old_full_image}."
        echo "Skipping loading old image to Kind cluster as it's not found locally."
        overall_success=false 
    fi
    echo ""

    pre_check_mariadb
    
    echo ""

    if "$overall_success"; then
        echo "✅ All specified images confirmed and loaded to Kind cluster successfully."
        return 0
    else
		    echo "❌ Some image checks or Kind cluster loading steps failed. Please review the logs."
        return 1
    fi
}

# 1.1. Deploy New MariaDB Operator
run_test_1_1() {
    echo -e "✨ 1.1. Deploy New MariaDB Operator Test Started...n"

		# Phase 1: Check for existing deployment
    echo -e "🔎 Checking for existing MariaDB Operator Deployment...n"
    if check_deployment_exists "${MARIADB_OPERATOR_DEPLOYMENT_NAME}" "${MARIADB_OPERATOR_NAMESPACE}"; then
		    echo "✅ Deployment ${MARIADB_OPERATOR_DEPLOYMENT_NAME} detected."
        echo -e "n⚠️ Existing deployment detected, initiating uninstallation process..."
        
        uninstall_mariadb_operator $MARIADB_OPERATOR_NEW_RESOURCES_PATH # set -e will exit if this fails critically
        
        echo -e "n⏳ Waiting for some time to ensure resources are released..."
        sleep 10 # Give Kubernetes some time to clean up resources
    else
        echo "ℹ️ No Deployment ${MARIADB_OPERATOR_DEPLOYMENT_NAME} detected. Skipping uninstallation."
    fi
    
    # Phase 2: Perform installation
    echo -e "n✅ apply -f $MARIADB_OPERATOR_NEW_RESOURCES_PATH"
    install_mariadb_operator $MARIADB_OPERATOR_NEW_RESOURCES_PATH
    
    # Phase 3: Verify the deployed installation
    echo -e "n✅ Installation complete, verifying deployment status..."
    local all_deployments_ready=true
    
    if ! check_deployment_ready "${MARIADB_OPERATOR_DEPLOYMENT_NAME}" "${MARIADB_OPERATOR_NAMESPACE}"; then
        all_deployments_ready=false
    fi
    
    if ! check_deployment_ready "${MARIADB_OPERATOR_WEBHOOK_DEPLOYMENT_NAME}" "${MARIADB_OPERATOR_NAMESPACE}"; then
        all_deployments_ready=false
    fi
    
    if [ "$all_deployments_ready" = true ]; then
        echo -e "n🎉 All specified MariaDB Operator Deployments are successfully deployed and Ready."
        return 0
    else
		    echo -e "n❌ Error: Some MariaDB Operator Deployments failed to reach Ready state."
        return 1
    fi
}

# 1.2. MariaDB Operator Image Upgrade
run_test_1_2() {
    echo -e "✨ 1.1. MariaDB Operator Image Upgrade Test Started...n"
    
    # Phase 1: Check for existing deployment
    echo -e "🔎 Checking for existing MariaDB Operator Deployment...n"
    if check_deployment_exists "${MARIADB_OPERATOR_DEPLOYMENT_NAME}" "${MARIADB_OPERATOR_NAMESPACE}"; then
		    echo "✅ Deployment ${MARIADB_OPERATOR_DEPLOYMENT_NAME} detected."
        echo -e "n⚠️ Existing deployment detected, initiating uninstallation process..."

        echo "Attempting to get current MariaDB Operator image version..."
        CURRENT_OPERATOR_IMAGE=$(kubectl -n "${MARIADB_OPERATOR_NAMESPACE}" get deploy "${MARIADB_OPERATOR_DEPLOYMENT_NAME}" -o jsonpath='{range .spec.template.spec.containers[?(@.name=="controller")]}{.image}{end}')
        
        if [ -n "$CURRENT_OPERATOR_IMAGE" ]; then
            CURRENT_OPERATOR_VERSION=$(echo "$CURRENT_OPERATOR_IMAGE" | awk -F: '{print $NF}')
            echo "ℹ️ Current MariaDB Operator Image: $CURRENT_OPERATOR_IMAGE"
            echo "ℹ️ Current MariaDB Operator Version (extracted tag): $CURRENT_OPERATOR_VERSION"
        else
            echo "❌ Could not determine current MariaDB Operator image/version. Is the 'controller' container name correct?"
            CURRENT_OPERATOR_VERSION="unknown"
        fi

        uninstall_mariadb_operator $MARIADB_OPERATOR_NEW_RESOURCES_PATH # set -e will exit if this fails critically
        echo -e "n⏳ Waiting for some time to ensure resources are released..."
        sleep 10 # Give Kubernetes some time to clean up resources
    else
		    echo "ℹ️ No Deployment ${MARIADB_OPERATOR_DEPLOYMENT_NAME} detected. Skipping uninstallation."
    fi

    # Phase 2: Perform installation
    install_mariadb_operator $MARIADB_OPERATOR_OLD_RESOURCES_PATH
    
    # Phase 3: Verify the deployed installation
    echo -e "n✅ Installation complete, verifying deployment status..."
    local all_deployments_ready=true
    
    if ! check_deployment_ready "${MARIADB_OPERATOR_DEPLOYMENT_NAME}" "${MARIADB_OPERATOR_NAMESPACE}"; then
        all_deployments_ready=false
    fi
    
    if ! check_deployment_ready "${MARIADB_OPERATOR_WEBHOOK_DEPLOYMENT_NAME}" "${MARIADB_OPERATOR_NAMESPACE}"; then
        all_deployments_ready=false
    fi
    
    if [ "$all_deployments_ready" = true ]; then
        echo -e "\n🎉 All specified MariaDB Operator Deployments are successfully deployed and Ready."
    else
		    echo -e "\n❌ Error: Some MariaDB Operator Deployments failed to reach Ready state."
        return 1
    fi

    # Phase 4: apply -f MARIADB_RESOURCES_130_3_PATH
    echo "🚀 Applying MariaDB resources to namespace ${MARIADB_NAMESPACE} from file ${MARIADB_RESOURCES_130_3_PATH}..."
    if kubectl -n "${MARIADB_NAMESPACE}" apply -f "${MARIADB_RESOURCES_130_3_PATH}"; then
		    echo "✅ MariaDB resources applied successfully."
    else
        echo "❌ Error: Failed to apply MariaDB resources. Script terminated."
        return 1 # Return non-zero to indicate failure
    fi
    
    # Phase 5: checking
    PRIMARY_POD_NAME=""
    SLAVE_POD_INDEXES=()

    local attempt=1
    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "--- Attempting to Checking (Attempt $attempt) ---"
        echo
        if pre_check_mariadb; then
            echo "Successfully pre-check-mariadb"
            echo
            break
        else
            echo "pre-check-mariadb failed."
            if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                echo "Retrying after $RETRY_DELAY seconds..."
                sleep "$RETRY_DELAY"
            else
		            echo "Maximum retry attempts ($MAX_RETRIES) reached. pre-check-mariadb failed."
                echo
                return 1
            fi
        fi
        attempt=$((attempt + 1))
    done
    
    # Phase 6: check operator image
    echo "Attempting to get current MariaDB Operator image version..."
    CURRENT_OPERATOR_IMAGE=$(kubectl -n "${MARIADB_OPERATOR_NAMESPACE}" get deploy "${MARIADB_OPERATOR_DEPLOYMENT_NAME}" -o jsonpath='{range .spec.template.spec.containers[?(@.name=="controller")]}{.image}{end}')
    
     if [ -n "$CURRENT_OPERATOR_IMAGE" ]; then
        CURRENT_OPERATOR_VERSION=$(echo "$CURRENT_OPERATOR_IMAGE" | awk -F: '{print $NF}')
        echo "ℹ️ Current MariaDB Operator Image: $CURRENT_OPERATOR_IMAGE"
        echo "ℹ️ Current MariaDB Operator Version (extracted tag): $CURRENT_OPERATOR_VERSION"
    else
        echo "❌ Could not determine current MariaDB Operator image/version. Is the 'controller' container name correct?"
        CURRENT_OPERATOR_VERSION="unknown"
    fi

    # Phase 7: upgrade operator
    install_mariadb_operator $MARIADB_OPERATOR_NEW_RESOURCES_PATH

    # Phase 8: Verify the deployed installation
    echo -e "n✅ Installation complete, verifying deployment status..."
    local all_deployments_ready=true
    
    if ! check_deployment_ready "${MARIADB_OPERATOR_DEPLOYMENT_NAME}" "${MARIADB_OPERATOR_NAMESPACE}"; then
        all_deployments_ready=false
    fi
    
    if ! check_deployment_ready "${MARIADB_OPERATOR_WEBHOOK_DEPLOYMENT_NAME}" "${MARIADB_OPERATOR_NAMESPACE}"; then
        all_deployments_ready=false
    fi
    
    if [ "$all_deployments_ready" = true ]; then
        echo -e "\n🎉 All specified MariaDB Operator Deployments are successfully deployed and Ready."
    else
		    echo -e "\n❌ Error: Some MariaDB Operator Deployments failed to reach Ready state."
        return 1
    fi

    # Phase 9: check operator image
    echo "Attempting to get current MariaDB Operator image version..."
    CURRENT_OPERATOR_IMAGE=$(kubectl -n "${MARIADB_OPERATOR_NAMESPACE}" get deploy "${MARIADB_OPERATOR_DEPLOYMENT_NAME}" -o jsonpath='{range .spec.template.spec.containers[?(@.name=="controller")]}{.image}{end}')
    
    if [ -n "$CURRENT_OPERATOR_IMAGE" ]; then
        CURRENT_OPERATOR_VERSION=$(echo "$CURRENT_OPERATOR_IMAGE" | awk -F: '{print $NF}')
        echo "ℹ️ Current MariaDB Operator Image: $CURRENT_OPERATOR_IMAGE"
        echo "ℹ️ Current MariaDB Operator Version (extracted tag): $CURRENT_OPERATOR_VERSION"
    else
        echo "❌ Could not determine current MariaDB Operator image/version. Is the 'controller' container name correct?"
        CURRENT_OPERATOR_VERSION="unknown"
    fi

    # Phase 10: check mariadb pod restart?
    if check_mariadb_pods_restarts "$MARIADB_NAMESPACE" "$MARIADB_NAME" "$PRIMARY_POD_INDEX" "$SLAVE_POD_INDEXES"; then
		    echo "All MariaDB Pod Status Ready (have no restart)。"
    else
        echo "Error: MariaDB Pod restartCount greater than 0"
    fi
}

# 測試 2.1 Deploy MariaDB 1+N (replicas:3, helm chart: 1.3.0)
run_test_2_1() {
    echo -e "✨ 2.1. Deploy MariaDB 1+N (replicas:3, helm chart: 1.3.0)...n"

    delete_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_130_3_PATH}
    
    sleep 10

    # Phase 1: apply -f MARIADB_RESOURCES_130_3_PATH
    apply_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_130_3_PATH}

    sleep 10

    check_mariadb_with_retries
    
    echo -e "\n✅ Test 2.1 Success."
    return 0
}

# 測試 2.2 Deploy MariaDB 1+N (replicas:3, helm chart: 1.4.0)
run_test_2_2() {
    echo -e "✨ 2.2. Deploy MariaDB 1+N (replicas:3, helm chart: 1.4.0)...n"

    delete_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_130_3_PATH}
    
    sleep 10

    # Phase 1: apply -f MARIADB_RESOURCES_140_3_PATH
    apply_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_140_3_PATH}

    sleep 10
    
    check_mariadb_with_retries

    echo -e "\n✅ Test 2.2 Success."
    return 0
}

# 測試 2.3 Deploy MariaDB 1+N (replicas:1, helm chart: 1.3.0)
run_test_2_3() {
    echo -e "✨ 2.3. Deploy MariaDB 1+N (replicas:1, helm chart: 1.3.0)...n"

    delete_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_130_3_PATH}
    
    sleep 10

    # Phase 1: apply -f MARIADB_RESOURCES_130_1_PATH
    apply_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_130_1_PATH}

    sleep 10
    
    check_mariadb_with_retries

    echo -e "\n✅ Test 2.3 Success."
    return 0
}

# 測試 2.4 Deploy MariaDB 1+N (replicas:1, helm chart: 1.4.0)
run_test_2_4() {
    echo -e "✨ 2.4. Deploy MariaDB 1+N (replicas:1, helm chart: 1.4.0)...n"

    delete_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_130_3_PATH}
    
    sleep 10

    # Phase 1: apply -f MARIADB_RESOURCES_140_1_PATH
    apply_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_140_1_PATH}

    sleep 10
    
    check_mariadb_with_retries

    echo -e "\n✅ Test 2.4 Success."
    return 0
}

# 測試 3.1 replicas scale down (3 to 1) and primary index is 0
run_test_3_1() {
    echo -e "✨ 3.1. replicas scale down (3 to 1) and primary index is 0...n"

    delete_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_130_3_PATH}
    
    sleep 10
    
    # Phase 1: apply -f MARIADB_RESOURCES_140_1_PATH
    apply_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_130_3_PATH}

    sleep 10

    check_mariadb_with_retries
    
    if kubectl -n "${MARIADB_NAMESPACE}" patch mdb "${MARIADB_NAME}" --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 1}]'; then
        echo "✅ MariaDB resources patch replicas successfully."
    else
		    echo "❌ Error: Failed to patch MariaDB replicas. Script terminated."
        return 1
    fi

    check_mariadb_with_retries

    echo -e "\n✅ Test 3.1 Success."
    return 0
}

# 測試 3.2 replicas scale down (3 to 1) and primary index is not 0
run_test_3_2() {
    echo -e "✨ 3.2. replicas scale down (3 to 1) and primary index is not 0...n"
    
    delete_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_130_3_PATH}
    
    sleep 10

    # Phase 1: apply -f MARIADB_RESOURCES
    apply_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_130_3_PATH}
    
    sleep 10

    check_mariadb_with_retries

    # switchover
    if kubectl -n "${MARIADB_NAMESPACE}" patch mdb "${MARIADB_NAME}" --type='json' -p='[{"op": "replace", "path": "/spec/replication/primary/podIndex", "value": 2}]'; then
        echo "✅ MariaDB resources patch to switchover successfully."
    else
        echo "❌ Error: Failed to patch MariaDB switchover. Script terminated."
        return 1
    fi

    sleep 10

    check_mariadb_with_retries
    
    apply_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_130_1_PATH}

    sleep 10

    check_mariadb_with_retries

    echo -e "\n✅ Test 3.2 Success."
    return 0
}

# 測試 3.3 replicas scale down (3 to 1) and primary index is not 0
run_test_3_3() {
    echo -e "✨ 3.3. replicas scale up (1 to 3)...n"

    delete_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_130_3_PATH}
    
    sleep 10

    # Phase 1: apply -f MARIADB_RESOURCES
    apply_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_130_1_PATH}

    sleep 10

    check_mariadb_with_retries
    
    apply_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_130_3_PATH}

    sleep 10

    check_mariadb_with_retries

    echo -e "\n✅ Test 3.3 Success."
    return 0
}

# 測試 4 Metrixcs Pod exist?
run_test_4_1() {
    echo -e "✨ 4.1. deploy replicas 3 to checking metrics pod...\n"

    apply_mariadb_resources ${MARIADB_NAMESPACE} ${MARIADB_RESOURCES_130_3_PATH}
    
    sleep 10

    check_mariadb_with_retries

    sleep 10

    pre_check_metrics_deployment

    echo -e "\n✅ Test 4.1 Success."
    return 0
}

# 測試 5.1 向 Primary寫入數據 * 確認 "能" 向 Primary寫入數據。
run_test_5_1() {
    echo -e "✨ 5.1. Checking Write into primary svc...\n"
    
    day0_pod_status=$(kubectl -n "${MARIADB_NAMESPACE}" get pod day0-pod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    echo "Day0 pod ready states: $day0_pod_status"

    echo 
    
    if [ -z "$day0_pod_status" ]; then
        echo "day0_pod_status is empty."
        if kubectl -n "${MARIADB_NAMESPACE}" apply -f ./temp/day0-pod.yaml; then
            echo "✅ Day0 resources applied successfully."
        else
            echo "❌ Error: Failed to apply Day0 resources. Script terminated."
            return 1 # Return non-zero to indicate failure
        fi
    fi

    sleep 20
    day0_pod_status=$(kubectl -n "${MARIADB_NAMESPACE}" get pod day0-pod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    echo "Day0 pod ready states: $day0_pod_status"
    
    Host=$(kubectl -n "$MARIADB_NAMESPACE" exec day0-pod -c day0-container -- bash -c 'mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -h '${MARIADB_NAME}-primary' -e "select @@hostname"')
    echo "Host: $Host"
    
    if [ -z "$Host" ]; then
        echo "Host empty."
        return 1
    fi

    echo ""
    echo "--- Test write ---"
    # 1. 建立一個測試資料庫和表格
    echo "Create databases and tables..."
    create_db_table_cmd='"
    CREATE DATABASE IF NOT EXISTS test_db;
    USE test_db;
    CREATE TABLE IF NOT EXISTS test_table (
        id INT AUTO_INCREMENT PRIMARY KEY,
        message VARCHAR(255) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    "'
    kubectl -n "$MARIADB_NAMESPACE" exec day0-pod -c day0-container -- bash -c 'mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -h '${MARIADB_NAME}-primary' -e '"${create_db_table_cmd}"''
    if [ $? -eq 0 ]; then
        echo "Databases and tables create success."
    else
        echo "Databases and tables create fail."
        exit 1
    fi
    
    # 2. 建立 test_user
    create_user_cmd='"CREATE USER IF NOT EXISTS '\''test_user'\''@'\''%'\'' IDENTIFIED BY '\''testTEST123456!'\'';  GRANT SELECT, INSERT, UPDATE, DELETE ON test_db.test_table TO '\''test_user'\''@'\''%'\'';"'
    kubectl -n "$MARIADB_NAMESPACE" exec day0-pod -c day0-container -- bash -c 'mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -h '${MARIADB_NAME}-primary' -e '"${create_user_cmd}"''
    if [ $? -eq 0 ]; then
        echo "Create user success."
    else
        echo "Create user fail"
        return 1
    fi
    
    # 3. 插入一筆資料
    TEST_MESSAGE="Hello from $(hostname) at $(date +%H:%M:%S)"
    echo "Insert data: '$TEST_MESSAGE'..."
    insert_cmd='"
    INSERT INTO test_db.test_table (message) VALUES ('\'"${TEST_MESSAGE}"\'');
    "'
    kubectl -n "$MARIADB_NAMESPACE" exec day0-pod -c day0-container -- bash -c 'mariadb -u test_user -p"'testTEST123456!'" -h '${MARIADB_NAME}-primary' -e '"${insert_cmd}"''
    if [ $? -eq 0 ]; then
        echo "Insert data success."
    else
        echo "Insert data fail"
        return 1
    fi

    echo -e "\n✅ Test 5.1 Success."
    return 0
}

# 測試 5.2 向 Slave寫入數據 * 確認 "不能" 向 Slave寫入數據。
run_test_5_2() {
    echo -e "✨ 5.2. Checking Write into slave svc...\n"
    
    day0_pod_status=$(kubectl -n "${MARIADB_NAMESPACE}" get pod day0-pod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    echo "Day0 pod ready states: $day0_pod_status"
    
    if [ "$day0_pod_status" = false ]; then
        if kubectl -n "${MARIADB_NAMESPACE}" apply -f ./temp/day0-pod.yaml; then
            echo "✅ Day0 resources applied successfully."
            return 0 # Return 0 for success
        else
            echo "❌ Error: Failed to apply Day0 resources. Script terminated."
            return 1 # Return non-zero to indicate failure
        fi
    fi
    
    Host=$(kubectl -n "$MARIADB_NAMESPACE" exec day0-pod -c day0-container -- bash -c 'mariadb -u test_user -p"'testTEST123456!'" -h '${MARIADB_NAME}-secondary' -e "select @@hostname"' || true)
    echo "Host: $Host"
    
    if [ -z "$Host" ]; then
        echo "Host empty."
        return 1
    fi

    echo ""
    echo "--- Test write ---"
    # 1. 插入一筆資料
    TEST_MESSAGE="Hello from $(hostname) at $(date +%H:%M:%S)"
    echo "Insert data: '$TEST_MESSAGE'..."
    insert_cmd='"
    INSERT INTO test_db.test_table (message) VALUES ('\'"${TEST_MESSAGE}"\'');
    "'
    kubectl -n "$MARIADB_NAMESPACE" exec day0-pod -c day0-container -- bash -c 'mariadb -u test_user -p"'testTEST123456!'" -h '${MARIADB_NAME}-secondary' -e '"${insert_cmd}"''
    if [ $? -eq 0 ]; then
        echo "Insert data success."
        return 1
    else
        echo "insert data fail"
    fi

    echo -e "\n✅ Test 5.2 Success."
    return 0
}

# 測試 5.3 向 Primay讀取數據 * 確認 "能" 向 Primay讀取數據。
run_test_5_3() {
    echo -e "✨ 5.3. Checking Select from primary svc...\n"
    
    day0_pod_status=$(kubectl -n "${MARIADB_NAMESPACE}" get pod day0-pod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    echo "Day0 pod ready states: $day0_pod_status"
    
    if [ "$day0_pod_status" = false ]; then
        if kubectl -n "${MARIADB_NAMESPACE}" apply -f ./temp/day0-pod.yaml; then
            echo "✅ Day0 resources applied successfully."
            return 0 # Return 0 for success
        else
            echo "❌ Error: Failed to apply Day0 resources. Script terminated."
            return 1 # Return non-zero to indicate failure
        fi
    fi
    
    Host=$(kubectl -n "$MARIADB_NAMESPACE" exec day0-pod -c day0-container -- bash -c 'mariadb -u test_user -p"'testTEST123456!'" -h '${MARIADB_NAME}-primary' -e "select @@hostname"')
    echo "Host: $Host"
    
    if [ -z "$Host" ]; then
        echo "Host empty."
        return 1
    fi

    echo ""
    echo "--- Test Select ---"
    # 1. 讀取資料
    select_cmd='"select * from test_db.test_table;"'
    kubectl -n "$MARIADB_NAMESPACE" exec day0-pod -c day0-container -- bash -c 'mariadb -u test_user -p"'testTEST123456!'" -h '${MARIADB_NAME}-primary' -e '"${select_cmd}"''
    if [ $? -eq 0 ]; then
        echo "Select data success."
    else
        echo "Select data fail"
        return 1
    fi

    echo -e "\n✅ Test 5.3 Success."
    return 0
}

# 測試 5.4 向 Slave讀取數據 * 確認 "能" 向 Slave讀取數據。
run_test_5_4() {
    echo -e "✨ 5.4. Checking Select from slave svc...\n"
    
    day0_pod_status=$(kubectl -n "${MARIADB_NAMESPACE}" get pod day0-pod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    echo "Day0 pod ready states: $day0_pod_status"
    
    if [ "$day0_pod_status" = false ]; then
        if kubectl -n "${MARIADB_NAMESPACE}" apply -f ./temp/day0-pod.yaml; then
            echo "✅ Day0 resources applied successfully."
            return 0 # Return 0 for success
        else
            echo "❌ Error: Failed to apply Day0 resources. Script terminated."
            return 1 # Return non-zero to indicate failure
        fi
    fi
    
    Host=$(kubectl -n "$MARIADB_NAMESPACE" exec day0-pod -c day0-container -- bash -c 'mariadb -u test_user -p"'testTEST123456!'" -h '${MARIADB_NAME}-secondary' -e "select @@hostname"' || true)
    echo "Host: $Host"
    
    if [ -z "$Host" ]; then
        echo "Host empty."
        return 1
    fi

    echo ""
    echo "--- Test Select ---"
    # 1. 讀取資料
    select_cmd='"select * from test_db.test_table;"'
    kubectl -n "$MARIADB_NAMESPACE" exec day0-pod -c day0-container -- bash -c 'mariadb -u test_user -p"'testTEST123456!'" -h '${MARIADB_NAME}-secondary' -e '"${select_cmd}"''
    if [ $? -eq 0 ]; then
        echo "Select data success."
    else
        echo "Select data fail"
        return 1
    fi

    echo -e "\n✅ Test 5.4 Success."
    return 0
}

run_test_6_1() {
    echo -e "✨ 6.1. Checking switchover on two slaves ready...\n"

    SLAVES_IO_SQL_READY_NUM=0
    pre_check_mariadb

    if [ $SLAVES_IO_SQL_READY_NUM -eq 2 ]; then
        echo "Two slave ready"
        echo "Primary pod: $PRIMARY_POD_NAME"

        kubectl -n "$MARIADB_NAMESPACE" delete pod "$PRIMARY_POD_NAME"
        if [ $? -eq 0 ]; then
            echo "Delete $PRIMARY_POD_NAME success."
        else
		        echo "Delete $PRIMARY_POD_NAME fail."
            return 1
        fi
    else
        echo "Not two slaves ready"
        return 1
    fi

    sleep 10

    check_mariadb_with_retries

    echo -e "\n✅ Test 6.1 Success."
    return 0
}

run_test_6_2() {
    echo -e "✨ 6.2. Checking switchover on one slaves ready...\n"

    SLAVES_IO_SQL_READY_NUM=0
    pre_check_mariadb

    echo "SLAVES_IO_SQL_READY_NUM: $SLAVES_IO_SQL_READY_NUM."
    if [ $SLAVES_IO_SQL_READY_NUM -eq 2 ]; then
        echo "Two slave ready"
        make_error_cmd='"
        STOP SLAVE '\''mariadb-operator'\'';
        FLUSH PRIVILEGES;
        START SLAVE '\''mariadb-operator'\'';
        "'
        kubectl -n "$MARIADB_NAMESPACE" exec day0-pod -c day0-container -- bash -c 'mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -h '${MARIADB_NAME}-secondary' -e '"${make_error_cmd}"''
        if [ $? -eq 0 ]; then
            echo "Make IO/SQL error success."
        else
            echo "Make IO/SQL error fail"
            return 1
        fi
    fi

    sleep 10

    local attempt=1
    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "--- Attempting to Check MariaDB (Attempt $attempt of $MAX_RETRIES) ---"
        echo

        if [ "$SLAVES_IO_SQL_READY_NUM" -eq 1 ]; then
		        echo "✅ SLAVES_IO_SQL_READY_NUM: $SLAVES_IO_SQL_READY_NUM."
            echo
            break
        else
            echo "❌ SLAVES_IO_SQL_READY_NUM: $SLAVES_IO_SQL_READY_NUM."
            if [ "$attempt" -lt "$MAX_RETRIES" ]; then
		            echo "Retrying after $RETRY_DELAY seconds..."
                sleep "$RETRY_DELAY"
                SLAVES_IO_SQL_READY_NUM=0
                pre_check_mariadb
            else
		            echo "❌ Maximum retry attempts ($MAX_RETRIES) reached. SLAVES_IO_SQL_READY_NUM: $SLAVES_IO_SQL_READY_NUM failed."
                echo
                return 1 # Failure after all retries
            fi
        fi
        attempt=$((attempt + 1))
    done

    if [ $SLAVES_IO_SQL_READY_NUM -eq 1 ]; then
        echo "One slave ready"
        echo "Primary pod: $PRIMARY_POD_NAME"

        kubectl -n "$MARIADB_NAMESPACE" delete pod "$PRIMARY_POD_NAME"
        if [ $? -eq 0 ]; then
            echo "Delete $PRIMARY_POD_NAME success."
        else
            echo "Delete $PRIMARY_POD_NAME fail."
            return 1
        fi
    else
        echo "Not one slaves ready"
        return 1
    fi
    
    sleep 10

    check_mariadb_with_retries

    echo -e "\n✅ Test 6.2 Success."
    return 0
}

run_test_6_3() {
    echo -e "✨ 6.3. Checking switchover on zore slaves ready...\n"

    SLAVES_IO_SQL_READY_NUM=0
    pre_check_mariadb

    echo "SLAVES_IO_SQL_READY_NUM: $SLAVES_IO_SQL_READY_NUM."
    if [ $SLAVES_IO_SQL_READY_NUM -eq 1 ]; then
        echo "One slave ready"
        make_error_cmd='"
        STOP SLAVE '\''mariadb-operator'\'';
        FLUSH PRIVILEGES;
        START SLAVE '\''mariadb-operator'\'';
        "'
        kubectl -n "$MARIADB_NAMESPACE" exec day0-pod -c day0-container -- bash -c 'mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -h '${MARIADB_NAME}-secondary' -e '"${make_error_cmd}"''
        if [ $? -eq 0 ]; then
            echo "Make IO/SQL error success."
        else
            echo "Make IO/SQL error fail"
            return 1
        fi
    fi
    
    sleep 10

    local attempt=1
    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "--- Attempting to Check MariaDB (Attempt $attempt of $MAX_RETRIES) ---"
        echo

        if [ "$SLAVES_IO_SQL_READY_NUM" -eq 0 ]; then
            echo "✅ SLAVES_IO_SQL_READY_NUM: $SLAVES_IO_SQL_READY_NUM."
            echo
            break
        else
		        echo "❌ SLAVES_IO_SQL_READY_NUM: $SLAVES_IO_SQL_READY_NUM."
            if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                echo "Retrying after $RETRY_DELAY seconds..."
                sleep "$RETRY_DELAY"
                SLAVES_IO_SQL_READY_NUM=0
                pre_check_mariadb
            else
                echo "❌ Maximum retry attempts ($MAX_RETRIES) reached. SLAVES_IO_SQL_READY_NUM: $SLAVES_IO_SQL_READY_NUM failed."
                echo
                return 1 # Failure after all retries
            fi
        fi
        attempt=$((attempt + 1))
    done

    echo "SLAVES_IO_SQL_READY_NUM: $SLAVES_IO_SQL_READY_NUM."
    if [ $SLAVES_IO_SQL_READY_NUM -eq 0 ]; then
        echo "zore slave ready"
        echo "Primary pod: $PRIMARY_POD_NAME"

        kubectl -n "$MARIADB_NAMESPACE" delete pod "$PRIMARY_POD_NAME"
        if [ $? -eq 0 ]; then
            echo "Delete $PRIMARY_POD_NAME success."
        else
            echo "Delete $PRIMARY_POD_NAME fail."
            return 1
        fi
    else
        echo "Not zore slaves ready"
        return 1
    fi

    sleep 10

    check_mariadb_with_retries

    echo -e "\n✅ Test 6.3 Success."
    return 0
}

# --- Helper function: Display usage instructions ---
usage() {
    echo "Usage: $0 [-t <test_item_ID,...>] [-h|--help]"
    echo ""
    echo "Description: This script is used to manage and test MariaDB Operator deployments."
    echo "      You can specify one or more test item IDs to execute specific test scenarios."
    echo ""
    echo "Options:"
    echo "  -t <test_item_ID,...>, --test <test_item_ID,...>"
    echo "      Specify the test items to execute, separated by commas, with no spaces."
    echo "      For example: -t 1.1,1.2 or --test 1.1,2.1"
    echo "      By default, if neither `-t` nor `--test` is specified, all defined test items will be executed."
    echo ""
    echo "Available Test Items:"
    echo "  0: Confirm Images"
    echo "  1.1: MariaDB Operator Deployment Test"
    echo "  1.2: Placeholder Test Case (e.g., Operator Upgrade Test)"
    echo "  2.1: Another Placeholder Test Case (e.g., MariaDB Backup/Restore Test)"
    echo ""
    echo "  -h, --help  Display this help message and exit."
    echo ""
    echo "Examples:"
    echo "  $0                  # Executes all available test items"
    echo "  $0 -t 1.1           # Executes only test item 1.1"
    echo "  $0 --test 0,1.1,1.2   # Executes test items 0, 1.1 and 1.2 in sequence"
    echo "  $0 -h               # Display help"
    echo "  $0 --help           # Display help"
    exit 1
}

# --- Main Workflow Controller ---

# This function controls which test cases are executed based on the input array.
run_workflow() {
    local tests_to_run=("$@") # Get test case IDs from function parameters
    
    echo -e "🚀 MariaDB Operator Test Workflow Starting...\n"
    echo "Test items to be executed: ${tests_to_run[@]}"
    echo ""

    local overall_success=true
    local failed_tests=()
    
    # Execute selected test cases sequentially
    for test_id in "${tests_to_run[@]}"; do
        echo "=== Starting Test Item $test_id ==="
        echo

        local test_passed=true # Flag to track if the current test_id passed
        
        case "$test_id" in
            "0")
                run_test_0 || test_passed=false
                ;;
            "1.1")
                run_test_1_1 || test_passed=false
                ;;
            "1.2")
                run_test_1_2 || test_passed=false
                ;;
            "2.1")
                run_test_2_1 || test_passed=false
                ;;
            "2.2")
                run_test_2_2 || test_passed=false
                ;;
            "2.3")
                run_test_2_3 || test_passed=false
                ;;
            "2.4")
                run_test_2_4 || test_passed=false
                ;;
            "3.1")
                run_test_3_1 || test_passed=false
                ;;
            "3.2")
                run_test_3_2 || test_passed=false
                ;;
            "3.3")
                run_test_3_3 || test_passed=false
                ;;
            "4.1")
                run_test_4_1 || test_passed=false
                ;;
            "5.1")
                run_test_5_1 || test_passed=false
                ;;
            "5.2")
                run_test_5_2 || test_passed=false
                ;;
            "5.3")
                run_test_5_3 || test_passed=false
                ;;
            "5.4")
                run_test_5_4 || test_passed=false
                ;;
            "6.1")
                run_test_6_1 || test_passed=false
                ;;
            "6.2")
                run_test_6_2 || test_passed=false
                ;;
            "6.3")
                run_test_6_3 || test_passed=false
                ;;
            *)
		             echo "❌ Error: Unknown test item ID: $test_id. Skipping and marking as overall failure."
                test_passed=false
                ;;
        esac
        
        # If the current test_id failed (either by returning non-zero or being an unknown ID)
        if ! "$test_passed"; then
            overall_success=false
            failed_tests+=("$test_id") # Add the failed test ID to the array
        fi

        echo -e "\n=== Test Item $test_id Completed ===\n"
    done
    
    if "$overall_success"; then
        echo -e "🎉 All selected test items:[${tests_to_run[@]}] completed successfully."
        exit 0
    else
		    echo "================"
        # 這裡會正確顯示失敗的測試項目
        if [ ${#failed_tests[@]} -gt 0 ]; then
            echo -e "Failed test items: [${failed_tests[@]}]"
        else
		        echo "An unexpected error occurred, but no specific failed test IDs were recorded."
        fi
        echo "================"
        exit 1
    fi
}

# --- Script Entry Point ---

# Default test items to run (if not specified via command line)
DEFAULT_TESTS=("1.1" "1.2" "2.1" "2.2" "2.3" "2.4" "3.1" "3.2" "3.3" "4.1" "5.1" "5.2" "5.3" "5.4" "6.1" "6.2" "6.3") # Added "0" to default tests

TESTS_TO_RUN=() # Initialize as empty

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--test)
            if [[ -z "$2" || "$2" == -* ]]; then
		            echo "Error: -t/--test option requires a value."
                usage
            fi
            # Convert comma-separated string to array elements
            IFS=',' read -r -a TESTS_TO_RUN <<< "$2"
            shift 2 # Process option and value, move two parameters
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option: $1"
            usage
            ;;
    esac
done

# If no test items are specified (i.e., TESTS_TO_RUN is still empty), run default tests
if [[ ${#TESTS_TO_RUN[@]} -eq 0 ]]; then
    TESTS_TO_RUN=("${DEFAULT_TESTS[@]}")
fi

# Execute workflow
run_workflow "${TESTS_TO_RUN[@]}"