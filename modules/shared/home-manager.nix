{ pkgs, lib, user, userInfo, ... }:

let
  homeDir = if pkgs.stdenv.isDarwin then "/Users/${user}" else "/home/${user}";
in

{
  # Shared shell configuration

  atuin = {
        enable = true;
        settings = {
        style = "compact"; 
        };
    };

    bat = {
        enable = true;
    };

    btop = {
        enable = true;
    };

    direnv = {
        enable = true;
    };

    zoxide = {
        enable = true;
        options = [
        "--cmd cd"
        ];
    };

    zsh = {
        enable = true;
        autocd = false;

        cdpath = [ "~/.local/share/src" ];
        plugins = [
          {
            name = "fzf-tab";
            src = "${pkgs.zsh-fzf-tab}/share/fzf-tab";
          }
        ];
        sessionVariables = {
          EDITOR = "nvim";
          VISUAL = "nvim";
          ALTERNATE_EDITOR = "";
          HISTIGNORE = "pwd:ls:cd";
          NOSYSZSHRC = "1";  # Prevent system zshrc from running after user config
        };
        initContent = ''
        # Source shared shell configuration
        if [[ -f "$HOME/dotfiles/.shell_common" ]]; then
            source "$HOME/dotfiles/.shell_common"
        fi
        
        # fzf colors are managed by stylix
        '';
        profileExtra = ''
        # Login shell configuration
        # Environment variables and PATH are set in dotfiles/.shell_env
        '';
    };

  git = {
    enable = true;
    ignores = [ "*.swp" ];
    userName = userInfo.fullName;
    userEmail = userInfo.email;
    lfs = {
      enable = true;
    };
    extraConfig = {
      init.defaultBranch = "main";
      core = {
	      editor = "nvim";
        autocrlf = "input";
      };
      gpg.format = "ssh";
      commit.gpgsign = true;
      user = {
        signingkey = "${homeDir}/.ssh/id_github.pub";
      };
      pull.rebase = true;
      rebase.autoStash = true; 
    };
  };

  ssh = {
    enable = true;
    serverAliveInterval = 180;
    includes = [
      "${homeDir}/.ssh/config_external"
    ];
    matchBlocks = {
      "github.com" = {
        identitiesOnly = true;
        identityFile = [
          "${homeDir}/.ssh/id_github"
        ];
      };
    };
  };

  starship = {
    enable = true;
    settings = {
    };
  };

  tmux = {
    enable = true;
    plugins = with pkgs.tmuxPlugins; [
      vim-tmux-navigator
      sensible
      yank
      prefix-highlight
      catppuccin
      {
        plugin = resurrect; # Used by tmux-continuum

        # Use XDG data directory
        # https://github.com/tmux-plugins/tmux-resurrect/issues/348
        extraConfig = ''
          set -g @resurrect-dir '$HOME/.cache/tmux/resurrect'
          set -g @resurrect-capture-pane-contents 'on'
          set -g @resurrect-pane-contents-area 'visible'
        '';
      }
      {
        plugin = continuum;
        extraConfig = ''
          set -g @continuum-restore 'on'
          set -g @continuum-save-interval '5' # minutes
        '';
      }
      {
        plugin = catppuccin;
        extraConfig = ''
          set -g @catppuccin_flavor "mocha"
          set -g @catppuccin_window_status_style "rounded"
          # Make the status line pretty and add some modules
          set -g status-right-length 100
          set -g status-left-length 100
          set -g status-left ""
          set -g status-right "#{E:@catppuccin_status_application}"
          set -ag status-right "#{E:@catppuccin_status_session}"
          set -ag status-right "#{E:@catppuccin_status_uptime}"
        '';
      }
    ];
    terminal = "screen-256color";
    prefix = "C-a";
    escapeTime = 10;
    historyLimit = 50000;
    extraConfig = ''
      # use zsh fix
      set -g default-command ${pkgs.zsh}/bin/zsh
      # fix color stuff
      set -ga terminal-overrides ",xterm-256color:Tc"

      # Remove Vim mode delays
      set -g focus-events on

      # Enable full mouse support
      set -g mouse on

      # -----------------------------------------------------------------------------
      # Key bindings
      # -----------------------------------------------------------------------------

      # Unbind default keys
      unbind C-b
      unbind '"'
      unbind %

      # Split panes, vertical or horizontal
      bind-key '\' split-window -h # Split panes horizontal
      bind-key '-' split-window -v # Split panes vertically

      # Move around panes with vim-like bindings (h,j,k,l)
      bind-key -n M-k select-pane -U
      bind-key -n M-h select-pane -L
      bind-key -n M-j select-pane -D
      bind-key -n M-l select-pane -R

      # Smart pane switching with awareness of Vim splits.
      # This is copy paste from https://github.com/christoomey/vim-tmux-navigator
      is_vim="ps -o state= -o comm= -t '#{pane_tty}' \
        | grep -iqE '^[^TXZ ]+ +(\\S+\\/)?g?(view|n?vim?x?)(diff)?$'"
      bind-key -n 'C-h' if-shell "$is_vim" 'send-keys C-h'  'select-pane -L'
      bind-key -n 'C-j' if-shell "$is_vim" 'send-keys C-j'  'select-pane -D'
      bind-key -n 'C-k' if-shell "$is_vim" 'send-keys C-k'  'select-pane -U'
      bind-key -n 'C-l' if-shell "$is_vim" 'send-keys C-l'  'select-pane -R'
      tmux_version='$(tmux -V | sed -En "s/^tmux ([0-9]+(.[0-9]+)?).*/\1/p")'
      if-shell -b '[ "$(echo "$tmux_version < 3.0" | bc)" = 1 ]' \
        "bind-key -n 'C-\\' if-shell \"$is_vim\" 'send-keys C-\\'  'select-pane -l'"
      if-shell -b '[ "$(echo "$tmux_version >= 3.0" | bc)" = 1 ]' \
        "bind-key -n 'C-\\' if-shell \"$is_vim\" 'send-keys C-\\\\'  'select-pane -l'"

      bind-key -T copy-mode-vi 'C-h' select-pane -L
      bind-key -T copy-mode-vi 'C-j' select-pane -D
      bind-key -T copy-mode-vi 'C-k' select-pane -U
      bind-key -T copy-mode-vi 'C-l' select-pane -R
      bind-key -T copy-mode-vi 'C-\' select-pane -l
      '';
    };
}
