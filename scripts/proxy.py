"""Local relay proxy for Codex.

Listens on 127.0.0.1:8787 and forwards requests to the relay configured in
upstream.txt. The selected model is passed through unchanged; only an explicit
"ultra" effort is downgraded to "max" because the relay does not accept it.
Background tasks (title generation, suggestions, commit messages, ...) are
routed to the last main model so they never fail on a model that is not
available.

Runs on Windows, macOS and Linux (Python 3.8+).
"""

import gzip
import http.client
import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.parse
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    from compression import zstd  # Python 3.14+
except ImportError:  # pragma: no cover
    zstd = None

DEFAULT_UPSTREAM = "https://your-relay.example.com"
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
UPSTREAM_FILE = os.path.join(BASE_DIR, "upstream.txt")
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8787
_upstream_cache = {"mtime": None, "value": DEFAULT_UPSTREAM}
_upstream_lock = threading.Lock()

# The relay currently accepts up to "max" and rejects "ultra" for every model.
# Keep supported levels as-is; only downgrade an explicit ultra to max.
EFFORT_FALLBACK_FROM = {"ultra"}
EFFORT_FALLBACK_TO = "max"

BACKGROUND_MODELS = {"gpt-6-luna", "gpt-6.1-terra"}
BACKGROUND_MARKERS = (
    "Generate a concise UI title",
    "hyperpersonalized suggestions",
    "git commit message",
    "pull request title and body",
    "thread turn summary",
)


def read_default_model():
    path = os.path.join(os.path.expanduser("~"), ".codex", "config.toml")
    try:
        with open(path, encoding="utf-8") as fh:
            match = re.search(r'^\s*model\s*=\s*"([^"]+)"', fh.read(), re.M)
            if match:
                return match.group(1)
    except OSError:
        pass
    return "gpt-6-astra"


_last_main_model = read_default_model()
_model_lock = threading.Lock()

LOG_PATH = os.path.join(BASE_DIR, "proxy.log")
PROXY_VERSION = "1.4.0-relay-max-only"
_log_lock = threading.Lock()


def log(message):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}\n"
    with _log_lock:
        try:
            with open(LOG_PATH, "a", encoding="utf-8") as fh:
                fh.write(line)
        except OSError:
            pass
    try:
        sys.stderr.write(line)
        sys.stderr.flush()
    except Exception:
        pass


def get_upstream():
    """Return the current upstream base URL, re-reading upstream.txt when it changes."""
    try:
        mtime = os.path.getmtime(UPSTREAM_FILE)
    except OSError:
        return DEFAULT_UPSTREAM
    with _upstream_lock:
        if _upstream_cache["mtime"] != mtime:
            url = DEFAULT_UPSTREAM
            try:
                with open(UPSTREAM_FILE, encoding="utf-8") as fh:
                    lines = fh.read().strip().splitlines()
                    if lines:
                        candidate = lines[0].strip()
                        if candidate.startswith(("http://", "https://")):
                            url = candidate
            except OSError:
                pass
            _upstream_cache["mtime"] = mtime
            _upstream_cache["value"] = url
        return _upstream_cache["value"]


def read_chunked(rfile):
    body = b""
    while True:
        line = rfile.readline()
        if not line:
            break
        size = int(line.split(b";")[0].strip() or b"0", 16)
        if size == 0:
            rfile.readline()
            break
        body += rfile.read(size)
        rfile.read(2)
    return body


SUPPORTED_ENCODINGS = {"gzip", "deflate", "zstd"}


def decode_body(body, encoding):
    enc = (encoding or "").strip().lower()
    if not body or enc in ("", "identity", "none") or enc not in SUPPORTED_ENCODINGS:
        return body, False
    try:
        if enc == "gzip":
            return gzip.decompress(body), True
        if enc == "deflate":
            return zlib.decompress(body), True
        if enc == "zstd" and zstd is not None:
            return zstd.decompress(body), True
    except Exception:
        return body, False
    return body, False


def rewrite_request(body):
    """Follow the last main model for background tasks and upgrade ultra efforts."""
    global _last_main_model
    info = {"model": None, "effort": None, "model_rewritten": None, "effort_rewritten": False, "effort_target": None}
    try:
        data = json.loads(body)
    except Exception:
        return body, info
    if not isinstance(data, dict):
        return body, info

    model = data.get("model")
    info["model"] = model
    text = body.decode("utf-8", "ignore")
    is_background = model in BACKGROUND_MODELS and any(marker in text for marker in BACKGROUND_MARKERS)
    changed = False

    if is_background:
        with _model_lock:
            target = _last_main_model
        if target and target != model:
            data["model"] = target
            info["model_rewritten"] = target
            changed = True
    elif model:
        with _model_lock:
            _last_main_model = model

    # Use the model exactly as selected; only unsupported ultra is downgraded.
    reasoning = data.get("reasoning")
    if isinstance(reasoning, dict):
        original = reasoning.get("effort")
        info["effort"] = original
        if original in EFFORT_FALLBACK_FROM:
            reasoning["effort"] = EFFORT_FALLBACK_TO
            info["effort_rewritten"] = True
            info["effort_target"] = EFFORT_FALLBACK_TO
            changed = True

    if not changed:
        return body, info
    return json.dumps(data, ensure_ascii=False).encode("utf-8"), info


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CodexRelayProxy/1.0"

    def log_message(self, fmt, *args):  # silence default stderr logging
        return

    def do_GET(self):
        self._proxy()

    def do_POST(self):
        self._proxy()

    def do_PUT(self):
        self._proxy()

    def do_DELETE(self):
        self._proxy()

    def _read_body(self):
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            return read_chunked(self.rfile)
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else None

    def _proxy(self):
        raw = self._read_body()
        body = raw
        ctype = self.headers.get("Content-Type") or ""
        cenc = self.headers.get("Content-Encoding") or ""
        detail = f"ct={ctype.split(';')[0]} enc={cenc or '-'} bytes={len(raw) if raw else 0}"
        rewrite_note = ""
        drop_encoding = False

        if raw and "responses" in self.path:
            decoded, decoded_ok = decode_body(raw, cenc)
            new_body, info = rewrite_request(decoded)
            detail += f" model={info['model'] or '-'} effort={info['effort'] or '-'}"
            notes = []
            if info["model_rewritten"]:
                notes.append(f"model {info['model']} -> {info['model_rewritten']}")
            if info["effort_rewritten"]:
                notes.append(f"effort {info['effort']} -> {info['effort_target']}")
            if new_body is not decoded:
                body = new_body
                drop_encoding = decoded_ok
                rewrite_note = " " + "; ".join(notes)
                detail += f" rewritten=1 decoded={decoded_ok}"

        skip = {
            "host", "connection", "content-length", "transfer-encoding",
            "accept-encoding", "keep-alive", "proxy-connection", "te", "trailer",
        }
        if drop_encoding:
            skip.add("content-encoding")
        headers = {k: v for k, v in self.headers.items() if k.lower() not in skip}

        upstream_url = get_upstream()
        parsed = urllib.parse.urlsplit(upstream_url)
        scheme = parsed.scheme or "https"
        host = parsed.hostname or urllib.parse.urlsplit(DEFAULT_UPSTREAM).hostname or LISTEN_HOST
        try:
            port = parsed.port or (443 if scheme == "https" else 80)
        except ValueError:
            port = 443 if scheme == "https" else 80
        base_path = parsed.path.rstrip("/")
        target_path = self.path or "/"
        if base_path and not (target_path == base_path or target_path.startswith(base_path + "/")):
            target_path = base_path + "/" + target_path.lstrip("/")
        if not target_path.startswith("/"):
            target_path = "/" + target_path

        if scheme == "https":
            conn = http.client.HTTPSConnection(
                host, port, timeout=600, context=ssl.create_default_context(),
            )
        else:
            conn = http.client.HTTPConnection(host, port, timeout=600)

        detail += f" upstream={upstream_url} path={target_path}"
        try:
            conn.request(self.command, target_path, body=body, headers=headers)
            resp = conn.getresponse()
        except Exception as exc:
            log(f"ERROR {self.command} {target_path} {exc} {detail}")
            try:
                self.send_response(502)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", "0")
                self.end_headers()
            except Exception:
                pass
            conn.close()
            return

        error_body = None
        if resp.status >= 400:
            try:
                error_body = resp.read()
                log(f"UPSTREAM-ERROR {resp.status} {self.path} {error_body[:400]!r} {detail}")
            except Exception as exc:
                log(f"UPSTREAM-ERROR {resp.status} {self.path} read-failed {exc} {detail}")

        log(f"{self.command} {self.path} -> {resp.status}{rewrite_note} {detail}")

        no_body = resp.status in (204, 304) or self.command == "HEAD"
        self.send_response(resp.status)
        for key, value in resp.getheaders():
            if key.lower() in {
                "transfer-encoding", "content-length", "connection",
                "keep-alive", "proxy-authenticate", "trailer", "upgrade",
            }:
                continue
            self.send_header(key, value)
        if no_body:
            self.send_header("Content-Length", "0")
        elif error_body is not None:
            self.send_header("Content-Length", str(len(error_body)))
        else:
            self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        try:
            if error_body is not None:
                self.wfile.write(error_body)
                self.wfile.flush()
            elif not no_body:
                while True:
                    chunk = resp.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(b"%X\r\n" % len(chunk) + chunk + b"\r\n")
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            log(f"STREAM-ERROR {self.path} {exc}")
        finally:
            conn.close()


def main():
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    server.daemon_threads = True
    log(f"listening on http://{LISTEN_HOST}:{LISTEN_PORT} -> {get_upstream()} [{PROXY_VERSION}]")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
