#!/usr/bin/env bash
# gha-prepare.sh — Prepara el build system de termux-packages para compilar
# commits antiguos dentro de GitHub Actions.
#
# Extraído de los steps "Fetch build system from master" y
# "Apply build system patches" del workflow build-old-package.yml, para que
# los jobs build-normal y build-subversioned compartan exactamente la misma
# preparación sin duplicar comandos.
#
# Uso:
#   ./scripts/gha-prepare.sh <dir_termux_packages>
#
#   p.ej. ./scripts/gha-prepare.sh "$PWD/termux-packages"
#
# Requiere: git, curl. Asume que <dir_termux_packages> ya fue clonado
# (por actions/checkout en el commit exacto del paquete).
set -euo pipefail

TP_DIR="${1:-${GITHUB_WORKSPACE:-$PWD}/termux-packages}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${TMPDIR:=/tmp}"
MASTER_DIR="$TMPDIR/termux-master"
trap 'rm -rf "$MASTER_DIR"' EXIT

echo "=== [gha-prepare] Preparando build system para: $TP_DIR ==="

if [ ! -d "$TP_DIR" ]; then
    echo "Error: el directorio de termux-packages no existe: $TP_DIR" >&2
    exit 1
fi

# ── 1. Fetch build system from master ──
echo "[gha-prepare] Cloning scripts/ from termux-packages master..."
rm -rf "$MASTER_DIR"
git clone --depth=1 --filter=blob:none --sparse \
    https://github.com/termux/termux-packages.git "$MASTER_DIR"
cd "$MASTER_DIR"
git sparse-checkout set scripts packages/termux-keyring packages/termux-elf-cleaner ndk-patches

echo "[gha-prepare] Downloading build-package.sh..."
curl -sL -o build-package.sh \
    "https://raw.githubusercontent.com/termux/termux-packages/master/build-package.sh"
chmod +x build-package.sh

echo "[gha-prepare] Downloading repo.json..."
curl -sL -o "${TP_DIR}/repo.json" \
    "https://raw.githubusercontent.com/termux/termux-packages/master/repo.json" 2>/dev/null || true

echo "[gha-prepare] Replacing build system files..."
cp build-package.sh "${TP_DIR}/build-package.sh"
rm -rf "${TP_DIR}/scripts"
cp -r scripts "${TP_DIR}/scripts"

# Copiar claves GPG (termux-keyring)
rm -rf "${TP_DIR}/packages/termux-keyring"
cp -r packages/termux-keyring \
    "${TP_DIR}/packages/termux-keyring"

# Copiar build.sh moderno de termux-elf-cleaner
rm -rf "${TP_DIR}/packages/termux-elf-cleaner"
cp -r packages/termux-elf-cleaner \
    "${TP_DIR}/packages/termux-elf-cleaner"

# Copiar ndk-patches modernos (con subdirectorios por versión)
rm -rf "${TP_DIR}/ndk-patches"
cp -r ndk-patches \
    "${TP_DIR}/ndk-patches"

# Crear directorios vacíos que el buildorder moderno espera
mkdir -p "${TP_DIR}/root-packages"
mkdir -p "${TP_DIR}/x11-packages"

rm -rf "$MASTER_DIR"
echo "[gha-prepare] Build system updated from master."

# ── 2. Apply build system patches (compatibilidad con commits antiguos) ──
echo "[gha-prepare] Applying build system patches..."
chmod +x "$SCRIPT_DIR/patch-build-system.sh"
"$SCRIPT_DIR/patch-build-system.sh" "$TP_DIR"

echo "=== [gha-prepare] Done. Build system listo. ==="
