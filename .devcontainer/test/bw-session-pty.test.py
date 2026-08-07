#!/usr/bin/env python3
"""Regression tests for interactive Bitwarden prompts through the sanitizer."""

import os
import pathlib
import pty
import select
import signal
import tempfile
import time
import unittest


LIBRARY = pathlib.Path(__file__).resolve().parents[1] / "lib" / "bw-session.sh"


class BwSessionPtyTest(unittest.TestCase):
    def run_scenario(self, logged_in: bool) -> str:
        with tempfile.TemporaryDirectory() as temporary_directory:
            fake_bin = pathlib.Path(temporary_directory)
            fake_bw = fake_bin / "bw"
            fake_bw.write_text(
                """#!/usr/bin/env bash
case "${1:-}" in
  login)
    if [ "${2:-}" = --check ]; then
      [ "${BW_TEST_LOGGED_IN:-}" = true ]
      exit
    fi
    printf 'Master password: '
    IFS= read -r _password
    printf '\\nexport BW_SESSION="pty-secret"\\n'
    ;;
  unlock)
    printf 'Master password: '
    IFS= read -r _password
    printf '\\nexport BW_SESSION="pty-secret"\\n'
    ;;
  sync|lock)
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
"""
            )
            fake_bw.chmod(0o755)

            pid, master = pty.fork()
            if pid == 0:
                environment = os.environ.copy()
                environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
                environment["BW_TEST_LOGGED_IN"] = "true" if logged_in else "false"
                os.execve(
                    "/bin/bash",
                    [
                        "bash",
                        "-c",
                        'source "$1"; ensure_bw_session fatal; bw_relock_if_ours',
                        "bw-session-pty-test",
                        str(LIBRARY),
                    ],
                    environment,
                )

            output = bytearray()
            deadline = time.monotonic() + 5
            status = None
            try:
                while b"Master password: " not in output:
                    remaining = deadline - time.monotonic()
                    self.assertGreater(remaining, 0, f"prompt not forwarded: {output!r}")
                    readable, _, _ = select.select([master], [], [], remaining)
                    self.assertTrue(readable, f"prompt not forwarded: {output!r}")
                    output.extend(os.read(master, 4096))

                os.write(master, b"test-password\n")
                while True:
                    waited_pid, status = os.waitpid(pid, os.WNOHANG)
                    if waited_pid == pid:
                        break
                    remaining = deadline - time.monotonic()
                    self.assertGreater(remaining, 0, f"process did not finish: {output!r}")
                    readable, _, _ = select.select([master], [], [], remaining)
                    if readable:
                        try:
                            output.extend(os.read(master, 4096))
                        except OSError:
                            pass

                while True:
                    readable, _, _ = select.select([master], [], [], 0)
                    if not readable:
                        break
                    try:
                        output.extend(os.read(master, 4096))
                    except OSError:
                        break
            finally:
                if status is None:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    try:
                        _, status = os.waitpid(pid, 0)
                    except ChildProcessError:
                        pass
                os.close(master)

            rendered = output.decode(errors="replace")
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, rendered)
            self.assertIn('BW_SESSION="[REDACTED]"', rendered)
            self.assertNotIn("pty-secret", rendered)
            return rendered

    def test_logged_out_login_prompt_is_forwarded_and_session_is_redacted(self):
        output = self.run_scenario(logged_in=False)
        self.assertIn("Logging into Bitwarden", output)

    def test_logged_in_unlock_prompt_is_forwarded_and_session_is_redacted(self):
        output = self.run_scenario(logged_in=True)
        self.assertIn("Bitwarden already logged in", output)


if __name__ == "__main__":
    unittest.main()
