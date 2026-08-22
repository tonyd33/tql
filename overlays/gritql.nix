final: prev: {
  gritql = prev.rustPlatform.buildRustPackage {
    pname = "gritql";
    version = "unstable-2026-08-15";

    src = prev.fetchFromGitHub {
      owner = "biomejs";
      repo = "gritql";
      rev = "c80b3026471b229f41b279c3eb0c162dcdacfdb1";
      fetchSubmodules = true;
      hash = "sha256-0JAymeEgbBmWEsTDY/JIFEBoJzuimi9jmdfwZamSF+Y=";
    };

    cargoLock = {
      lockFile = "${prev.fetchFromGitHub {
        owner = "biomejs";
        repo = "gritql";
        rev = "c80b3026471b229f41b279c3eb0c162dcdacfdb1";
        fetchSubmodules = true;
        hash = "sha256-0JAymeEgbBmWEsTDY/JIFEBoJzuimi9jmdfwZamSF+Y=";
      }}/Cargo.lock";
      outputHashes = {
        "ai_builtins-0.1.0" = "sha256-gw6gYqjBdm3zYzR21J7uJ+gCksYEkMsb4i5JEnD6wY0=";
        "biome_console-0.5.7" = "sha256-Eq1Lml72wS9+Oo7CPtfAGNFMy54HZ3bMjFtS/GXLYUE=";
        "clap-markdown-0.1.3" = "sha256-Lvu9GMA/pXdDobL65JhaDvvet5gX9PbYARpcSmk0n8A=";
        "cli_server-0.1.0" = "sha256-UaEFexhfsps7TAEf+Xs7Kclx5Hwf0hwHsHu+kRQo/Oc=";
        "embeddings-0.1.0" = "sha256-8nXG8k1xKf7Wc4aBlho6qFT96xpyp6I8D4NNrlGJRuE=";
        "grit_cloud_client-0.1.0" = "sha256-CbjOYs9irLkSEKqDmFyhHkum1ormhPygwBY0UyspM5Y=";
      };
    };

    buildAndTestSubdir = "crates/cli_bin";
    buildNoDefaultFeatures = true;

    nativeBuildInputs = [ prev.pkg-config prev.perl ];
    buildInputs = [ prev.openssl ] ++ prev.lib.optionals prev.stdenv.isDarwin [
      prev.darwin.apple_sdk.frameworks.Security
      prev.darwin.apple_sdk.frameworks.SystemConfiguration
    ];

    OPENSSL_NO_VENDOR = 1;
    doCheck = false;

    meta = {
      description = "GritQL query language CLI";
      homepage = "https://github.com/biomejs/gritql";
      mainProgram = "grit";
    };
  };
}
