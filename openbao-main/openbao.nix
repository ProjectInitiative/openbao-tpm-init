{ pkgs ? import <nixpkgs> { }
, pkgsLinux ? import <nixpkgs> { system = "x86_64-linux"; }
}:

let
  # OpenBao with HSM support
  openbao = pkgsLinux.openbao.override { withHsm = true; };
  
  # Enhanced entrypoint script that sources environment from sidecar
  entrypoint = pkgsLinux.writeShellScript "entrypoint.sh" ''
    #!/bin/bash
    # Enhanced entrypoint with seal key support

    set -e

    echo "🚀 Starting OpenBao with seal support..."

    # Source seal key from sidecar if available
    if [ -f "/shared/openbao.env" ]; then
      echo "📥 Loading seal configuration from sidecar..."
      source /shared/openbao.env
      echo "✅ Seal key loaded (type: ''${BAO_SEAL_TYPE:-unknown})"
    else
      echo "ℹ️ No seal configuration found, using manual unsealing"
    fi

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
        mkdir -p /openbao/data /openbao/logs /shared
        chown -R openbao:openbao /openbao/data /openbao/logs /shared 2>/dev/null || true
        
        echo "👤 Switching to openbao user..."
        exec su-exec openbao "$@"
    else
        echo "👤 Running as current user ($(whoami))"
        exec "$@"
    fi
  '';

  # Default OpenBao configuration
  defaultConfig = pkgsLinux.writeText "bao.hcl" ''
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
  etcFiles = pkgsLinux.runCommand "openbao-etc-files" {} ''
    mkdir -p $out/etc
    echo "root:x:0:0:root:/root:/bin/sh" > $out/etc/passwd
    echo "nobody:x:65534:65534:nobody:/:" >> $out/etc/passwd
    echo "openbao:x:1000:1000:OpenBao:/home/openbao:/bin/sh" >> $out/etc/passwd
    
    echo "root:x:0:" > $out/etc/group
    echo "nobody:x:65534:" >> $out/etc/group
    echo "openbao:x:1000:" >> $out/etc/group
  '';

in pkgsLinux.dockerTools.buildImage {
  name = "openbao-with-seal-support";
  tag = "latest";

  config = {
    Cmd = [ "${entrypoint}" "bao" "server" "-config=/openbao/config/bao.hcl" ];
    Env = [
      "PATH=${pkgsLinux.lib.makeBinPath [
        openbao
        pkgsLinux.su-exec
        pkgsLinux.shadow  # for adduser/addgroup
        pkgsLinux.coreutils
        pkgsLinux.bash
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
  copyToRoot = pkgsLinux.buildEnv {
    name = "openbao-root";
    paths = [
      # Core dependencies
      openbao
      pkgsLinux.su-exec
      pkgsLinux.shadow
      pkgsLinux.coreutils
      pkgsLinux.bash
      etcFiles  # Add pre-built /etc files
    ];
    postBuild = ''
      # Create directory structure
      mkdir -p $out/openbao/{data,logs,config}
      mkdir -p $out/shared
      
      # Copy default configuration
      cp ${defaultConfig} $out/openbao/config/bao.hcl
      
      # Copy entrypoint script
      cp ${entrypoint} $out/entrypoint.sh
      chmod +x $out/entrypoint.sh
    '';
  };
}
