{ pkgs, lib, config, inputs, ... }:

let
  package_groups = {
    essential = with pkgs; [
      git
      jq
      go-task
      wasmtime
      python3
    ];
    query_languages = with pkgs; [
      semgrep
      ast-grep
      gritql
    ];
  };
in
{
  # https://devenv.sh/overlays/
  overlays = [ (import ./overlays/gritql.nix) ];

  # https://devenv.sh/packages/
  packages = lib.flatten (lib.attrValues package_groups);

  # https://devenv.sh/outputs/
  outputs.tql = pkgs.stdenv.mkDerivation (finalAttrs: {
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
      "-Doptimize=ReleaseFast"
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

  # https://devenv.sh/languages/
  languages = {
    zig = {
      enable = true;
      # version = "0.16.0";
      lsp.enable = true;
    };
    javascript = {
      enable = true;
      package = pkgs.nodejs-slim_22;

      lsp.enable = true;
      nodejs.enable = true;
      npm.enable = false;
      pnpm.enable = true;
    };
  };

  cachix = {
    enable = true;
    pull = [ "devenv" "tql" ];
  };

  # https://devenv.sh/git-hooks/
  git-hooks.hooks = {
    nixpkgs-fmt.enable = true;
    actionlint.enable = true;
    # zizmor.enable = true;

    zig-fmt = {
      enable = true;
      name = "zig fmt";
      entry = "${lib.getExe config.languages.zig.package} fmt --check";
      files = "\\.zig$";
    };

  };

  # See full reference at https://devenv.sh/reference/options/
}
