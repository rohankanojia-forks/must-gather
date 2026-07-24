#!/usr/bin/env bash

set -Eeuo pipefail
trap 'echo "Error on line $LINENO: $BASH_COMMAND" >&2' ERR

LOGS_DIR="${LOGS_DIR:-must-gather}"
mkdir -p "$LOGS_DIR"

echo "[INFO] Starting DevSpaces must-gather..."

############################################
# 1. Collect CRDs (DevSpaces + OLM)
############################################
echo "[INFO] Collecting CRDs..."

readarray -t CRDS < <(
  oc get crd -o name | grep -E 'devworkspace|devfile|eclipse\.che'
)

oc adm inspect \
  "${CRDS[@]}" \
  customresourcedefinition/subscriptions.operators.coreos.com \
  customresourcedefinition/operators.operators.coreos.com \
  customresourcedefinition/operatorgroups.operators.coreos.com \
  customresourcedefinition/installplans.operators.coreos.com \
  customresourcedefinition/clusterserviceversions.operators.coreos.com \
  customresourcedefinition/catalogsources.operators.coreos.com \
  --dest-dir="$LOGS_DIR" || true

############################################
# 2. Collect DevSpaces API resources
############################################
echo "[INFO] Collecting DevSpaces resources..."

readarray -t API_RESOURCES < <(
  oc api-resources -o name | grep -E 'devworkspace|devfile|eclipse\.che'
)

# Collect resources sequentially (one at a time) for better resilience.
# Trade-off: Sequential is slower but prevents one failing resource from blocking the entire collection.
# Alternative (faster but less resilient): oc adm inspect $(IFS=,; echo "${API_RESOURCES[*]}") -A --dest-dir="$LOGS_DIR"
for resource in "${API_RESOURCES[@]}"; do
  echo "[INFO] Collecting resource: $resource"

  # Collect all instances across all namespaces in a single inspect call
  oc adm inspect "$resource" -A --dest-dir="$LOGS_DIR" 2>/dev/null || true
done

############################################
# 3. Detect operator namespaces dynamically
############################################
echo "[INFO] Detecting operator namespaces..."

# Find namespaces via Subscriptions (most reliable)
readarray -t OPERATOR_NAMESPACES < <(
  oc get subscriptions.operators.coreos.com -A -o json 2>/dev/null | jq -r '
    .items[]
    | select(.metadata.name | test("devspaces|devworkspace|web-terminal|eclipse.*che"; "i"))
    | .metadata.namespace' | sort -u
)

# Also check for CheCluster CRs (defines where DevSpaces is installed)
readarray -t CHE_NAMESPACES < <(
  oc get checlusters.org.eclipse.che -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u
)

# Merge both lists
ALL_NAMESPACES=("${OPERATOR_NAMESPACES[@]}" "${CHE_NAMESPACES[@]}")
readarray -t UNIQUE_NAMESPACES < <(printf '%s\n' "${ALL_NAMESPACES[@]}" | sort -u)

for ns in "${UNIQUE_NAMESPACES[@]}"; do
  if [ -n "$ns" ]; then
    echo "[INFO] Inspecting operator namespace: $ns"
    oc adm inspect "ns/$ns" --dest-dir="$LOGS_DIR" || true

    # Collect operator namespace description and pod descriptions
    mkdir -p "$LOGS_DIR/operator-namespaces/${ns}/pod-descriptions"
    oc describe project "$ns" > "$LOGS_DIR/operator-namespaces/${ns}-description.txt" 2>/dev/null || true

    # Collect core resources explicitly
    mkdir -p "$LOGS_DIR/operator-namespaces/${ns}/core-resources"

    # Services, Routes, Endpoints
    oc get svc,route,endpoints -n "$ns" -o yaml \
      > "$LOGS_DIR/operator-namespaces/${ns}/core-resources/networking.yaml" 2>/dev/null || true

    # ConfigMaps
    oc get configmaps -n "$ns" -o yaml \
      > "$LOGS_DIR/operator-namespaces/${ns}/core-resources/configmaps.yaml" 2>/dev/null || true

    # Events are collected by 'oc adm inspect' above - manual collection removed to avoid v1.List type conflicts

    # PVCs
    oc get pvc -n "$ns" -o yaml \
      > "$LOGS_DIR/operator-namespaces/${ns}/core-resources/pvcs.yaml" 2>/dev/null || true

    # NetworkPolicies
    oc get networkpolicies -n "$ns" -o yaml \
      > "$LOGS_DIR/operator-namespaces/${ns}/core-resources/networkpolicies.yaml" 2>/dev/null || true

    # ServiceAccounts
    oc get serviceaccounts -n "$ns" -o yaml \
      > "$LOGS_DIR/operator-namespaces/${ns}/core-resources/serviceaccounts.yaml" 2>/dev/null || true

    # ResourceQuotas
    oc get resourcequotas -n "$ns" -o yaml \
      > "$LOGS_DIR/operator-namespaces/${ns}/core-resources/resourcequotas.yaml" 2>/dev/null || true

    # LimitRanges
    oc get limitranges -n "$ns" -o yaml \
      > "$LOGS_DIR/operator-namespaces/${ns}/core-resources/limitranges.yaml" 2>/dev/null || true

    # Secrets (metadata only — strip data)
    oc get secrets -n "$ns" -o json 2>/dev/null | jq 'del(.items[].data)' \
      > "$LOGS_DIR/operator-namespaces/${ns}/core-resources/secrets-metadata.json" || true

    # Collect pod descriptions for operator pods
    readarray -t OPERATOR_PODS < <(oc get pods -n "$ns" -o name 2>/dev/null || true)
    if [ "${#OPERATOR_PODS[@]}" -gt 0 ]; then
      echo "[INFO]   Collecting logs for ${#OPERATOR_PODS[@]} pod(s) in operator namespace: $ns"
    fi
    for pod in "${OPERATOR_PODS[@]}"; do
      pod_name="${pod#*/}"  # Remove 'pod/' prefix
      if [ -n "$pod_name" ]; then
        oc describe pod "$pod_name" -n "$ns" > "$LOGS_DIR/operator-namespaces/${ns}/pod-descriptions/${pod_name}.txt" 2>/dev/null || true

        # Current logs (all containers including sidecars)
        oc logs "$pod_name" -n "$ns" --all-containers \
          > "$LOGS_DIR/operator-namespaces/${ns}/pod-descriptions/${pod_name}.log" 2>/dev/null || true

        # Previous logs (all containers) - critical for crash loop debugging
        oc logs "$pod_name" -n "$ns" --all-containers --previous \
          > "$LOGS_DIR/operator-namespaces/${ns}/pod-descriptions/${pod_name}-previous.log" 2>/dev/null || true
      fi
    done
  fi
done

############################################
# 4. Collect OLM resources per namespace
############################################
echo "[INFO] Collecting OLM resources..."

# Find namespaces with DevSpaces/DevWorkspace/Web Terminal related subscriptions
readarray -t OLM_NAMESPACES < <(
  oc get subscriptions -A -o json | jq -r '
    .items[]
    | select(.metadata.name | test("devspaces|devworkspace|web-terminal|eclipse.*che"; "i"))
    | .metadata.namespace' | sort -u
)

for ns in "${OLM_NAMESPACES[@]}"; do
  if [ -n "$ns" ]; then
    # Collect ALL CSVs, Subscriptions, and InstallPlans in the namespace
    # (InstallPlans have generated names so we can't filter by pattern)
    readarray -t OLM_RES < <(
      oc get clusterserviceversion,subscription,installplan -n "$ns" -o name --ignore-not-found 2>/dev/null
    )
    if [ "${#OLM_RES[@]}" -gt 0 ]; then
      oc adm inspect "${OLM_RES[@]}" -n "$ns" --dest-dir="$LOGS_DIR" || true
    fi
  fi
done

# Collect all PackageManifests for full catalog visibility
echo "[INFO] Collecting PackageManifests..."
mkdir -p "$LOGS_DIR/cluster-scoped-resources/packages.operators.coreos.com"
oc get packagemanifests.packages.operators.coreos.com -o yaml \
  > "$LOGS_DIR/cluster-scoped-resources/packages.operators.coreos.com/packagemanifests.yaml" 2>/dev/null || true

############################################
# 5. Workspace namespaces
############################################
echo "[INFO] Collecting workspace namespaces..."

readarray -t WS_NAMESPACES < <(
  oc get ns -l 'app.kubernetes.io/component=workspaces-namespace' -o name
)

if [ "${#WS_NAMESPACES[@]}" -gt 0 ]; then
  oc adm inspect "${WS_NAMESPACES[@]}" --dest-dir="$LOGS_DIR" || true

  # Collect workspace namespace descriptions and pod descriptions
  mkdir -p "$LOGS_DIR/workspace-namespaces"
  for ws_ns in "${WS_NAMESPACES[@]}"; do
    ns_name="${ws_ns#*/}"  # Remove 'namespace/' prefix
    if [ -n "$ns_name" ]; then
      echo "[INFO] Collecting descriptions for workspace namespace: $ns_name"

      # Collect workspace description
      oc describe project "$ns_name" > "$LOGS_DIR/workspace-namespaces/${ns_name}-description.txt" 2>/dev/null || true

      # Collect all resources (explicit requirement for support)
      oc get all -n "$ns_name" -o yaml \
        > "$LOGS_DIR/workspace-namespaces/${ns_name}-all-resources.yaml" 2>/dev/null || true

      # Collect core resources explicitly
      mkdir -p "$LOGS_DIR/workspace-namespaces/${ns_name}/core-resources"

      # Services, Routes, Endpoints
      oc get svc,route,endpoints -n "$ns_name" -o yaml \
        > "$LOGS_DIR/workspace-namespaces/${ns_name}/core-resources/networking.yaml" 2>/dev/null || true

      # ConfigMaps
      oc get configmaps -n "$ns_name" -o yaml \
        > "$LOGS_DIR/workspace-namespaces/${ns_name}/core-resources/configmaps.yaml" 2>/dev/null || true

      # Events are collected by 'oc adm inspect' above - manual collection removed to avoid v1.List type conflicts

      # PVCs
      oc get pvc -n "$ns_name" -o yaml \
        > "$LOGS_DIR/workspace-namespaces/${ns_name}/core-resources/pvcs.yaml" 2>/dev/null || true

      # NetworkPolicies
      oc get networkpolicies -n "$ns_name" -o yaml \
        > "$LOGS_DIR/workspace-namespaces/${ns_name}/core-resources/networkpolicies.yaml" 2>/dev/null || true

      # ServiceAccounts
      oc get serviceaccounts -n "$ns_name" -o yaml \
        > "$LOGS_DIR/workspace-namespaces/${ns_name}/core-resources/serviceaccounts.yaml" 2>/dev/null || true

      # ResourceQuotas
      oc get resourcequotas -n "$ns_name" -o yaml \
        > "$LOGS_DIR/workspace-namespaces/${ns_name}/core-resources/resourcequotas.yaml" 2>/dev/null || true

      # LimitRanges
      oc get limitranges -n "$ns_name" -o yaml \
        > "$LOGS_DIR/workspace-namespaces/${ns_name}/core-resources/limitranges.yaml" 2>/dev/null || true

      # Secrets (metadata only — strip data)
      oc get secrets -n "$ns_name" -o json 2>/dev/null | jq 'del(.items[].data)' \
        > "$LOGS_DIR/workspace-namespaces/${ns_name}/core-resources/secrets-metadata.json" || true

      # Collect pod descriptions
      mkdir -p "$LOGS_DIR/workspace-namespaces/${ns_name}/pod-descriptions"
      readarray -t PODS < <(oc get pods -n "$ns_name" -o name 2>/dev/null || true)
      if [ "${#PODS[@]}" -gt 0 ]; then
        echo "[INFO]   Collecting logs for ${#PODS[@]} pod(s) in workspace namespace: $ns_name"
      fi
      for pod in "${PODS[@]}"; do
        pod_name="${pod#*/}"  # Remove 'pod/' prefix
        if [ -n "$pod_name" ]; then
          oc describe pod "$pod_name" -n "$ns_name" > "$LOGS_DIR/workspace-namespaces/${ns_name}/pod-descriptions/${pod_name}.txt" 2>/dev/null || true

          # Current logs (all containers including sidecars)
          oc logs "$pod_name" -n "$ns_name" --all-containers \
            > "$LOGS_DIR/workspace-namespaces/${ns_name}/pod-descriptions/${pod_name}.log" 2>/dev/null || true

          # Previous logs (all containers) - critical for crash loop debugging
          oc logs "$pod_name" -n "$ns_name" --all-containers --previous \
            > "$LOGS_DIR/workspace-namespaces/${ns_name}/pod-descriptions/${pod_name}-previous.log" 2>/dev/null || true
        fi
      done
    fi
  done
fi

############################################
# 6. Admission Webhooks
############################################
echo "[INFO] Collecting webhook configurations..."

# Collect DevWorkspace-related webhooks using oc adm inspect
readarray -t MUTATING_WEBHOOKS < <(
  oc get mutatingwebhookconfigurations -o name | grep -E 'devfile\.io' || true
)
readarray -t VALIDATING_WEBHOOKS < <(
  oc get validatingwebhookconfigurations -o name | grep -E 'devfile\.io' || true
)

if [ "${#MUTATING_WEBHOOKS[@]}" -gt 0 ]; then
  oc adm inspect "${MUTATING_WEBHOOKS[@]}" --dest-dir="$LOGS_DIR" || true
fi

if [ "${#VALIDATING_WEBHOOKS[@]}" -gt 0 ]; then
  oc adm inspect "${VALIDATING_WEBHOOKS[@]}" --dest-dir="$LOGS_DIR" || true
fi

############################################
# 7. SecurityContextConstraints (from CheCluster CR)
############################################
echo "[INFO] Collecting SecurityContextConstraints..."

# Extract SCC names from CheCluster CRs
readarray -t SCC_NAMES < <(
  oc get checlusters.org.eclipse.che -A -o json 2>/dev/null | jq -r '
    .items[] |
    .spec.devEnvironments.containerBuildConfiguration.openShiftSecurityContextConstraint,
    .spec.devEnvironments.containerRunConfiguration.openShiftSecurityContextConstraint |
    select(. != null)' | sort -u
)

# Also collect any SCCs matching devworkspace/che pattern
readarray -t PATTERN_SCCS < <(
  oc get securitycontextconstraints -o name 2>/dev/null | grep -E 'devworkspace|che' || true
)

# Merge both lists
ALL_SCCS=("${SCC_NAMES[@]}" "${PATTERN_SCCS[@]}")
if [ "${#ALL_SCCS[@]}" -gt 0 ]; then
  for scc in "${ALL_SCCS[@]}"; do
    if [ -n "$scc" ]; then
      oc adm inspect "securitycontextconstraints/${scc}" --dest-dir="$LOGS_DIR" 2>/dev/null || true
    fi
  done
fi

############################################
# 8. ClusterRoles and ClusterRoleBindings
############################################
echo "[INFO] Collecting ClusterRoles and ClusterRoleBindings..."

# Collect DevSpaces/DevWorkspace-related ClusterRoles and ClusterRoleBindings
readarray -t CLUSTER_ROLES < <(
  oc get clusterrole -o name | grep -E 'devworkspace|devfile|che|eclipse' || true
)
readarray -t CLUSTER_ROLE_BINDINGS < <(
  oc get clusterrolebinding -o name | grep -E 'devworkspace|devfile|che|eclipse' || true
)

if [ "${#CLUSTER_ROLES[@]}" -gt 0 ]; then
  oc adm inspect "${CLUSTER_ROLES[@]}" --dest-dir="$LOGS_DIR" || true
fi

if [ "${#CLUSTER_ROLE_BINDINGS[@]}" -gt 0 ]; then
  oc adm inspect "${CLUSTER_ROLE_BINDINGS[@]}" --dest-dir="$LOGS_DIR" || true
fi

############################################
# 9. Cluster Storage
############################################
echo "[INFO] Collecting storage resources..."

oc adm inspect storageclass --dest-dir="$LOGS_DIR" || true
oc adm inspect persistentvolume --dest-dir="$LOGS_DIR" || true

############################################
# 10. Node State
############################################
echo "[INFO] Collecting node information..."

oc adm inspect node --dest-dir="$LOGS_DIR" || true

# Also collect detailed node descriptions
mkdir -p "$LOGS_DIR/cluster-resources/node-descriptions"
readarray -t NODES < <(oc get nodes -o name 2>/dev/null || true)
for node in "${NODES[@]}"; do
  node_name="${node#*/}"  # Remove 'node/' prefix
  if [ -n "$node_name" ]; then
    oc describe node "$node_name" > "$LOGS_DIR/cluster-resources/node-descriptions/${node_name}.txt" 2>/dev/null || true
  fi
done

############################################
# 11. Cluster Events
############################################
echo "[INFO] Collecting cluster events..."

# Note: Events are collected by 'oc adm inspect' for each namespace
# Cluster-wide event collection removed to avoid v1.List type assertion panics
# when oc inspect processes the manually created event files

############################################
# 12. Cluster version
############################################
echo "[INFO] Collecting cluster version..."

oc adm inspect clusterversion --dest-dir="$LOGS_DIR" || true

# Also collect oc version output (client and server versions)
mkdir -p "$LOGS_DIR/cluster-resources"
oc version > "$LOGS_DIR/cluster-resources/oc-version.txt" 2>/dev/null || true

############################################
# 13. Cluster-wide pods listing
############################################
echo "[INFO] Collecting cluster-wide pods listing..."

mkdir -p "$LOGS_DIR/cluster-resources"
oc get pods --all-namespaces=true -o yaml > "$LOGS_DIR/cluster-resources/pods-all-namespaces.yaml" 2>/dev/null || true

############################################
# 14. Cluster status
############################################
echo "[INFO] Collecting cluster status..."

oc status > "$LOGS_DIR/cluster-resources/cluster-status.txt" 2>/dev/null || true

############################################
# 15. ImageContentSourcePolicy
############################################
echo "[INFO] Collecting ImageContentSourcePolicy..."

oc adm inspect imagecontentsourcepolicy --dest-dir="$LOGS_DIR" || true

############################################
# 16. Cluster Proxy
############################################
echo "[INFO] Collecting cluster proxy configuration..."

oc adm inspect proxy --dest-dir="$LOGS_DIR" || true

# Note: The following resources are already collected by 'oc adm inspect ns/<namespace>':
# - Roles and RoleBindings (in operator and workspace namespaces)
# - Templates (in CheCluster namespace)
# - LimitRanges and ResourceQuotas (in workspace namespaces)

############################################
# Done
############################################
echo "[INFO] Summary:"
echo "[INFO]   - CRDs collected: ${#CRDS[@]}"
echo "[INFO]   - API resources collected: ${#API_RESOURCES[@]}"
echo "[INFO]   - Operator namespaces: ${#UNIQUE_NAMESPACES[@]}"
echo "[INFO]   - Workspace namespaces: ${#WS_NAMESPACES[@]}"
sync
echo "[INFO] Must-gather completed. Output: $LOGS_DIR"

