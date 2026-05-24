{
  description = "A Nix-flake-based Node.js development environment";

  inputs.nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1"; # unstable Nixpkgs
  inputs.fenix = {
    url = "https://flakehub.com/f/nix-community/fenix/0.1";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, ... }@inputs:

    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSupportedSystem =
        f:
        inputs.nixpkgs.lib.genAttrs supportedSystems (
          system:
          f {
            pkgs = import inputs.nixpkgs {
              inherit system;
              overlays = [ inputs.self.overlays.default ];
            };
          }
        );
    in
    {
      overlays.default = final: prev: rec {
        nodejs = prev.nodejs;
        # rustToolchain =
          # with inputs.fenix.packages.${prev.stdenv.hostPlatform.system};
          # combine (
            # with stable;
            # [
              # clippy
              # rustc
              # cargo
              # rustfmt
              # rust-src
            # ]
          # );
      };

      devShells = forEachSupportedSystem (
        { pkgs }:
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              tree-sitter
              pcre2
            ];
            packages = with pkgs; [
              nodejs
              pnpm
              openssl
              pkg-config
              zig_0_15
              zls
              just
              python3
              wasmtime

              actionlint
              act
            ];
          };
        }
      );
    };
}
