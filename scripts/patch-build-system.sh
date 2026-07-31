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
    echo "[1/10] Aplicando parche buildorder: -dev → padre"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/001-buildorder-dev-mapping.patch"
else
    echo "[1/10] Parche buildorder ya aplicado, saltando"
fi

# 2. Parche extract_dep_info.sh (normalización -dev)
if ! grep -q 'PKG=${PKG/-dev/}' "$REPO_DIR/scripts/build/termux_extract_dep_info.sh"; then
    echo "[2/10] Aplicando parche extract_dep_info: normalización -dev"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/002-extract-dep-info-dev.patch"
else
    echo "[2/10] Parche extract_dep_info ya aplicado, saltando"
fi

# 3. Parche setup_variables.sh (source de python/libllvm tolerante)
if ! grep -q "_MAJOR_VERSION:-\|_MAJOR_VERSION:-\|# Extract _MAJOR_VERSION without sourcing" "$REPO_DIR/scripts/build/termux_step_setup_variables.sh"; then
    echo "[3/10] Aplicando parche setup_variables: source tolerante"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/003-setup-vars-fallback.patch"
else
    echo "[3/10] Parche setup_variables ya aplicado, saltando"
fi

# 4. Parche make_install.sh (setup rust automático para build.sh viejos)
if ! grep -q "Legacy compatibility: old build.sh files don't call termux_setup_rust" "$REPO_DIR/scripts/build/termux_step_make_install.sh"; then
    echo "[4/10] Aplicando parche make_install: termux_setup_rust automático"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/004-make-install-rust.patch"
else
    echo "[4/10] Parche make_install ya aplicado, saltando"
fi

# 5. Parche termux_setup_rust.sh (extraccion con grep + fallback)
if ! grep -q "Legacy compatibility: extract version with grep" "$REPO_DIR/scripts/build/setup/termux_setup_rust.sh"; then
    echo "[5/10] Aplicando parche setup_rust: extraccion con grep + fallback"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/005-termux-setup-rust.patch"
else
    echo "[5/10] Parche setup_rust ya aplicado, saltando"
fi

# 6. Parche start_build.sh (BUILD_IN_SRC acepta yes/true)
if ! grep -q 'Legacy compatibility: build.sh files from 2018 use "yes" instead of "true"' "$REPO_DIR/scripts/build/termux_step_start_build.sh"; then
    echo "[6/10] Aplicando parche start_build: BUILD_IN_SRC tolerante (yes/true)"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/006-start-build-build-in-src.patch"
else
    echo "[6/10] Parche start_build ya aplicado, saltando"
fi

# 7. Parche patch_package.sh (normalizar rutas ../pkg-ver/ en patches de 2018)
# Los patches viejos tienen headers "--- ../bat-0.7.1/Cargo.toml"; BusyBox patch
# falla buscando "bat-0.7.1/Cargo.toml" tras la extracción plana. GNU patch lo
# resuelve por fallback, pero BusyBox no, así que normalizamos antes de aplicar.
if ! grep -qF 'Legacy compatibility: normalize "--- ../pkg-version/..." headers in' "$REPO_DIR/scripts/build/termux_step_patch_package.sh"; then
    echo "[7/10] Aplicando parche patch_package: normalizar rutas de patches legacy"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/007-patch-package-normalize-paths.patch"
else
    echo "[7/10] Parche patch_package ya aplicado, saltando"
fi

# 8. Parche build-package.sh (debug post-patch con marcadores)
# Patch 008 inserta marcadores "MARKER: >>>/<paso>" alrededor de los pasos del
# build para identificar cuál falla con exit 2 después de termux_step_patch_package.
if ! grep -qF 'MARKER: >>> patch_package' "$REPO_DIR/build-package.sh"; then
    echo "[8/10] Aplicando parche build-package: marcadores post-patch"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/008-post-patch-debug.patch"
else
    echo "[8/10] Parche build-package ya aplicado, saltando"
fi

# 9. Parche make_install.sh (debug: capturar stderr REAL del cargo install)
# El run 30615771833 confirmó que el exit 2 ocurre en termux_step_make_install
# sin output. El patch 009 envuelve el cargo install con "2>&1 | tee + PIPESTATUS"
# para que el stderr real quede en /tmp/cargo-install.log y, si falla, se
# impriman las últimas 40 líneas antes de continuar (el fallo natural sigue).
if ! grep -qF 'DEBUG-MI: Cargo.toml detectado' "$REPO_DIR/scripts/build/termux_step_make_install.sh"; then
    echo "[9/10] Aplicando parche make_install: debug stderr de cargo install"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/009-make-install-debug.patch"
else
    echo "[9/10] Parche make_install debug ya aplicado, saltando"
fi

# 10. Normalizar variables legacy en TODOS los build.sh (idempotente)
echo "[10/10] Normalizando variables legacy en build.sh..."
find "$REPO_DIR/packages" "$REPO_DIR/root-packages" "$REPO_DIR/x11-packages" \
    -name build.sh 2>/dev/null | while read -r f; do
    sed -i \
        -e 's/TERMUX_PKG_BLACKLISTED_ARCHES=/TERMUX_PKG_EXCLUDED_ARCHES=/g' \
        -e 's/TERMUX_DEBDIR/TERMUX_OUTPUT_DIR/g' \
        -e 's/TERMUX_MAKE_PROCESSES/TERMUX_PKG_MAKE_PROCESSES/g' \
        -e 's/TERMUX_PKG_NO_DEVELSPLIT/TERMUX_PKG_NO_STATICSPLIT/g' \
        -e 's/^\(TERMUX_PKG_[A-Z_]*\)=yes$/\1=true/g' \
        -e 's/^\(TERMUX_PKG_[A-Z_]*\)=no$/\1=false/g' \
        "$f"
done || true

echo "=== Parches aplicados correctamente ==="
