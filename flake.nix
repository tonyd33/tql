{
  description = "TQL - tree query language";

  inputs = {
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    devenv.url = "github:cachix/devenv";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, devenv, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f system nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (_system: pkgs: {
        default = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "tql";
          version = "0.2.1";

          src = ./.;
          setSourceRoot = ''
            sourceRoot=$(echo */packages/tql-engine-zig)
          '';

          nativeBuildInputs = [ pkgs.zig.hook ];

          postConfigure = ''
            cp -rLT ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
            chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR/p"
          '';

          zigBuildFlags = [
            "-Doptimize=ReleaseSafe"
            "-Dgrammars=available"
          ];

          zigDeps = pkgs.zig.fetchDeps {
            inherit (finalAttrs) pname version;
            src = ./packages/tql-engine-zig;
            hash = "sha256-PxRmXwRAbbRDtx2Mm8SPIRC36Wdq5Q485E0EXazoFqU=";
          };

          doCheck = true;
          zigCheckFlags = [ "test" ];

          meta = {
            description = "Tree query language";
            homepage = "https://github.com/tonyd33/tql";
            license = pkgs.lib.licenses.mit;
            mainProgram = "tql";
            platforms = pkgs.lib.platforms.unix;
          };
        });
      });

      apps = forAllSystems (system: _pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/tql";
        };
      });

      devShells = forAllSystems (_system: pkgs: {
        default = devenv.lib.mkShell {
          inherit inputs pkgs;
          modules = [ ./devenv.nix ];
        };
      });
    };
}
