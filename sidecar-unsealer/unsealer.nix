{ pkgs }:

let
  # Sidecar unsealer script
  unsealerScript = pkgs.writeShellScript "unsealer-script.sh" ''
    #!/bin/bash
    # unsealer-script.sh - TPM-based auto-unsealer sidecar

    set -euo pipefail

    TPM_STORE="''${TPM2_PKCS11_STORE:?}"
    PRIMARY_CTX_PATH="''${TPM_STORE}/primary.ctx"
    BOOTSTRAP_SEAL_PUB="''${TPM_STORE}/bootstrap_seal.pub"
    BOOTSTRAP_SEAL_PRIV="''${TPM_STORE}/bootstrap_seal.priv"
    INIT_FLAG="''${TPM_STORE}/initialized.flag"
    ENV_FILE="/shared/openbao.env"

    TSS2_TCTI="''${TSS2_TCTI:?TSS2_TCTI must be set}"
    export TSS2_TCTI

    POD_NAME="''${POD_NAME:?POD_NAME must be set}"
    NAMESPACE="''${NAMESPACE:?NAMESPACE must be set}"

    echo "🚀 Starting OpenBao unsealer sidecar for pod: $POD_NAME" >&2

    # Wait for OpenBao main container to start
    wait_for_openbao() {
        echo "⏳ Waiting for OpenBao to start..." >&2
        local attempts=0
        while ! curl -s "''${VAULT_ADDR:-http://localhost:8200}/v1/sys/health" >/dev/null 2>&1; do
            if [ $attempts -ge 60 ]; then
                echo "❌ Timeout waiting for OpenBao to start" >&2
                exit 1
            fi
            echo "   Attempt $((attempts + 1))/60..." >&2
            sleep 5
            attempts=$((attempts + 1))
        done
        echo "✅ OpenBao is responding" >&2
    }

    # Check if vault is initialized
    is_vault_initialized() {
        local status=$(curl -s "''${VAULT_ADDR:-http://localhost:8200}/v1/sys/seal-status" 2>/dev/null | jq -r '.initialized // false')
        [ "$status" = "true" ]
    }

    # Decrypt bootstrap key using TPM
    decrypt_bootstrap_key() {
        if [ ! -f "$INIT_FLAG" ] || [ ! -f "$BOOTSTRAP_SEAL_PRIV" ]; then
            echo "❌ Bootstrap initialization not found" >&2
            return 1
        fi
        
        echo "🔓 Decrypting bootstrap seal key using TPM..." >&2
        local sealed_ctx="/tmp/sealed_bootstrap.ctx"
        
        # Load the sealed object (no stdout leakage)
        if ! tpm2_load -T "$TSS2_TCTI" -C "$PRIMARY_CTX_PATH" \
            -u "$BOOTSTRAP_SEAL_PUB" -r "$BOOTSTRAP_SEAL_PRIV" \
            -c "$sealed_ctx" >/dev/null; then
            echo "❌ Failed to load sealed object" >&2
            return 1
        fi
        
        # Unseal the key (only output raw key to stdout)
        if ! key=$(tpm2_unseal -T "$TSS2_TCTI" -c "$sealed_ctx"); then
            echo "❌ Failed to unseal bootstrap key" >&2
            rm -f "$sealed_ctx"
            return 1
        fi
        
        rm -f "$sealed_ctx"
        printf "%s" "$key"
    }

    # Inject seal key into OpenBao environment
    inject_seal_key() {
        local key="$1"
        local b64_key=$(printf "%s" "$key" | base64 -w 0)
        
        echo "💉 Injecting seal key into OpenBao environment..." >&2
        mkdir -p "$(dirname "$ENV_FILE")"
        
        # Write environment file that OpenBao will source
        cat > "$ENV_FILE" << EOF
BAO_SEAL_TYPE="static"
BAO_SEAL_KEY="$b64_key"
EOF
        
        chmod 644 "$ENV_FILE"
        echo "✅ Seal key injected to $ENV_FILE" >&2
    }

    # Monitor cluster health and decide when to clean up
    monitor_and_cleanup() {
        echo "👀 Monitoring cluster health..." >&2
        local healthy_count=0
        local required_healthy_cycles=6  # 3 minutes of consistent health
        
        while true; do
            local seal_status=$(curl -s "''${VAULT_ADDR:-http://localhost:8200}/v1/sys/seal-status" 2>/dev/null || echo '{}')
            local initialized=$(echo "$seal_status" | jq -r '.initialized // false')
            local sealed=$(echo "$seal_status" | jq -r '.sealed // true')

            if [ "$initialized" = "true" ] && [ "$sealed" = "false" ]; then
                healthy_count=$((healthy_count + 1))
                echo "✅ Vault unsealed and healthy ($healthy_count/$required_healthy_cycles)" >&2

                if [ $healthy_count -ge $required_healthy_cycles ]; then
                    echo "🎉 Cluster appears stable, initiating cleanup..." >&2
                    cleanup_bootstrap_secret
                    return 0
                fi
            elif [ "$initialized" = "true" ] && [ "$sealed" = "true" ]; then
                echo "⏳ Vault is initialized but still sealed (waiting for auto-unseal)..." >&2
                healthy_count=0
            else
                echo "⚠️ Vault not initialized yet, waiting..." >&2
                healthy_count=0
            fi

            sleep 30
        done
    }

    # Clean up bootstrap secret from Kubernetes
    cleanup_bootstrap_secret() {
        echo "🧹 Attempting to clean up bootstrap secret..." >&2
        
        if kubectl get secret openbao-bootstrap-seal-key -n "$NAMESPACE" >/dev/null 2>&1; then
            if kubectl delete secret openbao-bootstrap-seal-key -n "$NAMESPACE" >/dev/null 2>&1; then
                echo "✅ Bootstrap secret deleted successfully" >&2
            else
                echo "⚠️ Failed to delete bootstrap secret (may already be deleted)" >&2
            fi
        else
            echo "ℹ️ Bootstrap secret already deleted or not found" >&2
        fi
        
        # Clear the environment file
        if [ -f "$ENV_FILE" ]; then
            rm -f "$ENV_FILE"
            echo "✅ Environment file cleared" >&2
        fi
    }

    # Main execution
    main() {
        # Decrypt the bootstrap key
        if ! DECRYPTED_KEY=$(decrypt_bootstrap_key); then
            echo "❌ Failed to decrypt bootstrap key" >&2
            exit 1
        fi
        
        # Inject into OpenBao
        inject_seal_key "$DECRYPTED_KEY"
        
        # Clear from memory
        unset DECRYPTED_KEY
        
        # Monitor and cleanup
        monitor_and_cleanup
        
        echo "✅ Sidecar job completed successfully" >&2
    }

    # Handle cleanup on exit
    trap 'echo "🛑 Sidecar shutting down..." >&2; unset DECRYPTED_KEY 2>/dev/null || true; exit' INT TERM

    main "$@"
  '';

in pkgs.dockerTools.buildImage {
  name = "openbao-unsealer-sidecar";
  tag = "latest";
  
  config = {
    Cmd = [ "${pkgs.bash}/bin/bash" "${unsealerScript}" ];
    Env = [
      "PATH=${pkgs.lib.makeBinPath [
        pkgs.tpm2-tools
        pkgs.curl
        pkgs.jq
        pkgs.kubectl
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gawk
        pkgs.bash
      ]}"
      "TSS2_TCTI=device:/dev/tpmrm0"
      "TPM2_PKCS11_STORE=/pkcs11-store"
      "VAULT_ADDR=http://[::1]:8200"
    ];
    WorkingDir = "/";
    User = "0";  # Run as root for TPM access and kubectl
  };
  
  # Include necessary files and setup
  copyToRoot = pkgs.buildEnv {
    name = "unsealer-root";
    paths = [
      pkgs.tpm2-tools
      pkgs.curl
      pkgs.jq
      pkgs.kubectl
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gawk
      pkgs.bash
    ];
    postBuild = ''
      mkdir -p $out/pkcs11-store
      mkdir -p $out/shared
      mkdir -p $out/tmp
      
      cp ${unsealerScript} $out/unsealer-script.sh
      chmod +x $out/unsealer-script.sh
    '';
  };
}
