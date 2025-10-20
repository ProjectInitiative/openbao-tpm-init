# OpenBao TPM Sidecar Auto-Unsealer Implementation Plan

## Architecture Overview

This implementation uses a **bootstrap + sidecar pattern** where:
1. **Bootstrap Init Container**: Encrypts a static unsealing secret using TPM/HSM and stores it locally
2. **Main OpenBao Container**: Uses "seal" configuration with the decrypted static secret for auto-unsealing
3. **Sidecar Container**: Decrypts the static secret, injects it into OpenBao environment, monitors health, and cleans up

## Security Model

- 🔐 **Static Bootstrap Secret**: One-time Kubernetes secret containing the master unsealing key
- 🔒 **TPM-Encrypted Storage**: Each node encrypts the bootstrap secret using its own TPM
- 🚫 **Zero Persistence**: Bootstrap K8s secret is deleted after successful cluster initialization
- 🔄 **Restart Resilience**: Nodes can restart indefinitely using TPM-decrypted secrets

## Components

### 1. Kubernetes Bootstrap Secret (Temporary)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: openbao-bootstrap-seal-key
  namespace: openbao
type: Opaque
data:
  # Base64-encoded 32-byte AES key for OpenBao's seal configuration
  seal-key: <base64-encoded-32-byte-key>
  # Optional: key wrapping/derivation info
  key-id: "bootstrap-2024"
```

### 2. Bootstrap Init Container

**Purpose**: Take K8s secret → Encrypt with TPM → Store encrypted version locally

**Image**: `ghcr.io/projectinitiative/openbao-bootstrap:latest`

**Responsibilities**:
- Mount Kubernetes bootstrap secret (read-only)
- Initialize TPM/HSM hardware and metadata store
- Encrypt the bootstrap seal key using TPM
- Store encrypted seal key + metadata in PVC
- Exit successfully when encryption is complete

**Key Files Created**:
```
/pkcs11-store/
├── tpm_metadata/           # TPM tools metadata
├── bootstrap_seal.enc      # TPM-encrypted seal key
├── bootstrap_seal.pub      # TPM public key for seal key
├── primary.ctx            # TPM primary context
└── initialized.flag       # Marker file indicating successful init
```

### 3. Sidecar Container  

**Purpose**: TPM decrypt → Inject into OpenBao env → Monitor → Clean up → Exit

**Image**: `ghcr.io/projectinitiative/openbao-unsealer-sidecar:latest`

**Responsibilities**:
- Wait for OpenBao main container to start
- Use TPM to decrypt bootstrap seal key from PVC
- Inject decrypted key into OpenBao's environment (shared process namespace or IPC)
- Monitor OpenBao health until it's fully operational
- Detect successful cluster formation across all nodes
- Clean up bootstrap Kubernetes secret
- Clear injected environment variables (if possible)
- Exit when job is complete

### 4. Main OpenBao Container

**Purpose**: Run OpenBao with seal configuration using injected key

**Configuration**:
```hcl
# OpenBao will use this seal config with the key injected by sidecar
seal "aes-gcm" {
  # The key will be provided via BAO_SEAL_KEY environment variable
  # This is injected by the sidecar container
}

storage "raft" {
  path = "/openbao/data"
  retry_join {
    leader_api_addr = "http://openbao-0.openbao-internal:8200"
  }
  retry_join {
    leader_api_addr = "http://openbao-1.openbao-internal:8200"
  }
  retry_join {
    leader_api_addr = "http://openbao-2.openbao-internal:8200"
  }
}

listener "tcp" {
  tls_disable     = true
  address         = "[::]:8200"
  cluster_address = "[::]:8201"
}
```

## Implementation Steps

### Step 1: Bootstrap Init Container

Create `bootstrap-init/` directory with:

```
bootstrap-init/
├── Dockerfile
├── bootstrap.nix          # Nix expression for dependencies
├── bootstrap-script.sh    # Main initialization script
└── README.md
```

**Dependencies Needed**:
- TPM2 tools (`tpm2-tools`)
- TPM2 PKCS#11 (`tpm2-pkcs11`) 
- SoftHSM (`softhsm`)
- OpenSSL (for key operations)
- jq (for JSON processing)

**Key Script Logic**:
```bash
#!/bin/bash
# bootstrap-script.sh

# 1. Check if already initialized
if [ -f "/pkcs11-store/initialized.flag" ]; then
    echo "✅ Already initialized, skipping..."
    exit 0
fi

# 2. Initialize TPM hardware and metadata
initialize_tpm_hardware()

# 3. Read bootstrap secret from K8s mount
BOOTSTRAP_KEY=$(cat /bootstrap-secret/seal-key | base64 -d)

# 4. Encrypt bootstrap key using TPM
encrypt_with_tpm "$BOOTSTRAP_KEY" "/pkcs11-store/bootstrap_seal.enc"

# 5. Mark as initialized
touch "/pkcs11-store/initialized.flag"
```

### Step 2: Sidecar Unsealer Container

Create `sidecar-unsealer/` directory with:

```
sidecar-unsealer/
├── Dockerfile
├── unsealer.nix           # Nix expression for dependencies  
├── unsealer-script.sh     # Main sidecar logic
└── README.md
```

**Dependencies Needed**:
- TPM2 tools
- curl (for OpenBao API calls)
- jq (for JSON processing)
- kubectl (for K8s API calls)

**Key Script Logic**:
```bash
#!/bin/bash
# unsealer-script.sh

# 1. Wait for OpenBao to start
wait_for_openbao_startup()

# 2. Decrypt bootstrap seal key from TPM
DECRYPTED_KEY=$(decrypt_with_tmp "/pkcs11-store/bootstrap_seal.enc")

# 3. Inject into OpenBao environment
# Options:
#   - Shared volume with env file
#   - Process namespace sharing + env injection
#   - IPC mechanism

inject_seal_key_to_openbao "$DECRYPTED_KEY"

# 4. Monitor OpenBao until fully operational
monitor_cluster_health()

# 5. Clean up bootstrap secret from Kubernetes
kubectl delete secret openbao-bootstrap-seal-key -n $NAMESPACE

# 6. Clear injected environment (attempt)
clear_injected_environment()

# 7. Exit successfully
echo "✅ Sidecar job complete"
```

### Step 3: Modified Helm Values

```yaml
# openbao-values.yaml
server:
  image:
    registry: "ghcr.io/projectinitiative"
    repository: "openbao-hsm" 
    tag: "latest"

  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      config: |
        ui = true
        
        # Seal configuration using injected environment variable
        seal "aes-gcm" {
          # Key injected by sidecar via BAO_SEAL_KEY env var
        }
        
        storage "raft" {
          path = "/openbao/data"
          retry_join {
            leader_api_addr = "http://openbao-0.openbao-internal:8200"
          }
          retry_join {
            leader_api_addr = "http://openbao-1.openbao-internal:8200"
          }
          retry_join {
            leader_api_addr = "http://openbao-2.openbao-internal:8200"
          }
        }
        
        listener "tcp" {
          tls_disable     = true
          address         = "[::]:8200"  
          cluster_address = "[::]:8201"
        }

  # Bootstrap init container
  extraInitContainers:
    - name: bootstrap-init
      image: "ghcr.io/projectinitiative/openbao-bootstrap:latest"
      env:
        - name: TPM2_PKCS11_STORE
          value: "/pkcs11-store"
        - name: TSS2_TCTI
          value: "device:/dev/tpmrm0"
      volumeMounts:
        - name: data
          mountPath: /pkcs11-store
          subPath: pkcs11-data
        - name: bootstrap-secret-volume
          mountPath: /bootstrap-secret
          readOnly: true
      resources:
        limits:
          squat.ai/tpm: 1
        requests:
          squat.ai/tpm: 1

  # Sidecar unsealer container
  extraContainers:
    - name: unsealer-sidecar
      image: "ghcr.io/projectinitiative/openbao-unsealer-sidecar:latest"
      env:
        - name: VAULT_ADDR
          value: "http://localhost:8200"
        - name: TPM2_PKCS11_STORE  
          value: "/pkcs11-store"
        - name: TSS2_TCTI
          value: "device:/dev/tpmrm0"
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
      volumeMounts:
        - name: data
          mountPath: /pkcs11-store
          subPath: pkcs11-data
      resources:
        limits:
          squat.ai/tpm: 1
        requests:
          squat.ai/tpm: 1
      # Sidecar should restart if it fails during cluster init
      restartPolicy: Always

  # Volume definitions
  volumes:
    - name: bootstrap-secret-volume
      secret:
        secretName: openbao-bootstrap-seal-key
        optional: true  # Won't fail after secret is deleted

  # Shared process namespace to allow env injection
  shareProcessNamespace: true
```

## Deployment Flow

### Initial Bootstrap

1. **Create bootstrap secret**:
   ```bash
   # Generate 32-byte AES key
   SEAL_KEY=$(openssl rand -base64 32)
   
   kubectl create secret generic openbao-bootstrap-seal-key \
     --from-literal=seal-key="$SEAL_KEY" \
     -n openbao
   ```

2. **Deploy OpenBao cluster**:
   ```bash
   helm install openbao openbao/openbao \
     -f openbao-values.yaml \
     -n openbao --create-namespace
   ```

3. **Initialize first node**:
   ```bash
   kubectl exec -ti openbao-0 -- bao operator init
   # Store recovery keys securely
   ```

4. **Monitor sidecar logs**:
   ```bash
   kubectl logs -f openbao-0 -c unsealer-sidecar
   kubectl logs -f openbao-1 -c unsealer-sidecar  
   kubectl logs -f openbao-2 -c unsealer-sidecar
   ```

5. **Verify cluster formation**:
   ```bash
   kubectl exec -ti openbao-0 -- bao operator raft list-peers
   ```

### Steady State Operations

- **Pod Restarts**: Bootstrap init skips (already initialized), sidecar decrypts and injects, OpenBao auto-unseals
- **Cluster Restarts**: All nodes auto-unseal using their TPM-stored keys
- **Scaling**: New nodes get bootstrap secret (if it still exists) or require manual unsealing

## Security Considerations

### Threat Model

- ✅ **Physical Access**: TPM prevents key extraction from powered-off nodes
- ✅ **Pod Compromise**: Decrypted keys exist only in memory during unsealing
- ✅ **Kubernetes Access**: Bootstrap secret is deleted after initialization
- ⚠️ **Process Namespace**: Shared namespace allows sidecar→main container communication
- ⚠️ **Memory Dumps**: Decrypted key briefly exists in sidecar memory

### Mitigations

- Use `mlock()` in sidecar to prevent key swapping to disk
- Clear memory after key injection
- Monitor for unauthorized access to shared process namespace
- Regular rotation of recovery keys (standard OpenBao practice)

## Technical Challenges

### Environment Variable Injection

**Challenge**: How does sidecar inject `BAO_SEAL_KEY` into running OpenBao process?

**Options**:
1. **Shared Process Namespace** + `/proc/<pid>/environ` modification (complex)
2. **Shared Volume** with environment file that OpenBao reads on startup
3. **Init Container** approach where sidecar runs before OpenBao starts
4. **IPC Socket** for key exchange between containers

**Recommended**: Option 2 (shared volume with env file) - most reliable and secure.

### Cleanup Timing

**Challenge**: When is it safe to delete bootstrap secret?

**Solution**: Sidecar should wait until:
- All expected nodes are present in raft cluster
- All nodes report as unsealed and healthy
- Cluster has achieved quorum and is processing requests

This ensures the bootstrap secret isn't deleted while nodes are still joining.

## Future Work

- **Replace Sidecar with Init Container**: The current sidecar model works, but it leaves the container running. A better approach would be to use an init container to decrypt the key and pass it to the main container. This would prevent the bootstrap information from sitting around.
- **Alternative to `kubectl`**: The `kubectl` commands within the sidecar are not functioning as expected. A more robust method for interacting with the Kubernetes API is needed for tasks like secret cleanup.

## Next Steps

1. **Build bootstrap init container** with TPM encryption logic
2. **Build sidecar unsealer container** with decryption and injection logic  
3. **Test environment variable injection** mechanism
4. **Update Helm chart** with new container configurations
5. **Create deployment and testing procedures**

Would you like to start with implementing the bootstrap init container first?
