"""A small synchronous client of the agent socket (the command line uses it; so can scripts)."""
import itertools
import json
import socket

from . import protocol
from .server import socket_path


class AgentError(Exception):
    def __init__(self, code, message):
        super().__init__(f'{code}: {message}')
        self.code, self.message = code, message


class AgentUnavailable(Exception):
    pass


class AgentClient:
    def __init__(self, path=None, timeout=30):
        self.path = str(path or socket_path())
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        try:
            self.sock.connect(self.path)
        except OSError as e:
            self.sock.close()
            raise AgentUnavailable(f'the agent is not running ({self.path}: {e.strerror or e}); '
                                   'start it with: python3 -m mng_agent install (or serve)') from None
        self.ids = itertools.count(1)
        self.buffer = b''
        self.pending_events = []

    def close(self):
        self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def _read(self):
        while b'\n' not in self.buffer:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise AgentUnavailable('the agent closed the connection')
            self.buffer += chunk
            if len(self.buffer) > protocol.MAX_LINE * 2:
                raise AgentUnavailable('reply too long')
        line, self.buffer = self.buffer.split(b'\n', 1)
        return json.loads(line)

    def call(self, method, **params):
        rid = next(self.ids)
        self.sock.sendall(protocol.encode({'id': rid, 'method': method, 'params': params}))
        while True:
            message = self._read()
            if 'event' in message:
                self.pending_events.append(message)
                continue
            if message.get('id') != rid:
                continue
            if 'error' in message:
                raise AgentError(message['error'].get('code'), message['error'].get('message'))
            return message.get('result')

    def events(self, timeout=None):
        """Subscribe, then yield events forever (or until timeout seconds pass with none)."""
        self.call('subscribe')
        self.sock.settimeout(timeout)
        while True:
            while self.pending_events:
                yield self.pending_events.pop(0)
            try:
                message = self._read()
            except socket.timeout:
                return
            if 'event' in message:
                yield message
