#!/usr/bin/env python3
"""Keep Codex pointed at the local relay proxy (Linux / macOS / Windows).

apply    Remember the real upstream in upstream.txt, then rewrite the active
         provider's base_url to the local proxy.
restore  Put the real upstream back into config.toml.

Line-based editing keeps comments, ordering and unknown keys intact.
"""

import argparse
import os
import re
import shutil
import sys
import time

DEFAULT_PROXY = "http://127.0.0.1:8787"
LOCAL_RE = re.compile(r"^https?://(127\.0\.0\.1|localhost|\[::1\])(:\d+)?")
PROVIDER_RE = re.compile(r'(?m)^\s*model_provider\s*=\s*"([^"]+)"')
BASE_URL_RE = re.compile(r"(?m)^(\s*base_url\s*=\s*[\"'])([^\"']*)([\"'])")
CATALOG_RE = re.compile(r"(?m)^\s*model_catalog_json\s*=.*(?:\r?\n|$)")


def log(log_path, message):
    line = "%s [repair] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message)
    try:
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass
    print("[repair] " + message)


def read_upstream(path):
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                value = line.strip()
                if value:
                    return value
    except OSError:
        return None
    return None


def write_upstream(path, value):
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(value + "\n")
    os.replace(tmp, path)


def active_provider(text):
    match = PROVIDER_RE.search(text)
    return match.group(1) if match else None


def provider_section(text, provider):
    pattern = re.compile(
        r"(?ms)^\[model_providers\." + re.escape(provider) + r"\]\s*\r?\n(.*?)(?=^\[|\Z)"
    )
    match = pattern.search(text)
    if not match:
        return None
    return match.start(1), match.end(1)


def write_config(path, text):
    try:
        shutil.copy2(path, path + ".bak")
    except OSError:
        pass
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def apply(text, upstream_path, proxy_url, log_path):
    provider = active_provider(text)
    log(log_path, "active provider: " + (provider or "-"))
    if not provider:
        return text, False

    section = provider_section(text, provider)
    if not section:
        log(log_path, "provider section not found: model_providers." + provider)
        return text, False

    start, end = section
    body = text[start:end]
    match = BASE_URL_RE.search(body)
    if not match:
        log(log_path, "base_url not found in provider section")
        return text, False

    current = match.group(2)
    if LOCAL_RE.match(current):
        log(log_path, "base_url already local: " + current)
        return text, False

    write_upstream(upstream_path, current)
    log(log_path, "upstream updated: " + current)
    new_body = body[:match.start(2)] + proxy_url + body[match.end(2):]
    log(log_path, "base_url -> " + proxy_url)
    return text[:start] + new_body + text[end:], True


def restore(text, upstream, log_path):
    provider = active_provider(text)
    if not provider:
        return text, False

    section = provider_section(text, provider)
    if not section:
        return text, False

    start, end = section
    body = text[start:end]
    match = BASE_URL_RE.search(body)
    if not match:
        return text, False

    current = match.group(2)
    if not LOCAL_RE.match(current):
        log(log_path, "base_url is not local, keep: " + current)
        return text, False

    if not upstream:
        log(log_path, "upstream.txt missing; base_url unchanged")
        return text, False

    new_body = body[:match.start(2)] + upstream + body[match.end(2):]
    log(log_path, "base_url restored: " + upstream)
    return text[:start] + new_body + text[end:], True


def ensure_catalog(text, catalog, log_path):
    path = catalog.replace("\\", "/")
    line = 'model_catalog_json = "%s"' % path
    if CATALOG_RE.search(text):
        new_text = CATALOG_RE.sub(line + "\n", text, count=1)
    else:
        new_text = line + "\n" + text
    if new_text == text:
        return text, False
    log(log_path, "model catalog ensured: " + path)
    return new_text, True


def main():
    parser = argparse.ArgumentParser(description="Repair Codex config for the local relay proxy")
    parser.add_argument("--config", default=os.path.expanduser("~/.codex/config.toml"))
    parser.add_argument(
        "--upstream-file", default=os.path.expanduser("~/.codex/relay-proxy/upstream.txt")
    )
    parser.add_argument("--proxy-url", default=DEFAULT_PROXY)
    parser.add_argument("--catalog", default="", help="optional model catalog JSON to configure")
    parser.add_argument("--restore", action="store_true", help="restore the real upstream address")
    parser.add_argument("--log", default="", help="log file (default: repair.log next to upstream.txt)")
    args = parser.parse_args()

    log_path = args.log or os.path.join(os.path.dirname(args.upstream_file), "repair.log")

    if not os.path.isfile(args.config):
        log(log_path, "config not found: " + args.config)
        return 1

    with open(args.config, encoding="utf-8-sig") as fh:
        original = fh.read()

    text = original
    changed = False
    if args.restore:
        text, changed = restore(text, read_upstream(args.upstream_file), log_path)
    else:
        text, changed = apply(text, args.upstream_file, args.proxy_url, log_path)
        if args.catalog and os.path.isfile(args.catalog):
            text, catalog_changed = ensure_catalog(text, args.catalog, log_path)
            changed = changed or catalog_changed

    if changed and text != original:
        write_config(args.config, text)
        log(log_path, "config written")
    else:
        log(log_path, "config unchanged")
    return 0


if __name__ == "__main__":
    sys.exit(main())
