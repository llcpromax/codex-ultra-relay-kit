#!/usr/bin/env bash
set -euo pipefail

KEEP_CONFIG=0
REMOVE_FILES=0

usage() {
    cat <<'EOF'
Codex Relay Kit 卸载脚本（Linux / Ubuntu）

用法:
  bash uninstall.sh [--keep-config] [--remove-files]

参数:
  --keep-config   保留 config.toml 不改（仍指向 127.0.0.1:8787）
  --remove-files  同时删除安装目录 ~/.codex/relay-proxy
  -h, --help      显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-config)
            KEEP_CONFIG=1
            shift
            ;;
        --remove-files)
            REMOVE_FILES=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            usage
            exit 1
            ;;
    esac
done

INSTALL_DIR="$HOME/.codex/relay-proxy"
CONFIG_PATH="$HOME/.codex/config.toml"
UPSTREAM_FILE="$INSTALL_DIR/upstream.txt"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_PATH="$UNIT_DIR/codex-relay-proxy.service"

step() { printf '[*] %s\n' "$1"; }
ok() { printf '[+] %s\n' "$1"; }
warn() { printf '[!] %s\n' "$1"; }

step "停止并移除 systemd 用户服务"
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now codex-relay-proxy.service >/dev/null 2>&1 || true
    rm -f "$UNIT_PATH"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
fi
pkill -f "$INSTALL_DIR/proxy.py" >/dev/null 2>&1 || true
ok "服务已停止"

if [[ $KEEP_CONFIG -eq 1 ]]; then
    warn "已指定 --keep-config，config.toml 保持不变"
elif [[ -f "$CONFIG_PATH" && -f "$INSTALL_DIR/repair_config.py" ]]; then
    step "还原 config.toml"
    PYTHON=""
    if command -v python3 >/dev/null 2>&1; then
        PYTHON="$(command -v python3)"
    fi
    if [[ -n "$PYTHON" ]]; then
        "$PYTHON" "$INSTALL_DIR/repair_config.py" \
            --restore \
            --config "$CONFIG_PATH" \
            --upstream-file "$UPSTREAM_FILE"
        ok "config.toml 已还原"
    else
        warn "未找到 python3，跳过配置还原"
    fi
else
    warn "未找到 $CONFIG_PATH 或 repair_config.py，跳过配置还原"
fi

if [[ $REMOVE_FILES -eq 1 ]]; then
    step "删除安装目录 $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
    ok "安装目录已删除"
else
    warn "安装目录保留：$INSTALL_DIR"
fi

echo
echo "=== 卸载完成 ==="
echo "重启 Codex 使配置变更生效。"
