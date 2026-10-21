"""The wire format between the agent and its clients: one JSON object per line, UTF-8, both ways.

    request   {"id": <int|str>, "method": "<name>", "params": {...}}
    response  {"id": <same>, "result": <any>}  or  {"id": <same>, "error": {"code": "<code>", "message": "..."}}
    event     {"event": "<name>", ...}           (pushed to clients that called "subscribe"; never has an "id")

A line longer than MAX_LINE bytes closes the connection. Error codes are the constants below.
"""
import json

MAX_LINE = 1 << 20

BAD_REQUEST = 'bad_request'
UNKNOWN_METHOD = 'unknown_method'
INVALID_PARAMS = 'invalid_params'
NOT_FOUND = 'not_found'
CONFLICT = 'conflict'
FAILED = 'failed'
INTERNAL = 'internal'


class ProtocolError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def encode(obj):
    return (json.dumps(obj, separators=(',', ':'), ensure_ascii=False, default=str) + '\n').encode()


def decode(line):
    """A request object from one line, or ProtocolError."""
    if len(line) > MAX_LINE:
        raise ProtocolError(BAD_REQUEST, 'line too long')
    try:
        obj = json.loads(line.decode('utf-8'))
    except (UnicodeDecodeError, ValueError) as e:
        raise ProtocolError(BAD_REQUEST, f'not JSON: {e}') from None
    if not isinstance(obj, dict):
        raise ProtocolError(BAD_REQUEST, 'a request is a JSON object')
    return obj


def check_request(obj):
    """(id, method, params) of a valid request."""
    rid = obj.get('id')
    if rid is None or isinstance(rid, (bool, float, dict, list)):
        raise ProtocolError(BAD_REQUEST, 'a request needs an integer or string id')
    method = obj.get('method')
    if not isinstance(method, str) or not method:
        raise ProtocolError(BAD_REQUEST, 'a request needs a method')
    params = obj.get('params', {})
    if params is None:
        params = {}
    if not isinstance(params, dict):
        raise ProtocolError(INVALID_PARAMS, 'params must be an object')
    return rid, method, params


def response(rid, result):
    return {'id': rid, 'result': result}


def error(rid, code, message):
    return {'id': rid, 'error': {'code': code, 'message': message}}


def read_lines(sock, buffer=b''):
    """Yield complete lines (without the newline) from a socket until it closes; raises ProtocolError on an
    over-long line."""
    while True:
        while b'\n' in buffer:
            line, buffer = buffer.split(b'\n', 1)
            if len(line) > MAX_LINE:
                raise ProtocolError(BAD_REQUEST, 'line too long')
            yield line
        if len(buffer) > MAX_LINE:
            raise ProtocolError(BAD_REQUEST, 'line too long')
        chunk = sock.recv(65536)
        if not chunk:
            return
        buffer += chunk
