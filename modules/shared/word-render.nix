# word-render — faithful docx -> PDF through the REAL Microsoft Word engine
# running in a QEMU Windows guest, driven over SSH.
#
# Why Word and not LibreOffice/x2t: only Word recomputes fields
# (REF/NOTEREF/PAGEREF/TOC) across every story faithfully. This is the portable
# replacement for the macOS-Word GUI path in ~/projects/workflows (which dies on
# Linux) — the transport is SSH so the exact same host scripts survive the
# Mac (Win11 ARM guest) -> Linux (Win11 x64 + KVM guest) hypervisor change.
# Only the SSH target differs between environments.
#
# This module ships the HOST side: QEMU + swtpm, the render scripts, AND the full
# VM provisioning kit (./word-render/vm/) — launcher, unattended-install answer
# file, and guest bootstrap — so a fresh machine can rebuild the guest from an
# ISO with `word-render-provision`. The genuinely manual bits Nix can't do (the
# Win11 ISO download, the ~20-min install, optional Office activation) are
# documented in ./word-render/README.md.
#
# Enable per host, e.g. in modules/darwin/home-manager.nix or a Linux host:
#   programs.wordRender.enable = true;
#   programs.wordRender.sshTarget = "word@192.168.64.7";  # optional override
{ config, pkgs, lib, ... }:

let
  cfg = config.programs.wordRender;
in
{
  options.programs.wordRender = {
    enable = lib.mkEnableOption
      "faithful docx->PDF rendering via Microsoft Word in a QEMU Windows guest";

    sshTarget = lib.mkOption {
      type = lib.types.str;
      default = "word@winvm";
      example = "word@192.168.64.7";
      description = ''
        SSH target (user@host) of the Windows guest running OpenSSH Server.
        This is the ONE value that differs per environment. Keep the default
        and add a `Host winvm` block to ~/.ssh/config so the alias resolves to
        the right address on each machine, or override this option per host.
      '';
    };

    guestDir = lib.mkOption {
      type = lib.types.str;
      default = "C:/Users/word/render";
      description = "Scratch directory inside the guest for docx/pdf transfer.";
    };

    guestScript = lib.mkOption {
      type = lib.types.str;
      default = "C:/Users/word/render_docx.ps1";
      description = "Path to render_docx.ps1 as dropped inside the guest.";
    };
  };

  config = lib.mkIf cfg.enable {
    # QEMU runs the Win11 guest (HVF on aarch64-darwin, KVM on x86_64-linux);
    # swtpm provides the TPM 2.0 Win11 requires. On Linux, xorriso builds the
    # unattend ISO (macOS uses the system `hdiutil`).
    home.packages = [ pkgs.qemu pkgs.swtpm ]
      ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.xorriso ];

    # Adopted scripts land at stable paths on any machine.
    #  - render_docx.ps1 is the GUEST-side renderer; kept here so the setup doc
    #    can copy it into the guest, and so it's version-controlled with the host
    #    wrapper it pairs with.
    #  - word_render_remote.sh is the HOST-side transport (scp in / ssh render /
    #    scp out), used verbatim; the `word-render` launcher below feeds it the
    #    per-host defaults from the options above.
    home.file.".local/share/word-render/render_docx.ps1".source =
      ./word-render/render_docx.ps1;

    home.file.".local/share/word-render/word_render_remote.sh" = {
      source = ./word-render/word_render_remote.sh;
      executable = true;
    };

    # VM provisioning kit — the host scripts that stand up / boot / drive the
    # Windows guest, plus the unattended-install automation. Deployed to stable
    # paths so a fresh machine can rebuild the guest from an ISO. See
    # ./word-render/README.md and ./word-render/vm/provision.sh.
    home.file.".local/share/word-render/vm/start-winvm.sh"   = { source = ./word-render/vm/start-winvm.sh;   executable = true; };
    home.file.".local/share/word-render/vm/start-tpm.sh"     = { source = ./word-render/vm/start-tpm.sh;     executable = true; };
    home.file.".local/share/word-render/vm/typer.sh"         = { source = ./word-render/vm/typer.sh;         executable = true; };
    home.file.".local/share/word-render/vm/provision.sh"     = { source = ./word-render/vm/provision.sh;     executable = true; };
    home.file.".local/share/word-render/vm/guest-setup.ps1".source  = ./word-render/vm/guest-setup.ps1;
    home.file.".local/share/word-render/vm/autounattend.xml".source = ./word-render/vm/autounattend.xml;

    # Launcher on PATH: word-render-provision (one-time host setup for the guest).
    home.file.".local/bin/word-render-provision" = {
      executable = true;
      text = ''
        #!/usr/bin/env bash
        exec "$HOME/.local/share/word-render/vm/provision.sh" "$@"
      '';
    };

    # Convenience launcher on PATH:  word-render <docx> [out.pdf]
    # Bakes the resolved options as defaults while still honouring any env
    # override (so a one-off `WINVM_SSH=... word-render x.docx` still works).
    home.file.".local/bin/word-render" = {
      executable = true;
      text = ''
        #!/usr/bin/env bash
        # Generated by modules/shared/word-render.nix — do not edit.
        export WINVM_SSH="''${WINVM_SSH:-${cfg.sshTarget}}"
        export WINVM_DIR="''${WINVM_DIR:-${cfg.guestDir}}"
        export WINVM_SCRIPT="''${WINVM_SCRIPT:-${cfg.guestScript}}"
        exec "$HOME/.local/share/word-render/word_render_remote.sh" "$@"
      '';
    };

    # Shell-visible defaults (mkDefault so a host/user can still override).
    home.sessionVariables = {
      WINVM_SSH = lib.mkDefault cfg.sshTarget;
      WINVM_DIR = lib.mkDefault cfg.guestDir;
      WINVM_SCRIPT = lib.mkDefault cfg.guestScript;
    };
  };
}
