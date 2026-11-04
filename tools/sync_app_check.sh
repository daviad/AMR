#!/usr/bin/env bash
# 构建前校验：只读比对 WSL 源与 Windows 构建副本，不写入任何文件。
#
# 用法：
#   ./tools/sync_app_check.sh          # 只读检查，退出码 0=一致 / 1=漂移
#   ./tools/sync_app_check.sh --help   # 显示本帮助
#
# Windows 侧等价命令（复制粘贴即可，路径已写死，无需替换占位符）：
#   powershell -ExecutionPolicy Bypass -File "\\wsl.localhost\Ubuntu\home\dxw\amr\tools\sync_app_to_windows.ps1" -Check
#
# 正式同步（会执行 robocopy /MIR，先备份目标目录；不要误粘成这行）：
#   powershell -ExecutionPolicy Bypass -File "\\wsl.localhost\Ubuntu\home\dxw\amr\tools\sync_app_to_windows.ps1"
#
# 本脚本直接调用同一个 ps1 的 -Check，因此指纹算法、排除列表与 Windows 侧完全一致。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PS1_WIN="$(wslpath -w "$HERE/sync_app_to_windows.ps1")"

usage() {
  cat <<'EOF'
构建前校验：只读比对 WSL 源与 Windows 构建副本，不写入任何文件。
用法：./tools/sync_app_check.sh [--help]   退出码 0=一致 / 1=漂移
Windows 侧等价命令（复制粘贴即可）：
  powershell -ExecutionPolicy Bypass -File "\\wsl.localhost\Ubuntu\home\dxw\amr\tools\sync_app_to_windows.ps1" -Check
正式同步（/MIR，先备份）：去掉上面的 -Check。
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1_WIN" -Check
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "副本过期，请先同步：powershell -ExecutionPolicy Bypass -File \"\\\\wsl.localhost\\Ubuntu\\home\\dxw\\amr\\tools\\sync_app_to_windows.ps1\"" >&2
fi
exit "$rc"
