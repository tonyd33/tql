{
  lib,
  buildGoModule,
  fetchFromGitHub,
  makeWrapper,
  go,
}:

buildGoModule (finalAttrs: {
  pname = "ruleguard";
  version = "0.4.5";

  src = fetchFromGitHub {
    owner = "quasilyte";
    repo = "go-ruleguard";
    rev = "v${finalAttrs.version}";
    hash = "sha256-xHzFk68tntClPdX5rZAL9i+utIWhJ0//eKl4GBFb/Kg=";
  };

  vendorHash = "sha256-DBdi4+LoOp6+PHnb7Cul3UsxuT2yhkoZZooVY4iJfto=";

  subPackages = [ "cmd/ruleguard" ];
  doCheck = false;
  allowGoReference = true;

  nativeBuildInputs = [ makeWrapper ];
  postInstall = ''
    wrapProgram $out/bin/ruleguard --suffix PATH : ${lib.makeBinPath [ go ]}
  '';

  meta = {
    description = "Go linter driven by gogrep-based rules written in a Go DSL";
    homepage = "https://github.com/quasilyte/go-ruleguard";
    mainProgram = "ruleguard";
  };
})
