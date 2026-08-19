{ pkgs }:

# linecast — weather, sunshine, moon, tides, radar and maps drawn for the
# terminal. Six commands plus a `linecast` dispatcher.
#
# Built from the GitHub tag rather than PyPI: upstream cuts no GitHub Releases
# (the releases API is empty), only tags, and fetchFromGitHub takes exactly the
# auto-generated tag archive.
#
# Pure Python with NO runtime dependencies — the only build input is hatchling,
# its build backend — so there is nothing to pin beyond the source hash.

pkgs.python3Packages.buildPythonApplication rec {
  pname = "linecast";
  version = "1.9.2";
  pyproject = true;

  src = pkgs.fetchFromGitHub {
    owner = "ashuttl";
    repo = "linecast";
    rev = "v${version}";
    hash = "sha256-cqUu4l5pmNPEuN6Ybr38WjnoLTruQ60oFGLG1tiJhnc=";
  };

  build-system = [ pkgs.python3Packages.hatchling ];

  # `sunshine` collides with the Sunshine game-streaming server already in this
  # profile — home-manager's buildEnv refuses the overlap outright ("two given
  # paths contain a conflicting subpath"), so this is a hard build failure, not
  # a silent shadowing. Drop linecast's alias rather than the streaming server:
  # the dispatcher still reaches it as `linecast sunshine`, and the other six
  # commands are untouched.
  postInstall = ''
    rm -f "$out/bin/sunshine"
  '';

  # Ships no test suite; the import check is the smoke test.
  doCheck = false;
  pythonImportsCheck = [ "linecast" ];

  meta = with pkgs.lib; {
    description = "Weather, sunlight, tides, radar, the moon, and maps, in your terminal";
    homepage = "https://github.com/ashuttl/linecast";
    license = licenses.mit;
    mainProgram = "linecast";
    platforms = platforms.unix;
  };
}
