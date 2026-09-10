# cliamp, with a resolved-URL cache in front of the yt-dlp streaming path.
#
# THE PROBLEM. Every yt-dlp track starts by spawning `yt-dlp | ffmpeg`
# (player/ytdl.go, decodeYTDLPipe). Nearly all of that cost is extraction --
# fetching YouTube's player JS and running the nsig decipher -- not the audio
# download. Measured on this host: 1.3-2.1 s to first bytes for a cold page
# URL, against 67 ms for ffmpeg opening the already-resolved media URL. So a
# Next or Prev keypress stalls for a second or two before audio.
#
# WHY UPSTREAM'S PRELOAD DOES NOT COVER IT. ui/model/preload.go arms a gapless
# pipeline for the next track, but only inside a 15 s window before the current
# track ends (ytdlPreloadLeadTime), and beginPlaybackTrack calls ClearPreload()
# on EVERY explicit track change. So the armed pipeline serves auto-advance at
# the end of a track and nothing else: a mid-track skip always pays full price,
# and Prev has no preload path at all.
#
# WHAT THIS ADDS. player/ytdlurlcache.go memoises page URL -> direct media URL.
# buildYTDLPipeline consults it and, on a hit, plays through ffmpeg alone;
# ui/model warms both playlist neighbours whenever a track starts. Warming
# holds no connection and no pipeline -- it stores a string -- which is why it
# can run for the whole track instead of a lead-time window, and why a manual
# switch need not discard it. That distinction is what makes this safe to do
# where upstream's pipeline preload is not.
#
# WHY IT DEGRADES SAFELY. Every failure path falls back to the stock yt-dlp
# pipe: a cache miss, an expired URL, or an ffmpeg that refuses the URL all
# return nil from buildCachedYTDLPipeline. A stale entry therefore costs a slow
# start, never a failed track. Entries expire on the URL's own expire= epoch
# (~6 h for googlevideo) minus a guard, and HLS is declined outright because it
# needs yt-dlp's segment handling. Seeking is untouched: the fast path is taken
# only at startSec == 0, so seek-by-restart still re-extracts from the page URL.
#
# WHY NOT nixpkgs' cliamp. nixpkgs pins v1.63.2 (2026-08-13). The patch targets
# v2.2.0, which upstream released 2026-09-08; the touched files differ by
# ~1,600 lines between the two, so the patch cannot apply to the packaged
# version. Rebasing onto month-old code upstream has already moved past would
# be more work for a worse result.
#
# WHY UPSTREAM'S package.nix AND NOT overrideAttrs ON nixpkgs' DERIVATION.
# nixpkgs' v1.63.2 derivation predates upstream's own non-NixOS ALSA fix
# (v2.1.0, "ship ALSA pipewire/pulse plugins so audio works on non-NixOS").
# Omarchy is non-NixOS and routes the default ALSA device through
# libasound_module_pcm_pipewire.so, named by bare filename in
# /etc/alsa/conf.d; nix's libasound searches only its own store path, so
# without ALSA_PLUGIN_DIR the lookup fails and cliamp plays into SILENCE. The
# override route was verified to produce a wrapper with no ALSA_PLUGIN_DIR.
# Upstream's nix/package.nix sets it, and also carries the vendorHash matching
# this tag, so the patched source is built with its own packaging.
#
# THE GATE. buildGoModule's checkPhase runs the package's tests, and the patch
# ships player/ytdlurlcache_test.go and ui/model/warm_neighbors_test.go, so a
# fast path that stops being wired up fails the build rather than silently
# reverting to cold starts. postPatch asserts the same at source level for a
# clearer message, and passthru.ytdlURLCache lets a consumer check at EVAL time
# that it got the patched build and not stock nixpkgs cliamp.
{
  applyPatches,
  callPackage,
  fetchFromGitHub,
  lib,
}:

let
  version = "2.2.0";

  # The patch is applied to the SOURCE, then upstream's own package.nix is
  # evaluated from inside that patched tree: its `src = lib.cleanSource ../.`
  # resolves relative to the file, so it picks up the patched checkout rather
  # than a pristine fetch.
  patchedSrc = applyPatches {
    name = "cliamp-${version}-ytdl-url-cache-src";
    src = fetchFromGitHub {
      owner = "bjarneo";
      repo = "cliamp";
      tag = "v${version}";
      hash = "sha256-PC+1uOt/LBGkW+ASNyGrS0e/rB8mcr+ILlcnf3F8esU=";
    };
    patches = [ ./cliamp-ytdl-url-cache.patch ];
  };
in
(callPackage "${patchedSrc}/nix/package.nix" { inherit version; }).overrideAttrs (prev: {
  # Upstream's package.nix computed its vendorHash against a different nixpkgs;
  # this pin's Go produces a different module set. Tracks the pin, not the
  # patch -- net/url, os/exec and sync are stdlib, so the patch vendors nothing.
  vendorHash = "sha256-d/ENFm9b1DkIir1lz50VVX1pvuQpwPUVlA5XOC7Jj5o=";

  postPatch = (prev.postPatch or "") + ''
    # Decidable proof the fast path is wired in, independent of `patch` exit
    # codes: buildYTDLPipeline must consult the cache, and the UI must warm
    # neighbours. Either one missing means tracks quietly start cold again.
    grep -q 'buildCachedYTDLPipeline' player/ytdl.go || {
      echo "cliamp: buildYTDLPipeline does not consult the URL cache --" >&2
      echo "the patch did not apply. Track changes would pay a full yt-dlp" >&2
      echo "extraction. See modules/linux/cliamp-ytdl-cache.nix." >&2
      exit 1
    }
    grep -q 'warmNeighbors' ui/model/playback.go || {
      echo "cliamp: neighbours are never warmed; the cache would stay empty." >&2
      exit 1
    }
    test -f player/ytdlurlcache_test.go || {
      echo "cliamp: cache tests missing; the build gate is gone." >&2
      exit 1
    }
    # The reason this build exists rather than an overrideAttrs on nixpkgs'
    # cliamp: on non-NixOS the ALSA default device needs the plugin directory,
    # or playback is silent with no error.
    grep -q 'ALSA_PLUGIN_DIR' nix/package.nix || {
      echo "cliamp: upstream package.nix no longer sets ALSA_PLUGIN_DIR;" >&2
      echo "audio would be silent on this non-NixOS host." >&2
      exit 1
    }
  '';

  passthru = (prev.passthru or { }) // { ytdlURLCache = true; };
})
