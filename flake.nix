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
        let
        treeSitterGrammar =
          grammar:
          let src = pkgs.tree-sitter-grammars."tree-sitter-${grammar}".src;
          in
          {
            "TS_${pkgs.lib.toUpper grammar}" =
              if grammar == "typescript" then "${src}/typescript"
              else if grammar == "tsx" then "${src}/tsx"
              else src;
          };
        in
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              tree-sitter
            ];
            packages = with pkgs; [
              node2nix
              nodejs
              nodePackages.pnpm
              openssl
              pkg-config
            ];
            env = { }
            // treeSitterGrammar "bash"
            // treeSitterGrammar "c"
            // treeSitterGrammar "cpp"
            // treeSitterGrammar "css"
            // treeSitterGrammar "go"
            // treeSitterGrammar "haskell"
            // treeSitterGrammar "java"
            // treeSitterGrammar "javascript"
            // treeSitterGrammar "json"
            // treeSitterGrammar "python"
            // treeSitterGrammar "rust"
            // treeSitterGrammar "tsx"
            // treeSitterGrammar "typescript"
            ;
          };
        }
      );
    };
}
