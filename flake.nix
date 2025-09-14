{
  description = "A Nix flake to build Grafana and its Docker image from source";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

        # --- Arguments from the Dockerfile ---
        # These can be overridden when building, e.g., `nix build .#default --override-input go-build-tags "enterprise"`
        go-build-tags = pkgs.lib.mkOptionDefault "oss";
        wire-tags = pkgs.lib.mkOptionDefault "oss";

        # --- Javascript Frontend Build Derivation ---
        # This derivation replicates the 'js-builder' stage of the Dockerfile.
        grafana-frontend = pkgs.stdenv.mkDerivation {
          pname = "grafana-frontend";
          version = "dev";
          src = ./.;

          nativeBuildInputs = [
            pkgs.nodejs-22_x
            pkgs.yarn
            pkgs.make
            pkgs.python3
            pkgs.gcc # for 'build-base'
          ];

          # Configure Yarn to use a local cache to avoid network access during the build.
          # This makes the build more reproducible.
          configurePhase = ''
            export HOME=$(mktemp -d)
            yarn config set cache-folder $HOME/.yarn-cache
          '';

          buildPhase = ''
            # Replicates 'yarn install' and 'yarn build'
            yarn install --immutable
            yarn build
          '';

          installPhase = ''
            # Copies the build artifacts to the output directory ($out)
            mkdir -p $out/public
            cp -r public/* $out/public
            cp LICENSE $out/LICENSE
          '';
        };

        # --- Golang Backend Build Derivation ---
        # This derivation replicates the 'go-builder' stage of the Dockerfile.
        grafana-backend = pkgs.stdenv.mkDerivation {
          pname = "grafana-backend";
          version = "dev";
          src = ./.;

          nativeBuildInputs = [
            pkgs.go_1_24
            pkgs.gnumake
            pkgs.git
            pkgs.gcc
            pkgs.binutils
          ];

          # This is required for Go builds to find dependencies like glibc.
          hardeningDisable = [ "fortify" ];

          # Set build environment variables
          # In Nix, we don't need to run `go mod download` separately.
          # The build process will fetch them as needed. For true hermetic builds,
          # a `vendorSha256` would be used here.
          buildPhase = ''
            make build-go GO_BUILD_TAGS="${go-build-tags}" WIRE_TAGS="${wire-tags}"
          '';

          installPhase = ''
            # Copies the build artifacts to the output directory ($out)
            mkdir -p $out/bin $out/conf
            cp -r bin/* $out/bin/
            cp -r conf/* $out/conf/
          '';
        };

      in
      {
        # The final Docker image, which assembles the build artifacts.
        packages.default = pkgs.dockerTools.buildImage {
          name = "grafana-from-source";
          tag = "latest";

          # Start from a minimal empty image. Nix provides all necessary libraries.
          fromImage = null;

        # Runtime dependencies for the final image.
        copyToRoot = pkgs.buildEnv {
          name = "image-root";
          paths = [
            pkgs.bash
            pkgs.cacert
            pkgs.curl
            pkgs.tzdata
            pkgs.shadow # for useradd/groupadd
            pkgs.coreutils # for getent, chown, etc.
          ];
        };

        # This script runs once during image creation to set everything up.
        runAsRoot = ''
          #!${pkgs.bash}/bin/bash
          set -e

          # Config values from Dockerfile
          GF_UID="472"
          GF_GID="0" # root group
          GF_PATHS_HOME="/usr/share/grafana"
          GF_PATHS_CONFIG="/etc/grafana/grafana.ini"
          GF_PATHS_DATA="/var/lib/grafana"
          GF_PATHS_LOGS="/var/log/grafana"
          GF_PATHS_PLUGINS="/var/lib/grafana/plugins"
          GF_PATHS_PROVISIONING="/etc/grafana/provisioning"

          # 1. Create user, group, and directory structure
          if ! getent group $GF_GID >/dev/null; then
            groupadd -r -g $GF_GID grafana
          fi
          GF_GID_NAME=$(getent group $GF_GID | cut -d':' -f1)
          useradd -r -u $GF_UID -g "$GF_GID_NAME" grafana

          mkdir -p \
            "$GF_PATHS_HOME" \
            "$GF_PATHS_HOME/.aws" \
            "$GF_PATHS_PROVISIONING/datasources" \
            "$GF_PATHS_PROVISIONING/dashboards" \
            "$GF_PATHS_PROVISIONING/notifiers" \
            "$GF_PATHS_PROVISIONING/plugins" \
            "$GF_PATHS_PROVISIONING/access-control" \
            "$GF_PATHS_PROVISIONING/alerting" \
            "$GF_PATHS_LOGS" \
            "$GF_PATHS_PLUGINS" \
            "$GF_PATHS_DATA" \
            /etc/grafana

          # 2. Copy build artifacts from the backend and frontend builds
          cp -r ${grafana-backend}/bin/* $GF_PATHS_HOME/bin/
          cp -r ${grafana-backend}/conf/* $GF_PATHS_HOME/conf/
          cp -r ${grafana-frontend}/public/* $GF_PATHS_HOME/public/
          cp ${grafana-frontend}/LICENSE $GF_PATHS_HOME/LICENSE

          # 3. Set up config files and entrypoint
          cp $GF_PATHS_HOME/conf/sample.ini "$GF_PATHS_CONFIG"
          touch /etc/grafana/ldap.toml
          cat > /run.sh <<'EOF'
          ${builtins.readFile ./packaging/docker/run.sh}
          EOF
          chmod +x /run.sh

          # 4. Set final permissions
          chown -R "grafana:$GF_GID_NAME" "$GF_PATHS_DATA" "$GF_PATHS_HOME" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING"
          chmod 777 "$GF_PATHS_DATA" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS"
        '';

        # Configure container metadata
        config = {
          Labels = {
            "maintainer" = "Grafana Labs <hello@grafana.com>";
            "org.opencontainers.image.source" = "https://github.com/grafana/grafana";
          };

          Env = [
            "PATH=/usr/share/grafana/bin:${pkgs.lib.makeBinPath [ pkgs.bash pkgs.coreutils pkgs.curl ]}"
            "GF_PATHS_CONFIG=/etc/grafana/grafana.ini"
            "GF_PATHS_DATA=/var/lib/grafana"
            "GF_PATHS_HOME=/usr/share/grafana"
            "GF_PATHS_LOGS=/var/log/grafana"
            "GF_PATHS_PLUGINS=/var/lib/grafana/plugins"
            "GF_PATHS_PROVISIONING=/etc/grafana/provisioning"
          ];

          WorkingDir = "/usr/share/grafana";
          ExposedPorts = { "3000/tcp" = {}; };
          User = "472";
          Entrypoint = [ "/run.sh" ];
        };
      };
    );
}
