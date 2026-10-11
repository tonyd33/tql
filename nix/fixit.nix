{
  buildPythonPackage,
  fetchPypi,
  hatchling,
  hatch-vcs,
  click,
  libcst,
  moreorless,
  packaging,
  tomli,
  trailrunner,
}:

buildPythonPackage rec {
  pname = "fixit";
  version = "2.2.1";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-mPfjC+CDtAAv3o2keubYF+TdF09nW4SFd9Ok9uDISVQ=";
  };

  build-system = [
    hatchling
    hatch-vcs
  ];

  dependencies = [
    click
    libcst
    moreorless
    packaging
    tomli
    trailrunner
  ];

  pythonRelaxDeps = true;
  pythonImportsCheck = [ "fixit" ];
}
