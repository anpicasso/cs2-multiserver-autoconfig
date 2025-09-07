#!/usr/bin/env bash
set -euo pipefail

# Stops all instances listed in managed_game_servers.json using cs2-server/msm.
# Also stops the 'tmt2' Docker container if present, and cleans up /home/tmt2.

# --- Resolve cs2-multiserver binaries ---
# Use the folder where this script resides as working base
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR/cs2-multiserver"
CS2_BIN_PATH="$REPO_DIR/cs2-server"
DID_CLONE=0

have_cmd() { command -v "$1" >/dev/null 2>&1; }

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

JSON_FILE="/home/tmt2/storage/managed_game_servers.json"
if [[ -f "$JSON_FILE" ]]; then
  echo "Using JSON: $JSON_FILE"
  COUNT=0
  if command -v jq >/dev/null 2>&1; then
    COUNT=$(jq 'length' "$JSON_FILE")
  else
    # Crude fallback without jq: count lines containing '"port":'
    COUNT=$(grep -c '"port"' "$JSON_FILE" || true)
  fi
  if [[ -n "$COUNT" && "$COUNT" -gt 0 ]]; then
    for ((i=1; i<=COUNT; i++)); do
      instance="game${i}"
      #echo "Stopping @${instance} ..."
      "$MSM_CMD" "@${instance}" stop || true
    done
    echo "CS2 instances stopped (COUNT=$COUNT)."
  else
    echo "No instances to stop (COUNT=$COUNT)."
  fi
else
  echo "Notice: $JSON_FILE not found; skipping CS2 instance stop."
fi

# Stop Docker container 'tmt2' if it exists
docker_cmd() {
  if docker "$@"; then return 0; fi
  if command -v sudo >/dev/null 2>&1; then sudo docker "$@"; else return 1; fi
}

if command -v docker >/dev/null 2>&1 || command -v sudo >/dev/null 2>&1; then
  if docker_cmd ps -a --format '{{.Names}}' | grep -Fxq tmt2; then
    echo "Stopping Docker container 'tmt2'..."
    docker_cmd stop tmt2 >/dev/null || true
  else
    echo "Container 'tmt2' does not exist; nothing to stop."
  fi
else
  echo "Notice: Docker is not available; skipping container stop."
fi

# Remove directory /home/tmt2
TARGET_DIR="/home/tmt2"
if [[ -d "$TARGET_DIR" ]]; then
  echo "Deleting $TARGET_DIR ..."
  if rm -rf "$TARGET_DIR" 2>/dev/null; then
    :
  elif command -v sudo >/dev/null 2>&1; then
    sudo rm -rf "$TARGET_DIR" || true
  fi
else
  echo "Directory $TARGET_DIR does not exist; skipped."
fi

echo "Done. Stops and cleanup completed."
