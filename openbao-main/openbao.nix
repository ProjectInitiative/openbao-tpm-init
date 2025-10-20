{ pkgs }:

let
  # OpenBao override with HSM + source pinned to a newer commit/tag
  openbao = (pkgs.openbao.override {
    withHsm = true;
    withUi = true;
  }).overrideAttrs (old: rec {
    version = "2.4.1-unstable";

    src = pkgs.fetchFromGitHub {
      owner = "openbao";
      repo = "openbao";
      rev = "6d1e0edaf167fac0bc122dd956bb5a439d8782ed";
      hash = "sha256-dZR8LkPILcnKy1peYIqu273FUTqUgV2nxV0d4lW6ilM=";
    };

    vendorHash = "sha256-AA63G9Jq6RW7Ru62nqhPlIqF+hx4k2bX8q2SK8MA5sc=";
  });
  # This wrapper script becomes the container's main entrypoint.
  # It exists to work around a hardcoded command and config path in the official Helm chart.
  wrapperEntrypoint = pkgs.writeShellScript "docker-entrypoint.sh" ''
    #!/bin/bash
    echo "Executing wrapper docker-entrypoint.sh to fix arguments..."
    echo "Original args: $@"
    
    # The Helm chart mounts config to extraconfig-from-values.hcl
    CONFIG_FILE="/openbao/config/extraconfig-from-values.hcl"
    
    if [ -f "$CONFIG_FILE" ]; then
      echo "Using Helm-provided config: $CONFIG_FILE"
      exec /entrypoint.sh bao server -config="$CONFIG_FILE"
    else
      echo "No Helm config found, trying to use provided args: $@"
      exec /entrypoint.sh "$@"
    fi
  '';
  
  # Enhanced entrypoint script that sources environment from sidecar
  entrypoint = pkgs.writeShellScript "entrypoint.sh" ''
    #!/bin/bash
    # Enhanced entrypoint with seal key support

    set -e

    echo "🚀 Starting OpenBao with seal support..."

    ENV_FILE="/shared/openbao.env"
    echo "⏳ Waiting for seal key from sidecar at $ENV_FILE..."
    while [ ! -s "$ENV_FILE" ]; do
      sleep 2
    done
    echo "✅ Seal key file found!"

    # Source seal key from sidecar
    echo "📥 Loading seal configuration from sidecar..."
    source "$ENV_FILE"
    echo "✅ Seal key loaded (type: ''${BAO_SEAL_TYPE:-unknown})"

    # Prepare environment as root if needed
    if [ "$(id -u)" = '0' ]; then
        echo "🔧 Setting up directory permissions as root..."
        
        # Set up directories (user already exists from etcFiles)
        mkdir -p /openbao/data /openbao/logs /openbao/config /shared /tmp
        chown -R 1000:1000 /openbao 2>/dev/null || true
        chmod 1777 /tmp

        # Write the seal key to a file
        echo "$BAO_SEAL_KEY" | base64 -d > /tmp/bao_seal_key
        chown 1000:1000 /tmp/bao_seal_key
        
        echo "👤 Switching to openbao user..."
        exec su-exec openbao "$@"
    else
        echo "👤 Running as current user ($(whoami))"
        # Write the seal key to a file
        echo "$BAO_SEAL_KEY" | base64 -d > /tmp/bao_seal_key
        exec "$@"
    fi
  '';

  # Default OpenBao configuration
  defaultConfig = pkgs.writeText "bao.hcl" ''
    ui = true
    
    # Conditional seal configuration - will be activated when BAO_SEAL_KEY is present
    seal "aes-gcm" {
      # Key provided by sidecar via BAO_SEAL_KEY environment variable  
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
  '';

# Basic passwd/group files for the container
  etcFiles = pkgs.runCommand "openbao-etc-files" {} ''
    mkdir -p $out/etc
    echo "root:x:0:0:root:/root:/bin/sh" > $out/etc/passwd
    echo "nobody:x:65534:65534:nobody:/:" >> $out/etc/passwd
    echo "openbao:x:1000:1000:OpenBao:/home/openbao:/bin/sh" >> $out/etc/passwd
    
    echo "root:x:0:" > $out/etc/group
    echo "nobody:x:65534:" >> $out/etc/group
    echo "openbao:x:1000:" >> $out/etc/group
  '';

in pkgs.dockerTools.buildImage {
  name = "openbao-with-seal-support";
  tag = "latest";

  config = {
    Env = [
      "PATH=${pkgs.lib.makeBinPath [
        pkgs.openbao
        # Old override
        # openbao
        pkgs.su-exec
        pkgs.shadow  # for adduser/addgroup
        pkgs.coreutils
        pkgs.bash
        pkgs.gnused # Add sed
      ]}"
    ];
    WorkingDir = "/openbao";
    User = "0";  # Start as root, then drop to openbao user
    ExposedPorts = {
      "8200/tcp" = {};
      "8201/tcp" = {};
    };
  };

  # Create directory structure and copy files
  copyToRoot = pkgs.buildEnv {
    name = "openbao-root";
    paths = [
      # Core dependencies
      pkgs.openbao
      # Old override
      # openbao
      pkgs.su-exec
      pkgs.shadow
      pkgs.coreutils
      pkgs.bash
      pkgs.gnused # Add sed
      etcFiles  # Add pre-built /etc files
    ];
    postBuild = ''
      # Create directory structure
      mkdir -p $out/openbao/{data,logs,config}
      mkdir -p $out/shared
      mkdir -p $out/tmp
      mkdir -p $out/usr/local/bin
      
      # Don't copy default config - let Helm provide it via values
      
      # Copy our real entrypoint (now handled in postBuild instead of paths)
      cp ${entrypoint} $out/entrypoint.sh
      chmod +x $out/entrypoint.sh

      # Copy the wrapper entrypoint to the location the Helm chart expects
      cp ${wrapperEntrypoint} $out/usr/local/bin/docker-entrypoint.sh
      chmod +x $out/usr/local/bin/docker-entrypoint.sh
    '';
  };
}
