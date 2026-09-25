from pathlib import Path
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "zig-build.sh"


class ZigBuildTests(unittest.TestCase):
    def run_script(self, zig, *args):
        env = os.environ.copy()
        env["PATH"] = str(zig.parent) + os.pathsep + env["PATH"]
        env["TOASTTY_ZIG_BUILD_ATTEMPTS"] = "3"
        env["TOASTTY_ZIG_BUILD_RETRY_DELAY"] = "0"
        return subprocess.run(
            [str(SCRIPT), *args],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
        )

    def write_zig(self, directory, body):
        path = Path(directory) / "zig"
        path.write_text(textwrap.dedent(body))
        path.chmod(path.stat().st_mode | stat.S_IEXEC)
        return path

    def test_retries_savannah_fetch_timeouts(self):
        with tempfile.TemporaryDirectory() as tmp:
            count = Path(tmp) / "count"
            zig = self.write_zig(tmp, f"""\
                #!/bin/bash
                n=0
                [[ -f {count} ]] && n=$(cat {count})
                n=$((n + 1))
                echo "$n" > {count}
                if [[ "$n" -lt 3 ]]; then
                  echo 'pkg/freetype/build.zig.zon:9:20: error: unable to connect to server: Timeout' >&2
                  exit 1
                fi
                echo "built $*"
                """)
            result = self.run_script(zig, "-Demit-macos-app=false", "-Doptimize=ReleaseFast")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(count.read_text().strip(), "3")
            self.assertIn("built build -Demit-macos-app=false -Doptimize=ReleaseFast", result.stdout)
            self.assertEqual(result.stderr.count("retrying"), 2)

    def test_does_not_retry_tests_that_print_the_fetch_phrase(self):
        with tempfile.TemporaryDirectory() as tmp:
            count = Path(tmp) / "count"
            zig = self.write_zig(tmp, f"""\
                #!/bin/bash
                echo 1 >> {count}
                echo '1/1 test.fetch... FAIL (unable to connect to server)' >&2
                exit 1
                """)
            result = self.run_script(zig, "test")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(count.read_text().strip(), "1")
            self.assertNotIn("retrying", result.stderr)

    def test_does_not_retry_compile_failures(self):
        with tempfile.TemporaryDirectory() as tmp:
            count = Path(tmp) / "count"
            zig = self.write_zig(tmp, f"""\
                #!/bin/bash
                echo 1 >> {count}
                echo 'error: unexpected token' >&2
                exit 1
                """)
            result = self.run_script(zig, "test")
            self.assertEqual(result.returncode, 1)
            self.assertEqual(count.read_text().strip(), "1")
            self.assertNotIn("retrying", result.stderr)

    def test_nightly_reuses_the_macos_ci_zig_cache(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        nightly = (ROOT / ".github/workflows/nightly.yml").read_text()
        # setup-zig names its cache with the job id. These jobs must stay
        # aligned, and the cap must stay above a ReleaseFast cache (~2143 MiB).
        self.assertEqual(ci.count("cache-size-limit: 8192"), 2)
        self.assertEqual(nightly.count("cache-size-limit: 8192"), 1)
        self.assertRegex(ci.split("jobs:", 1)[1], r"\n  build-and-test:\n")
        self.assertRegex(nightly.split("jobs:", 1)[1], r"\n  build-and-test:\n")
        self.assertIn("scripts/zig-build.sh -Demit-macos-app=false -Doptimize=ReleaseFast", nightly)
