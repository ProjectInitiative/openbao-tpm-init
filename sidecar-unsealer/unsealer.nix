{ pkgs ? import <nixpkgs> { }
, pkgsLinux ? import <nixpkgs> { system = "x86_64-linux"; }
}:

let
  # Sidecar unsealer script
  unsealerScript = pkgs.writeShellScript "unsealer-script.sh" ''
    #!/bin/bash
    # unsealer-script.sh - TPM-based auto-unsealer sidecar

    set -e

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

    echo "🚀 Starting OpenBao unsealer sidecar for pod: $POD_NAME"

    # Wait for OpenBao main container to start
    wait_for_openbao() {
        echo "⏳ Waiting for OpenBao to start..."
        local attempts=0
        while ! curl -s "''${VAULT_ADDR:-http://localhost:8200}/v1/sys/health" >/dev/null 2>&1; do
            if [ $attempts -ge 60 ]; then
                echo "❌ Timeout waiting for OpenBao to start"
                exit 1
            fi
            echo "   Attempt $((attempts + 1))/60..."
            sleep 5
            attempts=$((attempts + 1))
        done
        echo "✅ OpenBao is responding"
    }

    # Check if vault is initialized
    is_vault_initialized() {
        local status=$(curl -s "''${VAULT_ADDR:-http://localhost:8200}/v1/sys/seal-status" 2>/dev/null | jq -r '.initialized // false')
        [ "$status" = "true" ]
    }

    # Decrypt bootstrap key using TPM
    decrypt_bootstrap_key() {
        if [ ! -f "$INIT_FLAG" ] || [ ! -f "$BOOTSTRAP_SEAL_PRIV" ]; then
            echo "❌ Bootstrap initialization not found"
            return 1
        fi
        
        echo "🔓 Decrypting bootstrap seal key using TPM..."
        local sealed_ctx="/tmp/sealed_bootstrap.ctx"
        
        # Load the sealed object
        tpm2_load -T "$TSS2_TCTI" -C "$PRIMARY_CTX_PATH" \
            -u "$BOOTSTRAP_SEAL_PUB" -r "$BOOTSTRAP_SEAL_PRIV" \
            -c "$sealed_ctx" \
            || { echo "❌ Failed to load sealed object"; return 1; }
        
        # Unseal the key
        local key=$(tpm2_unseal -T "$TSS2_TCTI" -c "$sealed_ctx") \
            || { echo "❌ Failed to unseal bootstrap key"; rm -f "$sealed_ctx"; return 1; }
        
        rm -f "$sealed_ctx"
        echo "$key"
    }

    # Inject seal key into OpenBao environment
    inject_seal_key() {
        local key="$1"
        
        echo "💉 Injecting seal key into OpenBao environment..."
        mkdir -p "$(dirname "$ENV_FILE")"
        
        # Write environment file that OpenBao will source
        cat > "$ENV_FILE" << EOF
export BAO_SEAL_KEY="$key"
export BAO_SEAL_TYPE="aes-gcm"
EOF
        
        chmod 600 "$ENV_FILE"
        echo "✅ Seal key injected to $ENV_FILE"
    }

    # Monitor cluster health and decide when to clean up
    monitor_and_cleanup() {
        echo "👀 Monitoring cluster health..."
        local healthy_count=0
        local required_healthy_cycles=6  # 3 minutes of consistent health
        
        while true; do
            if is_vault_initialized; then
                local seal_status=$(curl -s "''${VAULT_ADDR:-http://localhost:8200}/v1/sys/seal-status" 2>/dev/null || echo '{}')
                local is_sealed=$(echo "$seal_status" | jq -r '.sealed // true')
                
                if [ "$is_sealed" = "false" ]; then
                    healthy_count=$((healthy_count + 1))
                    echo "✅ Vault healthy ($healthy_count/$required_healthy_cycles)"
                    
                    if [ $healthy_count -ge $required_healthy_cycles ]; then
                        echo "🎉 Cluster appears stable, initiating cleanup..."
                        cleanup_bootstrap_secret
                        return 0
                    fi
                else
                    healthy_count=0
                    echo "⚠️ Vault is sealed, resetting health counter"
                fi
            else
                healthy_count=0
                echo "⚠️ Vault not initialized, waiting..."
            fi
            
            sleep 30
        done
    }

    # Clean up bootstrap secret from Kubernetes
    cleanup_bootstrap_secret() {
        echo "🧹 Attempting to clean up bootstrap secret..."
        
        if kubectl get secret openbao-bootstrap-seal-key -n "$NAMESPACE" >/dev/null 2>&1; then
            kubectl delete secret openbao-bootstrap-seal-key -n "$NAMESPACE" \
                && echo "✅ Bootstrap secret deleted successfully" \
                || echo "⚠️ Failed to delete bootstrap secret (may already be deleted)"
        else
            echo "ℹ️ Bootstrap secret already deleted or not found"
        fi
        
        # Clear the environment file
        if [ -f "$ENV_FILE" ]; then
            rm -f "$ENV_FILE" && echo "✅ Environment file cleared"
        fi
    }

    # Main execution
    main() {
        wait_for_openbao
        
        # Decrypt the bootstrap key
        if ! DECRYPTED_KEY=$(decrypt_bootstrap_key); then
            echo "❌ Failed to decrypt bootstrap key"
            exit 1
        fi
        
        # Inject into OpenBao
        inject_seal_key "$DECRYPTED_KEY"
        
        # Clear from memory
        unset DECRYPTED_KEY
        
        # Monitor and cleanup
        monitor_and_cleanup
        
        echo "✅ Sidecar job completed successfully"
    }

    # Handle cleanup on exit
    trap 'echo "🛑 Sidecar shutting down..."; unset DECRYPTED_KEY 2>/dev/null || true; exit' INT TERM

    main "$@"
  '';

in pkgsLinux.dockerTools.buildImage {
  name = "openbao-unsealer-sidecar";
  tag = "latest";
  
  config = {
    Cmd = [ "${pkgsLinux.bash}/bin/bash" "${unsealerScript}" ];
    Env = [
      "PATH=${pkgsLinux.lib.makeBinPath [
        pkgsLinux.tpm2-tools
        pkgsLinux.curl
        pkgsLinux.jq
        pkgsLinux.kubectl
        pkgsLinux.coreutils
        pkgsLinux.gnugrep
        pkgsLinux.gawk
        pkgsLinux.bash
      ]}"
      "TSS2_TCTI=device:/dev/tpmrm0"
      "TPM2_PKCS11_STORE=/pkcs11-store"
      "VAULT_ADDR=http://localhost:8200"
    ];
    WorkingDir = "/";
    User = "0";  # Run as root for TPM access and kubectl
  };
  
  # Include necessary files and setup
  copyToRoot = pkgsLinux.buildEnv {
    name = "unsealer-root";
    paths = [
      # Core dependencies
      pkgsLinux.tpm2-tools
      pkgsLinux.curl
      pkgsLinux.jq
      pkgsLinux.kubectl
      pkgsLinux.coreutils
      pkgsLinux.gnugrep
      pkgsLinux.gawk
      pkgsLinux.bash
    ];
    postBuild = ''
      # Create required directories
      mkdir -p $out/pkcs11-store
      mkdir -p $out/shared
      mkdir -p $out/tmp
      
      # Copy unsealer script
      cp ${unsealerScript} $out/unsealer-script.sh
      chmod +x $out/unsealer-script.sh
    '';
  };
}
