{ pkgs, lib, config, ... }:

{
  stylix = {
    enable = true;
    autoEnable = true;
    base16Scheme = "${pkgs.base16-schemes}/share/themes/catppuccin-mocha.yaml";
    fonts = {
      monospace = {
        package = pkgs.maple-mono.NF;
        name = "Maple Mono NF";
      };
      sizes.terminal = 13;
    };
    opacity.terminal = 0.8;

    # Qt theming via Stylix (generates Kvantum theme automatically)
    targets.qt = {
      enable = true;
      platform = "qtct";
    };
  };

  # Install qt configuration tools
  home.packages = with pkgs; [
    libsForQt5.qt5ct
    kdePackages.qt6ct
    libsForQt5.qtstyleplugin-kvantum
    kdePackages.qtstyleplugin-kvantum
  ];
}
