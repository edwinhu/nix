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

    fzf = {
        enable = true;
        enableZshIntegration = true;
        # Catppuccin Mocha theme is already handled by Stylix
    };

    direnv = {
        enable = true;
        config = {
          global = {
            hide_env_diff = true;
          };
        };
        # Ensure direnv doesn't interfere with other hooks
        nix-direnv = {
          enable = true;
        };
    };

    zoxide = {
        enable = true;
        # Override cd command with zoxide for smart navigation
        options = [ "--cmd cd" ];
    };

    zsh = {
        enable = true;
        autocd = false;
        enableCompletion = true;
        completionInit = ''
          # Safe compinit to prevent double-free errors in VSCode
          autoload -Uz compinit
          # Only regenerate dump once a day for performance
          if [[ -n ''${HOME}/.zcompdump(#qN.mh+24) ]]; then
            compinit -i
          else
            compinit -C -i
          fi
        '';

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
          # Zellij environment variables
          ZELLIJ_LOG_LEVEL = "off";
          ZELLIJ_LOG_DIR = "/tmp";
          ZELLIJ_CONFIG_DIR = "$HOME/.config/zellij";
        };
        shellAliases = {
          # NOTE: zellij requires Full Disk Access on macOS Sequoia
          # Grant permissions in: System Settings → Privacy & Security → Full Disk Access
          zj = "${pkgs.zellij}/bin/zellij";
          # API key retrieval aliases
          get-claude-api-key = "cat $CLAUDE_API_KEY_FILE";
          get-gemini-api-key = "cat $GEMINI_API_KEY_FILE";
          get-google-search-api-key = "cat $GOOGLE_SEARCH_API_KEY_FILE";
          get-google-search-engine-id = "cat $GOOGLE_SEARCH_ENGINE_ID_FILE";
          get-readwise-token = "cat $READWISE_TOKEN_FILE";
        };
        envExtra = ''
          # Source nix daemon early (before .zshrc) to make nix commands available
          if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
            . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
          fi
        '';
        initContent = ''
          # Source common shell configuration early (loads .shell_env with nix and PATH)
          if [[ -f "$HOME/.shell_common" ]]; then
            source "$HOME/.shell_common"
          fi

          # Source shell aliases
          if [[ -f ~/.shell_aliases ]]; then
            source ~/.shell_aliases
          fi
        '';
        profileExtra = ''
        # Login shell configuration
        # Environment variables and PATH are set in dotfiles/.shell_env
        '';
    };

  # zellij configuration disabled since we use custom wrapper
  # zellij = {
  #   enable = true;
  #   settings = {
  #     theme = "catppuccin-mocha";
  #     default_shell = "zsh";
  #     pane_frames = false;
  #     mouse_mode = false;
  #     copy_command = "pbcopy";
  #     copy_clipboard = "primary";
  #     show_startup_tips = false;
  #     session_serialization = false;
  #     auto_layout = true;
  #     scroll_buffer_size = 10000;
  #     log = {
  #       filter = "off";
  #       destination = "file";
  #       file = "/tmp/zellij.log";
  #     };
  #   };
  # };

  git = {
    enable = true;
    ignores = [ "*.swp" ];
    lfs = {
      enable = true;
    };
    settings = {
      user = {
        name = userInfo.fullName;
        email = userInfo.email;
        signingkey = "${homeDir}/.ssh/id_github.pub";
      };
      init.defaultBranch = "main";
      core = {
	      editor = "nvim";
        autocrlf = "input";
      };
      gpg.format = "ssh";
      commit.gpgsign = true;
      pull.rebase = true;
      rebase.autoStash = true;
    };
  };

  ssh = {
    enable = true;
    enableDefaultConfig = false;
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
      "*" = {
        serverAliveInterval = 180;
        addKeysToAgent = "yes";
        identityFile = [
          "${homeDir}/.ssh/id_ed25519_agenix"
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
