{
  description = "OpenBao TPM-based auto-unsealing containers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pkgsLinux = import nixpkgs { system = "x86_64-linux"; };
      in
      {
        packages = {
          # Bootstrap init container
          bootstrap-init = import ./bootstrap-init/bootstrap.nix {
            inherit pkgs pkgsLinux;
          };

          # Sidecar unsealer container
          unsealer-sidecar = import ./sidecar-unsealer/unsealer.nix {
            inherit pkgs pkgsLinux;
          };

          # Updated OpenBao main container with seal support
          openbao-main = import ./openbao-main/openbao.nix {
            inherit pkgs pkgsLinux;
          };
        };

        # Development shell
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            docker
            kubectl
            helm
            jq
            openssl
            tpm2-tools
            nix-build-uncached
          ];
          
          # This is the updated section
          shellHook = ''
            echo "🚀 OpenBao TPM Development Environment"
            echo ""
            echo "--- Build Only ---"
            echo "  nix build .#bootstrap-init      # Build bootstrap container"
            echo "  nix build .#unsealer-sidecar    # Build sidecar container"
            echo "  nix build .#openbao-main        # Build main container"
            echo "  (Then manually load with: docker load < result)"
            echo ""
            echo "--- Build & Load into Docker (Apps) ---"
            echo "  nix run .#build-bootstrap       # Build & load bootstrap container"
            echo "  nix run .#build-sidecar         # Build & load sidecar container"
            echo "  nix run .#build-main            # Build & load main container"
            echo "  nix run .#build-all             # Build & load all containers"
            echo ""
          '';
        };

        # Build all containers
        # this fails because the outputs are not directories, they are image files
        # packages.default = pkgs.symlinkJoin {
        #   name = "openbao-tpm-containers";
        #   paths = [
        #     self.packages.${system}.bootstrap-init
        #     self.packages.${system}.unsealer-sidecar
        #     self.packages.${system}.openbao-main
        #   ];
        # };

        # Individual build shortcuts
        apps = {
          build-bootstrap = {
            type = "app";
            program = toString (pkgs.writeShellScript "build-bootstrap" ''
              set -e
              echo "Building bootstrap init container..."
              nix build .#bootstrap-init
              echo "Loading into Docker..."
              docker load < result
              echo "✅ Bootstrap container ready!"
            '');
          };
          
          build-sidecar = {
            type = "app";
            program = toString (pkgs.writeShellScript "build-sidecar" ''
              set -e
              echo "Building unsealer sidecar container..."
              nix build .#unsealer-sidecar
              echo "Loading into Docker..."
              docker load < result
              echo "✅ Sidecar container ready!"
            '');
          };
          
          build-main = {
            type = "app";
            program = toString (pkgs.writeShellScript "build-main" ''
              set -e
              echo "Building OpenBao main container..."
              nix build .#openbao-main
              echo "Loading into Docker..."
              docker load < result
              echo "✅ OpenBao main container ready!"
            '');
          };

          build-all = {
            type = "app";
            program = toString (pkgs.writeShellScript "build-all" ''
              set -e
              echo "Building all containers..."
              nix build .#bootstrap-init
              docker load < result
              echo "✅ Bootstrap container loaded"
              
              nix build .#unsealer-sidecar
              docker load < result
              echo "✅ Sidecar container loaded"
              
              nix build .#openbao-main
              docker load < result
              echo "✅ Main container loaded"
              
              echo "🎉 All containers built and loaded into Docker!"
            '');
          };
        };
      });
}
