{ pkgs }:

let
  # OpenBao with HSM support
  openbao = pkgs.openbao.override { withHsm = true; };

  # This wrapper script becomes the container's main entrypoint.
  # It exists to work around a hardcoded command and config path in the official Helm chart.
  wrapperEntrypoint = pkgs.writeShellScript "docker-entrypoint.sh" ''
    #!/bin/sh
    echo "Executing wrapper docker-entrypoint.sh to fix arguments..."
    # We execute our real entrypoint, but pass the *correct* arguments,
    # ignoring the incorrect ones from the Helm chart's command.
    exec /entrypoint.sh bao server -config=/openbao/config/bao.hcl
  '';

  
  # Enhanced entrypoint script that sources environment from sidecar
  entrypoint = pkgs.writeShellScript "entrypoint.sh" ''
    #!/bin/bash
    # Enhanced entrypoint with seal key support

    set -e

    echo "🚀 Starting OpenBao with seal support..."

    ENV_FILE="/shared/openbao.env"
    echo "⏳ Waiting for seal key from sidecar at $ENV_FILE..."
    while [ ! -f "$ENV_FILE" ]; do
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
        
        # Ensure openbao user exists
        if ! getent passwd openbao >/dev/null; then
            echo "👤 Creating openbao user..."
            addgroup -g 1000 openbao || true
            adduser -u 1000 -G openbao -s /bin/sh -D openbao || true
        fi
        
        # Set up directories
        mkdir -p /openbao/data /openbao/logs /shared /tmp
        chown -R openbao:openbao /openbao/data /openbao/logs /shared 2>/dev/null || true
        chmod 1777 /tmp
        
        echo "👤 Switching to openbao user..."
        exec su-exec openbao "$@"
    else
        echo "👤 Running as current user ($(whoami))"
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
    Cmd = [ "${entrypoint}" "bao" "server" "-config=/openbao/config/bao.hcl" ];
    Env = [
      "PATH=${pkgs.lib.makeBinPath [
        openbao
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
      openbao
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
      
      # Copy default configuration
      cp ${defaultConfig} $out/openbao/config/bao.hcl
      
      # Copy our real entrypoint
      cp ${entrypoint} $out/entrypoint.sh
      chmod +x $out/entrypoint.sh

      # Copy the wrapper entrypoint to the location the Helm chart expects
      mkdir -p $out/usr/local/bin
      cp ${wrapperEntrypoint} $out/usr/local/bin/docker-entrypoint.sh
      chmod +x $out/usr/local/bin/docker-entrypoint.sh

      # Create a dummy docker-entrypoint.sh to satisfy the bao binary's expectations
      mkdir -p $out/usr/local/bin
      echo "#!/bin/sh\nexec \"\$@\"" > $out/usr/local/bin/docker-entrypoint.sh
      chmod +x $out/usr/local/bin/docker-entrypoint.sh
    '';
  };
}
