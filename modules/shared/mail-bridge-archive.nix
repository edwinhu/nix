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
{ config, lib, pkgs, ... }:

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
      budgets = lib.mkOption {
        type = budgetsType;
        description = "Cumulative finite ceilings for one cycle.";
      };
    };
  };

  exe = lib.getExe cfg.package;

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
      ExecStart = passCommand a;
    };
    Install.WantedBy = cycleWantedBy a [ ];
  };

  cycleTimer = name: a: lib.nameValuePair "mail-bridge-archive-cycle-${name}" {
    Unit.Description = "mail-bridge archive synchronization cadence for ${a.address}";
    Timer = {
      # A calendar cadence rather than an interval, so Persistent has something
      # to catch up against after a suspend or a reboot.
      OnCalendar = "*:0/5";
      # Two accounts on one five-minute grid would otherwise wake, hit two
      # providers, and contend for the writer lease at the same instant.
      RandomizedDelaySec = "60s";
      Persistent = true;
      Unit = "mail-bridge-archive-cycle-${name}.service";
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
      (lib.mapAttrs' serveUnit cfg.accounts) // (lib.mapAttrs' cycleUnit cfg.accounts);

    systemd.user.timers = lib.mapAttrs' cycleTimer cfg.accounts;

    # Gates on the EVALUATED units, not on the let-bindings above, so a caller
    # that overrides a unit body is judged too. They fail at eval: no build, no
    # switch, no activation.
    assertions =
      let
        exec = name: lib.concatStringsSep " "
          (lib.toList (config.systemd.user.services."mail-bridge-archive-cycle-${name}".Service.ExecStart));
        listenerExec = name: lib.concatStringsSep " "
          (lib.toList (config.systemd.user.services."mail-bridge-archive-${name}".Service.ExecStart));
        env = name: lib.concatStringsSep " "
          (config.systemd.user.services."mail-bridge-archive-cycle-${name}".Service.Environment or [ ]);
        others = name: lib.filter (n: n != name) (lib.attrNames cfg.accounts);

        perAccount = name: a: [
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
          {
            assertion = lib.all (o: cfg.accounts.${o}.port != a.port) (others name);
            message =
              "services.mail-bridge.accounts.${name}: port ${toString a.port} is "
              + "claimed by more than one account; a port has exactly one owner.";
          }
        ];
      in
      lib.concatLists (lib.mapAttrsToList perAccount cfg.accounts);
  };
}
