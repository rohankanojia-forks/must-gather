#!/usr/bin/env bash

set -euo pipefail

LOGS_DIR="${LOGS_DIR:-must-gather}"
BASE_DIR="$(realpath "$LOGS_DIR")"

echo "Using LOGS_DIR: $LOGS_DIR"
echo "Resolved BASE_DIR: $BASE_DIR"
echo

# -------------------------------
# Helpers
# -------------------------------

check_api() {
    local resource="$1"

    if oc get "$resource" &>/dev/null; then
        echo "✓ Can fetch: $resource"
        return 0
    else
        echo "ℹ $resource not available (expected on some clusters)"
        return 1
    fi
}

check_dir() {
    local path="$1"
    local message="$2"

    if [ -d "$path" ]; then
        echo "✓ $message"
    else
        echo "✗ Missing: $message"
        exit 1
    fi
}

check_file() {
    local path="$1"
    local message="$2"

    if [ -f "$path" ]; then
        echo "✓ $message"
    else
        echo "✗ Missing: $message"
        exit 1
    fi
}

check_dir_or_warn() {
    local path="$1"
    local message="$2"

    if [ -d "$path" ]; then
        echo "✓ $message"
    else
        echo "⚠ Warning: $message (may be empty on this cluster)"
    fi
    return 0
}

check_file_or_warn() {
    local path="$1"
    local message="$2"

    if [ -f "$path" ]; then
        echo "✓ $message"
    else
        echo "⚠ Warning: $message (may not exist on this cluster)"
    fi
    return 0
}

count_files_in_dir() {
    local path="$1"
    if [ -d "$path" ]; then
        find "$path" -type f | wc -l
    else
        echo "0"
    fi
}

# -------------------------------
# Must-gather sanity
# -------------------------------

if [ -d "$BASE_DIR" ]; then
    echo "✓ Must-gather is usable"
else
    echo "✗ Must-gather directory not found"
    exit 1
fi

echo
echo "Checking API accessibility via oc..."

check_api "checlusters.org.eclipse.che"
check_api "devworkspaceoperatorconfigs.controller.devfile.io"
check_api "devworkspaceroutings.controller.devfile.io"
check_api "devworkspaces.workspace.devfile.io"
check_api "devworkspacetemplates.workspace.devfile.io"

# OLM resources
check_api "subscriptions.operators.coreos.com"
check_api "operators.operators.coreos.com"
check_api "operatorgroups.operators.coreos.com"
check_api "installplans.operators.coreos.com"
check_api "clusterserviceversions.operators.coreos.com"
check_api "packagemanifests.packages.operators.coreos.com"

echo
echo "Validating collected structure..."

# -------------------------------
# Cluster-scoped resources
# -------------------------------

check_dir "$BASE_DIR/cluster-scoped-resources/admissionregistration.k8s.io/mutatingwebhookconfigurations" "Mutating webhooks collected"
check_dir "$BASE_DIR/cluster-scoped-resources/admissionregistration.k8s.io/validatingwebhookconfigurations" "Validating webhooks collected"

check_dir "$BASE_DIR/cluster-scoped-resources/storage.k8s.io/storageclasses" "StorageClasses collected"
check_dir "$BASE_DIR/cluster-scoped-resources/core/persistentvolumes" "PersistentVolumes collected"

check_dir "$BASE_DIR/cluster-scoped-resources/core/nodes" "Nodes collected"
check_dir "$BASE_DIR/cluster-scoped-resources/config.openshift.io/proxies" "ClusterProxy collected"

check_dir "$BASE_DIR/cluster-scoped-resources/security.openshift.io/securitycontextconstraints" "SecurityContextConstraints collected"
check_dir "$BASE_DIR/cluster-scoped-resources/rbac.authorization.k8s.io/clusterroles" "ClusterRoles collected"
check_dir "$BASE_DIR/cluster-scoped-resources/rbac.authorization.k8s.io/clusterrolebindings" "ClusterRoleBindings collected"

# -------------------------------
# Cluster-resources (FIXED)
# -------------------------------

check_file "$BASE_DIR/cluster-resources/oc-version.txt" "oc version output collected"
check_file "$BASE_DIR/cluster-resources/cluster-status.txt" "Cluster status collected"
check_file "$BASE_DIR/cluster-resources/pods-all-namespaces.yaml" "Cluster-wide pods listing collected"

check_dir "$BASE_DIR/cluster-resources/node-descriptions" "Node descriptions collected"

# -------------------------------
# Namespaces & events
# -------------------------------

check_dir "$BASE_DIR/namespaces" "Namespaces collected"

# Events exist inside namespaces
check_dir "$BASE_DIR/namespaces" "Events collected"

# -------------------------------
# OLM PackageManifests
# -------------------------------

check_dir "$BASE_DIR/cluster-scoped-resources/packages.operators.coreos.com" "PackageManifests collected"
check_file_or_warn "$BASE_DIR/cluster-scoped-resources/packages.operators.coreos.com/packagemanifests.yaml" "PackageManifests YAML collected"

# -------------------------------
# ImageContentSourcePolicy
# -------------------------------

check_dir_or_warn "$BASE_DIR/cluster-scoped-resources/operator.openshift.io/imagecontentsourcepolicies" "ImageContentSourcePolicy collected"

echo
echo "========================================"
echo "Validating Operator Namespaces..."
echo "========================================"

# Find operator namespace directories
if [ -d "$BASE_DIR/operator-namespaces" ]; then
    echo "✓ Operator namespaces directory exists"

    # Get list of operator namespaces
    readarray -t OP_NS_DIRS < <(find "$BASE_DIR/operator-namespaces" -maxdepth 1 -type d ! -path "$BASE_DIR/operator-namespaces" -printf "%f\n" 2>/dev/null || true)

    if [ "${#OP_NS_DIRS[@]}" -gt 0 ]; then
        echo "✓ Found ${#OP_NS_DIRS[@]} operator namespace(s)"

        for op_ns in "${OP_NS_DIRS[@]}"; do
            echo ""
            echo "Checking operator namespace: $op_ns"

            # Check namespace description
            check_file_or_warn "$BASE_DIR/operator-namespaces/${op_ns}-description.txt" "  Namespace description for $op_ns"

            # Check core resources directory
            if [ -d "$BASE_DIR/operator-namespaces/${op_ns}/core-resources" ]; then
                echo "  ✓ Core resources directory exists for $op_ns"

                # Check individual resource files
                check_file_or_warn "$BASE_DIR/operator-namespaces/${op_ns}/core-resources/networking.yaml" "    Services/Routes/Endpoints for $op_ns"
                check_file_or_warn "$BASE_DIR/operator-namespaces/${op_ns}/core-resources/configmaps.yaml" "    ConfigMaps for $op_ns"
                check_file_or_warn "$BASE_DIR/operator-namespaces/${op_ns}/core-resources/pvcs.yaml" "    PVCs for $op_ns"
                check_file_or_warn "$BASE_DIR/operator-namespaces/${op_ns}/core-resources/networkpolicies.yaml" "    NetworkPolicies for $op_ns"
                check_file_or_warn "$BASE_DIR/operator-namespaces/${op_ns}/core-resources/serviceaccounts.yaml" "    ServiceAccounts for $op_ns"
                check_file_or_warn "$BASE_DIR/operator-namespaces/${op_ns}/core-resources/resourcequotas.yaml" "    ResourceQuotas for $op_ns"
                check_file_or_warn "$BASE_DIR/operator-namespaces/${op_ns}/core-resources/limitranges.yaml" "    LimitRanges for $op_ns"
                check_file_or_warn "$BASE_DIR/operator-namespaces/${op_ns}/core-resources/secrets-metadata.json" "    Secrets metadata for $op_ns"
            else
                echo "  ⚠ Warning: Core resources directory missing for $op_ns"
            fi

            # Check pod descriptions directory
            if [ -d "$BASE_DIR/operator-namespaces/${op_ns}/pod-descriptions" ]; then
                pod_desc_count=$(count_files_in_dir "$BASE_DIR/operator-namespaces/${op_ns}/pod-descriptions")
                if [ "$pod_desc_count" -gt 0 ]; then
                    echo "  ✓ Pod descriptions/logs collected for $op_ns ($pod_desc_count files)"

                    # Verify at least one pod description exists
                    if ls "$BASE_DIR/operator-namespaces/${op_ns}/pod-descriptions/"*.txt &>/dev/null; then
                        echo "    ✓ Pod description files found"
                    fi

                    # Verify at least one pod log exists
                    if ls "$BASE_DIR/operator-namespaces/${op_ns}/pod-descriptions/"*.log &>/dev/null; then
                        echo "    ✓ Pod log files found"
                    fi
                else
                    echo "  ⚠ Warning: No pod descriptions/logs found for $op_ns (may have no pods)"
                fi
            else
                echo "  ⚠ Warning: Pod descriptions directory missing for $op_ns"
            fi

            # Check for namespace resources collected by oc adm inspect
            if [ -d "$BASE_DIR/namespaces/${op_ns}" ]; then
                echo "  ✓ Namespace resources collected by oc adm inspect for $op_ns"

                # Check for pods, deployments, etc.
                check_dir_or_warn "$BASE_DIR/namespaces/${op_ns}/core/pods" "    Pods collected for $op_ns"
                check_dir_or_warn "$BASE_DIR/namespaces/${op_ns}/apps/deployments" "    Deployments collected for $op_ns"
                check_dir_or_warn "$BASE_DIR/namespaces/${op_ns}/apps/replicasets" "    ReplicaSets collected for $op_ns"
                check_dir_or_warn "$BASE_DIR/namespaces/${op_ns}/apps/statefulsets" "    StatefulSets collected for $op_ns"
                check_dir_or_warn "$BASE_DIR/namespaces/${op_ns}/apps/daemonsets" "    DaemonSets collected for $op_ns"
            else
                echo "  ⚠ Warning: oc adm inspect namespace data missing for $op_ns"
            fi
        done
    else
        echo "⚠ Warning: No operator namespaces found (Dev Spaces may not be installed)"
    fi
else
    echo "✗ Missing: operator-namespaces directory"
    exit 1
fi

echo
echo "========================================"
echo "Validating Workspace Namespaces..."
echo "========================================"

# Find workspace namespace directories
if [ -d "$BASE_DIR/workspace-namespaces" ]; then
    echo "✓ Workspace namespaces directory exists"

    # Count workspace namespace files (description files indicate collected namespaces)
    readarray -t WS_DESC_FILES < <(find "$BASE_DIR/workspace-namespaces" -maxdepth 1 -name "*-description.txt" 2>/dev/null || true)

    if [ "${#WS_DESC_FILES[@]}" -gt 0 ]; then
        echo "✓ Found ${#WS_DESC_FILES[@]} workspace namespace(s)"

        for desc_file in "${WS_DESC_FILES[@]}"; do
            # Extract namespace name from description file
            ws_ns=$(basename "$desc_file" "-description.txt")
            echo ""
            echo "Checking workspace namespace: $ws_ns"

            # Check namespace description
            check_file "$desc_file" "  Namespace description for $ws_ns"

            # Check all resources YAML
            check_file_or_warn "$BASE_DIR/workspace-namespaces/${ws_ns}-all-resources.yaml" "  'oc get all' output for $ws_ns"

            # Check core resources directory
            if [ -d "$BASE_DIR/workspace-namespaces/${ws_ns}/core-resources" ]; then
                echo "  ✓ Core resources directory exists for $ws_ns"

                # Check individual resource files
                check_file_or_warn "$BASE_DIR/workspace-namespaces/${ws_ns}/core-resources/networking.yaml" "    Services/Routes/Endpoints for $ws_ns"
                check_file_or_warn "$BASE_DIR/workspace-namespaces/${ws_ns}/core-resources/configmaps.yaml" "    ConfigMaps for $ws_ns"
                check_file_or_warn "$BASE_DIR/workspace-namespaces/${ws_ns}/core-resources/pvcs.yaml" "    PVCs for $ws_ns"
                check_file_or_warn "$BASE_DIR/workspace-namespaces/${ws_ns}/core-resources/networkpolicies.yaml" "    NetworkPolicies for $ws_ns"
                check_file_or_warn "$BASE_DIR/workspace-namespaces/${ws_ns}/core-resources/serviceaccounts.yaml" "    ServiceAccounts for $ws_ns"
                check_file_or_warn "$BASE_DIR/workspace-namespaces/${ws_ns}/core-resources/resourcequotas.yaml" "    ResourceQuotas for $ws_ns"
                check_file_or_warn "$BASE_DIR/workspace-namespaces/${ws_ns}/core-resources/limitranges.yaml" "    LimitRanges for $ws_ns"
                check_file_or_warn "$BASE_DIR/workspace-namespaces/${ws_ns}/core-resources/secrets-metadata.json" "    Secrets metadata for $ws_ns"
            else
                echo "  ⚠ Warning: Core resources directory missing for $ws_ns"
            fi

            # Check pod descriptions directory
            if [ -d "$BASE_DIR/workspace-namespaces/${ws_ns}/pod-descriptions" ]; then
                pod_desc_count=$(count_files_in_dir "$BASE_DIR/workspace-namespaces/${ws_ns}/pod-descriptions")
                if [ "$pod_desc_count" -gt 0 ]; then
                    echo "  ✓ Pod descriptions/logs collected for $ws_ns ($pod_desc_count files)"

                    # Verify at least one pod description exists
                    if ls "$BASE_DIR/workspace-namespaces/${ws_ns}/pod-descriptions/"*.txt &>/dev/null; then
                        echo "    ✓ Pod description files found"
                    fi

                    # Verify at least one pod log exists
                    if ls "$BASE_DIR/workspace-namespaces/${ws_ns}/pod-descriptions/"*.log &>/dev/null; then
                        echo "    ✓ Pod log files found"
                    fi
                else
                    echo "  ⚠ Warning: No pod descriptions/logs found for $ws_ns (may have no pods)"
                fi
            else
                echo "  ⚠ Warning: Pod descriptions directory missing for $ws_ns"
            fi

            # Check for namespace resources collected by oc adm inspect
            if [ -d "$BASE_DIR/namespaces/${ws_ns}" ]; then
                echo "  ✓ Namespace resources collected by oc adm inspect for $ws_ns"

                # Check for pods, deployments, jobs, etc.
                check_dir_or_warn "$BASE_DIR/namespaces/${ws_ns}/core/pods" "    Pods collected for $ws_ns"
                check_dir_or_warn "$BASE_DIR/namespaces/${ws_ns}/apps/deployments" "    Deployments collected for $ws_ns"
                check_dir_or_warn "$BASE_DIR/namespaces/${ws_ns}/apps/replicasets" "    ReplicaSets collected for $ws_ns"
                check_dir_or_warn "$BASE_DIR/namespaces/${ws_ns}/batch/jobs" "    Jobs collected for $ws_ns"
            else
                echo "  ⚠ Warning: oc adm inspect namespace data missing for $ws_ns"
            fi
        done
    else
        echo "⚠ Warning: No workspace namespaces found (may not have active workspaces)"
    fi
else
    echo "✗ Missing: workspace-namespaces directory"
    exit 1
fi

echo
echo "========================================"
echo "Validating OLM Resources..."
echo "========================================"

# Check for OLM resources in namespaces
olm_found=false
if [ -d "$BASE_DIR/namespaces" ]; then
    for ns_dir in "$BASE_DIR/namespaces"/*; do
        if [ -d "$ns_dir" ]; then
            ns_name=$(basename "$ns_dir")

            # Check for CSVs
            if [ -d "$ns_dir/operators.coreos.com/clusterserviceversions" ]; then
                csv_count=$(count_files_in_dir "$ns_dir/operators.coreos.com/clusterserviceversions")
                if [ "$csv_count" -gt 0 ]; then
                    echo "✓ ClusterServiceVersions collected for namespace: $ns_name ($csv_count)"
                    olm_found=true
                fi
            fi

            # Check for Subscriptions
            if [ -d "$ns_dir/operators.coreos.com/subscriptions" ]; then
                sub_count=$(count_files_in_dir "$ns_dir/operators.coreos.com/subscriptions")
                if [ "$sub_count" -gt 0 ]; then
                    echo "✓ Subscriptions collected for namespace: $ns_name ($sub_count)"
                    olm_found=true
                fi
            fi

            # Check for InstallPlans
            if [ -d "$ns_dir/operators.coreos.com/installplans" ]; then
                ip_count=$(count_files_in_dir "$ns_dir/operators.coreos.com/installplans")
                if [ "$ip_count" -gt 0 ]; then
                    echo "✓ InstallPlans collected for namespace: $ns_name ($ip_count)"
                    olm_found=true
                fi
            fi
        fi
    done
fi

if [ "$olm_found" = false ]; then
    echo "⚠ Warning: No OLM resources (CSVs/Subscriptions/InstallPlans) found in any namespace"
fi

echo
echo "========================================"
echo "Validating Custom Resources..."
echo "========================================"

# Check for DevSpaces custom resources across namespaces
cr_found=false

# CheCluster instances
if [ -d "$BASE_DIR/namespaces" ]; then
    for ns_dir in "$BASE_DIR/namespaces"/*; do
        if [ -d "$ns_dir/org.eclipse.che/checlusters" ]; then
            che_count=$(count_files_in_dir "$ns_dir/org.eclipse.che/checlusters")
            if [ "$che_count" -gt 0 ]; then
                echo "✓ CheCluster instances collected: $(basename "$ns_dir") ($che_count)"
                cr_found=true
            fi
        fi

        # DevWorkspace instances
        if [ -d "$ns_dir/workspace.devfile.io/devworkspaces" ]; then
            dw_count=$(count_files_in_dir "$ns_dir/workspace.devfile.io/devworkspaces")
            if [ "$dw_count" -gt 0 ]; then
                echo "✓ DevWorkspace instances collected: $(basename "$ns_dir") ($dw_count)"
                cr_found=true
            fi
        fi

        # DevWorkspaceTemplate instances
        if [ -d "$ns_dir/workspace.devfile.io/devworkspacetemplates" ]; then
            dwt_count=$(count_files_in_dir "$ns_dir/workspace.devfile.io/devworkspacetemplates")
            if [ "$dwt_count" -gt 0 ]; then
                echo "✓ DevWorkspaceTemplate instances collected: $(basename "$ns_dir") ($dwt_count)"
                cr_found=true
            fi
        fi

        # DevWorkspaceRouting instances
        if [ -d "$ns_dir/controller.devfile.io/devworkspaceroutings" ]; then
            dwr_count=$(count_files_in_dir "$ns_dir/controller.devfile.io/devworkspaceroutings")
            if [ "$dwr_count" -gt 0 ]; then
                echo "✓ DevWorkspaceRouting instances collected: $(basename "$ns_dir") ($dwr_count)"
                cr_found=true
            fi
        fi

        # DevWorkspaceOperatorConfig instances
        if [ -d "$ns_dir/controller.devfile.io/devworkspaceoperatorconfigs" ]; then
            dwoc_count=$(count_files_in_dir "$ns_dir/controller.devfile.io/devworkspaceoperatorconfigs")
            if [ "$dwoc_count" -gt 0 ]; then
                echo "✓ DevWorkspaceOperatorConfig instances collected: $(basename "$ns_dir") ($dwoc_count)"
                cr_found=true
            fi
        fi
    done
fi

if [ "$cr_found" = false ]; then
    echo "⚠ Warning: No Dev Spaces custom resources found (Dev Spaces may not be installed)"
fi

echo
echo "========================================"
echo "Validating Events..."
echo "========================================"

# Check for events in namespaces
events_found=false
if [ -d "$BASE_DIR/namespaces" ]; then
    for ns_dir in "$BASE_DIR/namespaces"/*; do
        if [ -d "$ns_dir/core/events" ]; then
            event_count=$(count_files_in_dir "$ns_dir/core/events")
            if [ "$event_count" -gt 0 ]; then
                ns_name=$(basename "$ns_dir")
                echo "✓ Events collected for namespace: $ns_name ($event_count events)"
                events_found=true
            fi
        fi
    done
fi

if [ "$events_found" = false ]; then
    echo "⚠ Warning: No events found in any namespace"
fi

echo
echo "========================================"
echo "Summary"
echo "========================================"
echo "✓ All required checks passed!"
echo "✓ Must-gather validation complete"
