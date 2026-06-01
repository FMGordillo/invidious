{
  description = "Invidious - privacy-preserving YouTube frontend";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Runtime system libraries required by Crystal shards
        buildInputs = with pkgs; [
          openssl
          libxml2
          libyaml
          gmp
          libevent
          pcre
          readline
          sqlite
          postgresql
          librsvg   # rsvg-convert — used for CAPTCHA rendering
          zlib
        ];

        # Tools needed at build/development time
        nativeBuildInputs = with pkgs; [
          crystal
          shards
          pkg-config
          git     # embedded at compile-time via backtick macros
        ];

        # Development-only extras
        devInputs = with pkgs; [
          postgresql   # psql CLI for DB management
          gnumake
        ];

        # Helper: create a minimal config/config.yml for local dev if absent
        devConfigScript = pkgs.writeShellScript "ensure-dev-config" ''
          if [ ! -f config/config.yml ]; then
            echo "Creating config/config.yml from example..."
            cp config/config.example.yml config/config.yml
            # Patch in a dev hmac_key so the server starts without manual editing
            sed -i 's/^#\?hmac_key:.*/hmac_key: "dev-hmac-key-change-in-production"/' config/config.yml
          fi
        '';

      in
      {
        # ----------------------------------------------------------------
        # Development shell
        # ----------------------------------------------------------------
        devShells.default = pkgs.mkShell {
          inherit buildInputs nativeBuildInputs;
          packages = devInputs;

          # pkg-config search paths for Crystal's native extensions
          PKG_CONFIG_PATH = pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" buildInputs;

          shellHook = ''
            echo "Invidious dev shell"
            echo ""
            echo "Available commands:"
            echo "  inv-get-libs      Install Crystal shards"
            echo "  inv-build         Build invidious (debug)"
            echo "  inv-build-release Build invidious (release)"
            echo "  inv-verify        Type-check without emitting binary"
            echo "  inv-run           Build (debug) and run"
            echo "  inv-test          Run Crystal specs"
            echo "  inv-format        Format Crystal source files"
            echo "  inv-lint          Run Ameba static linter"
            echo "  inv-db-start      Start a local PostgreSQL instance"
            echo "  inv-db-stop       Stop the local PostgreSQL instance"
            echo "  inv-db-init       Create the invidious DB and schema"
            echo "  inv-db-console    Open a psql console to the invidious DB"
            echo ""

            # ---- convenience functions --------------------------------

            inv-get-libs() {
              shards install
            }

            inv-build() {
              shards install
              crystal build src/invidious.cr --debug --progress --stats --error-trace
            }

            inv-build-release() {
              shards install --production
              crystal build src/invidious.cr --release --debug --progress --stats --error-trace
            }

            inv-verify() {
              crystal build src/invidious.cr -Dskip_videojs_download \
                --no-codegen --progress --stats --error-trace
            }

            inv-run() {
              inv-build
              ${devConfigScript}
              ./invidious
            }

            inv-test() {
              crystal spec
            }

            inv-format() {
              crystal tool format
            }

            inv-lint() {
              bin/ameba
            }

            # ---- local PostgreSQL helpers ------------------------------
            # Uses a data directory inside the project so it doesn't
            # conflict with any system-wide PostgreSQL installation.

            _INV_PG_DIR="$PWD/.postgres"
            _INV_PG_SOCKET="$_INV_PG_DIR/socket"

            inv-db-start() {
              if [ ! -d "$_INV_PG_DIR/data" ]; then
                echo "Initialising PostgreSQL cluster at $_INV_PG_DIR/data ..."
                initdb -D "$_INV_PG_DIR/data" --auth=trust --no-locale --encoding=UTF8
              fi
              mkdir -p "$_INV_PG_SOCKET"
              if pg_ctl status -D "$_INV_PG_DIR/data" > /dev/null 2>&1; then
                echo "PostgreSQL is already running."
              else
                pg_ctl start -D "$_INV_PG_DIR/data" \
                  -o "-k $_INV_PG_SOCKET -p 5432" \
                  -l "$_INV_PG_DIR/postgres.log"
                echo "PostgreSQL started. Log: $_INV_PG_DIR/postgres.log"
              fi
            }

            inv-db-stop() {
              pg_ctl stop -D "$_INV_PG_DIR/data" -m fast
            }

            inv-db-init() {
              local socket="$_INV_PG_SOCKET"
              echo "Creating role 'kemal' and database 'invidious' ..."
              psql -h "$socket" -p 5432 -U "$(whoami)" postgres \
                -c "CREATE USER kemal WITH PASSWORD 'kemal';" 2>/dev/null || true
              psql -h "$socket" -p 5432 -U "$(whoami)" postgres \
                -c "CREATE DATABASE invidious OWNER kemal;" 2>/dev/null || true
              echo "Applying SQL schema ..."
              for sql in config/sql/*.sql; do
                psql -h "$socket" -p 5432 -U kemal invidious -f "$sql"
              done
              echo "Database ready."
            }

            inv-db-console() {
              psql -h "$_INV_PG_SOCKET" -p 5432 -U kemal invidious
            }

            export -f inv-get-libs inv-build inv-build-release inv-verify \
                      inv-run inv-test inv-format inv-lint \
                      inv-db-start inv-db-stop inv-db-init inv-db-console
          '';
        };

        # ----------------------------------------------------------------
        # Package build
        # ----------------------------------------------------------------
        packages.default = pkgs.crystal.buildCrystalPackage {
          pname = "invidious";
          version = "2.20260207.0-dev";

          src = ./.;

          inherit buildInputs nativeBuildInputs;

          shardsFile = ./shard.lock;
          crystalBinaries.invidious = {
            src = "src/invidious.cr";
            options = [
              "--release"
              "--debug"
              "--progress"
              "--stats"
              "--error-trace"
            ];
          };

          meta = with pkgs.lib; {
            description = "Privacy-preserving alternative front-end to YouTube";
            homepage = "https://invidious.io";
            license = licenses.agpl3Only;
            maintainers = [];
            platforms = platforms.linux ++ platforms.darwin;
          };
        };
      }
    );
}
