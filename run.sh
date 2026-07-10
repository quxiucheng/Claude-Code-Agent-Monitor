#!/usr/bin/env bash
#
# run.sh - Agent Dashboard 后台运行管理脚本
#
# 用法:
#   ./run.sh start    # 后台启动
#   ./run.sh stop     # 停止
#   ./run.sh restart  # 重启
#   ./run.sh status   # 查看状态
#   ./run.sh logs     # 查看日志（tail -f）
#   ./run.sh fg       # 前台运行（便于调试，Ctrl+C 退出）
#
set -euo pipefail

# ---------- 路径与配置 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="agent-dashboard"
PID_FILE="$SCRIPT_DIR/.run.pid"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/dashboard.log"
PORT="${PORT:-4820}"

# 默认放开到所有网卡（DASHBOARD_HOST=0.0.0.0）。hostGuard 始终放行回环 Host
# （localhost/127.0.0.1/::1/0.0.0.0 等），DASHBOARD_ALLOWED_HOSTS 仅用于追加额外的
# 非回环域名——例如通过 ccm.bj.ide.test.sankuai.com 反代到 4820 时需把该域名加进来，
# 否则会被 hostGuard 以 EBADHOST 拒掉（逗号分隔多个）。这里默认填 localhost 仅作
# 显式占位。DASHBOARD_TOKEN 设了默认值做基础鉴权；换成强随机串更稳妥。
# 以上均可被同名环境变量覆盖。
export DASHBOARD_HOST="${DASHBOARD_HOST:-0.0.0.0}"
export DASHBOARD_ALLOWED_HOSTS="${DASHBOARD_ALLOWED_HOSTS:-localhost}"
export DASHBOARD_TOKEN="${DASHBOARD_TOKEN:-112233}"

# Node 版本（README 要求 >= 18，本机装了 22，避免 jsdom@27 等 EBADENGINE）
NODE_VER="${NODE_VER:-22}"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

mkdir -p "$LOG_DIR"

# ---------- 切换 Node ----------
use_node() {
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck disable=SC1090
    . "$NVM_DIR/nvm.sh"
    nvm use "$NODE_VER" >/dev/null 2>&1 || nvm install "$NODE_VER" >/dev/null 2>&1
  fi
  : "${NODE:=node}"
  : "${NPM:=npm}"
}

# ---------- 进程检查 ----------
is_running() {
  [ -f "$PID_FILE" ] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

pid_of() { cat "$PID_FILE" 2>/dev/null || true; }

# ---------- 命令 ----------
cmd_start() {
  if is_running; then
    echo "[$APP_NAME] 已在运行 (pid $(pid_of))，端口 $PORT"
    echo "  日志: $LOG_FILE"
    return 0
  fi
  use_node
  echo "[$APP_NAME] 启动中... node=$(node --version) npm=$(npm --version)"
  echo "[$APP_NAME] 日志: $LOG_FILE"
  # nohup + setsid 脱离终端；stdout/stderr 全部写入日志
  nohup setsid npm start >>"$LOG_FILE" 2>&1 &
  local pid=$!
  echo "$pid" >"$PID_FILE"

  # 等待端口就绪（最多 ~20s）
  local i
  for ((i=0; i<40; i++)); do
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
      echo "[$APP_NAME] 已就绪: http://localhost:$PORT (pid $pid)"
      return 0
    fi
    # 若进程已退出，立即报错
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "[$APP_NAME] 进程已退出，查看日志: $LOG_FILE"
      tail -n 20 "$LOG_FILE" 2>/dev/null || true
      rm -f "$PID_FILE"
      return 1
    fi
    sleep 0.5
  done
  echo "[$APP_NAME] 已启动 (pid $pid)，但端口 $PORT 暂未就绪，请查看日志: $LOG_FILE"
  return 0
}

cmd_stop() {
  if ! is_running; then
    echo "[$APP_NAME] 未在运行"
    rm -f "$PID_FILE"
    return 0
  fi
  local pid
  pid="$(pid_of)"
  echo "[$APP_NAME] 停止中 (pid $pid)..."
  kill "$pid" 2>/dev/null || true
  local i
  for ((i=0; i<20; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "[$APP_NAME] 未响应 SIGTERM，发送 SIGKILL"
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  echo "[$APP_NAME] 已停止"
}

cmd_restart() {
  cmd_stop || true
  cmd_start
}

cmd_status() {
  if is_running; then
    echo "[$APP_NAME] 运行中 (pid $(pid_of))，端口 $PORT"
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
      echo "  HTTP: http://localhost:$PORT -> 200 OK"
    else
      echo "  HTTP: 端口无响应（进程在但服务未就绪？）"
    fi
  else
    echo "[$APP_NAME] 未运行"
    return 1
  fi
}

cmd_logs() {
  [ -f "$LOG_FILE" ] || { echo "无日志文件: $LOG_FILE"; exit 1; }
  echo "[$APP_NAME] 跟踪日志 $LOG_FILE （Ctrl+C 退出）"
  tail -n 100 -f "$LOG_FILE"
}

cmd_fg() {
  use_node
  echo "[$APP_NAME] 前台运行（Ctrl+C 退出）"
  exec npm start
}

# ---------- 入口 ----------
case "${1:-}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  status)  cmd_status ;;
  logs)    cmd_logs ;;
  fg)      cmd_fg ;;
  *)
    cat <<EOF
用法: $0 {start|stop|restart|status|logs|fg}
  start   后台启动 (日志: $LOG_FILE)
  stop    停止
  restart 重启
  status  查看状态
  logs    tail -f 日志
  fg      前台运行
环境变量: PORT (默认 $PORT), NODE_VER (默认 $NODE_VER), NVM_DIR
EOF
    exit 1 ;;
esac
