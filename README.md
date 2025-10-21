# OpenBao TPM Auto-Unsealer

This repository contains the components to build a set of Docker images for running OpenBao with TPM-based auto-unsealing. The setup is designed for use in a Kubernetes environment.

## Architecture

The architecture uses a bootstrap and sidecar pattern:

1.  **Bootstrap Init Container**: A temporary init container that runs once to encrypt a master unsealing key using the node's TPM and stores it in a persistent volume.
2.  **Unsealer Sidecar Container**: A sidecar container that runs alongside the OpenBao container. It decrypts the master key from the persistent volume using the TPM and provides it to the OpenBao container.
3.  **OpenBao Main Container**: The main OpenBao container. Its entrypoint is modified to read the decrypted key from a file provided by the sidecar and use it for auto-unsealing.

This approach ensures that the master unsealing key is only ever present in plaintext in the memory of the init container and the sidecar, and is otherwise always encrypted at rest.

For more details, see the [implementation plan](plan.md).

## Components

The repository is structured as a Nix flake, which builds the following Docker images:

*   `openbao-bootstrap-init`: The bootstrap init container.
*   `openbao-unsealer-sidecar`: The unsealer sidecar container.
*   `openbao-main`: The main OpenBao container.

## Prerequisites

*   [Nix](https://nixos.org/download.html)
*   [Docker](https://docs.docker.com/get-docker/)

## Building the Images

To build all the images for your current architecture and load them into your local Docker daemon, run:

```bash
nix run .#apps.$(nix eval --raw nixpkgs#system).build-all
```

You can also build each image individually:

*   **Bootstrap Init Container**:
    ```bash
    nix run .#apps.$(nix eval --raw nixpkgs#system).build-bootstrap
    ```
*   **Unsealer Sidecar Container**:
    ```bash
    nix run .#apps.$(nix eval --raw nixpkgs#system).build-sidecar
    ```
*   **OpenBao Main Container**:
    ```bash
    nix run .#apps.$(nix eval --raw nixpkgs#system).build-main
    ```

### Multi-Arch Builds

To build and push multi-arch images to a container registry, you can use the `push-multi-arch` app. You will need to be logged in to your container registry.

```bash
nix run .#push-multi-arch -- <package-name> <image-name> <owner> [tag]
```

For example, to build and push the `openbao-main` image to `ghcr.io/my-org/openbao-main:latest`:

```bash
nix run .#push-multi-arch -- openbao-main openbao-main my-org latest
```

## Usage

These images are designed to be used in a Kubernetes environment, likely deployed via a Helm chart. The `plan.md` file contains a detailed example of how to configure a Helm chart to use these images.

## Deployment

To deploy OpenBao using the components in this repository, you will need a Kubernetes cluster with a TPM device available on the nodes. You will also need Helm.

**1. Create the Namespace**

All resources should be deployed in the `openbao` namespace.

```bash
kubectl create namespace openbao
```

**2. Create the Bootstrap Secret**

The `bootstrap-init` container requires a Kubernetes secret named `openbao-bootstrap-seal-key` containing the base64-encoded 32-byte AES key. The following steps ensure this is created correctly.

First, generate the key and store it in an environment variable:

```bash
export SEAL_KEY=$(openssl rand -base64 32)

# Verify the key was generated successfully
if [ -z "$SEAL_KEY" ]; then
  echo "Error: Failed to generate seal key. Please check your OpenSSL installation."
  exit 1
fi
echo "Generated seal key."
```

Now, create the Kubernetes secret from the environment variable:

```bash
kubectl create secret generic openbao-bootstrap-seal-key \
  --from-literal=seal-key="$SEAL_KEY" \
  --namespace=openbao
```

**3. Verify the Secret**

You can verify that the secret was created correctly with these commands:

```bash
# Check that the secret exists in the 'openbao' namespace
kubectl get secret openbao-bootstrap-seal-key --namespace=openbao

# Describe the secret to confirm it has a 'seal-key' data key
kubectl describe secret openbao-bootstrap-seal-key --namespace=openbao

# You can also decode the key to ensure it's not empty.
# This command should output a string of random characters.
kubectl get secret openbao-bootstrap-seal-key --namespace=openbao -o jsonpath='{.data.seal-key}' | base64 --decode
```

If any of these commands fail, delete the secret and try creating it again.

**4. Deploy with Helm**

Once the secret is verified, deploy OpenBao using the official Helm chart and the `values.yaml` file from this repository.

```bash
helm repo add openbao https://openbao.org/helm-charts
helm repo update
helm install openbao openbao/openbao \
  -f values.yaml \
  --namespace openbao
```

**5. Initialize OpenBao**

Once the pods are running, you can initialize the OpenBao cluster. If you had a pod stuck in the `Init` phase, you may need to delete it first (`kubectl delete pod openbao-server-0 -n openbao`) to have it restart and find the secret.

```bash
# Wait for the pod to be running
kubectl wait --for=condition=Ready pod/openbao-server-0 --timeout=300s -n openbao

# Exec into the pod and initialize
kubectl exec -ti openbao-server-0 -n openbao -- bao operator init
```

Store the recovery keys and root token in a safe place.

**6. Monitor the Logs**

You can monitor the logs of the sidecar to see the unsealing process in action.

```bash
kubectl logs -f openbao-server-0 -c unsealer-sidecar -n openbao
```

## Development

To enter a development shell with all the necessary tools, run:

```bash
nix develop
```

## Backup and Restore

This repository includes a container for backing up OpenBao snapshots to an S3-compatible object store using `restic`. This provides a simple and effective way to ensure your OpenBao data is safe.

We recommend using the [Kubernetes Secrets Store CSI driver](https://secrets-store-csi-driver.sigs.k8s.io/) to manage the credentials for the backup job. This approach is more secure and decouples the backup container from OpenBao.

### Prerequisites

*   [Kubernetes Secrets Store CSI driver](https://secrets-store-csi-driver.sigs.k8s.io/getting-started/installation.html) installed in your cluster.
*   [OpenBao CSI provider](https://www.vaultproject.io/docs/platform/k8s/csi) installed in your cluster.

### Building the Backup Container

To build the backup container and load it into your local Docker daemon, run:

```bash
nix run .#build-backup
```

### Configuration

To use the backup container, you will need to configure the following:

1.  **OpenBao Secrets:** The backup job needs credentials for `restic`, your S3 provider, and an OpenBao token. These should be stored in OpenBao itself.

    *   **Restic and S3 Credentials:** Create a secret in OpenBao at `secret/backup/restic` with the following keys:
        *   `aws_access_key_id`: Your S3 access key.
        *   `aws_secret_access_key`: Your S3 secret key.
        *   `restic_repository`: The URL of your `restic` repository (e.g., `s3:https://s3.amazonaws.com/your-bucket-name`).
        *   `restic_password`: The password for your `restic` repository.

        You can create this secret with the following command:

        ```bash
        bao kv put secret/backup/restic \
          aws_access_key_id="..." \
          aws_secret_access_key="..." \
          restic_repository="..." \
          restic_password="..."
        ```

    *   **OpenBao Token:** Create a periodic token in OpenBao that the backup job can use to authenticate and create snapshots. The token should have policies that allow it to take snapshots.

        ```bash
        # Create a policy for the backup job
        bao policy write backup - <<EOF
        path "sys/storage/raft/snapshot" {
          capabilities = ["read"]
        }
        EOF

        # Create a periodic token with the backup policy
        export BAO_TOKEN=$(bao token create -policy=backup -period=24h -format=json | jq -r .auth.client_token)

        # Store the token in a secret
        bao kv put secret/backup/token value=$BAO_TOKEN
        ```

2.  **Kubernetes Service Account:** Create a service account for the backup job:
    ```bash
    kubectl create serviceaccount openbao-backup -n openbao
    ```

3.  **OpenBao Kubernetes Auth:** Configure the OpenBao Kubernetes auth method to allow the `openbao-backup` service account to authenticate. You will need to create a role in OpenBao that is bound to this service account and has policies that allow it to read the `secret/backup/restic` and `secret/backup/token` secrets.

### Deployment

The `backup-job` directory contains the following files for deploying the backup job:

*   `secret-provider-class.yaml`: Defines a `SecretProviderClass` that tells the CSI driver how to fetch the `restic` credentials from OpenBao.
*   `backup-cronjob.yaml`: Defines a Kubernetes `CronJob` that runs the backup container.

You can add these files to your ArgoCD application as a new source.

For example, you can add the following to your ArgoCD `Application` manifest:

```yaml
    - repoURL: https://github.com/your-org/your-repo.git # Replace with your repo URL
      targetRevision: HEAD
      path: backup-job # Path to the directory containing the backup job manifests
```

You will also need to update the `backup-cronjob.yaml` to use the correct image name from your container registry and to set the desired schedule and pruning policy.

**Note on Snapshot Creation:** The backup container expects the OpenBao snapshot to be available in a shared volume at `/path/to/shared/volume/bao-snapshot.snap`. A separate process should be responsible for creating the snapshot. We recommend using a sidecar container in the main OpenBao pod that periodically creates a snapshot and saves it to a shared volume that is also mounted by the backup CronJob.
