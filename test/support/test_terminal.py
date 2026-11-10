"""Controlled stdlib tests; run with python3 -B /absolute/path/to/this/file.

Only private temporary Python clients are launched, never Workbench or providers.
"""
import errno
import importlib.util
import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from support.screen import terminal_screen
from support.terminal import Terminal

REPO = Path(__file__).resolve().parents[2]


class TerminalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='workbench-pty-support-', dir='/tmp/opencode')
        self.addCleanup(self.temp.cleanup)
        self.evidence = Path(self.temp.name)
        self.client = self.evidence / 'client'
        self.session = SimpleNamespace(args=SimpleNamespace(client=self.client),
                                       url='unused', root=self.evidence,
                                       env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'),
                                       evidence=self.evidence)

    def start(self, body):
        self.client.write_text('#!' + sys.executable + '\n' + body)
        self.client.chmod(0o700)
        terminal = Terminal(self.session)
        self.addCleanup(terminal.close)
        return terminal

    def idle(self):
        return self.start('import time\nprint("READY", flush=True)\ntime.sleep(30)\n')

    def test_screen_replaces_stale_diff_and_preserves_unicode_rules(self):
        data = 'OLD\x1b[2J\x1b[Hnew\x1b[2;1H界e\u0301!'.encode()
        self.assertEqual(terminal_screen(data, width=8, height=2), 'new\n界 e!')

    def test_capture_and_saved_evidence(self):
        terminal = self.idle()
        text = terminal.capture('ready', ['ready'], ['old'], timeout=2)
        self.assertIn('READY', text)
        self.assertEqual((self.evidence / 'ready.ansi').read_bytes(), terminal.data)
        self.assertEqual((self.evidence / 'ready.txt').read_text(), text)

    def test_capture_deadline_saves_failure(self):
        terminal = self.idle()
        terminal.capture('ready', ['READY'], timeout=2)
        started = time.monotonic()
        with self.assertRaisesRegex(AssertionError, 'expected.*missing'):
            terminal.capture('missing', ['missing'], timeout=.06)
        self.assertLess(time.monotonic() - started, .6)
        self.assertIn('READY', (self.evidence / 'missing.txt').read_text())
        self.assertEqual((self.evidence / 'missing.ansi').read_bytes(), terminal.data)

    def test_exit_is_not_a_successful_empty_capture(self):
        terminal = self.start('print("EXIT", flush=True)\n')
        terminal.process.wait(timeout=2)
        with self.assertRaisesRegex(AssertionError, 'exited unexpectedly'):
            terminal.capture('exit', timeout=.1)
        terminal.close()
        self.assertIn(b'EXIT', (self.evidence / 'pty.ansi').read_bytes())

    def test_spawn_failure_closes_both_fds(self):
        master, slave = pty.openpty()
        with patch('support.terminal.pty.openpty', return_value=(master, slave)):
            with self.assertRaises(FileNotFoundError):
                Terminal(self.session)
        for fd in (master, slave):
            with self.assertRaises(OSError):
                os.fstat(fd)

    def test_unexpected_read_error_propagates(self):
        terminal = self.idle()
        with patch('support.terminal.select.select', return_value=([terminal.master], [], [])), \
             patch('support.terminal.os.read', side_effect=OSError(errno.EBADF, 'bad fd')):
            with self.assertRaises(OSError) as error:
                terminal.drain(.1)
        self.assertEqual(error.exception.errno, errno.EBADF)

    def test_close_kills_reaps_and_is_idempotent(self):
        terminal = self.start('import signal,time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
                              'print("READY", flush=True)\ntime.sleep(30)\n')
        terminal.capture('ready', ['READY'], timeout=2)
        fd = terminal.master
        terminal.close(timeout=.1)
        self.assertEqual(terminal.process.returncode, -9)
        with self.assertRaises(OSError):
            os.fstat(fd)
        terminal.close(timeout=.1)
        self.assertIn(b'READY', (self.evidence / 'pty.ansi').read_bytes())

    def test_close_still_closes_fd_and_saves_if_wait_fails(self):
        terminal = self.idle()
        terminal.capture('ready', ['READY'], timeout=2)
        with patch.object(terminal.process, 'wait', side_effect=RuntimeError('wait failed')):
            with self.assertRaisesRegex(RuntimeError, 'wait failed'):
                terminal.close()
        terminal.process.wait(timeout=2)
        self.assertIsNone(terminal.master)
        self.assertIn(b'READY', (self.evidence / 'pty.ansi').read_bytes())

    def test_imports_are_path_independent_and_do_not_run_main(self):
        modules = {}
        previous = Path.cwd()
        try:
            os.chdir(self.evidence)
            with patch('subprocess.Popen', side_effect=AssertionError('spawn on import')), \
                 patch('subprocess.run', side_effect=AssertionError('run on import')), \
                 patch('tempfile.mkdtemp', side_effect=AssertionError('evidence on import')):
                for filename in ('test-fs0.py', 'test-fs0-dashboard.py', 'test-fs2-native.py'):
                    spec = importlib.util.spec_from_file_location('compat_' + filename, REPO / 'scripts' / filename)
                    module = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(module)
                    modules[filename] = module
        finally:
            os.chdir(previous)
        self.assertIs(modules['test-fs0.py'].terminal_screen, terminal_screen)
        self.assertIs(modules['test-fs0-dashboard.py'].Terminal, Terminal)
        self.assertTrue(issubclass(modules['test-fs2-native.py'].Terminal, Terminal))
        self.assertEqual(list(self.evidence.iterdir()), [])

    def test_historical_help_entrypoints_from_another_directory(self):
        for filename in ('test-fs0.py', 'test-fs0-dashboard.py', 'test-fs2-native.py'):
            result = subprocess.run([sys.executable, '-B', str(REPO / 'scripts' / filename), '--help'],
                                    cwd=self.evidence, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertIn(b'--client', result.stdout)
        self.assertEqual(list(self.evidence.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
