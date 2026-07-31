#!/usr/bin/env bash
# gha-build.sh — Compila un paquete antiguo de termux-packages dentro de
# GitHub Actions usando run-docker.sh.
#
# Extraído del step "Build package" del workflow build-old-package.yml, para
# que los jobs build-normal y build-subversioned compartan la misma lógica.
#
# Con --subversioned se compila con un PREFIX versionado (path ABSOLUTO del
# dispositivo, no ~):
#   TERMUX_PREFIX_OVERRIDE=/data/data/com.termux/files/home/.local/opt/<pkg>-<ver>
#   TERMUX_DOCKER_EXEC_EXTRA_ARGS="--env TERMUX_PREFIX_OVERRIDE=$TERMUX_PREFIX_OVERRIDE"
# (run-docker.sh de termux-packages pasa TERMUX_DOCKER_EXEC_EXTRA_ARGS a
#  docker exec; el parche 010-prefix-override hace que build-package.sh lea
#  TERMUX_PREFIX_OVERRIDE como PREFIX.)
#
# Uso:
#   ./scripts/gha-build.sh \
#       --package <pkg> \
#       --git-ref <sha> \
#       --arch <aarch64|arm|i686|x86_64> \
#       --format <pacman|debian> (input aceptado y validado por compatibilidad
#                                  con el dispatch manual/workflow; el build
#                                  SIEMPRE compila .deb — formato universal — y
#                                  deb2pkg.sh lo convierte a .pkg.tar.xz)
#       --build-mode <fast|full> \
#       [--subversioned] \
#       [--workdir <dir_termux_packages>]
#
#   p.ej. ./scripts/gha-build.sh \
#       --package bash --git-ref abc1234 --arch aarch64 \
#       --format pacman --build-mode fast \
#       --workdir "$PWD/termux-packages"
set -euo pipefail

# ── Config ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Librería canónica de extracción de versión (scripts/lib/version-extract.sh)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/version-extract.sh"

PREFIX_BASE="/data/data/com.termux/files/home/.local/opt"
REAL_PREFIX="/data/data/com.termux/files/usr"
WORKDIR_DEFAULT=""

# ── Argumentos ──
PACKAGE=""
GIT_REF=""
ARCH=""
FORMAT=""
BUILD_MODE=""
SUBVERSIONED=0

while [ $# -gt 0 ]; do
    case "$1" in
        --package)   PACKAGE="${2:?--package requiere un valor}"; shift 2 ;;
        --git-ref)   GIT_REF="${2:?--git-ref requiere un valor}"; shift 2 ;;
        --arch)      ARCH="${2:?--arch requiere un valor}"; shift 2 ;;
        --format)    FORMAT="${2:?--format requiere un valor}"; shift 2 ;;
        --build-mode) BUILD_MODE="${2:?--build-mode requiere un valor}"; shift 2 ;;
        --subversioned) SUBVERSIONED=1; shift ;;
        --workdir)   WORKDIR_DEFAULT="${2:?--workdir requiere un valor}"; shift 2 ;;
        *) echo "Error: argumento desconocido: $1" >&2; exit 1 ;;
    esac
done

# ── Validaciones ──
[ -n "$PACKAGE" ]   || { echo "Error: falta --package" >&2; exit 1; }
[ -n "$GIT_REF" ]   || { echo "Error: falta --git-ref" >&2; exit 1; }
[ -n "$ARCH" ]      || { echo "Error: falta --arch" >&2; exit 1; }
[ -n "$FORMAT" ]    || { echo "Error: falta --format" >&2; exit 1; }
[ -n "$BUILD_MODE" ] || { echo "Error: falta --build-mode (fast|full)" >&2; exit 1; }

case "$BUILD_MODE" in
    fast|full) ;;
    *) echo "Error: build-mode inválido: '$BUILD_MODE' (debe ser fast o full)" >&2; exit 1 ;;
esac

# --format: se acepta pacman|debian como entrada. El input se mantiene por
# compatibilidad con el dispatch manual/workflow, pero el build SIEMPRE
# compila debian (formato universal de termux-packages, compatible con commits
# pre-2021-09 que no soportan --format pacman); el flag se IGNORA para el build
# (ver sección Build).
case "$FORMAT" in
    pacman|debian) ;;
    *) echo "Error: formato inválido: '$FORMAT' (debe ser pacman o debian)" >&2; exit 1 ;;
esac

if [ -n "$WORKDIR_DEFAULT" ]; then
    WORKDIR="$WORKDIR_DEFAULT"
elif [ -d "$PWD/termux-packages" ]; then
    WORKDIR="$PWD/termux-packages"
else
    WORKDIR="$PWD"
fi

if [ ! -d "$WORKDIR" ]; then
    echo "Error: directorio de trabajo no existe: $WORKDIR" >&2
    exit 1
fi

BUILD_SH="$WORKDIR/packages/$PACKAGE/build.sh"
if [ ! -f "$BUILD_SH" ]; then
    echo "Error: build.sh not found for package '$PACKAGE'"
    echo "Expected path: $BUILD_SH"
    exit 1
fi

# ── CI (igual que el env CI=true del step original) ──
export CI=true

# ── Extract package version (algoritmo canónico de version-extract.sh) ──
PACKAGE_VERSION="$(version_extract "$BUILD_SH")" || {
    echo "Error: could not extract TERMUX_PKG_VERSION from $BUILD_SH" >&2
    exit 1
}
echo "Extracted version: ${PACKAGE_VERSION}"

# ── Modo subversioned: PREFIX versionado ──
if [ "$SUBVERSIONED" -eq 1 ]; then
    # ── Guard de sanidad: el parche 010 debe estar aplicado ──
    if ! grep -q 'TERMUX_PREFIX_OVERRIDE' "$WORKDIR/build-package.sh"; then
        echo "Error: build-package.sh no soporta TERMUX_PREFIX_OVERRIDE." >&2
        echo "El patch 010-prefix-override no está aplicado — el build subversioned" >&2
        echo "produciría un paquete estándar (sin prefix versionado)." >&2
        echo "Revisa: $WORKDIR/build-package.sh" >&2
        exit 1
    fi

    # ── Guard de sanidad: arquitectura válida (el formato ya se validó arriba) ──
    case "$ARCH" in
        aarch64|arm|i686|x86_64) ;;
        *) echo "Error: arquitectura inválida: '$ARCH' (debe ser aarch64, arm, i686 o x86_64)" >&2; exit 1 ;;
    esac

    # ── Sanitización unificada de la versión (misma regla que CLI y workflow):
    #    tr -d '"' "'" ' ' + sed 's/[^a-zA-Z0-9._-]/-/g' ──
    PACKAGE_VERSION="$(echo "$PACKAGE_VERSION" | tr -d '"' | tr -d "'" | tr -d ' ' | sed 's/[^a-zA-Z0-9._-]/-/g')"
    TERMUX_PREFIX_OVERRIDE="$PREFIX_BASE/${PACKAGE}-${PACKAGE_VERSION}"

    # ── Assert: el path resultante no debe contener espacios ni globs (* ? [) ──
    case "$TERMUX_PREFIX_OVERRIDE" in
        *' '*|*'*'*|*'?'*|*'['*)
            echo "Error: TERMUX_PREFIX_OVERRIDE contiene espacios o globs (* ? [): $TERMUX_PREFIX_OVERRIDE" >&2
            exit 1
            ;;
    esac

    TERMUX_DOCKER_EXEC_EXTRA_ARGS="--env TERMUX_PREFIX_OVERRIDE=$TERMUX_PREFIX_OVERRIDE"
    export TERMUX_PREFIX_OVERRIDE
    export TERMUX_DOCKER_EXEC_EXTRA_ARGS
    echo "=== [gha-build] MODO SUBVERSIONED ==="
    echo "TERMUX_PREFIX_OVERRIDE=$TERMUX_PREFIX_OVERRIDE"
    echo "TERMUX_DOCKER_EXEC_EXTRA_ARGS=$TERMUX_DOCKER_EXEC_EXTRA_ARGS"
    echo "PREFIX real del sistema: $REAL_PREFIX"
fi

# ── Build ──
cd "$WORKDIR"

# El .deb es el formato UNIVERSAL de termux-packages: los commits pre-2021-09
# solo producen .deb (no soportan --format pacman). Por eso el build SIEMPRE
# usa --format debian. El --format de entrada ya se validó arriba pero se
# IGNORA aquí (se mantiene solo por compatibilidad con el dispatch manual).
BUILD_FORMAT="debian"

# En modo subversioned se fuerza -F (TERMUX_FORCE_BUILD_DEPENDENCIES) SIEMPRE,
# sin importar el --build-mode de entrada (fast/-I): las deps deben quedar
# versionadas — la recursión de build-package hereda TERMUX_PREFIX_OVERRIDE y
# las deps caen en el prefix versionado. En modo normal se conserva el
# comportamiento actual (-I o -F según --build-mode).
if [ "$SUBVERSIONED" -eq 1 ] || [ "$BUILD_MODE" = "full" ]; then
    echo "Running full build (-F) for $PACKAGE..."
    ./scripts/run-docker.sh ./build-package.sh \
        --format debian \
        -a "$ARCH" \
        -F "$PACKAGE"
else
    echo "Running fast build (-I) for $PACKAGE..."
    ./scripts/run-docker.sh ./build-package.sh \
        --format debian \
        -a "$ARCH" \
        -I "$PACKAGE"
fi

# ── Conversión post-build: .deb → .pkg.tar.xz (scripts/deb2pkg.sh) ──
# El build SIEMPRE produce .deb; los ubicamos en $WORKDIR/output (master,
# TERMUX_OUTPUT_DIR) o en $WORKDIR/debs (commits pre-2021, TERMUX_DEBDIR).
shopt -s nullglob
debs=("$WORKDIR"/output/*.deb "$WORKDIR"/debs/*.deb)
if [ "${#debs[@]}" -eq 0 ]; then
    echo "Error: No .deb files found after build — expected in output/ or debs/" >&2
    exit 1
fi

for deb in "${debs[@]}"; do
    echo "=== [gha-build] Convirtiendo $deb a .pkg.tar.xz ==="
    if ! "$SCRIPT_DIR/deb2pkg.sh" "$deb"; then
        echo "Error: falló la conversión de $deb con deb2pkg.sh" >&2
        exit 1
    fi
done

echo "Conversión completada. Archivos .pkg.tar.xz generados:"
for deb in "${debs[@]}"; do
    echo "  - ${deb%.deb}.pkg.tar.xz"
done
