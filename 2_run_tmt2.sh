#!/usr/bin/env bash
set -euo pipefail

# Installs Docker if missing (Debian/Ubuntu), then runs TMT2 container.

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
  # Ejecuta docker y, si falla por permisos, intenta con sudo.
  if docker "$@"; then
    return 0
  fi
  if have_cmd sudo; then
    sudo docker "$@"
  else
    echo "No hay permisos para ejecutar docker y no hay sudo disponible." >&2
    return 1
  fi
}

main() {
  ensure_docker_installed

  # Verificar acceso a docker (daemon y permisos)
  if ! docker_cmd ps >/dev/null 2>&1; then
    echo "No se pudo comunicar con el daemon de Docker. Verifica que esté en ejecución." >&2
    exit 1
  fi

  # Asegurar el directorio de almacenamiento
  local host_dir="/home/tmt2/storage"
  if [[ ! -d "$host_dir" ]]; then
    mkdir -p "$host_dir" 2>/dev/null || {
      if have_cmd sudo; then
        sudo mkdir -p "$host_dir"
        sudo chown "$USER":"$USER" "$host_dir" || true
      else
        echo "No se pudo crear $host_dir (quizá requiere permisos elevados)." >&2
        exit 1
      fi
    }
  fi

  # Si el contenedor existe, arrancarlo; si no, crearlo
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

  # Mostrar el archivo de tokens creado por el contenedor cuando aparezca
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
