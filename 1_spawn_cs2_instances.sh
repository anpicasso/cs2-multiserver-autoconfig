#!/usr/bin/env bash
set -euo pipefail

# Purpose: Provision and start multiple CS2 server instances via cs2-multiserver (msm/cs2-server).
# - Creates instances game1..gameN, assigns game + GOTV ports incrementally.
# - Generates distinct passwords per instance: game password and RCON password.
# - Writes managed servers JSON to /home/tmt2/storage/managed_game_servers.json (includes only RCON password).
# - Writes a CSV with game passwords at ./game_passwords.csv (instance,port,game_password).
# Usage: ./spawn_cs2_instances.sh <count> <ip> <gslt> [start_game_port=27015] [start_tv_port=27050]

COUNT="${1:-}"
IP_INPUT="${2:-}"
GSLT_INPUT="${3:-}"
GAME_PORT_START="${4:-27015}"
TV_PORT_START="${5:-27050}"

if [[ -z "${COUNT}" || -z "${IP_INPUT}" || -z "${GSLT_INPUT}" ]]; then
  echo "Usage: $0 <count> <ip> <gslt> [start_game_port=27015] [start_tv_port=27050]" >&2
  exit 1
fi

# --- Bootstrap cs2-multiserver and dependencies ---
# Use the folder where this script resides as working base
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Download repository ZIP and extract in the same directory as this script
ZIP_URL="https://github.com/dasisdormax/cs2-multiserver/archive/refs/heads/main.zip"
REPO_DIR="$SCRIPT_DIR/cs2-multiserver"
CS2_BIN_PATH="$REPO_DIR/cs2-server"
DID_CLONE=0

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_deps() {
  # Install required packages if missing (Debian/Ubuntu)
  local pkgs=(lib32gcc-s1 lib32stdc++6 jq unzip inotify-tools tmux wget)
  if have_cmd apt-get && have_cmd dpkg; then
    local SUDO=""
    if [[ $EUID -ne 0 ]]; then
      if have_cmd sudo; then SUDO="sudo"; else echo "Notice: no sudo/root available; cannot install dependencies" >&2; return 0; fi
    fi

    # Ensure i386 architecture is enabled for 32-bit libs
    if ! dpkg --print-foreign-architectures | grep -q '^i386$'; then
      $SUDO dpkg --add-architecture i386 || true
      $SUDO apt-get update -y || true
    fi

    # Detect missing packages
    local missing=()
    for p in "${pkgs[@]}"; do
      if ! dpkg -s "$p" >/dev/null 2>&1; then
        missing+=("$p")
      fi
    done
    if ((${#missing[@]})); then
      $SUDO apt-get update -y
      # Try to install; continue even if some fail to avoid aborting
      $SUDO apt-get install -y "${missing[@]}" || true
    fi
  else
    # Package manager not auto-supported; print required packages for manual install
    echo "Notice: install manually -> lib32gcc-s1 lib32stdc++6 jq unzip inotify-tools tmux" >&2
  fi
}

ensure_repo() {
  # Download and extract the repo if the cs2-server executable is not available
  if ! have_cmd cs2-server && [[ ! -x "$CS2_BIN_PATH" ]]; then
    echo "cs2-server not found; downloading cs2-multiserver (ZIP) into $SCRIPT_DIR" >&2
    local zip_path="$SCRIPT_DIR/cs2-multiserver-main.zip"
    rm -f "$zip_path" || true
    if have_cmd wget; then
      wget -q -O "$zip_path" "$ZIP_URL"
    else
      echo "ERROR: 'wget' is not available and is required to download the ZIP" >&2
      return 1
    fi

    # Unzip downloaded archive
    (cd "$SCRIPT_DIR" && unzip -q -o "$zip_path")
    rm -f "$zip_path" || true

    # Rename extracted folder cs2-multiserver-main -> cs2-multiserver
    if [[ -d "$SCRIPT_DIR/cs2-multiserver-main" ]]; then
      rm -rf "$REPO_DIR" || true
      mv "$SCRIPT_DIR/cs2-multiserver-main" "$REPO_DIR"
    fi

    DID_CLONE=1
  fi
}

run_setup_or_update() {
  local cs2_cmd=""
  if [[ -x "$CS2_BIN_PATH" ]]; then
    cs2_cmd="$CS2_BIN_PATH"
  elif have_cmd cs2-server; then
    cs2_cmd="$(command -v cs2-server)"
  else
    # Fallback: try msm if it exists
    if have_cmd msm; then cs2_cmd="$(command -v msm)"; else return 0; fi
  fi

  if (( DID_CLONE == 1 )); then
    echo "Running initial cs2-server setup"
    # Auto-accept installation and use 'anonymous' Steam user
    printf "y\nanonymous\n" | "$cs2_cmd" setup || true
  fi
  echo "Updating cs2-server"
  "$cs2_cmd" update || true
}

ensure_repo
ensure_deps
run_setup_or_update

# Resolve MSM/cs2-server entrypoint path
resolve_msm() {
  if command -v cs2-server >/dev/null 2>&1; then
    command -v cs2-server
  elif command -v msm >/dev/null 2>&1; then
    command -v msm
  elif [[ -x "$REPO_DIR/cs2-server" ]]; then
    echo "$REPO_DIR/cs2-server"
  elif [[ -x "$REPO_DIR/msm" ]]; then
    echo "$REPO_DIR/msm"
  else
    echo "ERROR: Neither 'msm' nor 'cs2-server' found. Add to PATH or ensure cs2-multiserver in $REPO_DIR" >&2
    exit 2
  fi
}

MSM_CMD="$(resolve_msm)"
CFG_DIR="$HOME/msm.d/cs2/cfg"
BASE_CFG_DIR="$CFG_DIR/base"

# Managed output JSON (reset on each run)
JSON_FILE="/home/tmt2/storage/managed_game_servers.json"
if [[ ! -d "/home/tmt2/storage" ]]; then
  mkdir -p "/home/tmt2/storage" 2>/dev/null || {
    if command -v sudo >/dev/null 2>&1; then
      sudo mkdir -p "/home/tmt2/storage"
      sudo chown "$USER":"$USER" "/home/tmt2" "/home/tmt2/storage" || true
    else
      echo "ERROR: Could not create /home/tmt2/storage" >&2
      exit 1
    fi
  }
fi
if [[ -f "$JSON_FILE" ]]; then
  rm -f "$JSON_FILE"
fi
echo '[]' > "$JSON_FILE"

# CSV containing per-instance game passwords (created in script directory)
CSV_FILE="$SCRIPT_DIR/game_passwords.csv"
# Reset CSV on each run and write header
echo 'instance,port,game_password' > "$CSV_FILE"

# Helpers
rand_pass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 6; echo; }

ensure_inst_cfg() {
  local inst="$1"
  local inst_cfg_dir="$CFG_DIR/inst-$inst"
  mkdir -p "$inst_cfg_dir"
  # Seed config from base if files missing
  [[ -f "$inst_cfg_dir/server.conf" ]] || cp -f "$BASE_CFG_DIR/server.conf" "$inst_cfg_dir/server.conf"
  [[ -f "$inst_cfg_dir/gotv.conf"   ]] || cp -f "$BASE_CFG_DIR/gotv.conf"   "$inst_cfg_dir/gotv.conf"
}

set_kv_server_conf() {
  local file="$1" key="$2" value="$3"
  # Handles commented and uncommented forms of __KEY__ and normal KEY
  # For passwords/host we set __KEY__ (weak default), which becomes KEY via applyDefaults
  if grep -Eq "^[#[:space:]]*__${key}__=" "$file"; then
    sed -i -E "s|^[#[:space:]]*__${key}__=.*|__${key}__=\"${value}\"|" "$file"
  else
    printf '__%s__="%s"\n' "$key" "$value" >> "$file"
  fi
}

enable_rcon() {
  local file="$1"
  if grep -Eq "^[#[:space:]]*USE_RCON=" "$file"; then
    sed -i -E 's|^[#[:space:]]*USE_RCON=.*|USE_RCON="-usercon"|' "$file"
  else
    echo 'USE_RCON="-usercon"' >> "$file"
  fi
}

set_tv_port() {
  local file="$1" tvp="$2"
  # Force explicit TV_PORT=<num>, replacing default arithmetic if present
  if grep -Eq "^TV_PORT=" "$file"; then
    sed -i -E "s|^TV_PORT=.*|TV_PORT=${tvp}|" "$file"
  else
    echo "TV_PORT=${tvp}" >> "$file"
  fi
  # Ensure TV enabled
  if grep -Eq "^[#[:space:]]*__TV_ENABLE__=" "$file"; then
    sed -i -E 's|^[#[:space:]]*__TV_ENABLE__=.*|__TV_ENABLE__="1"|' "$file"
  else
    echo '__TV_ENABLE__="1"' >> "$file"
  fi
}

# Main loop
for ((i=1; i<=COUNT; i++)); do
  instance="game${i}"
  game_port=$(( GAME_PORT_START + i - 1 ))
  tv_port=$(( TV_PORT_START + i - 1 ))
  # Generate distinct passwords for game and RCON
  game_pass="$(rand_pass)"
  rcon_pass="$(rand_pass)"
  # Ensure they are different (collision is very unlikely but handled)
  if [[ "$rcon_pass" == "$game_pass" ]]; then
    rcon_pass="$(rand_pass)"
  fi

  echo "==> Creating/adjusting @$instance (game_port=$game_port, tv_port=$tv_port)"

  # Create instance if needed (idempotent)
  "$MSM_CMD" "@${instance}" create || true

  # Ensure config files exist for the instance
  ensure_inst_cfg "$instance"
  server_conf="$CFG_DIR/inst-$instance/server.conf"
  gotv_conf="$CFG_DIR/inst-$instance/gotv.conf"

  # Apply server settings
  set_kv_server_conf "$server_conf" "PORT" "$game_port"
  set_kv_server_conf "$server_conf" "PASS" "$game_pass"
  set_kv_server_conf "$server_conf" "RCON_PASS" "$rcon_pass"
  set_kv_server_conf "$server_conf" "HOST" "Game ${i}"
  enable_rcon "$server_conf"

  # Apply GOTV settings
  set_tv_port "$gotv_conf" "$tv_port"

  # Start instance with provided GSLT
  echo "    Starting @$instance ..."
  GSLT="$GSLT_INPUT" "$MSM_CMD" "@${instance}" start

  # Append entry to managed servers JSON
  obj=$(jq -n --arg ip "$IP_INPUT" --argjson port "$game_port" --arg rcon "$rcon_pass" '{canBeUsed:true, ip:$ip, port:$port, rconPassword:$rcon, usedBy:null}')
  tmpfile=$(mktemp)
  jq --argjson o "$obj" '. + [ $o ]' "$JSON_FILE" > "$tmpfile" && mv "$tmpfile" "$JSON_FILE"

  # Record game password in CSV
  echo "${instance},${game_port},${game_pass}" >> "$CSV_FILE"
done

echo "Done. JSON generated at: $JSON_FILE"
echo "Passwords CSV generated at: $CSV_FILE"
