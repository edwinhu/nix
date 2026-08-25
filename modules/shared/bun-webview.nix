# bun-webview — the shared Bun.WebView helper, installed as source.
#
# A copy, not a build. The library has zero runtime dependencies, so there is no
# `bun install` to run and none of the fixed-output node_modules dance
# mail-bridge needs; and consumers import the TypeScript directly under bun, so
# there is nothing to compile either. The shape follows onlyoffice-x2t: a
# derivation that installs a tree under $out/lib rather than a binary.
#
# Consumers point BUN_WEBVIEW_LIB at $out/lib/bun-webview and import
# index.ts from there.
{
  lib,
  stdenvNoCC,
  bun,
}:
stdenvNoCC.mkDerivation {
  pname = "bun-webview";
  version = "0.1.0";

  # An explicit fileset rather than the whole directory: index.test.ts is
  # repo-only. Shipping it would drag `bun:test` and the fixture server into
  # what consumers import, and the store path would churn on every test edit.
  src = lib.fileset.toSource {
    root = ./bun-webview;
    fileset = lib.fileset.unions [
      ./bun-webview/index.ts
      ./bun-webview/package.json
      ./bun-webview/tsconfig.json
    ];
  };

  nativeBuildInputs = [ bun ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/bun-webview
    install -Dm644 index.ts package.json tsconfig.json -t $out/lib/bun-webview
    runHook postInstall
  '';

  # Artifact-level proof, the repo's convention (see mail-bridge.nix): nothing
  # that merely reads the files shows that bun can resolve and load them.
  #
  # The check runs from $TMPDIR, never the source tree, because every consumer
  # imports by absolute store path from an unrelated cwd — an import that only
  # worked in-tree would pass a weaker test than the one that matters.
  #
  # It asserts resolveChromium THROWS. The build sandbox has no browser on PATH
  # (chromium is the Arch system package, deliberately not packaged here), so
  # the failure path is the only one observable in a sandbox — and the message
  # naming all four candidates is the part a user actually reads.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    export HOME=$TMPDIR
    probe=$TMPDIR/probe
    mkdir -p $probe
    cat > $probe/probe.ts <<PROBE
    const mod = await import("$out/lib/bun-webview/index.ts");
    for (const name of ["resolveChromium", "openView", "attachView", "listTargets", "waitFor", "renderHtmlToPng"]) {
      if (typeof (mod as any)[name] !== "function") throw new Error("missing export: " + name);
    }
    let message = "";
    try {
      mod.resolveChromium();
      throw new Error("resolveChromium resolved a browser inside the build sandbox");
    } catch (err) {
      message = String((err as Error).message);
    }
    if (message.includes("resolved a browser inside")) throw new Error(message);
    for (const candidate of ["chromium", "chromium-browser", "google-chrome-stable", "chrome"]) {
      if (!message.includes(candidate)) {
        throw new Error("resolveChromium's error does not name " + candidate + ": " + message);
      }
    }
    console.log("bun-webview: imports; resolveChromium reports -- " + message);
    PROBE

    ( cd $probe && bun $probe/probe.ts )

    runHook postInstallCheck
  '';

  meta = {
    description = "Shared Bun.WebView helpers for driving headless Chrome from bun scripts";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
