#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start.sh — единая точка входа: установка зависимостей + запуск всех сервисов.
#
# После `git clone` и `bash start.sh` вы получаете:
#   • Frontend (index.html)        http://localhost:8080
#   • Workspace API                http://localhost:8764/ws/ping
#   • Terminal Server (WebSocket)  ws://localhost:8765/term  |  /exec
#   • MCP stdio Bridge             ws://127.0.0.1:7777
#   • CLI agent-browser            (для browser_action в чате; запускает Chromium
#                                   через playwright-core, slug в $PATH)
#
# Флаги:
#   --no-browser     не ставить agent-browser shim и playwright-core
#   --skip-deps      пропустить установку зависимостей (только запуск)
#
# Переменные окружения:
#   FRONTEND_PORT, WORKSPACE_PORT, TERM_PORT, BRIDGE_PORT, HOST,
#   TOKEN (terminal), WORKSPACE_DIR, AGENT_PRO_BRIDGE_HOST,
#   PLAYWRIGHT_TERMUX_ROOT (default ~/playwright-termux),
#   AGENT_BROWSER_PORT (default 9876).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m›\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!\033[0m %s\n' "$*"; }
err()   { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }

# ── Параметры ────────────────────────────────────────────────────────────────
WITH_BROWSER=1
SKIP_DEPS=0
PASSTHROUGH=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-browser) WITH_BROWSER=0; shift ;;
    --skip-deps)  SKIP_DEPS=1;    shift ;;
    --help|-h)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *) PASSTHROUGH+=("$1"); shift ;;
  esac
done

bold "Agent Pro — установка и запуск (start.sh)"

# ── Окружение ────────────────────────────────────────────────────────────────
if [ -n "${PREFIX:-}" ] && [ -d "/data/data/com.termux" ]; then
  IS_TERMUX=1
  BIN_DIR="${PREFIX}/bin"
else
  IS_TERMUX=0
  BIN_DIR="${HOME}/.local/bin"
fi
info "среда: $([ $IS_TERMUX -eq 1 ] && echo Termux || echo 'Linux/macOS')  (bin: $BIN_DIR)"

# ── Проверки базовых тулов ───────────────────────────────────────────────────
need() {
  command -v "$1" >/dev/null 2>&1 || {
    err "не найден '$1' — установите его и повторите."
    case "$1" in
      node|npm)
        if [ $IS_TERMUX -eq 1 ]; then echo "  Termux: pkg install -y nodejs"
        else echo "  Ubuntu/Debian: sudo apt install -y nodejs npm  # или https://nodejs.org/"
        fi ;;
      python3|python)
        if [ $IS_TERMUX -eq 1 ]; then echo "  Termux: pkg install -y python"
        else echo "  Ubuntu/Debian: sudo apt install -y python3 python3-venv python3-pip"
        fi ;;
    esac
    exit 1
  }
}
need node
need npm

if command -v python3 >/dev/null 2>&1; then
  PYTHON=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON=python
else
  need python3
fi

# ── Версия Node ──────────────────────────────────────────────────────────────
NODE_MAJOR=$("$(command -v node)" -e 'process.stdout.write(String(process.versions.node.split(".")[0]))')
if [ "${NODE_MAJOR:-0}" -lt 18 ]; then
  err "Node.js $(node -v) — нужен ≥ 18 (требование node-pty 1.x и playwright-core)."
  exit 1
fi
ok "node $(node -v) | $PYTHON $($PYTHON -V 2>&1 | awk '{print $2}')"

# ── Проверка модуля venv (на Ubuntu без python3-venv падает) ─────────────────
if ! "$PYTHON" -c 'import venv, ensurepip' >/dev/null 2>&1; then
  err "у '$PYTHON' нет модуля venv/ensurepip."
  if [ $IS_TERMUX -eq 0 ]; then
    echo "  Ubuntu/Debian: sudo apt install -y python3-venv python3-pip"
  fi
  exit 1
fi

if [ $SKIP_DEPS -eq 1 ]; then
  warn "--skip-deps: пропускаю установку зависимостей."
else

# ── Python venv + flask/flask-cors ───────────────────────────────────────────
if [ ! -d .venv ]; then
  info "создаю виртуальное окружение .venv (для wsapi_server.py)…"
  "$PYTHON" -m venv .venv
fi
# shellcheck disable=SC1091
. .venv/bin/activate

if [ ! -f .venv/.deps-installed ] || [ requirements.txt -nt .venv/.deps-installed ]; then
  info "ставлю Python-зависимости (flask, flask-cors)…"
  python -m pip install --quiet --upgrade pip
  python -m pip install --quiet -r requirements.txt
  date > .venv/.deps-installed
  ok "python deps OK"
else
  ok "python deps уже установлены"
fi

# ── Node-зависимости (root) ──────────────────────────────────────────────────
if [ ! -d node_modules ] || [ ! -d node_modules/node-pty ] || [ ! -d node_modules/ws ]; then
  info "ставлю Node-зависимости в корне (ws, node-pty)…"
  if ! npm install --omit=dev --no-audit --no-fund; then
    err "npm install в корне упал. Возможно, не хватает build tools для node-pty."
    if [ $IS_TERMUX -eq 0 ]; then
      echo "  Ubuntu/Debian: sudo apt install -y build-essential python3 make g++"
    else
      echo "  Termux: pkg install -y build-essential python make"
    fi
    exit 1
  fi
  ok "root node_modules OK"
else
  ok "root node_modules уже установлены"
fi

# ── Node-зависимости (bridge) ────────────────────────────────────────────────
if [ ! -d bridge/node_modules ] || [ ! -d bridge/node_modules/ws ]; then
  info "ставлю Node-зависимости в bridge/ …"
  ( cd bridge && npm install --omit=dev --no-audit --no-fund )
  ok "bridge node_modules OK"
else
  ok "bridge node_modules уже установлены"
fi

# ── agent-browser (CLI для browser_action в чате) ────────────────────────────
if [ $WITH_BROWSER -eq 1 ]; then
  PT_ROOT="${PLAYWRIGHT_TERMUX_ROOT:-${HOME}/playwright-termux}"
  WRAPPER="${BIN_DIR}/agent-browser"

  # Поищем Chromium заранее, чтобы дать понятный warn
  CHROMIUM=""
  for p in chromium chromium-browser google-chrome google-chrome-stable; do
    if command -v "$p" >/dev/null 2>&1; then CHROMIUM="$(command -v "$p")"; break; fi
  done
  if [ -z "$CHROMIUM" ]; then
    for p in /usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome \
             "${PREFIX:-/usr}/bin/chromium" "${PREFIX:-/usr}/bin/chromium-browser"; do
      [ -x "$p" ] && CHROMIUM="$p" && break
    done
  fi

  if [ ! -x "$WRAPPER" ] || [ ! -d "${PT_ROOT}/node_modules/playwright-core" ]; then
    info "ставлю agent-browser shim (для browser_action в чате)…"
    # install.sh падает на smoke-тесте если порт 9876 занят / Chromium кривой,
    # но сама установка к этому моменту уже завершена. Проверяем по факту наличия
    # обёртки и playwright-core.
    bash tools/agent-browser-termux/install.sh || true
    if [ -x "$WRAPPER" ] && [ -d "${PT_ROOT}/node_modules/playwright-core" ]; then
      ok "agent-browser shim установлен ($WRAPPER)"
    else
      warn "agent-browser shim не установился — браузер в чате работать не будет."
      warn "перезапустите с --no-browser, либо см. tools/agent-browser-termux/README.md"
    fi
  else
    ok "agent-browser shim уже установлен ($WRAPPER)"
  fi

  if [ -z "$CHROMIUM" ]; then
    warn "Chromium не найден. agent-browser будет падать при первом open."
    if [ $IS_TERMUX -eq 1 ]; then
      echo "    поставьте: pkg install -y chromium-browser"
    else
      echo "    поставьте: sudo apt install -y chromium-browser   # или google-chrome"
    fi
  else
    ok "Chromium: $CHROMIUM"
  fi

  # Гарантируем, что server.js (и mcp-bridge npx) увидят agent-browser в PATH.
  case ":$PATH:" in
    *":${BIN_DIR}:"*) ;;
    *) export PATH="${BIN_DIR}:$PATH" ;;
  esac
else
  warn "--no-browser: agent-browser shim пропущен (browser_action в чате не будет работать)."
fi

fi  # SKIP_DEPS

# Активируем venv даже когда --skip-deps — run.py хочет .venv/bin/python.
if [ -d .venv ] && [ -z "${VIRTUAL_ENV:-}" ]; then
  # shellcheck disable=SC1091
  . .venv/bin/activate
fi

# Прокидываем ~/.local/bin в PATH чтобы agent-browser был доступен из server.js exec.
if [ -d "${HOME}/.local/bin" ]; then
  case ":$PATH:" in
    *":${HOME}/.local/bin:"*) ;;
    *) export PATH="${HOME}/.local/bin:$PATH" ;;
  esac
fi

# ── Запуск ───────────────────────────────────────────────────────────────────
echo
bold "запускаю все сервисы (Ctrl+C — остановить):"
exec python run.py "${PASSTHROUGH[@]:-}"
