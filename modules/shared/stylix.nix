{ pkgs, lib, config, ... }:

{
  stylix = {
    enable = true;
    autoEnable = true;
    base16Scheme = "${pkgs.base16-schemes}/share/themes/catppuccin-mocha.yaml";
    fonts = {
      monospace = {
        package = pkgs.nerd-fonts.jetbrains-mono;
        name = "JetBrainsMono Nerd Font Mono";
      };
      sizes.terminal = 13;
    };
    opacity.terminal = 0.8;

    # Explicitly enable targets
    targets = {
      fzf.enable = true;
      btop.enable = true;
      tmux.enable = true;
      bat.enable = true;
    };
  };
}
