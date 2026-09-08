"""Exercise the Nix-defined serve script without building or switching a profile.

Run: python3 modules/linux/test_aerc_mail_serve.py
The Nix packaging primitives are stubs; the evaluated shell and mail helpers
are real. Each test owns its runtime file, temp root, and child processes.
"""

import ctypes
import json
import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
HELPERS = ROOT / "hosts/linux/omarchy/files"
MESSAGE = b"MIME-Version: 1.0\nContent-Type: text/html; charset=utf-8\n\n<html><body>preview-leak-test</body></html>\n"


def serve_script():
    expression = r"""
      import MODULE {
        lib.makeBinPath = _: "/usr/bin:/bin";
        writeText = _: _: "";
        writeShellScript = name: text:
          if name == "aerc-mail-serve" then
            "SERVE_BEGIN" + builtins.toJSON text + "SERVE_END"
          else "";
        symlinkJoin = attrs: attrs.postBuild;
        python3 = null; coreutils = null; aerc = null;
        mailServe = SERVER;
        mailInlineImages = INLINE;
      }
    """
    expression = expression.replace(
        "MODULE", str(ROOT / "modules/linux/aerc-html-terminal-browser.nix")
    )
    expression = expression.replace(
        "SERVER", json.dumps(str(HELPERS / "mail-serve.py"))
    )
    expression = expression.replace(
        "INLINE", json.dumps(str(HELPERS / "mail-inline-images.py"))
    )
    result = subprocess.run(
        ["nix", "eval", "--impure", "--raw", "--expr", expression],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout.split("SERVE_BEGIN", 1)[1].split("SERVE_END", 1)[0])


class ServeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Adopt only our detached descendants, so the test can wait for them
        # rather than depending on the host's PID 1 to collect zombies.
        if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")
        cls.script = serve_script()
        subprocess.run(["bash", "-n"], input=cls.script, text=True, check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="aerc-serve-test-")
        self.root = Path(self.temp.name)
        self.runtime = self.root / "runtime"
        self.docs = self.root / "docs"
        self.runtime.mkdir()
        self.docs.mkdir()
        self.urlfile = self.runtime / "aerc-mail-browser-url"
        self.env = dict(
            os.environ, TMPDIR=str(self.docs), XDG_RUNTIME_DIR=str(self.runtime)
        )
        self.servers = []

    def tearDown(self):
        for _, _, pid in self.servers:
            try:
                waited, _ = os.waitpid(pid, os.WNOHANG)
                if waited == 0:
                    os.kill(pid, signal.SIGTERM)
                    os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        self.temp.cleanup()

    def new_doc(self):
        return Path(
            subprocess.check_output(
                ["mktemp", "-d", "-t", "aerc-mail-XXXXXX"],
                env=self.env,
                text=True,
            ).strip()
        )

    def run_serve(self):
        result = subprocess.run(
            ["bash", "-c", self.script],
            input=MESSAGE,
            env=self.env,
            capture_output=True,
            timeout=15,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        lines = self.urlfile.read_text().splitlines()
        self.assertEqual(len(lines), 3, lines)
        url, directory, pid = lines
        record = (url, Path(directory), int(pid))
        self.servers.append(record)
        self.assertTrue(record[1].is_dir())
        os.kill(record[2], 0)
        with urlopen(url, timeout=3) as response:
            self.assertEqual(response.status, 200)
            self.assertIn(b"preview-leak-test", response.read())
        print(
            f"RUN exit=0; URL file lines={len(lines)}; HTTP=200; body marker=yes",
            flush=True,
        )
        print(self.urlfile.read_text(), end="", flush=True)
        return record

    def gone(self, pid):
        for _ in range(100):
            try:
                waited, _ = os.waitpid(pid, os.WNOHANG)
                if waited == pid:
                    return True
            except ChildProcessError:
                return not Path(f"/proc/{pid}").exists()
            time.sleep(0.01)
        return False

    def test_previous_preview_reaped(self):
        print("\nMISSING FILE -> FIRST RUN", flush=True)
        first = self.run_serve()
        print("SECOND RUN", flush=True)
        second = self.run_serve()
        gone = self.gone(first[2])
        removed = not first[1].exists()
        print(
            f"FIRST pid={first[2]} gone={gone}; directory={first[1]} removed={removed}",
            flush=True,
        )
        print(
            f"SECOND pid={second[2]} alive={Path(f'/proc/{second[2]}').exists()}; directory exists={second[1].is_dir()}",
            flush=True,
        )
        self.assertTrue(gone, "previous server survived second run")
        self.assertTrue(removed, "previous directory survived second run")

    def test_short_files(self):
        for line_count, final_newline in ((0, False), (1, True), (2, True), (2, False)):
            directory = self.new_doc()
            text = "\n".join(["old-url", str(directory)][:line_count])
            if final_newline:
                text += "\n"
            self.urlfile.write_text(text)
            print(f"\nSHORT FILE lines={len(text.splitlines())}", flush=True)
            self.run_serve()
            if len(text.splitlines()) == 2:
                self.assertFalse(directory.exists())

    def test_unrelated_pid_and_unsafe_paths(self):
        safe = self.new_doc()
        other_script = self.root / "unrelated.py"
        other_script.write_text("import time; time.sleep(60)\n")
        unrelated = subprocess.Popen(
            ["python3", str(other_script), str(safe)], cwd=safe
        )
        try:
            victim = self.root / "keep"
            victim.mkdir()
            (victim / "sentinel").write_text("keep")
            link = self.docs / "aerc-mail-ABC123"
            link.symlink_to(victim, target_is_directory=True)
            for directory in (
                str(safe),
                "",
                "/",
                str(victim),
                str(link),
                str(self.docs / "aerc-mail-ABC123/.."),
            ):
                self.urlfile.write_text(f"old-url\n{directory}\n{unrelated.pid}\n")
                self.run_serve()
                self.assertIsNone(unrelated.poll(), "unrelated PID was killed")
                self.assertTrue((victim / "sentinel").exists())
                self.assertTrue(self.docs.is_dir())
            self.assertFalse(safe.exists())
            self.assertTrue(link.is_symlink())
            print(
                "SAFE: unrelated PID alive; unsafe paths and symlink target preserved",
                flush=True,
            )
        finally:
            unrelated.terminate()
            unrelated.wait()

    def test_dead_and_invalid_pids(self):
        dead = subprocess.Popen(["true"])
        dead.wait()
        for pid in (str(dead.pid), "", "not-a-pid", "0", "-1"):
            directory = self.new_doc()
            self.urlfile.write_text(f"old-url\n{directory}\n{pid}\n")
            self.run_serve()
            self.assertFalse(directory.exists())
        print(
            "SAFE: dead, missing, nonnumeric, zero and negative PIDs tolerated",
            flush=True,
        )

    def test_different_preview_pid(self):
        first = self.run_serve()
        other = self.new_doc()
        self.urlfile.write_text(f"old-url\n{other}\n{first[2]}\n")
        self.run_serve()
        os.kill(first[2], 0)
        self.assertTrue(first[1].is_dir())
        self.assertFalse(other.exists())
        print(
            "SAFE: mail-serve PID for a different document was not killed", flush=True
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
