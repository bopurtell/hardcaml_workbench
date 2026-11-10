"""Shared dashboard PTY driver, using an already configured test session.

Session needs args.client, url, root, env and evidence. No daemon, provider,
fixture or build is started here. Defaults preserve the 120x40 dashboard oracle.
"""
import errno
import fcntl
import os
import pty
import select
import struct
import subprocess
import termios
import time

from .screen import terminal_screen


class Terminal:
    def __init__(self, session):
        self.session = session
        self.data = bytearray()
        self.master, slave = pty.openpty()
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
            self.process = subprocess.Popen(
                [str(session.args.client), '--connect', session.url, '--project-root', str(session.root)],
                stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
                env=dict(session.env, TERM='xterm-256color'))
        except BaseException:
            os.close(self.master)
            self.master = None
            raise
        finally:
            os.close(slave)

    def drain(self, seconds=.3):
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            if select.select([self.master], [], [], min(.05, remaining))[0]:
                try:
                    data = os.read(self.master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:  # Linux PTY EOF after slave exit.
                        raise
                    break
                if not data:
                    break
                self.data.extend(data)
        if self.process.poll() is not None:
            raise AssertionError('PTY client exited unexpectedly')
        return terminal_screen(bytes(self.data))

    def capture(self, label, expected=(), absent=(), timeout=12):
        deadline = time.monotonic() + timeout
        while True:
            text = self.drain(min(.3, max(0, deadline - time.monotonic())))
            if (all(s.casefold() in text.casefold() for s in expected)
                    and all(s.casefold() not in text.casefold() for s in absent)):
                break
            if time.monotonic() >= deadline:
                self.save(label, text)
                raise AssertionError(f'{label}: expected {expected!r}, absent {absent!r}\n{text}')
        self.save(label, text)
        return text

    def save(self, label, text):
        (self.session.evidence / (label + '.txt')).write_text(text)
        (self.session.evidence / (label + '.ansi')).write_bytes(self.data)

    def palette(self, title):
        for key in (b' ', b'c', b'c'):
            os.write(self.master, key)
            self.drain(.12)
        os.write(self.master, title.encode())
        self.capture('palette-' + str(time.time_ns()), [title])
        os.write(self.master, b'\r')
        self.drain(.5)

    def close(self, timeout=10):
        """Reap this client, close the PTY and retain bytes, also on kill fallback.

        Idempotent; timeout bounds each terminate/kill wait separately.
        """
        try:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=timeout)
        finally:
            if self.master is not None:
                os.close(self.master)
                self.master = None
            (self.session.evidence / 'pty.ansi').write_bytes(self.data)
