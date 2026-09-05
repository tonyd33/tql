{ pkgs, lib, config, inputs, ... }:

let
  version = "0.2.1";

  zigDeps = pkgs.zig.fetchDeps {
    pname = "tql";
    inherit version;
    src = ./packages/tql-engine-zig;
    hash = "sha256-fuKXm9wavDlI+5Q1yEhyCnVpaohbvyEukQNnkE8873A=";
  };

  # Every engine artifact comes from the same source tree and dependency set;
  # only the build step and what it installs differ.
  mkEngine =
    { pname
    , zigBuildFlags
    , doCheck ? false
    , description
    , mainProgram ? null
    , installPhase ? null
    }:
    pkgs.stdenv.mkDerivation {
      inherit pname version doCheck;

      src = ./.;
      setSourceRoot = ''
        sourceRoot=$(echo */packages/tql-engine-zig)
      '';

      nativeBuildInputs = [ pkgs.zig.hook ];

      postConfigure = ''
        cp -rLT ${zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
        chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR/p"
      '';

      inherit zigBuildFlags;
      zigCheckFlags = [ "test" ];

      ${if installPhase != null then "installPhase" else null} = installPhase;

      meta = {
        inherit description;
        homepage = "https://github.com/tonyd33/tql";
        license = lib.licenses.mit;
        platforms = lib.platforms.unix;
      } // lib.optionalAttrs (mainProgram != null) { inherit mainProgram; };
    };

  tql-cli = mkEngine {
    pname = "tql";
    zigBuildFlags = [ "-Doptimize=ReleaseFast" "-Dgrammars=available" ];
    doCheck = true;
    description = "Tree query language";
    mainProgram = "tql";
  };

  tql-wasm = mkEngine {
    pname = "tql-wasm";
    zigBuildFlags = [ "wasm" "-Dgrammars=none" ];
    description = "Tree query language engine, as WebAssembly";
    installPhase = ''
      runHook preInstall
      install -Dm444 zig-out/bin/tql.wasm "$out/tql.wasm"
      runHook postInstall
    '';
  };

  tql-wasm-grammars = mkEngine {
    pname = "tql-wasm-grammars";
    zigBuildFlags = [ "wasm-grammars" ];
    description = "Tree-sitter grammars as WebAssembly side modules";
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      install -Dm444 zig-out/wasm-grammars/*.wasm -t "$out"
      runHook postInstall
    '';
  };

  tql-wasm-assets = pkgs.symlinkJoin {
    name = "tql-wasm-assets";
    paths = [ tql-wasm tql-wasm-grammars ];
  };

  # Both JS packages install from the same pnpm workspace lockfile, so they
  # share a dependency set.
  mkPnpmDeps = { pname, version, src }: pkgs.fetchPnpmDeps {
    inherit pname version src;
    pnpm = pkgs.pnpm_10;
    fetcherVersion = 3;
    hash = "sha256-pqFjya865PkAyMqMuRSAOaPKcs16Bo8IxFJoYoyyfYg=";
  };

  jsNativeBuildInputs = [
    pkgs.nodejs
    pkgs.pnpm_10
    (pkgs.pnpmConfigHook.override { pnpm = pkgs.pnpm_10; })
  ];

  tql-js = pkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "tql-js";
    version = "1.0.0";

    src = ./.;

    nativeBuildInputs = jsNativeBuildInputs;

    pnpmDeps = mkPnpmDeps { inherit (finalAttrs) pname version src; };

    buildPhase = ''
      runHook preBuild
      pnpm --filter tql run build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -r packages/tql-js/dist "$out/dist"
      install -Dm444 packages/tql-js/package.json "$out/package.json"
      runHook postInstall
    '';

    meta = {
      description = "Tree query language, JavaScript bindings";
      homepage = "https://github.com/tonyd33/tql";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
  });

  mkPlayground = { basePath ? "" }: pkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "tql-playground";
    version = "0.0.1";

    src = ./.;

    nativeBuildInputs = jsNativeBuildInputs;

    pnpmDeps = mkPnpmDeps { inherit (finalAttrs) pname version src; };

    # The engine wasm and the per-grammar side modules are fetched at runtime
    # from the site root, so they have to be in static/ before vite builds.
    preBuild = ''
      install -m644 ${tql-wasm-assets}/*.wasm packages/playground/static/
    '';

    env.BASE_PATH = basePath;

    buildPhase = ''
      runHook preBuild
      pnpm --filter tql run build
      pnpm --filter @tql/playground run build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp -r packages/playground/build "$out"
      runHook postInstall
    '';

    meta = {
      description = "Tree query language playground";
      homepage = "https://github.com/tonyd33/tql";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
  });

  tql-playground = mkPlayground { };

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
  outputs = {
    tql = tql-cli;
    inherit tql-wasm tql-wasm-grammars tql-wasm-assets tql-js tql-playground;
  };

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
