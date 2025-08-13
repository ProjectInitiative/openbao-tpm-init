{
  description = "OpenBao TPM-based auto-unsealing containers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          bootstrap-init = import ./bootstrap-init/bootstrap.nix { inherit pkgs; };
          unsealer-sidecar = import ./sidecar-unsealer/unsealer.nix { inherit pkgs; };
          openbao-main = import ./openbao-main/openbao.nix { inherit pkgs; };
        });

      apps = nixpkgs.lib.recursiveUpdate (forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
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
          build-all = {
            type = "app";
            program = toString (pkgs.writeShellScript "build-all" ''
              set -e
              echo "Building all containers for ${system}..."
              nix run .#apps.${system}.build-bootstrap
              nix run .#apps.${system}.build-sidecar
              nix run .#apps.${system}.build-main
              echo "🎉 All containers for ${system} built and loaded into Docker!"
            '');
          };
        }))
      ({
        "x86_64-linux" = {
          push-multi-arch = {
            type = "app";
            program = let pkgs = nixpkgs.legacyPackages."x86_64-linux"; in toString (pkgs.writeShellScript "push-multi-arch" ''
              set -e
              set -o pipefail

              PACKAGE_NAME=$1
              IMAGE_NAME=$2
              OWNER=$3
              TAG=''${4:-latest}

              if [ -z "$PACKAGE_NAME" ] || [ -z "$IMAGE_NAME" ] || [ -z "$OWNER" ]; then
                echo "Usage: $0 <package-name> <image-name> <owner> [tag]"
                exit 1
              fi

              MANIFEST_LIST=()
              for ARCH_SYSTEM in ${builtins.toString systems}; do
                # Derive arch from system string, e.g., x86_64-linux -> amd64
                ARCH=$(echo "$ARCH_SYSTEM" | sed 's/-linux//' | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
                
                echo "--- Building $PACKAGE_NAME for $ARCH_SYSTEM ($ARCH) ---"
                nix build ".#packages.$ARCH_SYSTEM.$PACKAGE_NAME" -o "result-$PACKAGE_NAME-$ARCH"
                
                LOADED_IMAGE=$(docker load < "result-$PACKAGE_NAME-$ARCH" | grep "Loaded image" | sed 's/Loaded image: //')
                echo "Loaded image: $LOADED_IMAGE"

                TARGET_TAG="ghcr.io/$OWNER/$IMAGE_NAME:$TAG-$ARCH"
                echo "Tagging $LOADED_IMAGE as $TARGET_TAG"
                docker tag "$LOADED_IMAGE" "$TARGET_TAG"
                
                echo "Pushing $TARGET_TAG"
                docker push "$TARGET_TAG"

                MANIFEST_LIST+=("$TARGET_TAG")
                
                rm "result-$PACKAGE_NAME-$ARCH"
              done

              MANIFEST_TAG="ghcr.io/$OWNER/$IMAGE_NAME:$TAG"
              echo "--- Creating and pushing manifest for $MANIFEST_TAG ---"
              echo "Manifest list: ''${MANIFEST_LIST[@]}"
              docker manifest create "$MANIFEST_TAG" "''${MANIFEST_LIST[@]}"
              docker manifest push "$MANIFEST_TAG"

              echo "✅ Successfully pushed multi-arch image $MANIFEST_TAG"
            '');
          };
        };
      });

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
