#!/usr/bin/env bash
set -euo pipefail

# Detiene todas las instancias listadas en managed_game_servers.json usando cs2-server/msm

# --- Bootstrap cs2-multiserver and dependencies ---
# Usar la carpeta donde está el script como base
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
    echo "ERROR: No se encuentra 'msm' ni 'cs2-server'. Añádelo al PATH o asegúrate de tener cs2-multiserver en $REPO_DIR" >&2
    exit 2
  fi
}

MSM_CMD="$(resolve_msm)"

JSON_FILE="/home/tmt2/storage/managed_game_servers.json"
if [[ -f "$JSON_FILE" ]]; then
  echo "Usando JSON: $JSON_FILE"
  COUNT=0
  if command -v jq >/dev/null 2>&1; then
    COUNT=$(jq 'length' "$JSON_FILE")
  else
    # Fallback tosco sin jq: cuenta líneas con '"port":'
    COUNT=$(grep -c '"port"' "$JSON_FILE" || true)
  fi
  if [[ -n "$COUNT" && "$COUNT" -gt 0 ]]; then
    for ((i=1; i<=COUNT; i++)); do
      instance="game${i}"
      echo "Deteniendo @${instance} ..."
      "$MSM_CMD" "@${instance}" stop || true
    done
    echo "Instancias cs2 detenidas (COUNT=$COUNT)."
  else
    echo "No hay instancias para detener (COUNT=$COUNT)."
  fi
else
  echo "Aviso: No se encontró $JSON_FILE; omitiendo parada de instancias cs2."
fi

# Detener contenedor Docker 'tmt2' si existe
docker_cmd() {
  if docker "$@"; then return 0; fi
  if command -v sudo >/dev/null 2>&1; then sudo docker "$@"; else return 1; fi
}

if command -v docker >/dev/null 2>&1 || command -v sudo >/dev/null 2>&1; then
  if docker_cmd ps -a --format '{{.Names}}' | grep -Fxq tmt2; then
    echo "Deteniendo contenedor Docker 'tmt2'..."
    docker_cmd stop tmt2 >/dev/null || true
  else
    echo "Contenedor 'tmt2' no existe; nada que detener."
  fi
else
  echo "Aviso: Docker no está disponible; omitiendo parada del contenedor."
fi

# Eliminar directorio /home/tmt2
TARGET_DIR="/home/tmt2"
if [[ -d "$TARGET_DIR" ]]; then
  echo "Eliminando $TARGET_DIR ..."
  if rm -rf "$TARGET_DIR" 2>/dev/null; then
    :
  elif command -v sudo >/dev/null 2>&1; then
    sudo rm -rf "$TARGET_DIR" || true
  fi
else
  echo "Directorio $TARGET_DIR no existe; omitido."
fi

echo "Listo. Paradas y limpieza completadas."
