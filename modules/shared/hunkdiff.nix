# hunkdiff - Review-first terminal diff viewer for agentic coders
# Pre-bundled npm package from https://github.com/modem-dev/hunk
{ lib, buildNpmPackage, fetchurl, stdenv }:

let
  version = "0.10.0";

  # Map nix platform to hunkdiff platform binary package
  platformPkg = {
    "x86_64-linux" = {
      name = "hunkdiff-linux-x64";
      hash = "sha256-ICkeeCq8X7czMDtVBH3P5lPDhSrgueZMeQb0QwTcfSA=";
    };
    "aarch64-linux" = {
      name = "hunkdiff-linux-arm64";
      hash = "sha256-PLACEHOLDER";
    };
    "aarch64-darwin" = {
      name = "hunkdiff-darwin-arm64";
      hash = "sha256-PLACEHOLDER";
    };
    "x86_64-darwin" = {
      name = "hunkdiff-darwin-x64";
      hash = "sha256-PLACEHOLDER";
    };
  }.${stdenv.hostPlatform.system} or (throw "Unsupported platform for hunkdiff: ${stdenv.hostPlatform.system}");

  platformBin = fetchurl {
    url = "https://registry.npmjs.org/${platformPkg.name}/-/${platformPkg.name}-${version}.tgz";
    hash = platformPkg.hash;
  };
in
buildNpmPackage rec {
  pname = "hunkdiff";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/hunkdiff/-/hunkdiff-${version}.tgz";
    hash = "sha256-wOp9cLyfE6PM+KLhxp8v1NOuGQ4Y+RygHIGdBdqTthY=";
  };

  postPatch = ''
    # Remove optionalDependencies (platform-specific native binaries are placed
    # manually below) so npm ci doesn't complain about lock mismatch
    node -e "
      const fs = require('fs');
      const pkg = JSON.parse(fs.readFileSync('package.json','utf8'));
      delete pkg.optionalDependencies;
      fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2));
    "

    cat > package-lock.json <<'LOCKFILE'
    {
      "name": "hunkdiff",
      "version": "0.10.0",
      "lockfileVersion": 3,
      "requires": true,
      "packages": {
        "": {
          "name": "hunkdiff",
          "version": "0.10.0"
        }
      }
    }
    LOCKFILE
  '';

  npmDepsHash = "sha256-ipf9A4HXsN+/CHwstDhZLZxpOWozeZpBeP37qD9j43M=";
  forceEmptyCache = true;

  dontNpmBuild = true;
  dontNpmInstall = true;

  installPhase = ''
    runHook preInstall

    # Install the main package into node_modules layout
    mkdir -p $out/lib/node_modules/hunkdiff $out/bin
    cp -r . $out/lib/node_modules/hunkdiff/

    # Unpack platform-specific binary into the node_modules tree where
    # hunk.cjs findInstalledBinary() will discover it
    mkdir -p $out/lib/node_modules/${platformPkg.name}
    tar xzf ${platformBin} --strip-components=1 -C $out/lib/node_modules/${platformPkg.name}
    chmod +x $out/lib/node_modules/${platformPkg.name}/bin/hunk

    # Symlink the launcher
    ln -s $out/lib/node_modules/hunkdiff/bin/hunk.cjs $out/bin/hunk
    chmod +x $out/lib/node_modules/hunkdiff/bin/hunk.cjs

    runHook postInstall
  '';

  meta = {
    description = "Review-first terminal diff viewer for agentic coders";
    homepage = "https://github.com/modem-dev/hunk";
    license = lib.licenses.mit;
    mainProgram = "hunk";
  };
}
