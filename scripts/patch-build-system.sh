#!/usr/bin/env bash
# patch-build-system.sh — Adapta el build system moderno de termux-packages
# para compilar commits antiguos (2018-2023).
# Idempotente: puede ejecutarse múltiples veces sin efectos secundarios.
set -euo pipefail

REPO_DIR="${1:-$PWD}"  # Directorio del checkout de termux-packages
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/../patches"

echo "=== Aplicando parches al build system ==="

# 1. Parche buildorder.py (-dev → padre)
if ! grep -q "re.sub('-dev\$', '', dependency_value)" "$REPO_DIR/scripts/buildorder.py"; then
    echo "[1/3] Aplicando parche buildorder: -dev → padre"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/001-buildorder-dev-mapping.patch"
else
    echo "[1/3] Parche buildorder ya aplicado, saltando"
fi

# 2. Parche extract_dep_info.sh (normalización -dev)
if ! grep -q 'PKG=${PKG/-dev/}' "$REPO_DIR/scripts/build/termux_extract_dep_info.sh"; then
    echo "[2/3] Aplicando parche extract_dep_info: normalización -dev"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/002-extract-dep-info-dev.patch"
else
    echo "[2/3] Parche extract_dep_info ya aplicado, saltando"
fi

# 3. Normalizar variables legacy en TODOS los build.sh (idempotente)
echo "[3/3] Normalizando variables legacy en build.sh..."
find "$REPO_DIR/packages" "$REPO_DIR/root-packages" "$REPO_DIR/x11-packages" \
    -name build.sh 2>/dev/null | while read -r f; do
    sed -i \
        -e 's/TERMUX_PKG_BLACKLISTED_ARCHES=/TERMUX_PKG_EXCLUDED_ARCHES=/g' \
        -e 's/TERMUX_DEBDIR/TERMUX_OUTPUT_DIR/g' \
        -e 's/TERMUX_MAKE_PROCESSES/TERMUX_PKG_MAKE_PROCESSES/g' \
        -e 's/TERMUX_PKG_NO_DEVELSPLIT/TERMUX_PKG_NO_STATICSPLIT/g' \
        -e 's/\(TERMUX_PKG_[A-Z_]*=\).*yes/\1true/g' \
        -e 's/\(TERMUX_PKG_[A-Z_]*=\).*no/\1false/g' \
        "$f"
done || true

echo "=== Parches aplicados correctamente ==="
