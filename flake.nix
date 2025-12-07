{
  description = "OpenBao TPM-based auto-unsealing containers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ops-utils.url = "github:projectinitiative/ops-utils";
  };

  outputs = { self, nixpkgs, ops-utils,  ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          ops = ops-utils.lib.mkUtils { inherit pkgs; };
        in
        {
          inherit (ops) build-image push-multi-arch;
          bootstrap-init = import ./bootstrap-init/bootstrap.nix { inherit pkgs; };
          unsealer-sidecar = import ./sidecar-unsealer/unsealer.nix { inherit pkgs; };
          openbao-main = import ./openbao-main/openbao.nix { inherit pkgs; };
          backup-job = import ./backup-job/backup.nix { inherit pkgs; };
        });

      apps = nixpkgs.lib.recursiveUpdate (forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          ops = ops-utils.lib.mkUtils { inherit pkgs; };
          opsApps = ops-utils.lib.mkApps { inherit pkgs; } ops;

        in
        {
          inherit (opsApps) build-image push-multi-arch push-insecure;

          # TODO: remove all of these in favor of build-image, imported above
          build-bootstrap = {
            type = "app";
            program = toString (pkgs.writeShellScript "build-bootstrap" ''
              set -e
              echo "Building bootstrap init container for ${system}..."
              nix build ".#packages.${system}.bootstrap-init" -o result-bootstrap
              echo "Loading into Docker..."
              docker load < result-bootstrap
              rm result-bootstrap
              echo "✅ Bootstrap container for ${system} ready!"
            '');
          };
          build-sidecar = {
            type = "app";
            program = toString (pkgs.writeShellScript "build-sidecar" ''
              set -e
              echo "Building unsealer sidecar container for ${system}..."
              nix build ".#packages.${system}.unsealer-sidecar" -o result-sidecar
              echo "Loading into Docker..."
              docker load < result-sidecar
              rm result-sidecar
              echo "✅ Sidecar container for ${system} ready!"
            '');
          };
          build-main = {
            type = "app";
            program = toString (pkgs.writeShellScript "build-main" ''
              set -e
              echo "Building OpenBao main container for ${system}..."
              nix build ".#packages.${system}.openbao-main" -o result-main
              echo "Loading into Docker..."
              docker load < result-main
              rm result-main
              echo "✅ OpenBao main container for ${system} ready!"
            '');
          };
          build-backup = {
            type = "app";
            program = toString (pkgs.writeShellScript "build-backup" ''
              set -e
              echo "Building backup job container for ${system}..."
              nix build ".#packages.${system}.backup-job" -o result-backup
              echo "Loading into Docker..."
              docker load < result-backup
              rm result-backup
              echo "✅ Backup job container for ${system} ready!"
            '');
          };
          build-all = {
            type = "app";
            program = toString (pkgs.writeShellScript "build-all" ''
              set -e
              echo "Building all containers for ${system}..."
              nix run .#apps.${system}.build-bootstrap
              nix run .#apps.${system}.build-sidecar
              nix run .#apps.${system}.build-main
              nix run .#apps.${system}.build-backup
              echo "🎉 All containers for ${system} built and loaded into Docker!"
            '');
          };
          dev-push = {
            type = "app";
            program = toString (pkgs.writeShellScript "dev-push" ''
              set -e
              INSECURE_REGISTRY=$1
              if [ -z "$INSECURE_REGISTRY" ]; then
                echo "Usage: $0 <insecure-registry>"
                exit 1
              fi
              nix run .#push-insecure -- bootstrap-init openbao-bootstrap-init $INSECURE_REGISTRY
              nix run .#push-insecure -- unsealer-sidecar openbao-unsealer-sidecar $INSECURE_REGISTRY
              nix run .#push-insecure -- openbao-main openbao-with-seal-support $INSECURE_REGISTRY
              nix run .#push-insecure -- backup-job openbao-backup $INSECURE_REGISTRY
            '');
          };
        }));
      

      devShells = forAllSystems (system:
        {
          default = nixpkgs.legacyPackages.${system}.mkShell {
            buildInputs = with nixpkgs.legacyPackages.${system}; [
              docker
              kubectl
              helm
              jq
              openssl
              tpm2-tools
              nix-build-uncached
            ];
          };
        });
    };
}
