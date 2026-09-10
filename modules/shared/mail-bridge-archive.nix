# mail-bridge archive mode — the deployment half of the archive-backed bridge.
#
# The live bridge (`mail-bridge imapd`) answers every IMAP command by calling
# Graph or Gmail. The archive replacement serves a local SQLite archive and
# talks to the provider only from a bounded, timer-driven `archive cycle`. That
# split is the whole point of this module: the LISTENER gets no token broker at
# all, and only the periodic cycle carries one.
#
# `services.mail-bridge.accounts.<name>.mode` selects which implementation sits
# behind that account's existing Aerc port. The two accounts switch
# independently — Work is the first canary and Personal stays live — so nothing
# here is global. Rolling back is `home-manager switch --rollback` onto the
# previous generation: this module never mutates a running unit or a generated
# Aerc file, so a generation IS the whole state of the choice.
#
# Aerc's TRANSPORT is untouched by mode: it keeps pointing at 127.0.0.1:1143 /
# :1144 and keeps sending through the `mail-bridge sendmail` shim. Its mailbox
# NAMES are untouched too: both serve paths present every derived membership
# BARE (`Focused`, `Respond`), the archive translating from its canonical
# `kind/value` storage at the IMAP boundary. Only the PHYSICAL set differs by
# mode — the archive has no Outbox — so a consumer selects folders, not a
# vocabulary, from `mode`. The host's generated accounts.conf does exactly that.
#
# The timer-driven pass has two shapes, chosen per account by `outboxEnabled`:
# the full `archive account cycle`, or the inbound-only `archive account sync`
# while an account is TEMPORARILY INBOUND-ONLY UNTIL PROVIDER FLAGS ARE FIXED.
# Only the command differs — unit names, cadence, jitter, Persistent, token
# environment and the seven finite budgets are the same either way.
{ config, lib, pkgs, nix-secrets, ... }:

let
  cfg = config.services.mail-bridge;

  # One shared, account-scoped archive. Not the live UID maps under
  # ~/.config/owa-bridge — those stay untouched so a rollback lands on a live
  # bridge whose state never moved.
  stateDb = "${cfg.stateDirectory}/archive.sqlite3";

  budgetsType = lib.types.submodule {
    options = {
      maxRequests = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Provider HTTP requests one cycle may issue.";
      };
      maxPages = lib.mkOption {
        type = lib.types.ints.positive;
        description = "List/delta pages one cycle may consume.";
      };
      maxMessages = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Messages one cycle may acquire or reconcile.";
      };
      maxRawBytes = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Raw RFC822 bytes one cycle may fetch.";
      };
      maxRetries = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Retries per provider request.";
      };
      maxElapsedMs = lib.mkOption {
        type = lib.types.ints.positive;
        description = ''
          Wall-clock ceiling for one cycle, in MILLISECONDS. Milliseconds and
          not a duration word because that is the only unit the production
          parser takes; a second unit system here is a deployment that emits an
          argv the binary refuses. Must stay below the timer cadence, or a slow
          cycle overlaps the next one.
        '';
      };
      maxOperations = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Outbox operations one cycle may deliver.";
      };
    };
  };

  accountType = lib.types.submodule {
    options = {
      mode = lib.mkOption {
        type = lib.types.enum [ "live" "archive" ];
        default = "live";
        description = ''
          Which implementation owns this account's port. "live" keeps the
          provider-calling `imapd` bridge; "archive" serves the local archive
          and synchronizes on a timer.
        '';
      };
      cycleEnabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether this account's bounded synchronization cycle is wired to run.
          false pauses the cycle without leaving archive mode: the cycle service
          and its timer are still emitted, they are simply enabled by nothing.
          The pause is therefore a source fact the activation agrees with, not a
          runtime mask the next switch fights.
        '';
      };
      outboxEnabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether this account's timer-driven pass is allowed to deliver the
          durable outbox. true is the full `archive account cycle` (inbound,
          drain, reconcile, index). false is the inbound half alone, via the
          bounded `archive account sync`, which reaches the provider to acquire
          and reconcile but delivers nothing.

          TEMPORARILY false ON BOTH HOST ACCOUNTS UNTIL PROVIDER FLAGS ARE
          FIXED. Work holds 9 and Personal 14 pending local mutations, and the
          provider-read flags they would be reconciled against are not yet
          canonical, so a drain would push decisions taken from stale state.

          This selects the COMMAND, not the cadence: names, timer, jitter,
          Persistent, token environment and the seven finite budgets are
          identical either way. Pausing the cadence is `cycleEnabled`, and the
          two are independent.
        '';
      };
      address = lib.mkOption {
        type = lib.types.str;
        description = "The mailbox address; every command is bound to it.";
      };
      provider = lib.mkOption {
        type = lib.types.enum [ "gmail" "msgraph" ];
        description = "Provider backend, stated explicitly on every command.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        description = "The loopback port Aerc already points at.";
      };
      liveUnit = lib.mkOption {
        type = lib.types.str;
        description = ''
          The systemd user unit running the live bridge for this account. It is
          enabled only while mode = "live", so the two implementations can never
          contend for the port.
        '';
      };
      tokenEnvironmentVariable = lib.mkOption {
        type = lib.types.str;
        description = "Env var the binary reads this account's broker command from.";
      };
      tokenCommand = lib.mkOption {
        type = lib.types.str;
        description = ''
          Absolute broker invocation printing a bearer token on stdout. Reaches
          the bounded cycle unit only — never the listener.
        '';
      };
      staleAfterMs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 900000;
        description = ''
          How old the last completed cycle may be before the listener reports
          itself stale, in MILLISECONDS. Finite by construction: there is no
          "never" value, and milliseconds are what the production parser takes.
        '';
      };
      keepGenerations = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 2;
        description = "Historical generations kept beside the current one.";
      };
      retainGenerations = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 3;
        description = ''
          Historical generations retain-apply keeps beside the current one.
          The current generation is additional, so the default retains four
          generations in total.
        '';
      };
      budgets = lib.mkOption {
        type = budgetsType;
        description = "Cumulative finite ceilings for one cycle.";
      };

      # The provider-driven trigger. Off by default: it is the ONE archive unit
      # besides the cycle that carries a token, and it is reachable from the
      # public internet through the tunnel, so it is opted into per account
      # rather than appearing with the rest.
      graphWebhookEnabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Run a Graph change-notification receiver for this account, so mail
          arrives when the provider says so instead of at the next timer fire.
          The timer stays regardless: a missed, refused or expired notification
          must degrade to the old cadence rather than to silence.
        '';
      };
      graphWebhookUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          The PUBLIC URL Graph posts to, which must reach this host's receiver.
          Graph validates it synchronously when the subscription is created, so
          the tunnel route has to exist before the unit can succeed.
        '';
      };
      graphWebhookPort = lib.mkOption {
        type = lib.types.port;
        default = 8787;
        description = ''
          Loopback port the receiver binds. Must agree with the tunnel's
          ingress rule; the cloudflared config in reader-services.nix carries
          the matching value.
        '';
      };
      refreshCommand = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Command both push receivers run when the provider says mail arrived.
          Split on whitespace and spawned DIRECTLY — no shell, so no quoting,
          no expansion and no part of a notification reaches it. Required by
          `graph-webhook` and `gmail-push` now that the SQLite archive (and its
          in-process `runCycleOnDemand`) is gone: a notification triggers the
          same Maildir pull the timer runs, rather than an archive cycle.
        '';
      };
      # Gmail's trigger. Same shape as the Graph one and deliberately separate:
      # the two providers share no transport. Gmail publishes to Pub/Sub and
      # this PULLS, so there is no public endpoint and no inbound surface.
      gmailPushEnabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Run a Gmail Pub/Sub pull subscriber for this account. The timer stays
          regardless: `users.watch` lapses SILENTLY after seven days, so a
          renewal that fails must degrade to the old cadence, not to silence.
        '';
      };
      gmailPushSubscription = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Full PULL subscription name, projects/<p>/subscriptions/<s>.";
      };
      gmailPushTopic = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Full topic name `users.watch` publishes to, projects/<p>/topics/<t>.
          The subscriber re-calls watch against this before the seven-day lapse.
        '';
      };

      # The clientState secret is NOT an option: it is agenix-decrypted below,
      # to one path, and reaches the unit as an EnvironmentFile. A file rather
      # than an argument because argv is world-readable through `ps`, and not a
      # per-account knob because a second spelling of "where the secret lives"
      # is a second thing that can be wrong.
    };
  };

  exe = lib.getExe cfg.package;

  # Archive units are emitted for archive-mode accounts ONLY. A live account
  # has no archive listener, cycle or retention pass to write down, and an
  # inert unit definition for a retired subsystem is a unit somebody starts by
  # hand. The receivers below are gated on their own flags instead: they are
  # provider triggers, not archive cadence, and survive the mode change.
  archiveAccounts = lib.filterAttrs (_: a: a.mode == "archive") cfg.accounts;

  # Any account driving a receiver needs the one clientState secret; it is
  # decrypted once, not per account, because it identifies the tunnel route
  # rather than a mailbox.
  anyGraphWebhook = lib.any (a: a.graphWebhookEnabled) (lib.attrValues cfg.accounts);
  graphClientStatePath = "${config.home.homeDirectory}/.config/mail-bridge/graph-client-state.env";

  # The Gmail subscriber's service-account key. agenix-managed for the same
  # reason the clientState is: a credential nothing tracks is a credential
  # nobody rotates. mail-bridge refuses this file unless it is 0600.
  anyGmailPush = lib.any (a: a.gmailPushEnabled) (lib.attrValues cfg.accounts);
  gmailKeyPath = "${config.home.homeDirectory}/.config/mail-bridge/gmail-push-sa.json";

  # Serve: provider-free by construction. No token environment, no broker, no
  # network dependency — it reads the archive and nothing else.
  #
  # `archive account serve`, not `archive serve`: the latter is the
  # investigation corpus reader, which names no account's production state and
  # refuses 1143/1144 outright. The production namespace is the one that owns a
  # port, and it is the only argv the packaged parser accepts here.
  serveCommand = a: lib.concatStringsSep " " [
    exe
    "archive account serve"
    "--account ${a.address}"
    "--provider ${a.provider}"
    "--port ${toString a.port}"
    "--state ${stateDb}"
    "--stale-after-ms ${toString a.staleAfterMs}"
  ];

  # Cycle: the only unit that may reach a provider. Every ceiling is stated;
  # there is no default, so an unbounded synchronization is not one forgotten
  # flag away.
  # The seven flag names are the seven OperationBudgets fields the production
  # parser knows, spelled its way. A near-miss (`--max-items`, `--max-elapsed`)
  # is not a lenient synonym: the parser refuses an unknown option, so the unit
  # would fail on every timer fire.
  budgetFlags = a: [
    "--max-requests ${toString a.budgets.maxRequests}"
    "--max-pages ${toString a.budgets.maxPages}"
    "--max-messages ${toString a.budgets.maxMessages}"
    "--max-raw-bytes ${toString a.budgets.maxRawBytes}"
    "--max-retries ${toString a.budgets.maxRetries}"
    "--max-elapsed-ms ${toString a.budgets.maxElapsedMs}"
    "--max-operations ${toString a.budgets.maxOperations}"
  ];

  cycleCommand = a: lib.concatStringsSep " " ([
    exe
    "archive account cycle"
    "--account ${a.address}"
    "--provider ${a.provider}"
    "--state ${stateDb}"
    "--keep-generations ${toString a.keepGenerations}"
  ] ++ budgetFlags a);

  # Sync: the inbound half alone — acquire, promote, reconcile, no drain. Used
  # while an account is TEMPORARILY INBOUND-ONLY UNTIL PROVIDER FLAGS ARE
  # FIXED (`outboxEnabled = false`), so pending local mutations are not pushed
  # against provider-read flags that are not yet canonical.
  #
  # The flag set is NOT the cycle set minus a word. `--keep-generations` is
  # absent because the packaged parser permits it for `cycle` ONLY (its
  # per-operation `permitted` set adds it under `operation === "cycle"`), and
  # refuses an unpermitted flag outright — carrying it here would fail the unit
  # at parse on every timer fire rather than trim retention. Retention is a
  # cycle concern; an inbound pass promotes into the current generation and
  # rotates nothing. The seven budget flags DO belong: `sync` is one of the
  # provider-touching operations the parser requires all seven from.
  syncCommand = a: lib.concatStringsSep " " ([
    exe
    "archive account sync"
    "--account ${a.address}"
    "--provider ${a.provider}"
    "--state ${stateDb}"
  ] ++ budgetFlags a);

  # Retention is applied separately from cycle, which deliberately only plans
  # it. `retain-apply` takes `--retain`, not `--keep-generations`: the packaged
  # parser permits the latter for cycle only and would reject it here. It is not
  # a budgeted provider operation either, so carrying the seven --max-* flags
  # would likewise make every scheduled invocation fail at parse.
  retainCommand = a: lib.concatStringsSep " " [
    exe
    "archive account retain-apply"
    "--account ${a.address}"
    "--provider ${a.provider}"
    "--state ${stateDb}"
    "--retain ${toString a.retainGenerations}"
  ];

  # Which of the two the timer fires. One expression, so the unit body cannot
  # drift from the option.
  passCommand = a: if a.outboxEnabled then cycleCommand a else syncCommand a;

  # 0700 on the directory, so the archive (which holds complete message bodies)
  # is not group- or world-readable. Done here rather than by an activation
  # script so the guarantee travels with the unit that opens the database.
  ensureStateDir = "${pkgs.coreutils}/bin/mkdir -p -m 0700 ${cfg.stateDirectory}";

  serveUnit = name: a: lib.nameValuePair "mail-bridge-archive-${name}" {
    Unit = {
      Description = "mail-bridge archive listener for ${a.address} (provider-free)";
    };
    Service = {
      Type = "simple";
      ExecStartPre = ensureStateDir;
      ExecStart = serveCommand a;
      Restart = "on-failure";
      RestartSec = 10;
    };
    Install.WantedBy = lib.optionals (a.mode == "archive") [ "default.target" ];
  };

  # `graph-webhook`, a TOP-LEVEL subcommand with its own parser — not part of
  # the `archive account` namespace, so it takes neither `--keep-generations`
  # nor the archive parser's flag spellings. It no longer takes the seven cycle
  # budgets, `--provider` or `--state` either: with the archive deleted the
  # receiver runs a refresh command instead of an in-process cycle, and the
  # parser REFUSES an unpermitted flag outright, so a stale argv is a unit that
  # dies at parse on every start.
  graphWebhookCommand = a: lib.concatStringsSep " " [
    exe
    "graph-webhook"
    "--account ${a.address}"
    "--notification-url ${a.graphWebhookUrl}"
    "--port ${toString a.graphWebhookPort}"
    ''--refresh-command "${a.refreshCommand}"''
  ];

  # Gmail's subscriber. `--sa-key` takes a PATH, never the key: the binary reads
  # the file and refuses it unless it is 0600. Same flag surface as the Graph
  # receiver above, and the same reason for what is absent.
  gmailPushCommand = a: lib.concatStringsSep " " [
    exe
    "gmail-push"
    "--account ${a.address}"
    "--subscription ${a.gmailPushSubscription}"
    "--topic ${a.gmailPushTopic}"
    "--sa-key ${gmailKeyPath}"
    ''--refresh-command "${a.refreshCommand}"''
  ];

  gmailPushUnit = name: a: lib.nameValuePair "mail-bridge-gmail-push-${name}" {
    Unit = {
      Description = "mail-bridge Gmail Pub/Sub subscriber for ${a.address}";
      # Same agenix ordering as the Graph receiver, for the same measured
      # reason: the key must be on disk before the process is spawned.
      After = [ "network-online.target" "agenix.service" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "simple";
      ExecStartPre = ensureStateDir;
      Environment = [ ''"${a.tokenEnvironmentVariable}=${a.tokenCommand}"'' ];
      ExecStart = gmailPushCommand a;
      # A lapsed watch or a Pub/Sub blip must not become a dead unit; the timer
      # keeps delivering meanwhile, so retrying costs nothing.
      Restart = "on-failure";
      RestartSec = 30;
    };
    # Gated on the flag alone, not on mode: the subscriber is a provider
    # trigger and keeps running now that the archive cadence is retired.
    Install.WantedBy = lib.optionals a.gmailPushEnabled [ "default.target" ];
  };

  # The second unit that carries a token, and the only one reachable from the
  # public internet. It binds loopback and the tunnel is the sole path in; the
  # clientState secret arrives by EnvironmentFile because argv is readable by
  # every process on the box.
  graphWebhookUnit = name: a: lib.nameValuePair "mail-bridge-graph-webhook-${name}" {
    Unit = {
      Description = "mail-bridge Graph change-notification receiver for ${a.address}";
      # agenix.service, not just the network. systemd reads EnvironmentFile
      # BEFORE ExecStartPre, so a wait inside the unit body is too late: the
      # clientState has to be on disk when the unit is spawned. Measured
      # 2026-09-02 21:44:11 — the first start lost this race and died with
      # `Failed to load environment files: No such file or directory`, and only
      # the 30s Restart=on-failure retry saved it. Ordering, not Wants: agenix
      # is a oneshot that has already run outside an activation transaction,
      # and pulling it in would re-decrypt every secret for no reason.
      After = [ "network-online.target" "agenix.service" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "simple";
      ExecStartPre = ensureStateDir;
      # Same quoting rule as the cycle unit: systemd splits an unquoted
      # Environment= on whitespace and would drop every argument after the
      # broker binary.
      Environment = [ ''"${a.tokenEnvironmentVariable}=${a.tokenCommand}"'' ];
      EnvironmentFile = graphClientStatePath;
      ExecStart = graphWebhookCommand a;
      # A subscription Graph refuses, or a tunnel not yet up, must not become a
      # dead unit: the timer keeps delivering meanwhile, so retrying is free.
      Restart = "on-failure";
      RestartSec = 30;
    };
    # Flag alone, for the same reason as the Gmail subscriber.
    Install.WantedBy = lib.optionals a.graphWebhookEnabled [ "default.target" ];
  };

  # One gate for both cycle units: a cycle is wired only while the account is in
  # archive mode AND its cycle is not paused. The service's own enablement list
  # is empty either way — the timer is its only enabler — so the gate is stated
  # once and applied to both rather than living on the timer alone.
  cycleWantedBy = a: targets:
    lib.optionals (a.mode == "archive" && a.cycleEnabled) targets;

  cycleUnit = name: a: lib.nameValuePair "mail-bridge-archive-cycle-${name}" {
    Unit = {
      Description =
        if a.outboxEnabled then
          "mail-bridge bounded archive synchronization cycle for ${a.address}"
        else
          "mail-bridge bounded archive inbound synchronization for ${a.address}"
          + " (temporarily inbound-only until provider flags are fixed)";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      # The surrounding quotes are load-bearing: systemd splits an unquoted
      # Environment= on whitespace and would drop every argument after the
      # broker binary, leaving the cycle to spawn a bare broker.
      Environment = [ ''"${a.tokenEnvironmentVariable}=${a.tokenCommand}"'' ];
      ExecStartPre = ensureStateDir;
      # SERIALISED ACROSS ACCOUNTS. SQLite admits one writer, so two cycles on
      # one archive contend; the loser blocks, spends its whole --max-elapsed-ms
      # ceiling waiting, and dies reporting `budget-exhausted` — a message that
      # names the ceiling rather than the lock and sent three separate
      # investigations down the wrong path on 2026-08-21. RandomizedDelaySec
      # below was the original mitigation and is an order of magnitude too small:
      # a 60s jitter cannot separate runs that take two to four minutes.
      #
      # flock waits BEFORE exec, so the wait is not charged to the budget the
      # way an in-process lock wait is. -w bounds it, so a wedged cycle cannot
      # starve the other account indefinitely — the timer simply retries.
      ExecStart = "${pkgs.util-linux}/bin/flock -w 540 %t/mail-bridge-cycle.lock ${passCommand a}";
    };
    Install.WantedBy = cycleWantedBy a [ ];
  };

  cycleTimer = name: a: lib.nameValuePair "mail-bridge-archive-cycle-${name}" {
    Unit.Description = "mail-bridge archive synchronization cadence for ${a.address}";
    Timer = {
      # A calendar cadence rather than an interval, so Persistent has something
      # to catch up against after a suspend or a reboot.
      #
      # This interval IS the mail-arrival latency: the listeners hold no
      # provider credential, so nothing reaches the archive between ticks and
      # IDLE can only push what a cycle has already committed. Measured on the
      # five-minute grid, a message took 1m55s and 2m40s to surface in aerc.
      #
      # Deliberately NOT shortened toward real-time: polling harder is the wrong
      # lever, and this stays a safety net for a provider-driven trigger.
      OnCalendar = "*:0/5";
      # Staggering the two accounts is flock's job, not the timer's -- it waits
      # before exec, so the wait is not charged to the cycle's budget, and -w
      # bounds it. The jitter that used to serve this purpose is retained only
      # to keep two accounts off the same instant, not to separate whole runs,
      # which is why it is seconds rather than a minute.
      RandomizedDelaySec = "5s";
      # systemd's default is 1min, which silently added up to another minute on
      # top of the interval and the jitter above.
      AccuracySec = "1s";
      Persistent = true;
      Unit = "mail-bridge-archive-cycle-${name}.service";
    };
    Install.WantedBy = cycleWantedBy a [ "timers.target" ];
  };

  retainUnit = name: a: lib.nameValuePair "mail-bridge-archive-retain-${name}" {
    Unit.Description = "mail-bridge archive retention for ${a.address}";
    Service = {
      Type = "oneshot";
      ExecStartPre = ensureStateDir;
      # The shared lock makes the destructive apply wait outside the process, so
      # it can never overlap a sync, drain, or another account's retention pass.
      ExecStart = "${pkgs.util-linux}/bin/flock -w 540 %t/mail-bridge-cycle.lock ${retainCommand a}";
    };
    Install.WantedBy = cycleWantedBy a [ ];
  };

  retainTimer = name: a: lib.nameValuePair "mail-bridge-archive-retain-${name}" {
    Unit.Description = "mail-bridge archive retention cadence for ${a.address}";
    Timer = {
      OnCalendar = "daily";
      # Spread the two account jobs across the hour; flock remains the hard
      # guarantee if their randomized windows still overlap a cycle or each other.
      RandomizedDelaySec = "1h";
      Persistent = true;
      Unit = "mail-bridge-archive-retain-${name}.service";
    };
    Install.WantedBy = cycleWantedBy a [ "timers.target" ];
  };
in
{
  options.services.mail-bridge = {
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.mail-bridge;
      defaultText = lib.literalExpression "pkgs.mail-bridge";
      description = "The mail-bridge build serving both modes.";
    };

    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "%h/.local/state/mail-bridge";
      description = ''
        Directory holding the one shared archive database. A systemd specifier
        is deliberate: the units resolve it, so nothing bakes a home path into
        a store path.
      '';
    };

    accounts = lib.mkOption {
      type = lib.types.attrsOf accountType;
      default = { };
      description = ''
        Mailboxes this host bridges, each independently in live or archive
        mode. Units are emitted for every account regardless of mode; only
        Install.WantedBy follows the mode, so switching is a generation change
        rather than a unit appearing out of nowhere.
      '';
    };
  };

  config = lib.mkIf (cfg.accounts != { }) {
    systemd.user.services =
      (lib.mapAttrs' serveUnit archiveAccounts)
      // (lib.mapAttrs' cycleUnit archiveAccounts)
      // (lib.mapAttrs' retainUnit archiveAccounts)
      # Unlike the other three, this one is emitted ONLY where it is enabled.
      # A receiver unit for an account that opted out would be written with an
      # empty --notification-url: harmless while nothing starts it, and a trap
      # the first time somebody starts it by hand.
      // (lib.mapAttrs' graphWebhookUnit
            (lib.filterAttrs (_: a: a.graphWebhookEnabled) cfg.accounts))
      // (lib.mapAttrs' gmailPushUnit
            (lib.filterAttrs (_: a: a.gmailPushEnabled) cfg.accounts));

    age.secrets.mail-bridge-gmail-push-sa = lib.mkIf anyGmailPush {
      file = "${nix-secrets}/mail-bridge-gmail-push-sa.age";
      path = gmailKeyPath;
      mode = "600";
      symlink = false;
    };

    # An EnvironmentFile, so the plaintext holds `MAIL_BRIDGE_GRAPH_CLIENT_STATE=<secret>`
    # rather than a bare value. 0600 and symlink=false for the same reason the
    # cloudflared creds are: systemd reads it as the user, before the unit runs.
    age.secrets.mail-bridge-graph-client-state = lib.mkIf anyGraphWebhook {
      file = "${nix-secrets}/mail-bridge-graph-client-state.age";
      path = graphClientStatePath;
      mode = "600";
      symlink = false;
    };

    systemd.user.timers =
      (lib.mapAttrs' cycleTimer archiveAccounts) // (lib.mapAttrs' retainTimer archiveAccounts);

    # Gates on the EVALUATED units, not on the let-bindings above, so a caller
    # that overrides a unit body is judged too. They fail at eval: no build, no
    # switch, no activation.
    assertions =
      let
        exec = name: lib.concatStringsSep " "
          (lib.toList (config.systemd.user.services."mail-bridge-archive-cycle-${name}".Service.ExecStart));
        retainExec = name: lib.concatStringsSep " "
          (lib.toList (config.systemd.user.services."mail-bridge-archive-retain-${name}".Service.ExecStart));
        listenerExec = name: lib.concatStringsSep " "
          (lib.toList (config.systemd.user.services."mail-bridge-archive-${name}".Service.ExecStart));
        env = name: lib.concatStringsSep " "
          (config.systemd.user.services."mail-bridge-archive-cycle-${name}".Service.Environment or [ ]);
        others = name: lib.filter (n: n != name) (lib.attrNames cfg.accounts);

        # The unit-shape gates read units that exist only in archive mode; the
        # option-shape gates below them hold in either mode.
        perAccount = name: a: lib.optionals (a.mode == "archive") [
          {
            # The option is the ONLY thing that decides the namespace, in both
            # directions, so neither value can silently fall through to the other.
            assertion =
              if a.outboxEnabled
              then lib.hasInfix "archive account cycle " (exec name)
              else lib.hasInfix "archive account sync " (exec name);
            message =
              "mail-bridge-archive-cycle-${name}: outboxEnabled = "
              + (if a.outboxEnabled then "true" else "false")
              + " must select `archive account "
              + (if a.outboxEnabled then "cycle" else "sync")
              + "`, got ExecStart = ${exec name}";
          }
          {
            # Decisive parser fact, not taste: the packaged CLI adds
            # --keep-generations to the permitted set under `cycle` only and
            # refuses an unpermitted flag, so a sync carrying it fails at parse
            # on every timer fire.
            assertion = lib.hasInfix "--keep-generations " (exec name) == a.outboxEnabled;
            message =
              "mail-bridge-archive-cycle-${name}: --keep-generations is parser-valid "
              + "for `archive account cycle` only; it must be present exactly when "
              + "outboxEnabled is true. ExecStart = ${exec name}";
          }
          {
            assertion = lib.all (f: lib.hasInfix "${f} " (exec name)) [
              "--max-requests"
              "--max-pages"
              "--max-messages"
              "--max-raw-bytes"
              "--max-retries"
              "--max-elapsed-ms"
              "--max-operations"
            ];
            message =
              "mail-bridge-archive-cycle-${name}: all seven finite budget flags are "
              + "required by the parser for every provider-touching operation, sync "
              + "included. ExecStart = ${exec name}";
          }
          {
            assertion =
              lib.hasInfix "%t/mail-bridge-cycle.lock " (retainExec name)
              && lib.hasInfix "archive account retain-apply " (retainExec name)
              && lib.hasInfix "--retain ${toString a.retainGenerations}" (retainExec name)
              && !(lib.hasInfix "--keep-generations " (retainExec name))
              && lib.all (f: !(lib.hasInfix "${f} " (retainExec name))) [
                "--max-requests"
                "--max-pages"
                "--max-messages"
                "--max-raw-bytes"
                "--max-retries"
                "--max-elapsed-ms"
                "--max-operations"
              ];
            message =
              "mail-bridge-archive-retain-${name}: retain-apply must take the shared "
              + "cycle lock and --retain, with neither --keep-generations nor any "
              + "provider-operation budget flag. ExecStart = ${retainExec name}";
          }
          {
            assertion =
              (config.systemd.user.timers."mail-bridge-archive-retain-${name}".Install.WantedBy or [ ])
              == (config.systemd.user.timers."mail-bridge-archive-cycle-${name}".Install.WantedBy or [ ]);
            message =
              "mail-bridge-archive-retain-${name}.timer must follow the cycle timer's "
              + "mode/cycleEnabled gate exactly.";
          }
          {
            # The listener is provider-free by construction; a token reaching it
            # would undo the whole point of the split.
            assertion =
              (config.systemd.user.services."mail-bridge-archive-${name}".Service.Environment or [ ]) == [ ]
              && lib.hasInfix "archive account serve " (listenerExec name)
              && lib.hasInfix "--port ${toString a.port}" (listenerExec name);
            message =
              "mail-bridge-archive-${name}: the listener must stay a provider-free "
              + "`archive account serve` on port ${toString a.port} with no token "
              + "environment. ExecStart = ${listenerExec name}";
          }
          {
            assertion =
              lib.hasInfix a.tokenEnvironmentVariable (env name)
              && lib.all (o: !(lib.hasInfix cfg.accounts.${o}.tokenEnvironmentVariable (env name)))
                   (lib.filter (o: cfg.accounts.${o}.tokenEnvironmentVariable != a.tokenEnvironmentVariable)
                     (others name));
            message =
              "mail-bridge-archive-cycle-${name}: must carry its own broker and no "
              + "other account's. Environment = ${env name}";
          }
        ] ++ [
          {
            assertion = lib.all (o: cfg.accounts.${o}.port != a.port) (others name);
            message =
              "services.mail-bridge.accounts.${name}: port ${toString a.port} is "
              + "claimed by more than one account; a port has exactly one owner.";
          }
          # A receiver missing either half is a unit that starts and then dies,
          # or worse, one that accepts unauthenticated notifications. Both are
          # decidable here, so neither reaches a switch.
          {
            assertion = a.graphWebhookEnabled -> (a.graphWebhookUrl != "");
            message =
              "services.mail-bridge.accounts.${name}: graphWebhookEnabled needs "
              + "graphWebhookUrl. Graph validates the notification URL when the "
              + "subscription is created, so an empty one cannot succeed.";
          }
          {
            # Only ENABLED receivers contend for a port. Every account carries
            # the same default, so comparing against accounts that never opted
            # in made the default itself a collision and aborted evaluation.
            assertion =
              a.graphWebhookEnabled
              -> lib.all
                   (o:
                     !cfg.accounts.${o}.graphWebhookEnabled
                     || cfg.accounts.${o}.graphWebhookPort != a.graphWebhookPort)
                   (others name);
            message =
              "services.mail-bridge.accounts.${name}: graphWebhookPort "
              + "${toString a.graphWebhookPort} is claimed by more than one "
              + "account running a receiver.";
          }
          {
            assertion =
              a.gmailPushEnabled
              -> (a.gmailPushSubscription != "" && a.gmailPushTopic != "");
            message =
              "services.mail-bridge.accounts.${name}: gmailPushEnabled needs "
              + "both gmailPushSubscription and gmailPushTopic. The subscriber "
              + "pulls from the one and re-calls users.watch against the other; "
              + "without the topic the watch lapses after seven days in silence.";
          }
        ];
      in
      lib.concatLists (lib.mapAttrsToList perAccount cfg.accounts);
  };
}
