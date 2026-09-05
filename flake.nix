{
  description = "TQL - tree query language";

  inputs = {
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    devenv.url = "github:cachix/devenv";
    zig-overlay.url = "github:mitchellh/zig-overlay";
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

      mkArgs = pkgs: {
        inherit inputs pkgs;
        modules = [ ./devenv.nix ];
      };
    in
    {
      devShells = forAllSystems (_system: pkgs: {
        default = devenv.lib.mkShell (mkArgs pkgs);
      });

      packages = forAllSystems (_system: pkgs:
        let outputs = (devenv.lib.mkConfig (mkArgs pkgs)).outputs;
        in {
          default = outputs.tql;
          inherit (outputs) tql tql-wasm tql-wasm-grammars tql-wasm-assets tql-js
            tql-playground;
        });

      apps = forAllSystems (system: _pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/tql";
        };
      });
    };
}
