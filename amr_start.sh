#!/usr/bin/env bash
# =============================================================================
# amr_start.sh — AMR 仿真一键启动脚本
# 位置：/home/dxw/amr/amr_start.sh （项目根目录，用户指定）
# 对应文档：/home/dxw/amr/docs/RUNBOOK.md v2.0（2026-11-03）
# 覆盖范围：RUNBOOK §2（仿真端 WSL 全部步骤）+ §2.5 验证
#          Flutter App / Web 大屏（§3，Windows 侧）不在本脚本内，结束时会提示。
#
# 用法（项目根目录直接 ./amr_start.sh，任意路径也可用绝对路径调用）：
#   ./amr_start.sh                 # 默认：安全清理 + 按需编译 + headless 启动
#   ./amr_start.sh --gui           # 带 Gazebo GUI（headless:=false，需要 WSLg 图形环境）
#   ./amr_start.sh --video test    # 视频源换 videotestsrc（RUNBOOK §2.3）
#   ./amr_start.sh --no-clean      # 跳过清理
#   ./amr_start.sh --dry-run       # 只打印将要做的事，不 kill/删除/启动
#   ./amr_start.sh --clean-all     # 深度清理 Gazebo 日志 + fuel 缓存 + build/install/log（需二次确认）
#   ./amr_start.sh --clean-all --yes   # 深度清理不再确认
#   ./amr_start.sh --build         # 强制 colcon build（默认仅 install/ 缺失时编译）
#   ./amr_start.sh --force         # SIGTERM 等待缩短到 2s，并跳过确认
#   ./amr_start.sh --keep          # 失败时保留现场（默认回滚本次拉起的进程）
#   ./amr_start.sh --stop          # 只清理，不启动
#   ./amr_start.sh --help
#
# 日志目录：~/arm_logs/<YYYYmmdd-HHMMSS>/（放家目录，避免日志混进项目 git 仓库）
#   mosquitto.log      RUNBOOK §2.2（MQTT Broker 1884/9002）
#   full_bringup.log   RUNBOOK §2.3（Gazebo+Nav2+巡检+rosbridge+MQTT桥+MediaMTX+GStreamer）
#   initialpose.log    RUNBOOK §2.4（/initialpose 激活 Nav2）
#   verify.log         RUNBOOK §2.5（验证命令原始输出）
#   ros/                ROS 节点日志（ROS_LOG_DIR）
#   pids.txt           本次脚本拉起的进程，供 --stop / 失败回滚
#
# 安全说明：
#   - 清理只按"本项目特征"匹配（见 PATTERNS），不做 pkill -9 -f ros / python 这类误杀；
#     系统 mosquitto（/etc/mosquitto/mosquitto.conf，1883）不会被动。
#   - kill 前先打印 PID + 完整命令行；先 SIGTERM，超时才 SIGKILL。
# =============================================================================

set -o pipefail

# ---------- 路径（相对脚本自身位置推导，脚本整体移动也不失效） ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
WS="$PROJECT_DIR/amr_sim_ws"
RUNBOOK="$PROJECT_DIR/docs/RUNBOOK.md"
MOSQ_CONF="$WS/src/amr_comm/config/mosquitto.conf"
MEDIAMTX_BIN="$HOME/bin/mediamtx"
MEDIAMTX_CFG="$WS/src/amr_gazebo/config/mediamtx.yml"
ROS_SETUP="/opt/ros/jazzy/setup.bash"
WS_SETUP="$WS/install/setup.bash"

# ---------- 日志 ----------
TS="$(date +%Y%m%d-%H%M%S)"
LOG_ROOT="$HOME/arm_logs"
LOG_DIR="$LOG_ROOT/$TS"
TRACE_FILE=""

# ---------- 默认参数 ----------
DO_CLEAN=1
DEEP_CLEAN=0
DRY_RUN=0
HEADLESS=true
VIDEO_SOURCE=gazebo
FORCE_BUILD=0
ASSUME_YES=0
FORCE_KILL=0
KEEP_ON_FAIL=0
STOP_ONLY=0
ENABLE_GATEWAY=1

GRACE_SEC=5
READY=0
ROLLED_BACK=0
STARTED_PIDS=()

# ---------- 输出 ----------
c_info() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
c_warn() { printf '[%s] \033[33m[警告]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
c_err()  { printf '[%s] \033[31m[错误]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
c_ok()   { printf '[%s] \033[32m[ OK ]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
section() { printf '\n\033[36m===== %s =====\033[0m\n' "$*"; }

usage() {
  cat <<'EOF'
用法：./amr_start.sh [选项]

  （无参数）        安全清理 → 按需编译 → headless 启动 → 验证
  --gui             Gazebo 带界面（headless:=false，需要 WSLg 图形环境）
  --video test      视频源改为 videotestsrc（RUNBOOK §2.3）
  --no-clean        跳过清理
  --dry-run         只打印将要执行的操作
  --clean-all       深度清理（Gazebo 日志 + fuel 缓存 + build/install/log），需二次确认
  --yes             与 --clean-all 搭配，跳过确认
  --build           强制 colcon build
  --force           SIGTERM 等待缩短到 2s，并跳过确认
  --keep            启动失败时保留现场（默认回滚本次拉起的进程）
  --no-gateway      不启动业务网关（仅调试用；App 的 HTTP/WS 业务通道不可用）
  --stop            只清理，不启动
  -h, --help        显示本帮助

日志目录：~/arm_logs/<时间戳>/；脚本路径：/home/dxw/amr/amr_start.sh
EOF
}

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --no-clean)   DO_CLEAN=0 ;;
    --clean-all)  DEEP_CLEAN=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    --gui)        HEADLESS=false ;;
    --video)      shift; VIDEO_SOURCE="${1:-gazebo}" ;;
    --build)      FORCE_BUILD=1 ;;
    --yes)        ASSUME_YES=1 ;;
    --force)      FORCE_KILL=1; ASSUME_YES=1; GRACE_SEC=2 ;;
    --keep)       KEEP_ON_FAIL=1 ;;
    --no-gateway) ENABLE_GATEWAY=0 ;;
    --stop)       STOP_ONLY=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) c_err "未知参数：$1（--help 查看用法）"; exit 2 ;;
  esac
  shift
done

if [ "$VIDEO_SOURCE" != "gazebo" ] && [ "$VIDEO_SOURCE" != "test" ]; then
  c_err "--video 只能是 gazebo 或 test"; exit 2
fi

# =============================================================================
# 0. preflight 检查（只读）— RUNBOOK §1.1
# =============================================================================
preflight() {
  section "0. preflight 检查"
  local fail=0 f c port
  if [ -f "$RUNBOOK" ]; then c_ok "runbook: $RUNBOOK"; else c_warn "未找到 $RUNBOOK"; fi

  for f in "$MOSQ_CONF" "$MEDIAMTX_BIN" "$MEDIAMTX_CFG" "$ROS_SETUP"; do
    if [ -e "$f" ]; then c_ok "$f"; else c_err "缺少 $f"; fail=1; fi
  done

  if [ -f "$WS_SETUP" ]; then
    c_ok "工作空间已编译：$WS_SETUP"
  else
    c_warn "install/setup.bash 不存在，将自动 colcon build（RUNBOOK §2.1）"
  fi

  for c in mosquitto ros2 gz colcon ffprobe ss pgrep; do
    if command -v "$c" >/dev/null 2>&1; then
      c_ok "工具 $c -> $(command -v "$c")"
    elif [ "$c" = "ros2" ] || [ "$c" = "gz" ]; then
      c_warn "工具 $c 尚未在 PATH（稍后 source ROS 后可用）"
    else
      c_err "缺少工具 $c"; fail=1
    fi
  done

  for port in 1884 9002 9090 18554 8889; do
    if ss -lnt 2>/dev/null | grep -q ":$port "; then c_warn "端口 $port 已被占用（可能上次残留，清理阶段处理）"; fi
  done

  return $fail
}

# =============================================================================
# 1. 清理
# =============================================================================

# 只匹配本项目进程特征，避免误杀
PATTERNS=(
  'full_bringup\.launch\.py'
  'sim_bringup\.launch\.py'
  'ros2 launch amr_'
  'mission_bridge'
  'gst_video_source'
  'rtsp_publisher\.py'
  'inspection_node'
  'cmd_vel_watchdog'
  'cartographer_node'
  'cartographer_occupancy_grid_node'
  'rosbridge_websocket'
  'mqtt_client'
  'amr_gateway.main'
  'mediamtx .*mediamtx\.yml'
  'mosquitto .*amr_comm/config/mosquitto\.conf'
  'ros_gz_sim/create'
  'parameter_bridge'
  'gz sim'
  'gzserver'
  'gzclient'
  'robot_state_publisher'
  'controller_spawner'
  'amcl|planner_server|controller_server|bt_navigator|behavior_server|velocity_smoother|waypoint_follower|collision_monitor|route_server|docking_server|map_server|lifecycle_manager'
  'component_container_isolated.*nav2_container'
)

collect_candidates() {
  local out="$1" pat p cmd user
  : > "$out"
  for pat in "${PATTERNS[@]}"; do
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      [ "$p" = "$$" ] && continue
      [ "$p" = "${PPID:-0}" ] && continue
      cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" || continue
      case "$cmd" in *amr_start\.sh*) continue ;; esac
      user="$(ps -o user= -p "$p" 2>/dev/null | tr -d ' ')"
      [ "$user" = "$(id -un)" ] || continue
      printf '%s|%s\n' "$p" "$cmd" >> "$out"
    done < <(pgrep -f -- "$pat" 2>/dev/null)
  done
  sort -u "$out" -o "$out"
}

stop_candidates() {
  local f="$1" p cmd n remain
  if [ ! -s "$f" ]; then c_ok "没有需要清理的残留进程"; return 0; fi

  n="$(wc -l < "$f" | tr -d ' ')"
  c_info "发现 $n 个候选进程，清单如下："
  while IFS='|' read -r p cmd; do printf '   PID %-8s %s\n' "$p" "${cmd:0:140}"; done < "$f"

  if [ "$DRY_RUN" -eq 1 ]; then echo "   [dry-run] 不执行 kill（真实：SIGTERM → 等 ${GRACE_SEC}s → 兜底 SIGKILL）"; return 0; fi

  while IFS='|' read -r p cmd; do kill -TERM "$p" 2>/dev/null; done < "$f"
  c_info "已发送 SIGTERM，等待 ${GRACE_SEC}s ..."
  sleep "$GRACE_SEC"

  remain=""
  while IFS='|' read -r p cmd; do kill -0 "$p" 2>/dev/null && remain="$remain $p"; done < "$f"
  if [ -n "$remain" ]; then
    c_warn "仍未退出，兜底 SIGKILL：$remain"
    for p in $remain; do kill -KILL "$p" 2>/dev/null; done
    sleep 1
  fi
  c_ok "进程清理完成"
  report_residuals
}

# 启动前检查：cmd_vel_watchdog 是常驻补零速节点，残留会让新旧两个同名节点抢着下发指令
warn_cmd_vel_dupes() {
  local f="$1" cnt pids
  cnt="$(grep -c 'cmd_vel_watchdog' "$f" 2>/dev/null || true)"
  cnt="${cnt:-0}"
  [ "$cnt" -gt 0 ] || return 0
  pids="$(grep 'cmd_vel_watchdog' "$f" | cut -d'|' -f1 | tr '\n' ' ')"
  if [ "$cnt" -ge 2 ]; then
    c_warn "检测到 $cnt 个残留 cmd_vel_watchdog（双节点会重复补零速）：PID $pids，已纳入本次清理"
  else
    c_warn "检测到 1 个残留 cmd_vel_watchdog（PID $pids），与本次启动会产生同名双节点，已纳入清理"
  fi
}

# 清理后复查：用与 collect_candidates 相同的特征重新统计（会排除脚本自身）
report_residuals() {
  local tmp n m
  tmp="$(mktemp)"
  collect_candidates "$tmp"
  n="$(wc -l < "$tmp" | tr -d ' ')"
  m="$(grep -c 'cmd_vel_watchdog' "$tmp" 2>/dev/null || true)"
  m="${m:-0}"
  rm -f "$tmp"
  if [ "${n:-0}" -eq 0 ]; then
    c_ok "清理后复查：本项目相关进程 0 个（cmd_vel_watchdog 0 个）"
  else
    c_warn "清理后仍有 $n 个项目相关进程（其中 cmd_vel_watchdog $m 个），请检查：ps -eo pid,cmd | grep -E 'cmd_vel_watchdog|<其他特征>'"
  fi
}

estimate_cleanup() {
  section "1. 清理预估（先看清楚再动手）"
  local tmp f locks
  tmp="$(mktemp)"
  collect_candidates "$tmp"
  if [ -s "$tmp" ]; then c_info "残留仿真/ROS 进程 $(wc -l < "$tmp" | tr -d ' ') 个（下一步逐个列出 PID 与命令行）"; else c_info "残留仿真/ROS 进程：0 个"; fi
  rm -f "$tmp"

  c_info "临时/共享内存/锁文件："
  for f in /tmp/amr_trace.jsonl /tmp/amr-gst-registry.bin; do
    [ -e "$f" ] && printf '   %-40s %s\n' "$f" "$(du -h "$f" | cut -f1)"
  done
  compgen -G "/dev/shm/fastrtps*" >/dev/null 2>&1 && c_info "   /dev/shm/fastrtps* 存在（Fast DDS 残留）"
  compgen -G "/dev/shm/fastdds*"  >/dev/null 2>&1 && c_info "   /dev/shm/fastdds* 存在"
  locks="$(find "$HOME/.gz/sim" -name '*.lock' 2>/dev/null | wc -l | tr -d ' ')"
  c_info "   ~/.gz/sim 下 lock 文件：${locks} 个"

  if [ "$DEEP_CLEAN" -eq 1 ]; then
    c_warn "深度清理将删除：Gazebo 日志 $(du -sh "$HOME/.gz/sim/log" 2>/dev/null | cut -f1)、fuel 缓存 $(du -sh "$HOME/.gz/fuel" 2>/dev/null | cut -f1)、build $(du -sh "$WS/build" 2>/dev/null | cut -f1) / install $(du -sh "$WS/install" 2>/dev/null | cut -f1) / log $(du -sh "$WS/log" 2>/dev/null | cut -f1)"
    c_warn "后果：模型需重新联网下载；源码需重新 colcon build（本项目体量小，通常 1-3 分钟）"
  fi
}

clean_files() {
  c_info "删除失效临时文件 / 共享内存 / 锁文件"
  local f
  for f in /tmp/amr_trace.jsonl /tmp/amr-gst-registry.bin /tmp/amr_offer.sdp /tmp/answer.sdp; do
    [ -e "$f" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then echo "   [dry-run] rm -f $f"; else rm -f "$f" && c_ok "rm -f $f"; fi
  done
  for f in /dev/shm/fastrtps* /dev/shm/fastdds* /dev/shm/sem.fastrtps*; do
    [ -e "$f" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then echo "   [dry-run] rm -f $f"; else rm -f "$f" && c_ok "rm -f $f"; fi
  done
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ "$DRY_RUN" -eq 1 ]; then echo "   [dry-run] rm -f $f"; else rm -f "$f" && c_ok "rm -f $f"; fi
  done < <(find "$HOME/.gz/sim" -name '*.lock' 2>/dev/null)

  c_info "重启 ros2 daemon（避免缓存指向已死节点）"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "   [dry-run] ros2 daemon stop"
  elif command -v ros2 >/dev/null 2>&1; then
    ros2 daemon stop >/dev/null 2>&1 || true
    sleep 1
    c_ok "ros2 daemon 已停止（验证阶段按需自动拉起）"
  else
    c_warn "ros2 未 source，跳过 daemon 重启（启动阶段 sourcing 后再处理）"
  fi
}

deep_clean() {
  section "1b. 深度清理（--clean-all）"
  if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    echo "即将删除：Gazebo 运行日志 / fuel 模型缓存 / build install log。"
    printf '确认请输入 yes：'
    read -r ans
    if [ "$ans" != "yes" ]; then c_err "已取消深度清理（其余步骤继续）"; return 1; fi
  fi
  local d
  for d in "$HOME/.gz/sim/log" "$HOME/.gz/sim/8/log" "$HOME/.gz/fuel" \
           "$WS/build" "$WS/install" "$WS/log"; do
    [ -e "$d" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then echo "   [dry-run] rm -rf $d"; else rm -rf "$d" && c_ok "rm -rf $d"; fi
  done
  c_warn "深度清理完成：接下来会自动 colcon build 一次"
}

# =============================================================================
# 2. 启动（严格按 RUNBOOK §2 顺序；等就绪而非 sleep 硬等）
# =============================================================================
wait_until() {
  local desc="$1" timeout="$2"; shift 2
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if "$@" >/dev/null 2>&1; then c_ok "$desc（就绪）"; return 0; fi
    sleep 1
  done
  c_err "$desc（${timeout}s 超时）"
  return 1
}

has_clock()  { timeout 6 ros2 topic echo --once /clock >/dev/null 2>&1; }
# 注意：脚本开了 pipefail，`ros2 node list | grep -q` 会因 grep 提前退出
# 让 ros2 收到 SIGPIPE（141），导致"节点明明在却判为不在"，故先取完整输出再匹配。
has_node()   { local out; out="$(timeout 10 ros2 node list 2>/dev/null)" || return 1; [[ "$out" == *"$1"* ]]; }
has_action() { local out; out="$(timeout 10 ros2 action list 2>/dev/null)" || return 1; [[ "$out" == *"$1"* ]]; }
has_port()   { local out; out="$(ss -lnt 2>/dev/null)" || return 1; [[ "$out" == *":$1 "* ]]; }

setup_env() {
  section "2. 环境准备（RUNBOOK §2.1 / §6 Q9）"
  # Q9：IDE/沙箱注入的旧 libstdc++ 会让 ROS2 Python 扩展报 GLIBCXX 错误
  unset LD_LIBRARY_PATH
  # 本机已验证：WSLg 下 Mesa 不会自动选 d3d12，需显式指定才走 NVIDIA GPU
  if [ -e /dev/dxg ]; then export GALLIUM_DRIVER=d3d12; fi
  export ROS_HOME=/tmp/ros_home
  export ROS_LOG_DIR="$LOG_DIR/ros"
  export PYTHONDONTWRITEBYTECODE=1

  c_info "source $ROS_SETUP"
  # shellcheck disable=SC1090
  source "$ROS_SETUP"
  if [ -f "$WS_SETUP" ]; then
    c_info "source $WS_SETUP"
    # shellcheck disable=SC1090
    source "$WS_SETUP"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    c_ok "环境：ROS_DISTRO=${ROS_DISTRO:-?}（dry-run：不建日志目录、不重置 ros2 daemon）"
  else
    mkdir -p "$LOG_DIR/ros"
    # 关闭旧 daemon：上次实例被 kill 后它的节点缓存会失效，node list 每次都要等到超时
    ros2 daemon stop >/dev/null 2>&1 || true
    c_ok "环境：ROS_DISTRO=${ROS_DISTRO:-?}  ROS_LOG_DIR=$ROS_LOG_DIR（ros2 daemon 已重置）"
  fi
}

do_build() {
  # RUNBOOK §2.1：首次或代码变更后编译
  section "2b. 编译工作空间（RUNBOOK §2.1）"
  cd "$WS" || return 1
  if [ "$DRY_RUN" -eq 1 ]; then echo "   [dry-run] colcon build --symlink-install"; return 0; fi
  c_info "开始编译（日志：$LOG_DIR/build.log）..."
  if colcon build --symlink-install >"$LOG_DIR/build.log" 2>&1; then
    c_ok "编译完成"
    # shellcheck disable=SC1090
    source "$WS_SETUP"
  else
    c_err "编译失败，详见 $LOG_DIR/build.log"
    return 1
  fi
}

start_mosquitto() {
  # RUNBOOK §2.2：终端 1 mosquitto（TCP 1884 + WS 9002）
  section "2c. 启动 MQTT Broker（RUNBOOK §2.2）"
  if [ "$DRY_RUN" -eq 1 ]; then echo "   [dry-run] mosquitto -c $MOSQ_CONF &"; return 0; fi
  # ACL 收口后必须存在密码文件，否则 mosquitto 起不来
  local auth_script="$WS/src/amr_gateway/scripts/setup_mqtt_auth.sh"
  if [ -f "$auth_script" ]; then
    bash "$auth_script" || { c_err "生成 mosquitto 密码文件失败"; return 1; }
  else
    c_warn "缺少 $auth_script，mosquitto 可能因 password_file 不存在而启动失败"
  fi
  nohup mosquitto -c "$MOSQ_CONF" >"$LOG_DIR/mosquitto.log" 2>&1 &
  local pid=$!
  STARTED_PIDS+=("$pid")
  echo "mosquitto|$pid" >> "$LOG_DIR/pids.txt"
  wait_until "mosquitto 监听 1884" 15 has_port 1884 || {
    c_err "mosquitto 未起来，见 $LOG_DIR/mosquitto.log"; return 1; }
}

start_gateway() {
  # 业务网关：HTTP 8080 / WS 8081，唯一 MQTT 发布者 + 唯一 rosbridge 客户端
  section "2d. 启动业务网关（HTTP 8080 / WS 8081）"
  if [ "$ENABLE_GATEWAY" -eq 0 ]; then
    c_warn "--no-gateway：已跳过；App 只能使用旧版直连方式"
    return 0
  fi
  local runner="$WS/src/amr_gateway/scripts/run_gateway.sh"
  if [ ! -f "$runner" ]; then c_err "缺少 $runner"; return 1; fi
  if [ "$DRY_RUN" -eq 1 ]; then echo "   [dry-run] bash $runner &"; return 0; fi

  nohup bash "$runner" >"$LOG_DIR/gateway.stdout.log" 2>&1 &
  local pid=$!
  STARTED_PIDS+=("$pid")
  echo "gateway|$pid" >> "$LOG_DIR/pids.txt"

  local i ok=0
  for i in $(seq 1 40); do
    if curl -fsS "http://127.0.0.1:8080/healthz" >/dev/null 2>&1; then ok=1; break; fi
    sleep 0.5
  done
  if [ "$ok" -eq 1 ]; then
    c_ok "网关 /healthz 可达：$(curl -fsS http://127.0.0.1:8080/healthz 2>/dev/null)"
  else
    c_err "网关未在 20s 内就绪，见 $LOG_DIR/gateway.stdout.log / ~/.amr_gateway/gateway.log"
    return 1
  fi
}

start_bringup() {
  # RUNBOOK §2.3：终端 2 一键启动全链路（launch 内 TimerAction 排 0/5/6/8/10/12s）
  section "2e. 启动全链路（RUNBOOK §2.3）"
  cd "$WS" || return 1
  local trace="$LOG_DIR/amr_trace.jsonl"
  local cmd=(ros2 launch amr_bringup full_bringup.launch.py
             "headless:=$HEADLESS" "video_source:=$VIDEO_SOURCE"
             "trace_log_path:=$trace")
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "   [dry-run] ${cmd[*]}   (日志：$LOG_DIR/full_bringup.log)"
    return 0
  fi
  TRACE_FILE="$trace"
  nohup "${cmd[@]}" >"$LOG_DIR/full_bringup.log" 2>&1 &
  local pid=$!
  STARTED_PIDS+=("$pid")
  echo "full_bringup|$pid" >> "$LOG_DIR/pids.txt"
  c_info "launch 已拉起（PID $pid），等待组件就绪 ..."

  # 就绪判定：/clock 有数据 → Gazebo + ros_gz_bridge 通了（RUNBOOK Q1）
  wait_until "/clock 有数据（Gazebo + ros_gz_bridge 就绪）" 90 has_clock || return 1
  wait_until "mission_bridge 节点（RUNBOOK t=6s）" 45 has_node 'mission_bridge' || return 1
  wait_until "gst_video_source 节点（RUNBOOK t=8s）" 45 has_node 'gst_video_source' || return 1
  wait_until "Nav2 navigate_to_pose action（RUNBOOK t=10s）" 90 has_action '/navigate_to_pose' || return 1
}

send_initialpose() {
  # RUNBOOK §2.4：Nav2 需要初始位姿，否则 lifecycle 激活超时（Q2）
  section "2e. 发布 /initialpose 激活 Nav2（RUNBOOK §2.4）"
  if [ "$DRY_RUN" -eq 1 ]; then echo "   [dry-run] ros2 topic pub --once /initialpose ..."; return 0; fi
  # --max-wait-time-secs：避免上游没人订阅时 CLI 无限等待；重试是为了避开
  # 上一次实例残留的"幽灵订阅"（消息会发进空处）以及 AMCL 尚未订阅完成的竞态。
  local i
  for i in 1 2 3; do
    ros2 topic pub --once -w 1 --max-wait-time-secs 6 /initialpose \
      geometry_msgs/msg/PoseWithCovarianceStamped \
      '{header: {frame_id: map}, pose: {pose: {position: {x: 0.0, y: 0.0, z: 0.0}, orientation: {x: 0.0, y: 0.0, z: 0.0, w: 1.0}}, covariance: [0.25, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.25, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.06853891945200942, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]}}' \
      >>"$LOG_DIR/initialpose.log" 2>&1
    sleep 4
    # 用 /amcl_pose 是否有输出作为"初始位姿已生效"的直接证据
    if timeout 8 ros2 topic echo --once /amcl_pose >/dev/null 2>&1; then
      c_ok "/initialpose 已生效（第 $i 次，AMCL 已输出 /amcl_pose）"
      return 0
    fi
    c_warn "第 $i 次 /initialpose 未生效（AMCL 无输出），重试"
  done
  c_warn "3 次仍未生效，继续后续步骤；可按 RUNBOOK §2.4 手动补发"
}

# 兜底激活 8 个 lifecycle 节点（RUNBOOK §2.4 备用命令）；每步带超时避免 CLI 卡住
activate_fallback() {
  section "2f. 检查 Nav2 lifecycle 状态（RUNBOOK §2.4）"
  if [ "$DRY_RUN" -eq 1 ]; then echo "   [dry-run] ros2 lifecycle get/set 检查"; return 0; fi

  local nodes=(planner_server behavior_server bt_navigator waypoint_follower
               velocity_smoother collision_monitor route_server docking_server)
  local n st bad=() missing=()
  for n in "${nodes[@]}"; do
    st="$(timeout 8 ros2 lifecycle get "/$n" 2>/dev/null)"
    if [ -z "$st" ] || printf '%s' "$st" | grep -q 'Node not found'; then
      missing+=("$n"); continue
    fi
    case "$st" in active*) : ;; *) bad+=("$n") ;; esac
  done
  if [ ${#missing[@]} -gt 0 ]; then
    c_warn "未加载：${missing[*]}（容器 load_node 超时，详见 full_bringup.log 的 'failed to send response'）"
  fi
  if [ ${#bad[@]} -eq 0 ]; then
    [ ${#missing[@]} -eq 0 ] && c_ok "Nav2 lifecycle 节点均为 active"
    return 0
  fi

  c_warn "未 active：${bad[*]}（尝试手动 activate）"
  for n in "${bad[@]}"; do timeout 15 ros2 lifecycle set "/$n" activate >/dev/null 2>&1 || true; done
  sleep 2
  for n in "${bad[@]}"; do
    st="$(timeout 8 ros2 lifecycle get "/$n" 2>/dev/null)"
    case "$st" in active*) c_ok "/$n -> active" ;; *) c_warn "/$n 仍未 active（$st）" ;; esac
  done
}

# =============================================================================
# 3. 验证 — RUNBOOK §2.5
# =============================================================================
verify_all() {
  section "3. 验证（RUNBOOK §2.5）"
  local vlog="$LOG_DIR/verify.log" fail=0 url info p
  if [ "$DRY_RUN" -eq 1 ]; then echo "   [dry-run] 跳过实际验证"; return 0; fi
  : > "$vlog"

  c_info "3.1 关键节点（期望 mission_bridge / gst_video_source / mqtt_client / rosbridge_websocket）"
  ros2 node list 2>/dev/null | tee -a "$vlog" | grep -E 'mission_bridge|gst_video_source|mqtt_client|rosbridge_websocket|mediamtx' || true
  if has_node 'mission_bridge'; then c_ok "mission_bridge 在"; else c_err "mission_bridge 不在"; fail=1; fi

  c_info "3.2 业务话题（/amr/* /video/*）"
  ros2 topic list 2>/dev/null | tee -a "$vlog" | grep -E 'amr/|video/' || c_warn "未发现 amr/ 或 video/ 话题"

  if has_action '/navigate_to_pose'; then c_ok "navigate_to_pose action 可用"; else c_err "navigate_to_pose 不可用"; fail=1; fi
  if has_clock; then c_ok "/clock 有数据"; else c_err "/clock 无数据（检查 bridge_topics.yaml）"; fail=1; fi

  # 视频链路：RTSP 主/低码流（gst 8s 起 + 编码时间，每路最多等 60s）
  if command -v ffprobe >/dev/null 2>&1; then
    for url in rtsp://127.0.0.1:18554/camera rtsp://127.0.0.1:18554/camera_low; do
      info=""
      for _ in $(seq 1 30); do
        info="$(timeout 8 ffprobe -hide_banner -v error -rtsp_transport tcp -select_streams v:0 \
                -show_entries stream=codec_name,width,height -of default=nw=1 "$url" 2>/dev/null)"
        [ -n "$info" ] && break
        sleep 2
      done
      if [ -n "$info" ]; then
        c_ok "$url -> $(printf '%s' "$info" | tr '\n' ' ')"
        printf '%s\n%s\n' "$url" "$info" >> "$vlog"
      else
        c_warn "$url 暂无流（video_source=${VIDEO_SOURCE}；见 full_bringup.log）"
      fi
    done
  fi

  for p in 1884 9090 8889 8080 8081; do
    if has_port "$p"; then c_ok "端口 $p 监听中"; else c_warn "端口 $p 未监听"; fi
  done

  if has_port 8080 && curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    local gw
    gw="$(curl -fsS http://127.0.0.1:8080/healthz 2>/dev/null)"
    c_ok "网关健康：$gw"
    printf 'gateway_healthz\n%s\n' "$gw" >> "$vlog"
  else
    c_err "网关 /healthz 不可用（ENABLE_GATEWAY=$ENABLE_GATEWAY）"
    fail=1
  fi

  if pgrep -f 'gz sim' >/dev/null 2>&1; then c_ok "gz sim 进程在跑"; else c_err "gz sim 未运行"; fail=1; fi
  return $fail
}

# =============================================================================
# 4. 收尾 / 失败回滚
# =============================================================================
# 递归列出某进程的全部子孙（先收集再杀，避免父进程先死导致子进程被 init 收养后漏杀）
collect_tree() {
  local queue=("$1") p k
  while [ ${#queue[@]} -gt 0 ]; do
    p="${queue[0]}"; queue=("${queue[@]:1}")
    [ -n "$p" ] || continue
    printf '%s\n' "$p"
    for k in $(pgrep -P "$p" 2>/dev/null); do queue+=("$k"); done
  done
}

started_kill() {
  local name pid all="" k
  [ -f "$LOG_DIR/pids.txt" ] || return 0
  while IFS='|' read -r name pid; do
    [ -n "${pid:-}" ] || continue
    all="$all $(collect_tree "$pid" | tr '\n' ' ')"
  done < "$LOG_DIR/pids.txt"

  [ -n "$all" ] || return 0
  # shellcheck disable=SC2086
  kill -TERM $all 2>/dev/null || true
  sleep 3
  for k in $all; do kill -0 "$k" 2>/dev/null && kill -KILL "$k" 2>/dev/null || true; done
  # 兜底：串到进程树之外的残留（仅默认清理模式下，且只匹配本项目特征）
  if [ "$DO_CLEAN" -eq 1 ]; then
    local tmp; tmp="$(mktemp)"
    collect_candidates "$tmp"
    stop_candidates "$tmp" >/dev/null 2>&1 || true
    rm -f "$tmp"
  fi
}

on_exit() {
  [ "$READY" -eq 1 ] && return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ "$KEEP_ON_FAIL" -eq 1 ] && { c_warn "--keep：保留现场，未回滚"; return 0; }
  [ "$ROLLED_BACK" -eq 1 ] && return 0
  ROLLED_BACK=1
  c_warn "启动未完成，回滚本次脚本拉起的进程 ..."
  started_kill
}

# =============================================================================
# main
# =============================================================================
section "AMR 一键启动（脚本：$SCRIPT_DIR/amr_start.sh）"
c_info "项目：$PROJECT_DIR"
c_info "日志：$LOG_DIR"
if [ "$DRY_RUN" -eq 0 ]; then mkdir -p "$LOG_DIR" || { c_err "无法创建日志目录"; exit 1; }; fi

preflight || { c_err "preflight 未通过，退出（未改动任何进程）"; exit 1; }

if [ "$STOP_ONLY" -eq 1 ]; then DO_CLEAN=1; fi

if [ "$DO_CLEAN" -eq 1 ]; then
  estimate_cleanup
  section "1. 清理残留进程 / 文件"
  tmp_candidates="$(mktemp)"
  collect_candidates "$tmp_candidates"
  warn_cmd_vel_dupes "$tmp_candidates"
  stop_candidates "$tmp_candidates"
  rm -f "$tmp_candidates"
  clean_files
  if [ "$DEEP_CLEAN" -eq 1 ]; then deep_clean || true; fi
else
  section "1. 清理：已通过 --no-clean 跳过"
fi

if [ "$STOP_ONLY" -eq 1 ]; then
  c_ok "--stop 完成：已清理，未启动"
  READY=1
  exit 0
fi

setup_env || exit 1

if [ "$FORCE_BUILD" -eq 1 ] || [ ! -f "$WS_SETUP" ]; then
  do_build || { c_err "编译失败，终止"; exit 1; }
else
  c_info "跳过编译（默认不 build；源码改动后请加 --build）"
fi

trap on_exit EXIT INT TERM

start_mosquitto || exit 1
start_bringup    || { c_err "全链路启动失败，见 $LOG_DIR/full_bringup.log"; exit 1; }
send_initialpose
activate_fallback
start_gateway    || exit 1

if verify_all; then
  READY=1
  if [ "$DRY_RUN" -eq 1 ]; then
    section "dry-run 结束"
    c_ok "以上为将执行的操作；未实际 kill/删除/启动任何东西。日志目录未创建。"
    exit 0
  fi
  section "启动完成"
  c_ok "仿真端已就绪。日志：$LOG_DIR"
  echo "  下次单独验证：source $ROS_SETUP && source $WS_SETUP && ros2 node list"
  echo "  停止并清理：$SCRIPT_DIR/amr_start.sh --stop"
  echo "  下一步（Windows 侧，与本脚本同目录）："
  echo "    App： powershell.exe -ExecutionPolicy Bypass -File .\amr_start_windows.ps1"
  echo "    Web： powershell.exe -ExecutionPolicy Bypass -File .\amr_web_start.ps1"
  echo "  说明见 RUNBOOK §3.7（一键脚本）"
  exit 0
else
  section "启动失败：可能原因（RUNBOOK §6）"
  echo "  Q1  MQTT 状态上报无消息：/clock 未桥接 → 查 src/amr_gazebo/config/bridge_topics.yaml"
  echo "  Q2  Nav2 未激活：/initialpose 未发或 AMCL 未收敛 → 重跑本脚本"
  echo "  Q9  GLIBCXX 报错：务必 env -u LD_LIBRARY_PATH（脚本已处理）"
  echo "  Q11 GStreamer 断流：清 /tmp/amr-gst-registry.bin 后重启（脚本已顺手清）"
  echo "  Q18 GUI 空白：world 里不要有 <gui> 段，并确认 WSLg 图形环境可用"
  echo "  日志：$LOG_DIR/full_bringup.log"
  exit 1
fi
