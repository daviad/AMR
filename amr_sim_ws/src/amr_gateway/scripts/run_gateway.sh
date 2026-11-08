#!/usr/bin/env bash
# 网关启动器：首次运行自动建 venv 并安装依赖，然后 exec 进 Python 进程。
# 用法：bash amr_sim_ws/src/amr_gateway/scripts/run_gateway.sh [额外参数]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(dirname "$HERE")"
DATA_DIR="${AMR_GATEWAY_DATA:-$HOME/.amr_gateway}"
VENV="$DATA_DIR/venv"
mkdir -p "$DATA_DIR"

if [ ! -x "$VENV/bin/python" ]; then
  echo "[gateway] 创建 venv: $VENV"
  python3 -m venv "$VENV"
fi

if ! "$VENV/bin/python" -c "import paho.mqtt, websockets" >/dev/null 2>&1; then
  echo "[gateway] 安装依赖（requirements.txt）"
  "$VENV/bin/pip" install -q -r "$PKG_DIR/requirements.txt"
fi

exec env PYTHONPATH="$PKG_DIR" "$VENV/bin/python" -m amr_gateway.main \
  --config "$PKG_DIR/config/gateway.json" \
  --log-file "$DATA_DIR/gateway.log" "$@"
