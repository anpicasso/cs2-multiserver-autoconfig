#!/usr/bin/env bash
set -euo pipefail

# Purpose: Ensure Docker is available and run the TMT2 container.
# - Installs Docker if missing (Debian/Ubuntu-based systems).
# - Ensures the Docker daemon is running and accessible.
# - Creates the host storage directory at /home/tmt2/storage.
# - Starts or creates the 'tmt2' container (port 8080 exposed).
# - Waits for /home/tmt2/storage/access_tokens.json to appear and prints it.

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_docker_installed() {
  if have_cmd docker; then
    return 0
  fi

  echo "Docker no instalado. Intentando instalarlo..." >&2

  if have_cmd apt-get; then
    local SUDO=""
    if [[ $EUID -ne 0 ]]; then
      if have_cmd sudo; then SUDO="sudo"; else echo "Se requiere root/sudo para instalar Docker" >&2; exit 1; fi
    fi

    # Instalar docker.io de los repos del sistema
    $SUDO apt-get update -y
    $SUDO apt-get install -y docker.io
    # Asegurar que el servicio esté activo
    if have_cmd systemctl; then
      $SUDO systemctl enable --now docker || true
    fi

  else
    echo "Instalación automática no soportada en este sistema. Instala Docker manualmente: https://docs.docker.com/engine/install/" >&2
    exit 1
  fi

  if ! have_cmd docker; then
    echo "Docker no quedó instalado correctamente." >&2
    exit 1
  fi
}

docker_cmd() {
  # Run docker and, if permission denied, retry with sudo.
  if docker "$@"; then
    return 0
  fi
  if have_cmd sudo; then
    sudo docker "$@"
  else
    echo "No permissions to run docker and no sudo available." >&2
    return 1
  fi
}

main() {
  ensure_docker_installed

  # Verify docker daemon accessibility and permissions
  if ! docker_cmd ps >/dev/null 2>&1; then
    echo "Cannot communicate with Docker daemon. Ensure it is running." >&2
    exit 1
  fi

  # Ensure the storage directory exists with correct ownership
  local host_dir="/home/tmt2/storage"
  if [[ ! -d "$host_dir" ]]; then
    mkdir -p "$host_dir" 2>/dev/null || {
      if have_cmd sudo; then
        sudo mkdir -p "$host_dir"
        sudo chown "$USER":"$USER" "$host_dir" || true
      else
        echo "Could not create $host_dir (may require elevated privileges)." >&2
        exit 1
      fi
    }
  fi

  # If the container exists, start it; otherwise create it
  if docker_cmd ps -a --format '{{.Names}}' | grep -Fxq tmt2; then
    if docker_cmd ps --format '{{.Names}}' | grep -Fxq tmt2; then
      echo "El contenedor 'tmt2' ya está en ejecución."
    else
      echo "Iniciando contenedor existente 'tmt2'..."
      docker_cmd start tmt2 >/dev/null
    fi
  else
    echo "Creando y ejecutando contenedor 'tmt2'..."
    docker_cmd run --name tmt2 -d -p 8080:8080 -v /home/tmt2/storage:/app/backend/storage jensforstmann/tmt2 >/dev/null
  fi

  echo "Listo. TMT2 está disponible en http://localhost:8080"

  # Show the tokens file created by the container when it appears
  tokens_file="/home/tmt2/storage/access_tokens.json"
  echo "Esperando a que se genere $tokens_file ..."
  for i in {1..60}; do
    if [[ -f "$tokens_file" ]]; then break; fi
    sleep 1
  done
  if [[ -f "$tokens_file" ]]; then
    echo "Contenido de $tokens_file:"
    cat "$tokens_file"
  else
    echo "Advertencia: No se encontró $tokens_file tras esperar 60s. El contenedor podría seguir inicializando."
  fi
}

main "$@"
