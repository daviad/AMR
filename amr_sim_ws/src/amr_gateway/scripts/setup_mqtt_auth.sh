#!/usr/bin/env bash
# 生成 mosquitto 密码文件（password_file）。acl_file 是仓库内的 mosquitto.acl。
# 开发口令仅限内网仿真，真机/公网部署必须更换（见 docs/架构-网关收口.md §13）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${1:-$HERE/../../amr_comm/config}"
PASSWD="$CONF_DIR/mosquitto.passwd"

if ! command -v mosquitto_passwd >/dev/null 2>&1; then
  echo "[gateway] 找不到 mosquitto_passwd（apt install mosquitto）" >&2
  exit 1
fi

umask 077
rm -f "$PASSWD"
mosquitto_passwd -b -c "$PASSWD" gateway gateway-dev-pass
mosquitto_passwd -b "$PASSWD" robot robot-dev-pass
chmod 600 "$PASSWD"
echo "[gateway] 已生成 $PASSWD（账号 gateway / robot）"
