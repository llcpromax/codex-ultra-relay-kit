#!/usr/bin/env bash
set -euo pipefail

UPSTREAM=""
NO_START=0
WITH_CATALOG=0

usage() {
    cat <<'EOF'
Codex Relay Kit 安装脚本（Linux / Ubuntu）

用法:
  bash install.sh [--upstream URL] [--no-start] [--with-catalog]

参数:
  --upstream URL   中转站地址，例如 https://relay.example.com/v1
                   不传时使用占位地址，安装后编辑 ~/.codex/relay-proxy/upstream.txt
  --no-start       只安装并注册服务，不立即启动
  --with-catalog   同时安装 GPT-6.2 模型目录（~/.codex/model-catalog-v2.json）
  -h, --help       显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --upstream)
            UPSTREAM="${2:-}"
            if [[ -z "$UPSTREAM" ]]; then
                echo "缺少 --upstream 的值"
                exit 1
            fi
            shift 2
            ;;
        --upstream=*)
            UPSTREAM="${1#*=}"
            shift
            ;;
        --no-start)
            NO_START=1
            shift
            ;;
        --with-catalog)
            WITH_CATALOG=1
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/scripts"
INSTALL_DIR="$HOME/.codex/relay-proxy"
CONFIG_PATH="$HOME/.codex/config.toml"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_PATH="$UNIT_DIR/codex-relay-proxy.service"
UPSTREAM_FILE="$INSTALL_DIR/upstream.txt"
PORT=8787

step() { printf '[*] %s\n' "$1"; }
ok() { printf '[+] %s\n' "$1"; }
warn() { printf '[!] %s\n' "$1"; }

[[ -d "$SRC_DIR" ]] || { echo "未找到 scripts 目录：$SRC_DIR（请在仓库根目录运行）"; exit 1; }

if command -v python3 >/dev/null 2>&1; then
    PYTHON="$(command -v python3)"
else
    echo "未找到 python3，请先安装 Python 3.8+：sudo apt install python3"
    exit 1
fi
ok "Python: $PYTHON"

step "安装到 $INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$HOME/.codex"
cp "$SRC_DIR/proxy.py" "$INSTALL_DIR/proxy.py"
cp "$SRC_DIR/repair_config.py" "$INSTALL_DIR/repair_config.py"
ok "脚本已复制"

if [[ $WITH_CATALOG -eq 1 ]]; then
    cp "$SRC_DIR/model-catalog-v2.json" "$HOME/.codex/model-catalog-v2.json"
    ok "模型目录已安装：$HOME/.codex/model-catalog-v2.json"
fi

if [[ -f "$UPSTREAM_FILE" ]]; then
    ok "保留已有 upstream.txt -> $(head -n 1 "$UPSTREAM_FILE")"
else
    if [[ -z "$UPSTREAM" ]]; then
        UPSTREAM="https://your-relay.example.com"
        warn "未指定 --upstream，使用占位地址，稍后编辑 $UPSTREAM_FILE"
    fi
    printf '%s\n' "$UPSTREAM" > "$UPSTREAM_FILE"
    ok "已创建 upstream.txt -> $UPSTREAM"
fi

step "修复 config.toml"
if [[ -f "$CONFIG_PATH" ]]; then
    repair_args=(--config "$CONFIG_PATH" --upstream-file "$UPSTREAM_FILE" --proxy-url "http://127.0.0.1:$PORT")
    if [[ $WITH_CATALOG -eq 1 ]]; then
        repair_args+=(--catalog "$HOME/.codex/model-catalog-v2.json")
    fi
    "$PYTHON" "$INSTALL_DIR/repair_config.py" "${repair_args[@]}"
    ok "config.toml 已指向本地代理"
else
    warn "未找到 $CONFIG_PATH，请先在 Codex 中配置中转站，再运行："
    warn "  python3 $INSTALL_DIR/repair_config.py --config $CONFIG_PATH"
fi

step "注册 systemd 用户服务"
HAVE_SYSTEMD=0
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    HAVE_SYSTEMD=1
fi

if [[ $HAVE_SYSTEMD -eq 1 ]]; then
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Codex Relay Proxy
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart="$PYTHON" "$INSTALL_DIR/proxy.py"
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    if [[ $NO_START -eq 1 ]]; then
        systemctl --user enable codex-relay-proxy.service
        ok "服务已注册（未启动）"
    else
        systemctl --user enable --now codex-relay-proxy.service
        ok "服务已启动"
    fi
else
    warn "未检测到可用的 systemd 用户会话，跳过服务注册"
    warn "可手动后台运行：nohup $PYTHON $INSTALL_DIR/proxy.py >/dev/null 2>&1 &"
fi

port_open() {
    "$PYTHON" - "$PORT" <<'PY'
import socket
import sys

sock = socket.socket()
sock.settimeout(1)
try:
    sock.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    sock.close()
PY
}

if [[ $NO_START -eq 0 ]]; then
    step "检查代理端口"
    PORT_OK=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if port_open; then
            PORT_OK=1
            break
        fi
        sleep 0.5
    done
    if [[ $PORT_OK -eq 1 ]]; then
        ok "127.0.0.1:$PORT 已监听"
    else
        warn "代理未能在 $PORT 端口监听，查看 $INSTALL_DIR/proxy.log"
    fi
fi

echo
echo "=== 安装完成 ==="
echo "安装目录：$INSTALL_DIR"
echo "上游地址：$UPSTREAM_FILE"
echo "日志文件：$INSTALL_DIR/proxy.log、$INSTALL_DIR/repair.log"
echo
echo "接下来："
echo "  1. 编辑 $UPSTREAM_FILE 填入中转站地址（代理会自动感知，无需重启）"
echo "  2. 在 $CONFIG_PATH 中设置 model 和 model_reasoning_effort = \"max\""
echo "  3. 服务管理：systemctl --user status codex-relay-proxy"
if [[ $HAVE_SYSTEMD -eq 0 ]]; then
    echo
    warn "当前没有 systemd 用户会话，重启后需要手动启动代理"
fi
