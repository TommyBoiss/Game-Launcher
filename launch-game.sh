#!/usr/bin/env bash
set -euo pipefail

: "${HOME:?HOME is not set — cannot determine default paths}"

# ── Configuration ─────────────────────────────────────────────────────────────
# Precedence: environment variables > config file from init.sh > defaults.
UMU_WRAPPER_CONFIG_DIR="${UMU_WRAPPER_CONFIG_DIR:-$HOME/.config/umu-wrapper}"
UMU_WRAPPER_CONFIG_FILE="$UMU_WRAPPER_CONFIG_DIR/config.sh"

if [[ -f "$UMU_WRAPPER_CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$UMU_WRAPPER_CONFIG_FILE"
fi

GAME_ROOT="${GAME_ROOT:-$HOME/Games}"
PROTONPATH="${PROTONPATH:-$GAME_ROOT/.proton/GE-Proton11-1}"
WINEPREFIX="${WINEPREFIX:-$GAME_ROOT/.wine-game}"
UMU_DATA="${UMU_DATA:-$GAME_ROOT/.local-share}"
LOG_DIR="${LOG_DIR:-$GAME_ROOT/Logs}"
GAMEID="${GAMEID:-}"
STORE="${STORE:-none}"

NET_MODE="none"
ALLOW_DBUS=0
IGNORE_SECCOMP=0
PROTON_LOG=0

# ── UI Helpers ────────────────────────────────────────────────────────────────
C_ERR='\033[1;31m'
C_OK='\033[1;32m'
C_INFO='\033[1;34m'
C_WARN='\033[1;33m'
C_RESET='\033[0m'
C_BOLD='\033[1m'

info()  { echo -e "${C_INFO}::${C_RESET} ${C_BOLD}$1${C_RESET}"; }
ok()    { echo -e "${C_OK}::${C_RESET} ${C_BOLD}$1${C_RESET}"; }
warn()  { echo -e "${C_WARN}::${C_RESET} ${C_BOLD}$1${C_RESET}"; }
err()   { echo -e "${C_ERR}::${C_RESET} ${C_BOLD}$1${C_RESET}" >&2; exit 1; }

# ── Argument Parsing ──────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${C_BOLD}Usage:${C_RESET} $(basename "$0") [OPTIONS]

Paths (GAME_ROOT, PROTONPATH, WINEPREFIX, etc.) are read from
$UMU_WRAPPER_CONFIG_FILE if present. Run ./init.sh to configure them
interactively, or override any of them per-invocation as environment
variables, e.g. GAME_ROOT=\$HOME/OtherGames $(basename "$0").

${C_BOLD}Network:${C_RESET}
  --net-none         Disable all network access (default)
  --net-full         Allow full network access (WEAKENS sandbox — shares host net namespace)

${C_BOLD}Sandbox:${C_RESET}
  --allow-dbus       Enable filtered D-Bus session bus access only (default: off)
  --ignore-seccomp   Disable firejail seccomp filtering (WEAKENS sandbox — default: off)

${C_BOLD}Logging & Meta:${C_RESET}
  --proton-log       Enable Proton & UMU debug logging
  --gameid ID        Set the UMU game ID (alphanumeric, dash, underscore only)
  --help             Show this menu
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --net-none)       NET_MODE="none"; shift ;;
    --net-full)       NET_MODE="full"; shift ;;
    --allow-dbus)     ALLOW_DBUS=1; shift ;;
    --ignore-seccomp) IGNORE_SECCOMP=1; shift ;;
    --proton-log)     PROTON_LOG=1; shift ;;
    --gameid)         [[ $# -ge 2 ]] || err "--gameid requires a value."; GAMEID="$2"; shift 2 ;;
    --gameid=*)       GAMEID="${1#*=}"; shift ;;
    --help|-h)        usage; exit 0 ;;
    *)                err "Unknown argument: $1" ;;
  esac
done

# ── Input Validation ──────────────────────────────────────────────────────────
if [[ -n "$GAMEID" && ! "$GAMEID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  err "Invalid --gameid value: only letters, numbers, '-' and '_' are allowed."
fi

# ── Risk Warnings ─────────────────────────────────────────────────────────────
if (( IGNORE_SECCOMP )); then
  warn "SECCOMP FILTERING DISABLED — full host syscall surface is exposed to the game/Proton process."
fi
if (( ALLOW_DBUS )); then
  warn "D-BUS ACCESS ENABLED — filtered session bus socket only will be exposed."
fi
if [[ "$NET_MODE" == "full" ]]; then
  warn "FULL NETWORK ACCESS ENABLED — sandbox shares the host network namespace (including localhost services)."
fi

# ── Build Sandbox Arguments ───────────────────────────────────────────────────
FJ_ARGS=(
  --noprofile --private --private-dev
  --whitelist="$WINEPREFIX"
  --whitelist="$UMU_DATA"
  --whitelist="$PROTONPATH"
  --read-write="$WINEPREFIX"
  --read-write="$UMU_DATA"
  --read-only="/usr"
  --read-only="/lib"
  --read-only="/lib64"
  --read-only="/bin"
  --read-only="/etc/fonts"
  --read-only="/etc/locale.alias"
  --read-only="/etc/machine-id"
  --read-only="/etc/resolv.conf"
  --read-only="/etc/nsswitch.conf"
  --ipc-namespace
)

if [[ "$NET_MODE" == "none" ]]; then
  FJ_ARGS+=(--net=none)
else
  FJ_ARGS+=(--net=host)
fi

if (( ALLOW_DBUS )); then
  FJ_ARGS+=(--dbus-user=filter --dbus-system=none)
  BUS_SOCK="/run/user/$(id -u)/bus"
  if [[ -S "$BUS_SOCK" ]]; then
    FJ_ARGS+=(--whitelist="$BUS_SOCK")
  else
    warn "D-Bus socket not found at $BUS_SOCK — D-Bus access will not be available."
  fi
else
  FJ_ARGS+=(--dbus-user=none --dbus-system=none --private-tmp)
fi

(( IGNORE_SECCOMP )) && FJ_ARGS+=(--ignore=seccomp)

if (( PROTON_LOG )); then
  mkdir -p "$LOG_DIR"
  FJ_ARGS+=(--whitelist="$LOG_DIR" --read-write="$LOG_DIR")
  export PROTON_LOG=1
  export PROTON_LOG_DIR="$LOG_DIR"
  export UMU_LOG=1
fi

export PROTONPATH
export WINEPREFIX
export XDG_DATA_HOME="$UMU_DATA"
export STORE
[[ -n "$GAMEID" ]] && export GAMEID

# ── Dependency Check ──────────────────────────────────────────────────────────
missing=()
for bin in firejail umu-run; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
(( ${#missing[@]} > 0 )) && err "Missing required tool(s): ${missing[*]} — install them before launching."

# ── Selection UI ──────────────────────────────────────────────────────────────
[[ -d "$GAME_ROOT" ]] || err "Game root directory does not exist: $GAME_ROOT (run ./init.sh to configure)"

mapfile -d '' game_dirs < <(
  find "$GAME_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -not -name '.*' -not -name 'Logs' -print0 | sort -z
)

(( ${#game_dirs[@]} == 0 )) && err "No games found in $GAME_ROOT"

info "Select a Game:"
for i in "${!game_dirs[@]}"; do
  echo -e "  ${C_BOLD}$((i + 1))${C_RESET}) $(basename "${game_dirs[$i]}")"
done

while true; do
  read -rp "$(echo -e "\n${C_WARN}>${C_RESET} Choice: ")" choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#game_dirs[@]} )); then
    GAME_DIR="${game_dirs[$((choice - 1))]}"
    break
  fi
done

mapfile -d '' exes < <(find "$GAME_DIR" -type f \( -iname '*.exe' -o -iname '*.bat' \) -print0 | sort -z)
(( ${#exes[@]} == 0 )) && err "No executables found in $(basename "$GAME_DIR")"

if (( ${#exes[@]} == 1 )); then
  game="${exes[0]}"
else
  echo ""
  info "Select Executable:"
  for i in "${!exes[@]}"; do
    echo -e "  ${C_BOLD}$((i + 1))${C_RESET}) ${exes[$i]#"$GAME_DIR"/}"
  done
  while true; do
    read -rp "$(echo -e "\n${C_WARN}>${C_RESET} Choice: ")" exe_choice
    if [[ "$exe_choice" =~ ^[0-9]+$ ]] && (( exe_choice >= 1 && exe_choice <= ${#exes[@]} )); then
      game="${exes[$((exe_choice - 1))]}"
      break
    fi
  done
fi

# ── Pre-launch Setup ──────────────────────────────────────────────────────────
FJ_ARGS+=(--whitelist="$GAME_DIR" --read-write="$GAME_DIR")

DOSDEVICES="$WINEPREFIX/dosdevices"
if [[ -d "$DOSDEVICES" ]]; then
  find "$DOSDEVICES" -maxdepth 1 -type l ! -name 'c:' -delete
  ln -sf "$GAME_DIR" "$DOSDEVICES/d:"
fi

# ── Execution ─────────────────────────────────────────────────────────────────
clear
ok "Starting $(basename "$game")"
info "Network:   $NET_MODE"
info "Seccomp:   $(( IGNORE_SECCOMP ? 0 : 1 ))"
info "D-Bus:     $ALLOW_DBUS"
echo ""

firejail "${FJ_ARGS[@]}" umu-run "$game"

if (( PROTON_LOG )); then
  LOG_FILE="$LOG_DIR/steam-${GAMEID:-default}.log"
  echo ""
  if [[ -f "$LOG_FILE" ]]; then
    ok "Logs saved: $LOG_FILE ($(du -h "$LOG_FILE" | cut -f1))"
  else
    warn "Log file expected at $LOG_FILE but not found."
  fi
fi