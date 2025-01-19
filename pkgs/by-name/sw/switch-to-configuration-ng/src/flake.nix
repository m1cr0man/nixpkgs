{
  description = "switch-to-configuration-ng dev env";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    crane = {
      url = "github:ipetkov/crane";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
      # inputs.rust-analyzer-src.follows = "";
    };

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, crane, fenix, flake-utils, advisory-db, ... }:
    {
      overlays = {
        switch-to-configuration-nixpkgs =
          let
            cargoConfig = (builtins.fromTOML (builtins.readFile "${self}/Cargo.toml"));
            pname = cargoConfig.package.name;
          in
          final: prev: {
            ${pname} = final.rustPlatform.buildRustPackage {
              inherit pname;
              version = cargoConfig.package.version;
              src = self;
              buildFeatures = [ "cli" ];

              cargoHash = "sha256-j3B41omVog8J4yhuaYnolzm/F+QwGHTPyrgUjbvW8IE=";

              PKG_CONFIG_PATH = "${final.dbus.dev}/lib/pkgconfig";
              PKG_CONFIG = "${final.pkg-config}/bin/pkg-config";
              SYSTEMD_DBUS_INTERFACE_DIR = "${final.systemd}/share/dbus-1/interfaces";

              meta = with final.lib; {
                description = "Switch to configuration";
                license = licenses.asl20;
                maintainers = [ maintainers.m1cr0man ];
              };
            };
          };
      };
    } //
    (flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        envVars = {
          PKG_CONFIG_PATH = "${pkgs.dbus.dev}/lib/pkgconfig";
          PKG_CONFIG = "${pkgs.pkg-config}/bin/pkg-config";
          SYSTEMD_DBUS_INTERFACE_DIR = "${pkgs.systemd}/share/dbus-1/interfaces";
        };

        stdenv =
          if pkgs.stdenv.isLinux then
            pkgs.stdenvAdapters.useMoldLinker pkgs.stdenv
          else
            pkgs.stdenv;

        inherit (pkgs) lib;

        craneLib = crane.mkLib pkgs;
        src = craneLib.cleanCargoSource (craneLib.path ./.);

        mkToolchain = fenix.packages.${system}.combine;

        toolchain = fenix.packages.${system}.stable;

        buildToolchain = mkToolchain (with toolchain; [
          cargo
          rustc
        ]);

        craneLibBuild = craneLib.overrideToolchain buildToolchain;

        devToolchain = mkToolchain (with toolchain; [
          cargo
          clippy
          rust-src
          rustc
          llvm-tools
          rust-analyzer

          # Always use nightly rustfmt because most of its options are unstable
          fenix.packages.${system}.latest.rustfmt
        ]);

        craneLibDev = craneLib.overrideToolchain devToolchain;

        # Common arguments can be set here to avoid repeating them later
        commonArgs = {
          inherit src stdenv;
          strictDeps = true;

          buildInputs = [
            # Add additional build inputs here
          ] ++ lib.optionals pkgs.stdenv.isDarwin [
            # Additional darwin specific inputs can be set here
            pkgs.libiconv
          ];
        } // envVars;

        # Build *just* the cargo dependencies, so we can reuse
        # all of that work (e.g. via cachix) when running in CI
        cargoArtifacts = craneLibBuild.buildDepsOnly commonArgs;

        # Build the actual crate itself, reusing the dependency
        # artifacts from above.
        switch-to-configuration = craneLibBuild.buildPackage (commonArgs // {
          inherit cargoArtifacts;
          cargoExtraArgs = "--locked -F cli";
        });
      in
      {
        checks = {
          # Build the crate as part of `nix flake check` for convenience
          inherit switch-to-configuration;

          # Run clippy (and deny all warnings) on the crate source,
          # again, resuing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          switch-to-configuration-clippy = craneLibDev.cargoClippy (commonArgs // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          });

          switch-to-configuration-doc = craneLibDev.cargoDoc (commonArgs // {
            inherit cargoArtifacts;
          });

          # Check formatting
          switch-to-configuration-fmt = craneLibDev.cargoFmt {
            inherit src;
          };

          # Audit dependencies
          switch-to-configuration-audit = craneLibDev.cargoAudit {
            inherit src advisory-db;
          };

          # Audit licenses
          switch-to-configuration-deny = craneLibDev.cargoDeny {
            inherit src;
          };

          # Run tests with cargo-nextest
          # Consider setting `doCheck = false` on `switch-to-configuration` if you do not want
          # the tests to run twice
          switch-to-configuration-nextest = craneLibDev.cargoNextest (commonArgs // {
            inherit cargoArtifacts;
            partitions = 1;
            partitionType = "count";
          });

          overlay = (import nixpkgs {
            inherit system;
            overlays = [ self.overlays.switch-to-configuration-nixpkgs ];
          }).switch-to-configuration;
        };

        packages = {
          inherit switch-to-configuration;
          default = switch-to-configuration;
          switch-to-configuration-lib = craneLibBuild.buildPackage (commonArgs // {
            inherit cargoArtifacts;
          });
          switch-to-configuration-llvm-coverage = craneLibDev.cargoLlvmCov (commonArgs // {
            inherit cargoArtifacts;
          });
          devTools = pkgs.linkFarm "vscode-dev-tools" {
            inherit (pkgs) nixpkgs-fmt gcc pkg-config;
            dbus = pkgs.dbus.dev;
            dbus-interfaces = "${pkgs.buildPackages.systemd}/share/dbus-1/interfaces";
            rust = devToolchain;
          };
        };

        apps.default = flake-utils.lib.mkApp {
          drv = switch-to-configuration;
        };

        devShells.default = craneLibDev.devShell
          {
            # Inherit inputs from checks.
            checks = self.checks.${system};

            # Additional dev-shell environment variables can be set directly
            # MY_CUSTOM_DEVELOPMENT_VAR = "something else";
            RUST_SRC_PATH = "${devToolchain}/lib/rustlib/src/rust/library";

            # Extra inputs can be added here; cargo and rustc are provided by default.
            packages = [
              # pkgs.ripgrep
            ];
          } // envVars;
      })
    );
}
