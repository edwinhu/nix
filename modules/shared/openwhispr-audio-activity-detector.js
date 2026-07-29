// PATCHED (nix): Linux meeting detection is attributed to the owning application.
//
// Upstream's Linux path treats ANY microphone stream as a meeting: `pactl
// subscribe` is parsed for `source-output` new/remove events, a counter is
// bumped, and two seconds of "some process has the mic open" fires
// `sustained-audio-detected` — which is the ONLY trigger the detection engine
// listens to (process detection is deliberately context-only). Nothing checks
// WHICH application opened the mic, so a dictation daemon, a voice message, a
// browser mic test or a recorder all raise "It sounds like you're in a meeting."
//
// The counter is also blind to state that predates it: it only ever sees events
// that arrive after `pactl subscribe` starts, so a call already in progress when
// OpenWhispr launches produces no `new` event and is never detected.
//
// This fork replaces the event COUNTER with a debounced re-evaluation that asks
// pactl who actually holds the mic, and only reports activity when the owner
// looks like a conferencing app — either a known native client, or a browser
// that is simultaneously PLAYING audio (a call is two-way; dictation and voice
// notes are capture-only). Streams belonging to known non-meeting capture tools
// are ignored outright. The same predicate backs the polling fallback, and it is
// evaluated once at startup so an in-progress call is picked up.
//
// See modules/shared/openwhispr.nix for how this file is swapped into app.asar.

const { exec, spawn } = require("child_process");
const { promisify } = require("util");
const path = require("path");
const fs = require("fs");
const EventEmitter = require("events");
const debugLogger = require("./debugLogger");

const execAsync = promisify(exec);

const CHECK_INTERVAL_MS = process.platform === "win32" ? 15 * 1000 : 3 * 1000;
const SUSTAINED_THRESHOLD_CHECKS = 2;
const SUSTAINED_EVENT_DRIVEN_MS = 2 * 1000;
const COOLDOWN_MS = 5 * 60 * 1000;
const INACTIVE_RESET_MS = 60 * 1000;
const EXEC_OPTS = { timeout: 5000, encoding: "utf8" };

// Coalesce bursts of pactl events (joining a call opens several streams at once)
// into a single `pactl list` query.
const LINUX_EVAL_DEBOUNCE_MS = 750;

// Matched as case-insensitive substrings against every `application.name` and
// `application.process.binary` PulseAudio/PipeWire reports for a stream, so
// "ZOOM VoiceEngine", "zoom" and "teams-for-linux" all match one keyword.

// Native conferencing clients: holding the mic is meeting evidence on its own.
const LINUX_MEETING_KEYWORDS = [
  "zoom",
  "teams",
  "webex",
  "skype",
  "discord",
  "slack",
  "jitsi",
  "bluejeans",
  "gotomeeting",
  "ringcentral",
  "signal",
  "telegram",
  "element",
  "linphone",
  "mumble",
];

// Browsers cover Google Meet and the web clients of the apps above. A browser
// holding the mic is only treated as a meeting when that same browser is also
// playing audio — otherwise a web dictation page or a mic permission check
// would look identical to a call.
const LINUX_BROWSER_KEYWORDS = [
  "chromium",
  "chrome",
  "firefox",
  "librewolf",
  "brave",
  "vivaldi",
  "edge",
  "opera",
  "epiphany",
  "zen",
];

// Capture tools that are never a meeting. `pw-cat`/`pw-record`/`parecord` cover
// the raw-capture helpers dictation daemons spawn (this host runs one that holds
// the mic continuously); OpenWhispr's own capture is additionally guarded by the
// _userRecording flag.
const LINUX_IGNORED_KEYWORDS = [
  "pw-cat",
  "pw-record",
  "parecord",
  "arecord",
  "pactl",
  "swlinux",
  "openwhispr",
  "open-whispr",
  "whisper",
];

const matchesKeyword = (owner, keywords) => keywords.some((k) => owner.includes(k));

class AudioActivityDetector extends EventEmitter {
  constructor() {
    super();
    this.checkInterval = null;
    this.consecutiveChecks = 0;
    this.audioActiveStart = null;
    this.hasPrompted = false;
    this.lastDismissedAt = null;
    this._userRecording = false;
    this._checking = false;
    this._listenerProcess = null;
    this._activeMicPids = new Set();
    this._activeSources = 0;
    this._sustainedTimer = null;
    this._running = false;
    this._eventDriven = false;
    this._resetTimer = null;
    this._linuxEvalTimer = null;
    this._linuxEvaluating = false;
    this._linuxEvalPending = false;
  }

  setUserRecording(active) {
    this._userRecording = active;
    if (active) {
      this.consecutiveChecks = 0;
      this.audioActiveStart = null;
      this._clearSustainedTimer();
    }
    debugLogger.debug("User recording state changed", { active }, "meeting");
  }

  async start() {
    if (this._running) return;
    this._running = true;

    const started = await this._tryEventDriven();
    if (started) {
      this._eventDriven = true;
      debugLogger.info(
        "Audio activity detector started (event-driven)",
        { platform: process.platform },
        "meeting"
      );
    } else {
      this._eventDriven = false;
      this._startPolling();
      debugLogger.info(
        "Audio activity detector started (polling)",
        { intervalMs: CHECK_INTERVAL_MS, threshold: SUSTAINED_THRESHOLD_CHECKS },
        "meeting"
      );
    }
  }

  stop() {
    if (!this._running) return;
    this._running = false;
    this._killListenerProcess();
    this._clearSustainedTimer();
    this._clearResetTimer();
    this._clearLinuxEvalTimer();
    if (this.checkInterval) {
      clearInterval(this.checkInterval);
      this.checkInterval = null;
    }
    this._reset();
    this._eventDriven = false;
    debugLogger.info("Audio activity detector stopped", {}, "meeting");
  }

  dismiss() {
    this.lastDismissedAt = Date.now();
    this._reset();
    this._clearSustainedTimer();
    this._clearResetTimer();
    debugLogger.info(
      "Audio detection dismissed, cooldown started",
      { cooldownMs: COOLDOWN_MS },
      "meeting"
    );
  }

  resetPrompt() {
    this.hasPrompted = false;
    this._clearSustainedTimer();
    this.audioActiveStart = null;
    debugLogger.info("Audio detection prompt reset (no cooldown)", {}, "meeting");
  }

  _reset() {
    this.consecutiveChecks = 0;
    this.audioActiveStart = null;
    this.hasPrompted = false;
    this._activeMicPids.clear();
    this._activeSources = 0;
    this._clearResetTimer();
  }

  _clearSustainedTimer() {
    if (this._sustainedTimer) {
      clearTimeout(this._sustainedTimer);
      this._sustainedTimer = null;
    }
  }

  _startResetTimer() {
    this._clearResetTimer();
    this._resetTimer = setTimeout(() => {
      this._resetTimer = null;
      this.hasPrompted = false;
      debugLogger.debug("hasPrompted reset after sustained inactivity", {}, "meeting");
    }, INACTIVE_RESET_MS);
  }

  _clearResetTimer() {
    if (this._resetTimer) {
      clearTimeout(this._resetTimer);
      this._resetTimer = null;
    }
  }

  _clearLinuxEvalTimer() {
    if (this._linuxEvalTimer) {
      clearTimeout(this._linuxEvalTimer);
      this._linuxEvalTimer = null;
    }
  }

  _killListenerProcess() {
    if (this._listenerProcess) {
      try {
        this._listenerProcess.kill();
      } catch {
        // already exited
      }
      this._listenerProcess = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Event-driven approach
  // ---------------------------------------------------------------------------

  async _tryEventDriven() {
    switch (process.platform) {
      case "darwin":
        return this._tryEventDrivenDarwin();
      case "win32":
        return this._tryEventDrivenWin32();
      case "linux":
        return this._tryEventDrivenLinux();
      default:
        return false;
    }
  }

  _resolveBinary(binaryName) {
    const candidates = [
      path.join(__dirname, "..", "..", "resources", "bin", binaryName),
      path.join(__dirname, "..", "..", "resources", binaryName),
    ];

    if (process.resourcesPath) {
      candidates.push(
        path.join(process.resourcesPath, binaryName),
        path.join(process.resourcesPath, "bin", binaryName),
        path.join(process.resourcesPath, "resources", "bin", binaryName),
        path.join(process.resourcesPath, "app.asar.unpacked", "resources", "bin", binaryName)
      );
    }

    for (const candidate of candidates) {
      try {
        if (fs.existsSync(candidate)) {
          fs.accessSync(candidate, fs.constants.X_OK);
          debugLogger.info("Resolved binary", { name: binaryName, path: candidate }, "meeting");
          return candidate;
        }
      } catch {
        // continue
      }
    }
    return null;
  }

  _attachFallbackHandlers(child, label) {
    const fallbackToPolling = () => {
      this._listenerProcess = null;
      if (this._running && this._eventDriven) {
        this._eventDriven = false;
        this._startPolling();
      }
    };

    child.on("error", (err) => {
      debugLogger.warn(`${label} error`, { error: err.message }, "meeting");
      fallbackToPolling();
    });

    child.on("exit", (code) => {
      debugLogger.warn(`${label} exited`, { code }, "meeting");
      fallbackToPolling();
    });
  }

  _tryEventDrivenDarwin() {
    const binaryPath = this._resolveBinary("macos-mic-listener");
    if (!binaryPath) {
      debugLogger.warn("macos-mic-listener binary not found, will use polling", {}, "meeting");
      return false;
    }

    try {
      const child = spawn(binaryPath, [], { stdio: ["ignore", "pipe", "pipe"] });
      this._listenerProcess = child;

      let buffer = "";
      child.stdout.on("data", (data) => {
        buffer += data.toString();
        let newlineIdx;
        while ((newlineIdx = buffer.indexOf("\n")) !== -1) {
          const line = buffer.slice(0, newlineIdx).trim();
          buffer = buffer.slice(newlineIdx + 1);
          if (line === "MIC_ACTIVE") {
            this._onMicStateChanged(true);
          } else if (line === "MIC_INACTIVE") {
            this._onMicStateChanged(false);
          }
        }
      });

      child.stderr.on("data", (data) => {
        debugLogger.debug(
          "macos-mic-listener stderr",
          { output: data.toString().trim() },
          "meeting"
        );
      });

      this._attachFallbackHandlers(child, "macos-mic-listener");
      return true;
    } catch (err) {
      debugLogger.warn("Failed to spawn macos-mic-listener", { error: err.message }, "meeting");
      return false;
    }
  }

  _tryEventDrivenWin32() {
    const binaryPath = this._resolveBinary("windows-mic-listener.exe");
    if (!binaryPath) {
      debugLogger.warn("windows-mic-listener.exe not found, will use polling", {}, "meeting");
      return false;
    }

    try {
      // stdin must be "pipe" — the Windows binary monitors stdin for parent death
      const child = spawn(binaryPath, ["--exclude-pid", String(process.pid)], {
        stdio: ["pipe", "pipe", "pipe"],
      });
      this._listenerProcess = child;

      let buffer = "";
      child.stdout.on("data", (data) => {
        buffer += data.toString();
        let newlineIdx;
        while ((newlineIdx = buffer.indexOf("\n")) !== -1) {
          const line = buffer.slice(0, newlineIdx).trim();
          buffer = buffer.slice(newlineIdx + 1);
          this._parseWin32ListenerLine(line);
        }
      });

      child.stderr.on("data", (data) => {
        debugLogger.debug(
          "windows-mic-listener stderr",
          { output: data.toString().trim() },
          "meeting"
        );
      });

      this._attachFallbackHandlers(child, "windows-mic-listener");
      return true;
    } catch (err) {
      debugLogger.warn("Failed to spawn windows-mic-listener", { error: err.message }, "meeting");
      return false;
    }
  }

  _parseWin32ListenerLine(line) {
    const startMatch = line.match(/^MIC_START\s+(\d+)$/);
    if (startMatch) {
      const pid = parseInt(startMatch[1], 10);
      this._activeMicPids.add(pid);
      this._onMicStateChanged(true);
      return;
    }

    const stopMatch = line.match(/^MIC_STOP\s+(\d+)$/);
    if (stopMatch) {
      const pid = parseInt(stopMatch[1], 10);
      this._activeMicPids.delete(pid);
      if (this._activeMicPids.size === 0) {
        this._onMicStateChanged(false);
      }
      return;
    }
  }

  _tryEventDrivenLinux() {
    try {
      const child = spawn("pactl", ["subscribe"], { stdio: ["ignore", "pipe", "pipe"] });
      this._listenerProcess = child;

      let buffer = "";
      child.stdout.on("data", (data) => {
        buffer += data.toString();
        let newlineIdx;
        while ((newlineIdx = buffer.indexOf("\n")) !== -1) {
          const line = buffer.slice(0, newlineIdx).trim();
          buffer = buffer.slice(newlineIdx + 1);
          this._parsePactlSubscribeLine(line);
        }
      });

      this._attachFallbackHandlers(child, "pactl subscribe");

      // `pactl subscribe` only reports changes from here on, so a call that is
      // already up when OpenWhispr starts would otherwise never be seen.
      this._scheduleLinuxEvaluation();
      return true;
    } catch {
      return false;
    }
  }

  // Any capture OR playback change can flip the verdict: a browser call is only
  // recognised once both its mic and its playback stream exist, and those two
  // events do not arrive together.
  _parsePactlSubscribeLine(line) {
    if (!/on\s+(source-output|sink-input)/i.test(line)) return;
    this._scheduleLinuxEvaluation();
  }

  _scheduleLinuxEvaluation() {
    if (this._linuxEvalTimer) return;
    this._linuxEvalTimer = setTimeout(() => {
      this._linuxEvalTimer = null;
      this._evaluateLinux();
    }, LINUX_EVAL_DEBOUNCE_MS);
  }

  async _evaluateLinux() {
    if (!this._running) return;

    // Serialise: a burst of events must not race several pactl queries into
    // conflicting _onMicStateChanged calls. Re-run once if events arrived while
    // a query was in flight, so the last state observed always wins.
    if (this._linuxEvaluating) {
      this._linuxEvalPending = true;
      return;
    }
    this._linuxEvaluating = true;
    try {
      const active = await this._checkLinux();
      debugLogger.debug("Linux meeting audio evaluation", { active }, "meeting");
      this._onMicStateChanged(active);
    } catch (err) {
      debugLogger.warn("Linux meeting audio evaluation failed", { error: err.message }, "meeting");
    } finally {
      this._linuxEvaluating = false;
      if (this._linuxEvalPending) {
        this._linuxEvalPending = false;
        this._scheduleLinuxEvaluation();
      }
    }
  }

  // Every application.name / application.process.binary pactl reports for the
  // given stream kind, lowercased. Both properties are collected because apps
  // are inconsistent about which they set ("ZOOM VoiceEngine" vs "zoom").
  async _linuxStreamOwners(kind) {
    const { stdout } = await execAsync(`pactl list ${kind}`, EXEC_OPTS);
    const owners = new Set();
    const re = /application\.(?:name|process\.binary) = "([^"]*)"/g;
    let match;
    while ((match = re.exec(stdout)) !== null) {
      const value = match[1].trim().toLowerCase();
      if (value) owners.add(value.split("/").pop());
    }
    return owners;
  }

  // ---------------------------------------------------------------------------
  // Shared event-driven handler
  // ---------------------------------------------------------------------------

  _onMicStateChanged(active) {
    if (this._userRecording) {
      debugLogger.debug("Mic state changed but user recording, ignoring", { active }, "meeting");
      return;
    }
    if (this.lastDismissedAt && Date.now() - this.lastDismissedAt < COOLDOWN_MS) {
      debugLogger.debug(
        "Mic state changed but in cooldown",
        {
          active,
          remainingMs: COOLDOWN_MS - (Date.now() - this.lastDismissedAt),
        },
        "meeting"
      );
      return;
    }

    debugLogger.debug(
      "Mic state changed (event-driven)",
      { active, hasPrompted: this.hasPrompted },
      "meeting"
    );

    if (active) {
      this._clearResetTimer();
      if (this.hasPrompted) {
        debugLogger.debug("Mic active but already prompted, suppressing", {}, "meeting");
        return;
      }
      if (!this.audioActiveStart) this.audioActiveStart = Date.now();

      if (!this._sustainedTimer) {
        this._sustainedTimer = setTimeout(() => {
          this._sustainedTimer = null;
          if (this._userRecording || this.hasPrompted) return;
          if (this.lastDismissedAt && Date.now() - this.lastDismissedAt < COOLDOWN_MS) return;

          this.hasPrompted = true;
          const now = Date.now();
          const durationMs = now - this.audioActiveStart;
          debugLogger.info(
            "Sustained audio activity detected (event-driven)",
            { durationMs },
            "meeting"
          );
          this.emit("sustained-audio-detected", { durationMs, detectedAt: now });
        }, SUSTAINED_EVENT_DRIVEN_MS);
      }
    } else {
      this._clearSustainedTimer();
      this.audioActiveStart = null;
      if (this.hasPrompted) this._startResetTimer();
    }
  }

  // ---------------------------------------------------------------------------
  // Polling fallback
  // ---------------------------------------------------------------------------

  _startPolling() {
    this._check();
    this.checkInterval = setInterval(() => this._check(), CHECK_INTERVAL_MS);
  }

  async _check() {
    if (this._checking) return;
    if (this.lastDismissedAt && Date.now() - this.lastDismissedAt < COOLDOWN_MS) return;
    if (this._userRecording) return;

    this._checking = true;
    try {
      const active = await this._isMicActive();
      debugLogger.debug(
        "Mic check",
        { active, consecutiveChecks: this.consecutiveChecks },
        "meeting"
      );

      if (active) {
        this._clearResetTimer();
        this.consecutiveChecks++;
        if (!this.audioActiveStart) this.audioActiveStart = Date.now();

        if (!this.hasPrompted && this.consecutiveChecks >= SUSTAINED_THRESHOLD_CHECKS) {
          this.hasPrompted = true;
          const now = Date.now();
          const durationMs = now - this.audioActiveStart;
          debugLogger.info(
            "Sustained audio activity detected",
            { consecutiveChecks: this.consecutiveChecks, durationMs },
            "meeting"
          );
          this.emit("sustained-audio-detected", { durationMs, detectedAt: now });
        }
      } else {
        if (this.consecutiveChecks > 0) {
          debugLogger.debug(
            "Mic activity reset",
            { previousChecks: this.consecutiveChecks },
            "meeting"
          );
        }
        this.consecutiveChecks = 0;
        this.audioActiveStart = null;
        if (this.hasPrompted) this._startResetTimer();
      }
    } finally {
      this._checking = false;
    }
  }

  async _isMicActive() {
    switch (process.platform) {
      case "darwin":
        return this._checkDarwin();
      case "win32":
        return this._checkWin32();
      case "linux":
        return this._checkLinux();
      default:
        return false;
    }
  }

  async _checkDarwin() {
    try {
      const { stdout } = await execAsync(
        "ioreg -l -w 0 | grep '\"IOAudioEngineState\" = 1'",
        EXEC_OPTS
      );
      return stdout.trim().length > 0;
    } catch {
      return false;
    }
  }

  async _checkWin32() {
    try {
      const processListCache = require("./processListCache");
      const names = await processListCache.getProcessList();
      return (
        names.includes("cpthost.exe") ||
        names.includes("ms-teams_modulehost.exe") ||
        names.includes("webexmeetingsapp.exe")
      );
    } catch {
      return false;
    }
  }

  // True only when the microphone is held by something that looks like a
  // meeting — NOT merely when the microphone is in use.
  async _checkLinux() {
    let micOwners;
    try {
      micOwners = await this._linuxStreamOwners("source-outputs");
    } catch (err) {
      debugLogger.warn("pactl source-output query failed", { error: err.message }, "meeting");
      return false;
    }

    const candidates = [...micOwners].filter(
      (owner) => !matchesKeyword(owner, LINUX_IGNORED_KEYWORDS)
    );
    if (candidates.length === 0) return false;

    const nativeClient = candidates.find((owner) => matchesKeyword(owner, LINUX_MEETING_KEYWORDS));
    if (nativeClient) {
      debugLogger.debug("Meeting mic owner (native client)", { owner: nativeClient }, "meeting");
      return true;
    }

    // A browser has the mic. Require playback from the SAME browser — matched by
    // keyword rather than PID, since browsers capture and render audio from a
    // shared audio-service process whose identity differs from the tab's.
    const browserKeys = LINUX_BROWSER_KEYWORDS.filter((key) =>
      candidates.some((owner) => owner.includes(key))
    );
    if (browserKeys.length === 0) {
      debugLogger.debug("Mic in use by non-meeting app, ignoring", { candidates }, "meeting");
      return false;
    }

    let playbackOwners;
    try {
      playbackOwners = await this._linuxStreamOwners("sink-inputs");
    } catch (err) {
      debugLogger.warn("pactl sink-input query failed", { error: err.message }, "meeting");
      return false;
    }

    const twoWay = browserKeys.find((key) =>
      [...playbackOwners].some((owner) => owner.includes(key))
    );
    if (twoWay) {
      debugLogger.debug("Meeting mic owner (browser, two-way audio)", { browser: twoWay }, "meeting");
      return true;
    }

    debugLogger.debug(
      "Browser holds mic but is not playing audio, ignoring",
      { browserKeys },
      "meeting"
    );
    return false;
  }
}

module.exports = AudioActivityDetector;
