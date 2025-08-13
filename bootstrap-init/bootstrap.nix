{ pkgs }:

let
  # Bootstrap script with all dependencies
  bootstrapScript = pkgs.writeShellScript "bootstrap-script.sh" ''
    #!/bin/bash
    # bootstrap-script.sh - Initialize TPM and encrypt bootstrap seal key

    set -e
    set -o pipefail

    TPM_STORE="''${TPM2_PKCS11_STORE:?TPM2_PKCS11_STORE must be set}"
    PRIMARY_CTX_PATH="''${TPM_STORE}/primary.ctx"
    BOOTSTRAP_SEAL_PUB="''${TPM_STORE}/bootstrap_seal.pub"
    BOOTSTRAP_SEAL_PRIV="''${TPM_STORE}/bootstrap_seal.priv"
    INIT_FLAG="''${TPM_STORE}/initialized.flag"

    TSS2_TCTI="''${TSS2_TCTI:?TSS2_TCTI must be set}"
    export TSS2_TCTI

    echo "🔧 Starting bootstrap initialization..."

    # 1. Check if already initialized
    if [ -f "$INIT_FLAG" ]; then
        echo "✅ Already initialized (found $INIT_FLAG), skipping..."
        exit 0
    fi

    # 2. Create TPM store directory
    mkdir -p "$TPM_STORE"

    # 3. Read bootstrap secret from Kubernetes mount
    if [ ! -f "/bootstrap-secret/seal-key" ]; then
        echo "❌ Bootstrap secret not found at /bootstrap-secret/seal-key"
        exit 1
    fi

    echo "📖 Reading bootstrap seal key from Kubernetes secret..."
    BOOTSTRAP_KEY=$(cat /bootstrap-secret/seal-key | base64 -d)

    if [ -z "$BOOTSTRAP_KEY" ]; then
        echo "❌ Bootstrap key is empty after base64 decode"
        exit 1
    fi

    echo "🔐 Initializing TPM and creating primary context..."
    # Create TPM primary context for encryption
    tpm2_createprimary -T "$TSS2_TCTI" -C o -c "$PRIMARY_CTX_PATH" \
        || { echo "❌ Failed to create TPM primary context"; exit 1; }

    echo "🔒 Encrypting bootstrap key with TPM..."
    # Seal the bootstrap key using TPM
    echo -n "$BOOTSTRAP_KEY" | tpm2_create \
        -T "$TSS2_TCTI" \
        -C "$PRIMARY_CTX_PATH" -i- \
        -u "$BOOTSTRAP_SEAL_PUB" -r "$BOOTSTRAP_SEAL_PRIV" \
        || { echo "❌ Failed to seal bootstrap key with TPM"; exit 1; }

    # 4. Mark as successfully initialized
    touch "$INIT_FLAG"

    echo "✅ Bootstrap initialization complete!"
    echo "   - Primary context: $PRIMARY_CTX_PATH"
    echo "   - Sealed key: $BOOTSTRAP_SEAL_PRIV"
    echo "   - Init flag: $INIT_FLAG"

    # Clear the key from memory (best effort)
    unset BOOTSTRAP_KEY
  '';

in pkgs.dockerTools.buildImage {
  name = "openbao-bootstrap-init";
  tag = "latest";
  
  config = {
    Cmd = [ "${pkgs.bash}/bin/bash" "${bootstrapScript}" ];
    Env = [
      "PATH=${pkgs.lib.makeBinPath [
        pkgs.tpm2-tools
        pkgs.tpm2-pkcs11
        pkgs.softhsm
        pkgs.openssl
        pkgs.jq
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gawk
        pkgs.bash
      ]}"
      "TSS2_TCTI=device:/dev/tpmrm0"
      "TPM2_PKCS11_STORE=/pkcs11-store"
    ];
    WorkingDir = "/";
    User = "0";  # Run as root for TPM access
  };
  
  # Include necessary files and setup
  copyToRoot = pkgs.buildEnv {
    name = "bootstrap-root";
    paths = [
      # Core dependencies
      pkgs.tpm2-tools
      pkgs.tpm2-pkcs11  
      pkgs.softhsm
      pkgs.openssl
      pkgs.jq
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gawk
      pkgs.bash
    ];
    postBuild = ''
      # Create required directories
      mkdir -p $out/bootstrap-secret
      mkdir -p $out/pkcs11-store
      mkdir -p $out/tmp
      
      # Copy bootstrap script
      cp ${bootstrapScript} $out/bootstrap-script.sh
      chmod +x $out/bootstrap-script.sh
    '';
  };
}
