"""Patch the OpenAI ChatGPT/Codex VS Code extension so Ultra is shown.

The extension webview uses a Statsig gate (1186680773) to decide whether the
Ultra reasoning level is included. With an API key / relay (not an official
signed-in account) the gate is false, so Ultra is hidden. This script forces
the two gate checks in the webview bundle to true.

Usage:
    python patch-vscode-extension.py
Then reload VS Code: Command Palette -> Developer: Reload Window.
"""

import os
import re
import shutil
import sys
import time

EXT_ROOT = os.path.join(os.path.expanduser("~"), ".vscode", "extensions")
LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vscode-patch.log")

GATE_MODEL_LIST = re.compile(
    r'([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)&&([A-Za-z_$][\w$]*)'
    r'\(([A-Za-z_$][\w$]*),`1186680773`\)'
)
GATE_PICKER = re.compile(
    r'includeUltraReasoningEffort:([A-Za-z_$][\w$]*)'
    r'\(([A-Za-z_$][\w$]*),`1186680773`\)'
)


def log(message):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} [vscode] {message}\n"
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass
    print(message)


def latest_extension():
    if not os.path.isdir(EXT_ROOT):
        raise SystemExit(f"extension folder not found: {EXT_ROOT}")
    candidates = [
        os.path.join(EXT_ROOT, name)
        for name in os.listdir(EXT_ROOT)
        if name.startswith("openai.chatgpt-") and os.path.isdir(os.path.join(EXT_ROOT, name))
    ]
    if not candidates:
        raise SystemExit("openai.chatgpt extension not found")
    return max(candidates, key=os.path.getmtime)


def main():
    ext = latest_extension()
    log(f"extension: {ext}")
    assets = os.path.join(ext, "webview", "assets")
    patched = 0

    for name in os.listdir(assets):
        if not (name.startswith("app-initial-") and name.endswith(".js")):
            continue
        path = os.path.join(assets, name)
        with open(path, encoding="utf-8", errors="ignore") as fh:
            text = fh.read()
        if "1186680773" not in text:
            continue

        new_text = GATE_MODEL_LIST.sub(r"\1=!0", text)
        new_text = GATE_PICKER.sub("includeUltraReasoningEffort:!0", new_text)
        if new_text == text:
            log(f"no change: {name}")
            continue

        backup = path + ".bak"
        if not os.path.exists(backup):
            try:
                shutil.copy2(path, backup)
            except OSError:
                backup = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".bak")
                shutil.copy2(path, backup)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(new_text)
        patched += 1
        log(f"patched: {name}")

    if patched == 0:
        log("nothing patched (extension may already be patched or version changed)")
    else:
        log("done; reload VS Code: Developer: Reload Window")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        import traceback
        log("ERROR: " + traceback.format_exc().replace("\n", " | "))
        sys.exit(1)
