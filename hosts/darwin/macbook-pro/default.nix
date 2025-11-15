{ config, pkgs, user, userInfo, ... }:

{
  imports = [
    ../../../modules/shared
    ../../../modules/darwin/home-manager.nix
    ../../../modules/darwin/aerospace.nix
    ../../../modules/darwin/sketchybar
    ../../../modules/darwin/defaults.nix
  ];

  # Set environment variables for GUI applications
  # This makes nix binaries (like direnv) available to apps launched from Finder/Dock
  launchd.user.envVariables = {
    PATH = config.environment.systemPath;
  };

  # Reminder for terminal app permissions
  system.activationScripts.checkTerminalPermissions.text = ''
    echo "⚠️  Remember to grant Full Disk Access to terminal apps in System Settings"
    echo "   Privacy & Security → Full Disk Access → Add Ghostty & WezTerm"
    echo "   This is required for zellij and other terminal tools to work properly"
  '';

  # Create SSH config for port 420
  environment.etc."ssh/sshd_config_420".text = ''
    # SSH daemon configuration for port 420
    Port 420

    # Security settings
    PasswordAuthentication no
    PermitRootLogin no
    PubkeyAuthentication yes
    ChallengeResponseAuthentication no
    UsePAM yes

    # Protocol and key settings
    Protocol 2
    HostKey /etc/ssh/ssh_host_rsa_key
    HostKey /etc/ssh/ssh_host_ecdsa_key
    HostKey /etc/ssh/ssh_host_ed25519_key

    # Logging
    SyslogFacility AUTH
    LogLevel INFO

    # Authentication
    AuthorizedKeysFile .ssh/authorized_keys

    # Misc settings
    X11Forwarding yes
    PrintMotd yes
    AcceptEnv LANG LC_*
    Subsystem sftp /usr/libexec/sftp-server
  '';

  # Configure SSH daemon on port 420 via launchd
  launchd.daemons.sshd-420 = {
    serviceConfig = {
      Label = "org.nixos.sshd-420";
      Program = "/usr/sbin/sshd";
      ProgramArguments = [
        "/usr/sbin/sshd"
        "-D"  # Don't daemonize
        "-f"
        "/etc/ssh/sshd_config_420"
      ];
      KeepAlive = true;
      RunAtLoad = true;
      StandardErrorPath = "/var/log/sshd_420.log";
      StandardOutPath = "/var/log/sshd_420.log";
    };
  };

}
