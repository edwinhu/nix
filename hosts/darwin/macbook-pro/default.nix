{ config, pkgs, user, userInfo, ... }:

{
  imports = [
    ../../../modules/shared
    ../../../modules/darwin/home-manager.nix
    ../../../modules/darwin/aerospace.nix
    ../../../modules/darwin/sketchybar
    ../../../modules/darwin/defaults.nix
  ];

  # Reminder for terminal app permissions
  system.activationScripts.checkTerminalPermissions.text = ''
    echo "⚠️  Remember to grant Full Disk Access to terminal apps in System Settings"
    echo "   Privacy & Security → Full Disk Access → Add Ghostty & WezTerm"
    echo "   This is required for zellij and other terminal tools to work properly"
  '';

  # Configure SSH daemon on port 420
  system.activationScripts.sshPort420.text = ''
    echo "Configuring SSH daemon on port 420..."

    # Create SSH config for port 420 based on the system default
    if [ -f /etc/ssh/sshd_config.before-nix-darwin ]; then
      cp /etc/ssh/sshd_config.before-nix-darwin /tmp/sshd_config_420

      # Update port configuration - handle both commented and uncommented port lines
      sed -i "" "s/#Port 22/Port 420/" /tmp/sshd_config_420
      sed -i "" "s/^Port 22/Port 420/" /tmp/sshd_config_420

      # Add port 420 if no port line exists
      if ! grep -q "^Port" /tmp/sshd_config_420; then
        sed -i "" "1i\\
Port 420
" /tmp/sshd_config_420
      fi

      # Disable password authentication
      sed -i "" "s/#PasswordAuthentication yes/PasswordAuthentication no/" /tmp/sshd_config_420
      sed -i "" "s/^PasswordAuthentication yes/PasswordAuthentication no/" /tmp/sshd_config_420

      # Ensure root login is disabled
      sed -i "" "s/#PermitRootLogin prohibit-password/PermitRootLogin no/" /tmp/sshd_config_420
      sed -i "" "s/^PermitRootLogin.*/PermitRootLogin no/" /tmp/sshd_config_420

      # Kill any existing SSH daemon on port 420
      pkill -f "sshd.*-f /tmp/sshd_config_420" 2>/dev/null || true
      sleep 1

      # Test configuration before starting
      if /usr/sbin/sshd -t -f /tmp/sshd_config_420 2>/dev/null; then
        # Start SSH daemon on port 420
        /usr/sbin/sshd -f /tmp/sshd_config_420
        echo "SSH daemon started on port 420"

        # Verify it's listening
        sleep 2
        if lsof -i :420 >/dev/null 2>&1; then
          echo "Confirmed: SSH is listening on port 420"
        else
          echo "Warning: SSH may not be listening on port 420"
        fi
      else
        echo "Error: SSH configuration test failed for port 420"
      fi
    else
      echo "Error: SSH config backup not found at /etc/ssh/sshd_config.before-nix-darwin"
    fi
  '';

}
