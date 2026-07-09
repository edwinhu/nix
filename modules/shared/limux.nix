# Limux — GPU-accelerated terminal workspace manager (Ghostty-powered, cmux port).
#
# Upstream (am-will/limux) ships only x86_64 prebuilt artifacts and has no
# flake, so this builds it from source for any platform (notably aarch64-linux):
#
#   1. `libghostty` — the fork's vendored Ghostty submodule built with
#      `-Dapp-runtime=none`, which emits `libghostty.so` (the C API library the
#      Rust host links against) instead of the GTK terminal app.
#   2. `limux` — the Cargo workspace, linking libghostty + GTK4/libadwaita/
#      WebKitGTK. Installs the public `limux` CLI to bin/ and the private GTK
#      host to libexec/, matching the layout the CLI/host expect at runtime
#      (they resolve siblings and `share/limux/ghostty` by walking exe ancestors).
#
# The Ghostty fork's `build.zig.zon` has the identical set of direct dependency
# hashes as nixpkgs' ghostty 1.3.1, so we reuse nixpkgs' generated `deps.nix`
# (the vendored Zig-dependency cache) rather than regenerating it.
{
  lib,
  stdenv,
  fetchFromGitHub,
  rustPlatform,
  callPackage,
  path,
  zig_0_15,
  pkg-config,
  pandoc,
  ncurses,
  wrapGAppsHook4,
  gobject-introspection,
  autoPatchelfHook,
  ghostty,
  glib,
  gsettings-desktop-schemas,
  gtk4,
  libadwaita,
  webkitgtk_6_0,
  libepoxy,
  libGL,
  fontconfig,
  freetype,
  harfbuzz,
  oniguruma,
  glslang,
  bzip2,
  zlib,
  librsvg,
  gdk-pixbuf,
}:
let
  version = "0.1.21";

  src = fetchFromGitHub {
    owner = "am-will";
    repo = "limux";
    rev = "v${version}";
    fetchSubmodules = true;
    hash = "sha256-JF5fh94IxpD1v0fnHHG7wHP7i0cUshwZ482YXjfrVWs=";
  };

  # Vendored Zig-dependency cache, reused from nixpkgs' ghostty package.
  ghosttyDeps = callPackage (path + "/pkgs/by-name/gh/ghostty/deps.nix") {
    name = "limux-ghostty-cache-${version}";
  };

  # libghostty.so, built from the fork's Ghostty submodule with app-runtime=none.
  libghostty = stdenv.mkDerivation {
    pname = "limux-libghostty";
    inherit version src;

    # Build inside the ghostty submodule rather than the workspace root.
    postUnpack = "sourceRoot=$sourceRoot/ghostty";

    nativeBuildInputs = [
      zig_0_15
      pkg-config
      pandoc
      ncurses
    ];

    buildInputs = [
      oniguruma
      glslang
      libGL
      libepoxy
      bzip2
      zlib
      fontconfig
      freetype
      harfbuzz
    ];

    dontConfigure = true;
    dontSetZigDefaultFlags = true;

    # `dontConfigure` skips the zig hook's cache-dir setup; set it ourselves.
    preBuild = ''
      export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    '';

    zigBuildFlags = [
      "--system"
      "${ghosttyDeps}"
      "-Dcpu=baseline"
      "-Dapp-runtime=none"
      "-Doptimize=ReleaseFast"
      "-Dversion-string=1.3.0-dev"
    ];

    doCheck = false;

    meta.description = "libghostty.so for Limux (Ghostty fork, app-runtime=none)";
  };
in
rustPlatform.buildRustPackage {
  pname = "limux";
  inherit version src;

  cargoLock.lockFile = ./limux-Cargo.lock;

  # One dispatcher test spawns a live ghostty surface + Python and asserts on a
  # dump file; it can't run in the hermetic sandbox. The workspace otherwise
  # passes, so skip the runtime-dependent check phase.
  doCheck = false;

  nativeBuildInputs = [
    pkg-config
    wrapGAppsHook4
    gobject-introspection
    autoPatchelfHook
  ];

  buildInputs = [
    glib
    gsettings-desktop-schemas
    gtk4
    libadwaita
    webkitgtk_6_0
    libepoxy
    libGL
    fontconfig
    freetype
    harfbuzz
    oniguruma
    bzip2
    zlib
    librsvg
    gdk-pixbuf
  ];

  # The glad GL loader is compiled by ghostty-sys into a static lib, but the
  # symbols it defines (gladLoaderLoad/UnloadGLContext) are referenced only by
  # the *shared* libghostty.so. Under Nix's --gc-sections/--as-needed link
  # hardening those archive members are dropped before they satisfy the shared
  # lib's undefined refs, so force glad in with +whole-archive.
  postPatch = ''
    substituteInPlace rust/limux-ghostty-sys/build.rs \
      --replace-fail '.compile("glad");' \
      '.cargo_metadata(false).compile("glad"); println!("cargo:rustc-link-search=native={}", std::env::var("OUT_DIR").unwrap()); println!("cargo:rustc-link-lib=static:+whole-archive=glad");'
  '';

  # The ghostty-sys build script links against ghostty/zig-out/lib/libghostty.so
  # and compiles the vendored glad GL loader from the ghostty submodule tree.
  preBuild = ''
    mkdir -p ghostty/zig-out/lib
    install -m644 ${libghostty}/lib/libghostty.so ghostty/zig-out/lib/libghostty.so
  '';

  # Resolve libghostty.so from its installed location at runtime.
  appendRunpaths = [ "${placeholder "out"}/lib/limux" ];

  postInstall = ''
    # Cargo produces `limux` (the GTK host, from limux-host-linux) and
    # `limux-cli`. Install them into the layout the runtime expects: the public
    # CLI as bin/limux, the private host as libexec/limux/limux-host.
    install -Dm755 $out/bin/limux $out/libexec/limux/limux-host
    rm $out/bin/limux
    mv $out/bin/limux-cli $out/bin/limux

    # Drop extra workspace artifacts upstream's packaging does not ship.
    rm -f $out/bin/limux-control-server $out/lib/liblimux_control.a

    # libghostty next to a private ld path (see appendRunpaths).
    install -Dm644 ${libghostty}/lib/libghostty.so $out/lib/limux/libghostty.so

    # Ghostty runtime resources (themes, shell integration) + terminfo, taken
    # from nixpkgs' ghostty since app-runtime=none does not emit them.
    mkdir -p $out/share/limux/ghostty $out/share/limux/terminfo
    cp -r ${ghostty}/share/ghostty/. $out/share/limux/ghostty/
    cp -r ${ghostty.terminfo}/share/terminfo/. $out/share/limux/terminfo/

    # Desktop entry, metadata, and icons.
    install -Dm644 rust/limux-host-linux/dev.limux.linux.desktop \
      $out/share/applications/dev.limux.linux.desktop
    substituteInPlace $out/share/applications/dev.limux.linux.desktop \
      --replace-warn "Exec=limux" "Exec=$out/bin/limux" \
      --replace-warn "TryExec=limux" "TryExec=$out/bin/limux"
    install -Dm644 rust/limux-host-linux/dev.limux.linux.metainfo.xml \
      $out/share/metainfo/dev.limux.linux.metainfo.xml

    icons=rust/limux-host-linux/icons
    if [ -d "$icons/hicolor/scalable" ]; then
      mkdir -p $out/share/icons/hicolor/scalable
      cp -r "$icons/hicolor/scalable" $out/share/icons/hicolor/
    fi
    mkdir -p $out/share/icons/hicolor/scalable/actions
    for svg in "$icons"/*.svg; do
      [ -f "$svg" ] && install -Dm644 "$svg" \
        "$out/share/icons/hicolor/scalable/actions/$(basename "$svg")"
    done
    for size in 16 32 128 256 512; do
      if [ -f "$icons/app/$size.png" ]; then
        install -Dm644 "$icons/app/$size.png" \
          "$out/share/icons/hicolor/''${size}x''${size}/apps/limux.png"
      fi
    done
  '';

  # wrapGAppsHook4 must also wrap the host binary living under libexec.
  # (It wraps $out/bin and $out/libexec by default.)

  passthru = { inherit libghostty; };

  meta = {
    description = "GPU-accelerated terminal workspace manager for Linux, powered by Ghostty";
    homepage = "https://github.com/am-will/limux";
    license = lib.licenses.mit;
    mainProgram = "limux";
    platforms = lib.platforms.linux;
  };
}
