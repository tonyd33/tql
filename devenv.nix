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
  # https://devenv.sh/basics/
  # env.GREET = "devenv";

  # https://devenv.sh/overlays/
  overlays = [ (import ./overlays/gritql.nix) ];

  # https://devenv.sh/packages/
  packages = lib.flatten (lib.attrValues package_groups);

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

  # https://devenv.sh/processes/
  # processes.dev.exec = "${lib.getExe pkgs.watchexec} -n -- ls -la";

  # https://devenv.sh/services/
  # services.postgres.enable = true;

  # https://devenv.sh/scripts/
  # scripts.hello.exec = ''
  #   echo hello from $GREET
  # '';

  # https://devenv.sh/basics/
  # enterShell = ''
  #   hello         # Run scripts directly
  #   git --version # Use packages
  # '';

  # https://devenv.sh/tasks/
  # tasks = {
  #   "myproj:setup".exec = "mytool build";
  #   "devenv:enterShell".after = [ "myproj:setup" ];
  # };

  # https://devenv.sh/tests/
  # enterTest = ''
  #   echo "Running tests"
  #   git --version | grep --color=auto "${pkgs.git.version}"
  # '';

  # https://devenv.sh/git-hooks/
  # git-hooks.hooks.shellcheck.enable = true;

  # See full reference at https://devenv.sh/reference/options/
}
