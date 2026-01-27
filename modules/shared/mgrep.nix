# mgrep - Semantic grep using Mixedbread embeddings
# Built from pnpm source
{
  lib,
  stdenv,
  fetchFromGitHub,
  nodejs,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm,
  npmHooks,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "mgrep";
  version = "0.1.10";

  src = fetchFromGitHub {
    owner = "mixedbread-ai";
    repo = "mgrep";
    tag = "v${finalAttrs.version}";
    hash = "sha256-Njs0h2Roqm9xK8TV7BqrR5EwpK+ONNl3ct1fHU0UZEY=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    fetcherVersion = 2;
    hash = "sha256-qNsYMp25OAbbv+K7qvNRB+7QzzrgtrKQkUoe9IMIR5c=";
  };

  nativeBuildInputs = [
    nodejs
    pnpmConfigHook
    pnpm
    npmHooks.npmInstallHook
  ];

  buildPhase = ''
    runHook preBuild
    pnpm build
    runHook postBuild
  '';

  dontNpmPrune = true;

  meta = {
    description = "Semantic grep for local files using Mixedbread embeddings";
    homepage = "https://github.com/mixedbread-ai/mgrep";
    changelog = "https://github.com/mixedbread-ai/mgrep/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.asl20;
    mainProgram = "mgrep";
  };
})
