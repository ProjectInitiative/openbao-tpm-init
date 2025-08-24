# OpenBao TPM Auto-Unsealer

This repository contains the components to build a set of Docker images for running OpenBao with TPM-based auto-unsealing. The setup is designed for use in a Kubernetes environment.

## Architecture

The architecture uses a bootstrap and sidecar pattern:

1.  **Bootstrap Init Container**: A temporary init container that runs once to encrypt a master unsealing key using the node's TPM and stores it in a persistent volume.
2.  **Unsealer Sidecar Container**: A sidecar container that runs alongside the OpenBao container. It decrypts the master key from the persistent volume using the TPM and provides it to the OpenBao container.
3.  **OpenBao Main Container**: The main OpenBao container, which is configured to use the master key from the sidecar for auto-unsealing.

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

1.  **Create the Bootstrap Secret**

    The `bootstrap-init` container requires a Kubernetes secret named `openbao-bootstrap-seal-key` containing the base64-encoded 32-byte AES key for OpenBao's seal configuration.

    ```bash
    kubectl create secret generic openbao-bootstrap-seal-key \
      --from-literal=seal-key="$(openssl rand -base64 32)" \
      -n openbao
    ```

2.  **Deploy with Helm**

    Deploy OpenBao using the official Helm chart, providing the `values.yaml` file from this repository.

    ```bash
    helm repo add openbao https://openbao.org/helm-charts
    helm repo update
    helm install openbao openbao/openbao \
      -f values.yaml \
      -n openbao --create-namespace
    ```

3.  **Initialize OpenBao**

    Once the pods are running, you can initialize the OpenBao cluster.

    ```bash
    kubectl exec -ti openbao-server-0 -n openbao -- bao operator init
    ```

    Store the recovery keys and root token in a safe place.

4.  **Monitor the Logs**

    You can monitor the logs of the sidecar to see the unsealing process in action.

    ```bash
    kubectl logs -f openbao-server-0 -c unsealer-sidecar -n openbao
    ```

## Development

To enter a development shell with all the necessary tools, run:

```bash
nix develop
```
