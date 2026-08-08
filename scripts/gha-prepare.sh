#!/usr/bin/env bash
# gha-prepare.sh — Prepara el árbol del paquete histórico de termux-packages
# para compilar dentro de GitHub Actions usando el build system VENDERED del
# proyecto (build-system/ en la raíz del repo).
#
# Extraído de los steps "Fetch build system from master" y
# "Apply build system patches" del workflow build-old-package.yml, para que
# los jobs build-normal y build-subversioned compartan exactamente la misma
# preparación sin duplicar comandos.
#
# El runtime YA NO descarga master de termux-packages ni aplica parches: el
# build system propio (árbol de upstream de5ca479 + 16 implementaciones legacy +
# blindaje LLVM, metadata en build-system/REVISION y build-system/FORK.md) está
# COMMITEADO en el repo y se copia íntegro al árbol del paquete.
#
# Uso:
#   ./scripts/gha-prepare.sh <dir_termux_packages>
#
#   p.ej. ./scripts/gha-prepare.sh "$PWD/termux-packages"
#
# Requiere: el checkout histórico de termux-packages ya clonado
# (por actions/checkout en el commit exacto del paquete) y build-system/
# presente en el repo. NO usa git clone ni curl.
set -euo pipefail

TP_DIR="${1:-${GITHUB_WORKSPACE:-$PWD}/termux-packages}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDORED_DIR="$SCRIPT_DIR/../build-system"

echo "=== [gha-prepare] Preparando build system vendered para: $TP_DIR ==="

# ── Validaciones ──
if [ ! -d "$TP_DIR" ]; then
    echo "Error: el directorio de termux-packages no existe: $TP_DIR" >&2
    exit 1
fi

if [ ! -f "$VENDORED_DIR/REVISION" ]; then
    echo "Error: build system vendered no encontrado: $VENDORED_DIR" >&2
    echo "Se espera $VENDORED_DIR/REVISION (árbol commiteado del build system)." >&2
    echo "¿Se commiteó build-system/ en el repo?" >&2
    exit 1
fi

# SHA del upstream importado, para el echo de progreso
VENDORED_SHA="$(grep -m1 '^UPSTREAM_SHA=' "$VENDORED_DIR/REVISION" | cut -d= -f2 || true)"
VENDORED_SHA="${VENDORED_SHA:-desconocido}"

# ── 1. Copiar el build system vendered al árbol del paquete ──
echo "[gha-prepare] Copiando build system vendered (upstream $VENDORED_SHA)..."

cp "$VENDORED_DIR/build-package.sh" "${TP_DIR}/build-package.sh"
cp "$VENDORED_DIR/repo.json" "${TP_DIR}/repo.json"
rm -rf "${TP_DIR}/scripts"
cp -r "$VENDORED_DIR/scripts" "${TP_DIR}/scripts"

# PrevTermux Store: librería de acceso al pool de deps (código del PROYECTO,
# no del vendered). El hook de termux_step_get_dependencies la sourcea vía
# $TERMUX_SCRIPTDIR/scripts/store-lib.sh dentro del contenedor
# ($TERMUX_SCRIPTDIR = raíz del árbol, build-package.sh:24).
echo "[gha-prepare] Copiando store-lib.sh al build system..."
cp "$SCRIPT_DIR/store-lib.sh" "$TP_DIR/scripts/store-lib.sh"

# Copiar claves GPG (termux-keyring) y el build.sh moderno de termux-elf-cleaner
rm -rf "${TP_DIR}/packages/termux-keyring"
cp -r "$VENDORED_DIR/packages/termux-keyring" \
    "${TP_DIR}/packages/termux-keyring"
rm -rf "${TP_DIR}/packages/termux-elf-cleaner"
cp -r "$VENDORED_DIR/packages/termux-elf-cleaner" \
    "${TP_DIR}/packages/termux-elf-cleaner"

# Copiar ndk-patches modernos (con subdirectorios por versión)
rm -rf "${TP_DIR}/ndk-patches"
cp -r "$VENDORED_DIR/ndk-patches" \
    "${TP_DIR}/ndk-patches"

# Crear directorios vacíos que el buildorder moderno espera
mkdir -p "${TP_DIR}/root-packages"
mkdir -p "${TP_DIR}/x11-packages"

echo "[gha-prepare] Build system vendered copiado."

# ── 2. Normalizar los build.sh HISTÓRICOS del paquete ──
# (no es build system: es preparación del paquete; extraído del bloque [10/17]
#  de patch-build-system.sh, que se conserva como referencia pero no se ejecuta)
echo "[gha-prepare] Normalizando build.sh legacy..."
chmod +x "$SCRIPT_DIR/normalize-legacy-builds.sh"
"$SCRIPT_DIR/normalize-legacy-builds.sh" "$TP_DIR"

echo "=== [gha-prepare] Done. Build system listo (upstream $VENDORED_SHA). ==="
