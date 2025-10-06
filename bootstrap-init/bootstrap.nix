{ pkgs }:

let
  bootstrapScript = pkgs.writeShellScript "bootstrap-script.sh" ''
    #!/bin/bash
    # bootstrap-script.sh - Initialize TPM and seal bootstrap key (base64 preserved)

    set -euo pipefail

    TPM_STORE="''${TPM2_PKCS11_STORE:?TPM2_PKCS11_STORE must be set}"
    PRIMARY_CTX_PATH="''${TPM_STORE}/primary.ctx"
    BOOTSTRAP_SEAL_PUB="''${TPM_STORE}/bootstrap_seal.pub"
    BOOTSTRAP_SEAL_PRIV="''${TPM_STORE}/bootstrap_seal.priv"
    INIT_FLAG="''${TPM_STORE}/initialized.flag"

    TSS2_TCTI="''${TSS2_TCTI:?TSS2_TCTI must be set}"
    export TSS2_TCTI

    echo "🔧 Starting bootstrap initialization..." >&2

    # 1. Check if context is valid and clean up if not
    if [ -f "$PRIMARY_CTX_PATH" ]; then
        echo "ℹ️ Found existing primary context. Verifying with TPM..." >&2
        if ! tpm2_readpublic -T "$TSS2_TCTI" -c "$PRIMARY_CTX_PATH" >/dev/null 2>&1; then
            echo "⚠️ Primary context is invalid, possibly due to TPM reset. Cleaning up..." >&2
            rm -rf "$TPM_STORE"/*
        fi
    fi

    # 2. Check if already initialized
    if [ -f "$INIT_FLAG" ]; then
        echo "✅ Already initialized (found $INIT_FLAG), skipping..." >&2
        exit 0
    fi

    mkdir -p "$TPM_STORE"

    # 2. Read bootstrap secret from Kubernetes mount (base64, no decoding here)
    if [ ! -f "/bootstrap-secret/seal-key" ]; then
        echo "❌ Bootstrap secret not found at /bootstrap-secret/seal-key" >&2
        exit 1
    fi

    echo "📖 Reading bootstrap seal key (base64 preserved)..." >&2
    BOOTSTRAP_KEY=$(cat /bootstrap-secret/seal-key | tr -d '\n')

    if [ -z "$BOOTSTRAP_KEY" ]; then
        echo "❌ Bootstrap key is empty" >&2
        exit 1
    fi

    echo "🔐 Initializing TPM and creating primary context..." >&2
    if ! tpm2_createprimary -T "$TSS2_TCTI" -C o -c "$PRIMARY_CTX_PATH" >/dev/null; then
        echo "❌ Failed to create TPM primary context" >&2
        exit 1
    fi

    echo "🔒 Sealing base64 bootstrap key with TPM..." >&2
    if ! echo -n "$BOOTSTRAP_KEY" | tpm2_create \
        -T "$TSS2_TCTI" \
        -C "$PRIMARY_CTX_PATH" -i- \
        -u "$BOOTSTRAP_SEAL_PUB" -r "$BOOTSTRAP_SEAL_PRIV" >/dev/null; then
        echo "❌ Failed to seal bootstrap key with TPM" >&2
        exit 1
    fi

    # 3. Mark as successfully initialized
    touch "$INIT_FLAG"

    echo "✅ Bootstrap initialization complete!" >&2
    echo "   - Primary context: $PRIMARY_CTX_PATH" >&2
    echo "   - Sealed key: $BOOTSTRAP_SEAL_PRIV" >&2
    echo "   - Init flag: $INIT_FLAG" >&2

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
    User = "0";
  };
  
  copyToRoot = pkgs.buildEnv {
    name = "bootstrap-root";
    paths = [
      pkgs.tpm2-tools
      pkgs.openssl
      pkgs.jq
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gawk
      pkgs.bash
    ];
    postBuild = ''
      mkdir -p $out/bootstrap-secret
      mkdir -p $out/pkcs11-store
      mkdir -p $out/tmp
      cp ${bootstrapScript} $out/bootstrap-script.sh
      chmod +x $out/bootstrap-script.sh
    '';
  };
}
