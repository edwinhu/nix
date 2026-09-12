# Which package layers each host profile gets. THE source of truth: both
# package lists (shared/packages.nix, linux/omarchy-packages.nix) and the
# modules that gate services on a layer read this file, so a host cannot get a
# tool from one and the config for it from the other.
#
# Layers are declared here even when only one of the two package files defines
# entries for them (`mail` and `desktop` are Linux-only today); a package file
# contributes whatever subset it has and asserts it declares nothing else.
rec {
  layerNames = [
    "core"     # shell, files, search, VCS, secrets — every host
    "ai"       # the LLM CLIs and what installs them
    "dev"      # compilers, language servers, linters
    "cloud"    # cloud SDKs and remote storage
    "data"     # data science and tabular work
    "docs"     # typesetting, publishing, document conversion, previewers
    "pkm"      # personal knowledge management and research CLIs
    "media"    # chat, streaming, audio, terminals
    "desktop"  # GUI automation, file managers, fonts, theming
    "mail"     # the aerc/himalaya stack (Linux only)
  ];

  profiles = {
    # The main machine (omarchy) and the Macs.
    full = layerNames;

    # A box that drives the LLM CLIs and `herdr --remote` into the main
    # machine, but is still a laptop someone reads and writes on: it keeps the
    # desktop apps and the publishing stack, and gives up the mail stack and
    # the build/cloud/data toolchains that belong on the main machine.
    client = [ "core" "ai" "docs" "pkm" "media" "desktop" ];

    # Headless. Builds and serves; also renders documents. No mail, no desktop
    # apps, no theming.
    server = [ "core" "ai" "dev" "cloud" "data" "docs" ];
  };

  # `has "server" "docs"` -> true. Throws on an unknown profile rather than
  # silently answering false for every layer.
  has = profile: layer:
    let sel = profiles.${profile} or (throw
      "unknown profile '${profile}'; known: ${builtins.concatStringsSep ", " (builtins.attrNames profiles)}");
    in builtins.elem layer sel;

  layersFor = profile: profiles.${profile} or (throw
    "unknown profile '${profile}'; known: ${builtins.concatStringsSep ", " (builtins.attrNames profiles)}");
}
