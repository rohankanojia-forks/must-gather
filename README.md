# Dev Spaces Must-Gather

`Dev Spaces must-gather` is a tool to collect diagnostic information about the [Red Hat OpenShift Dev Spaces](https://developers.redhat.com/products/openshift-dev-spaces) (downstream of [Eclipse Che](https://eclipse.dev/che)) operator and workspace environment. It is built on top of [OpenShift must-gather](https://github.com/openshift/must-gather).

---

## Usage

```sh
oc adm must-gather --image=quay.io/<your-org>/dev-spaces-must-gather:latest
```

The command above will create a local directory with a dump of the Dev Spaces state in your OpenShift cluster.

> ⚠️ This must-gather focuses on Dev Spaces and related components. To collect full cluster data, run oc adm must-gather without specifying a custom image.

## Prerequisites

**Cluster-admin permissions are required** to run this must-gather. The tool needs elevated privileges to:
- Execute `oc adm inspect` commands
- Read resources across all namespaces
- Access cluster-scoped resources (CRDs, Nodes, PersistentVolumes, StorageClasses, ClusterVersion, Webhooks)

To verify you have the required permissions:
```bash
oc auth can-i '*' '*' --all-namespaces
```

## What is collected

This must-gather collects both operator-specific and cluster-level diagnostic data to enable effective troubleshooting.

### Dev Spaces & DevWorkspace resources
- All Dev Spaces and DevWorkspace CRDs and their definitions
- All Dev Spaces-related custom resources across namespaces
- Devfile-related resources
- Workspace namespaces and all objects within them (pods, PVCs, configmaps, etc.)
  - No secrets are collected

### Operator and OLM data
- Dev Spaces and DevWorkspace operator namespaces (including pods, logs, and events)
- Subscription, ClusterServiceVersion (CSV), and InstallPlan resources
- Operator logs and controller state


### Cluster-scoped resources
- Admission webhooks:
  - MutatingWebhookConfiguration
  - ValidatingWebhookConfiguration
- Storage configuration:
  - StorageClasses
  - PersistentVolumes
- Cluster version information

### Cluster diagnostics (for root cause analysis)
- Node information:
  - Node status, capacity, and conditions
- Cluster-wide events (warnings and errors)
- Scheduling and infrastructure-related signals

## When to use

This must-gather is useful for diagnosing:

- Workspace startup failures
- DevWorkspace reconciliation issues
- Operator deployment or upgrade failures
- Webhook misconfigurations or certificate issues
- PersistentVolumeClaim (PVC) binding problems
- Pod scheduling failures due to cluster capacity or node conditions

## Notes
- **Secrets:** Metadata is collected, but data fields are redacted by `oc adm inspect` (only byte length shown, not actual values).
- Some rapidly changing resources (e.g., logs, events) may differ slightly between runs.
- The scope is intentionally expanded beyond operator resources to include cluster-level diagnostics required for root cause analysis.
- **Dynamic detection:** No hardcoded namespaces - the tool automatically discovers operator and workspace namespaces regardless of installation method.

## Development

For building and pushing the image:

```shell
make help
```

## Image publishing

To push a custom image:
```shell
make REGISTRY_USERNAME=<your-org> CONTAINER_IMAGE_TAG=latest push
```

Using the latest tag is recommended during development, as it avoids caching on OpenShift nodes.

## Testing

### Prerequisites

- An OpenShift cluster with the Dev Spaces operator installed
- `oc` CLI configured and logged in
- **`omc` (OpenShift Must Gather)** - Required for validating must-gather output

#### Installing omc

Download the latest binary from the [omc releases page](https://github.com/gmeghnag/omc/releases).

### Running tests

1. **Collect must-gather data:**
   ```shell
   # Using a test image
   oc adm must-gather --image=<TEST_IMAGE>
   
   # Or run the script directly for local testing
   ./gather_dev_spaces.sh
   ```

2. **Validate the output:**
   ```shell
   # Test the collected data
   ./test_must_gather.sh
   
   # Or specify a custom directory
   LOGS_DIR=must-gather.local.<timestamp> ./test_must_gather.sh
   ```

The test script validates that:
- The must-gather archive is readable by `omc`
- All expected CRD resources are present and queryable
- All additional collected files (webhooks, storage, nodes, events, etc.) exist and are not empty
