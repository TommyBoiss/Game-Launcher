#!/usr/bin/env bash
set -euo pipefail

# init.sh — interactive configuration for launch-game.sh

CONFIG_DIR="${UMU_WRAPPER_CONFIG_DIR:-$HOME/.config/umu-wrapper}"
CONFIG_FILE="$CONFIG_DIR/config.sh"

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

GE_REPO="GloriousEggroll/proton-ge-custom"
GE_RELEASES_URL="https://github.com/$GE_REPO/releases"

# Downloads, verifies, and extracts a GE-Proton release into DEST_DIR.
# Sets OUT_VAR in the caller to the extracted path; returns non-zero on failure.
install_proton_ge() {
  local dest_dir="$1" version="$2" out_var="$3"
  local resolved_tag arch asset_arch tarball_name checksum_name base_url tmp_dir extracted_dir

  if [[ "$version" == "latest" ]]; then
    info "Looking up the latest GE-Proton release..."
    resolved_tag=$(curl -fsL -o /dev/null -w '%{url_effective}' "$GE_RELEASES_URL/latest" 2>/dev/null | sed -E 's#.*/tag/##')
    if [[ -z "$resolved_tag" ]]; then
      warn "Could not reach GitHub to determine the latest release. Check your network connection."
      return 1
    fi
  else
    resolved_tag="$version"
  fi
  info "Selected release: $resolved_tag"

  arch="$(uname -m)"
  case "$arch" in
    x86_64)          asset_arch="x86_64" ;;
    aarch64|arm64)   asset_arch="aarch64" ;;
    *)
      warn "Unrecognized architecture '$arch' — assuming x86_64 asset naming."
      asset_arch="x86_64"
      ;;
  esac

  base_url="$GE_RELEASES_URL/download/$resolved_tag"
  tmp_dir="$(mktemp -d)"
  cleanup() {
    [[ -n "$tmp_dir" && "$tmp_dir" != "/" && "$tmp_dir" == "${TMPDIR:-/tmp}"* ]] && rm -rf "$tmp_dir"
  }
  trap cleanup EXIT

  tarball_name="${resolved_tag}-${asset_arch}.tar.gz"
  checksum_name="${resolved_tag}-${asset_arch}.sha512sum"

  info "Downloading $tarball_name ..."
  if ! curl -fL --progress-bar -o "$tmp_dir/$tarball_name" "$base_url/$tarball_name" 2>&1 | tail -n 1; then
    warn "Asset not found as $tarball_name, trying legacy naming ..."
    tarball_name="${resolved_tag}.tar.gz"
    checksum_name="${resolved_tag}.sha512sum"
    if ! curl -fL --progress-bar -o "$tmp_dir/$tarball_name" "$base_url/$tarball_name" 2>&1 | tail -n 1; then
      warn "Failed to download $tarball_name from $base_url"
      return 1
    fi
  fi

  if curl -fsSL -o "$tmp_dir/$checksum_name" "$base_url/$checksum_name" 2>/dev/null; then
    info "Verifying checksum ..."
    if ( cd "$tmp_dir" && sha512sum -c "$checksum_name" ) >/dev/null 2>&1; then
      ok "Checksum verified."
    else
      warn "Checksum verification FAILED for $tarball_name — the download may be corrupt or tampered with."
      confirm "Install anyway despite the checksum mismatch? (not recommended)" || {
        warn "Aborting install."
        return 1
      }
    fi
  else
    warn "Could not download a checksum file for this release — skipping verification."
  fi

  mkdir -p "$dest_dir"
  info "Extracting to $dest_dir ..."
  if ! tar -xzf "$tmp_dir/$tarball_name" -C "$dest_dir"; then
    warn "Extraction failed."
    return 1
  fi

  extracted_dir="$dest_dir/$resolved_tag"
  if [[ ! -d "$extracted_dir" ]]; then
    extracted_dir=$(tar -tzf "$tmp_dir/$tarball_name" | head -n1 | cut -d/ -f1)
    extracted_dir="$dest_dir/$extracted_dir"
  fi

  if [[ ! -d "$extracted_dir" ]]; then
    warn "Installed, but could not determine the resulting Proton directory automatically."
    return 1
  fi

  ok "Installed GE-Proton to $extracted_dir"
  printf -v "$out_var" '%s' "$extracted_dir"
  trap - EXIT
  return 0
}

: "${HOME:?HOME is not set — cannot determine default paths}"

# ── Prompt helper ─────────────────────────────────────────────────────────────
# prompt_path VAR_NAME "Label" "default value"
prompt_path() {
  local __var="$1" __label="$2" __default="$3" __input
  read -rp "$(echo -e "${C_WARN}?${C_RESET} $__label [$__default]: ")" __input
  __input="${__input:-$__default}"
  __input="${__input/#\~/$HOME}"
  printf -v "$__var" '%s' "$__input"
}

confirm() {
  local __prompt="$1" __reply
  read -rp "$(echo -e "${C_WARN}?${C_RESET} $__prompt [y/N]: ")" __reply
  [[ "$__reply" =~ ^[Yy]$ ]]
}

# ── Warn if reconfiguring ──────────────────────────────────────────────────────
if [[ -f "$CONFIG_FILE" ]]; then
  warn "Existing config found at $CONFIG_FILE"
  info "Current values:"
  sed 's/^/    /' "$CONFIG_FILE"
  echo ""
  confirm "Overwrite this configuration?" || { info "Leaving existing config untouched."; exit 0; }
  echo ""
fi

# ── Dependency checks ──────────────────────────────────────────────────────────
missing=()
for bin in firejail umu-run; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
if (( ${#missing[@]} > 0 )); then
  warn "Missing required tool(s): ${missing[*]}"
  warn "The launcher will not work until these are installed and on your PATH."
  confirm "Continue configuring anyway?" || err "Aborted."
fi

download_tools_missing=()
for bin in curl tar sha512sum; do
  command -v "$bin" >/dev/null 2>&1 || download_tools_missing+=("$bin")
done
if (( ${#download_tools_missing[@]} > 0 )); then
  warn "Missing tool(s) needed for automatic Proton installs: ${download_tools_missing[*]}"
  warn "You'll be able to configure a Proton path manually, but not auto-download one."
fi

# ── Gather configuration ───────────────────────────────────────────────────────
info "Configure paths for the game launcher. Press Enter to accept each default."
echo ""

prompt_path GAME_ROOT "Game root directory (where your game folders live)" "$HOME/Games"

DEFAULT_PROTON_DIR="$GAME_ROOT/.proton"
prompt_path PROTON_BASE_DIR "Directory containing Proton builds" "$DEFAULT_PROTON_DIR"

proton_builds=()
if [[ -d "$PROTON_BASE_DIR" ]]; then
  mapfile -d '' proton_builds < <(find "$PROTON_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
fi

echo ""
info "Proton setup:"
for i in "${!proton_builds[@]}"; do
  echo -e "  ${C_BOLD}$((i + 1))${C_RESET}) $(basename "${proton_builds[$i]}")  (already installed)"
done
echo -e "  ${C_BOLD}i${C_RESET}) Download and install a GE-Proton build automatically"
echo -e "  ${C_BOLD}m${C_RESET}) Enter a Proton path manually"

while true; do
  read -rp "$(echo -e "\n${C_WARN}?${C_RESET} Choice [i]: ")" proton_action
  proton_action="${proton_action:-i}"

  if [[ "$proton_action" =~ ^[0-9]+$ ]] && (( proton_action >= 1 && proton_action <= ${#proton_builds[@]} )); then
    PROTONPATH="${proton_builds[$((proton_action - 1))]}"
    info "Using existing build: $PROTONPATH"
    break

  elif [[ "$proton_action" == "i" ]]; then
    if (( ${#download_tools_missing[@]} > 0 )); then
      warn "Cannot auto-install: missing ${download_tools_missing[*]}."
      continue
    fi
    read -rp "$(echo -e "${C_WARN}?${C_RESET} GE-Proton version to install (tag name, or 'latest') [latest]: ")" ge_version
    ge_version="${ge_version:-latest}"
    installed_path=""
    if install_proton_ge "$PROTON_BASE_DIR" "$ge_version" installed_path; then
      PROTONPATH="$installed_path"
      break
    else
      warn "Automatic install failed — pick another option, or choose 'm' to set a path manually."
    fi

  elif [[ "$proton_action" == "m" ]]; then
    prompt_path PROTONPATH "Full path to a specific Proton build" "$PROTON_BASE_DIR/GE-Proton11-6"
    break

  else
    warn "Invalid choice."
  fi
done

prompt_path WINEPREFIX "Wine prefix directory" "$GAME_ROOT/.wine-game"
prompt_path UMU_DATA   "UMU data directory (XDG_DATA_HOME for umu-run)" "$GAME_ROOT/.local-share"
prompt_path LOG_DIR    "Log directory (for --proton-log)" "$GAME_ROOT/Logs"

echo ""
prompt_path GAMEID "Default UMU game ID (letters, numbers, - and _ only; blank = umu-default)" ""
if [[ -n "$GAMEID" && ! "$GAMEID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  err "Invalid GAMEID: only letters, numbers, '-' and '_' are allowed."
fi

prompt_path STORE "Default storefront for protonfixes lookups (steam, egs, gog, none, ...)" "none"

# ── Create directories ─────────────────────────────────────────────────────────
echo ""
for dir_var in GAME_ROOT WINEPREFIX UMU_DATA LOG_DIR; do
  dir_val="${!dir_var}"
  if [[ ! -d "$dir_val" ]]; then
    if confirm "Directory for $dir_var does not exist: $dir_val — create it?"; then
      mkdir -p "$dir_val"
      ok "Created $dir_val"
    else
      warn "Skipped creating $dir_val — launch-game.sh may fail until it exists."
    fi
  fi
done

if [[ ! -d "$PROTONPATH" ]]; then
  warn "PROTONPATH does not exist yet: $PROTONPATH"
  warn "Make sure a Proton build is installed there before launching a game."
fi

# ── Write config file ──────────────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR"
umask 077
cat > "$CONFIG_FILE" <<EOF
# Generated by init.sh on $(date -Iseconds)
GAME_ROOT="\${GAME_ROOT:-$GAME_ROOT}"
PROTONPATH="\${PROTONPATH:-$PROTONPATH}"
WINEPREFIX="\${WINEPREFIX:-$WINEPREFIX}"
UMU_DATA="\${UMU_DATA:-$UMU_DATA}"
LOG_DIR="\${LOG_DIR:-$LOG_DIR}"
GAMEID="\${GAMEID:-$GAMEID}"
STORE="\${STORE:-$STORE}"
EOF

ok "Configuration written to $CONFIG_FILE"
echo ""
info "You can now run launch-game.sh, or override any value per-run, e.g.:"
echo -e "    ${C_BOLD}GAME_ROOT=\$HOME/OtherGames ./launch-game.sh${C_RESET}"
echo ""
info "To reconfigure later, just run ./init.sh again."