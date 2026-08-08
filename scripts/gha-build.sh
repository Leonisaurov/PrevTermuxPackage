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
#  docker exec; la impl 010 del build system vendered (build-system/build-package.sh,
#  copiado por gha-prepare.sh al árbol del paquete) hace que build-package.sh lea
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
#       [--store <on|off|true|false>] (default on — el input use_store del
#                            workflow pasa true|false; se aceptan también
#                            on|off por compatibilidad con invocaciones manuales)
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
STORE="on"

while [ $# -gt 0 ]; do
    case "$1" in
        --package)   PACKAGE="${2:?--package requiere un valor}"; shift 2 ;;
        --git-ref)   GIT_REF="${2:?--git-ref requiere un valor}"; shift 2 ;;
        --arch)      ARCH="${2:?--arch requiere un valor}"; shift 2 ;;
        --format)    FORMAT="${2:?--format requiere un valor}"; shift 2 ;;
        --build-mode) BUILD_MODE="${2:?--build-mode requiere un valor}"; shift 2 ;;
        --subversioned) SUBVERSIONED=1; shift ;;
        --store)       STORE="${2:?--store requiere on|off}"; shift 2 ;;
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

# --store: activa/desactiva el hook del PrevTermux Store (pool de releases).
# El workflow pasa --store con el input `use_store` del dispatch (true|false,
# opciones de GitHub Actions); se aceptan también on|off por compatibilidad con
# invocaciones manuales/legacy. Se normaliza a on/off para el resto del script.
case "$STORE" in
    on|true)   STORE="on" ;;
    off|false) STORE="off" ;;
    *) echo "Error: --store inválido: '$STORE' (debe ser on|off o true|false)" >&2; exit 1 ;;
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
    # ── Guard de sanidad: la impl 010 del vendered debe estar presente ──
    # (gha-prepare.sh copia build-system/build-package.sh, que ya lleva la
    #  impl 010 "Legacy compatibility: subversioned builds allow
    #  TERMUX_PREFIX_OVERRIDE" commiteada en el árbol del repo)
    if ! grep -q 'TERMUX_PREFIX_OVERRIDE' "$WORKDIR/build-package.sh"; then
        echo "Error: build-package.sh no soporta TERMUX_PREFIX_OVERRIDE." >&2
        echo "La impl 010 del build system vendered no está presente — el build" >&2
        echo "subversioned produciría un paquete estándar (sin prefix versionado)." >&2
        echo "Revisa que gha-prepare.sh copió build-system/build-package.sh a:" >&2
        echo "  $WORKDIR/build-package.sh" >&2
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

# ── PrevTermux Store: reutilización de deps del pool de releases ──
# El hook en termux_step_get_dependencies consulta el pool (GitHub Releases,
# tag prev-termux-pool-<arch>) ANTES de recompilar una dep. Estas envs llegan
# al contenedor vía TERMUX_DOCKER_EXEC_EXTRA_ARGS (mecanismo de la impl 010).
TERMUX_STORE_ENABLED="false"
[ "$STORE" = "on" ] && TERMUX_STORE_ENABLED="true"
TERMUX_STORE_URL="${TERMUX_STORE_URL:-https://github.com/${GITHUB_REPOSITORY:-unknown/unknown}/releases/download}"
if [ "$SUBVERSIONED" -eq 1 ]; then
    TERMUX_STORE_MODE="subversioned"
else
    TERMUX_STORE_MODE="normal"
fi

# TERMUX_DOCKER_EXEC_EXTRA_ARGS pudo ser definido por el bloque subversioned
# (--env TERMUX_PREFIX_OVERRIDE=...); acumulamos aquí el resto de envs.
TERMUX_DOCKER_EXEC_EXTRA_ARGS="${TERMUX_DOCKER_EXEC_EXTRA_ARGS:-}"
TERMUX_DOCKER_EXEC_EXTRA_ARGS+=" --env TERMUX_STORE_ENABLED=$TERMUX_STORE_ENABLED"
TERMUX_DOCKER_EXEC_EXTRA_ARGS+=" --env TERMUX_STORE_URL=$TERMUX_STORE_URL"
TERMUX_DOCKER_EXEC_EXTRA_ARGS+=" --env TERMUX_STORE_MODE=$TERMUX_STORE_MODE"
TERMUX_DOCKER_EXEC_EXTRA_ARGS+=" --env GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-unknown/unknown}"

if [ "$STORE" = "on" ]; then
    # NO se sobreescribe TERMUX_TOPDIR (default del contenedor
    # /home/builder/.termux-build): TERMUX_PKG_BUILDDIR/SRCDIR/CACHEDIR/
    # MASSAGEDIR/PACKAGEDIR y TERMUX_COMMON_CACHEDIR cuelgan de él, y meter
    # TODO el estado de build en .store-cache (persistido por actions/cache)
    # hinchaba la caché con cientos de MB/GB. En su lugar se redirigen SOLO
    # los dirs del store al árbol montado (HOST=$WORKDIR/.store-cache ↔
    # contenedor=/home/builder/termux-packages/.store-cache; VOLUME fijo de
    # run-docker.sh: $REPOROOT:/home/builder/termux-packages). Así
    # .store-cache SOLO contiene .built-packages/ (markers del build system)
    # y store/ (manifest + debs descargados del pool), que actions/cache
    # (fase 2) puede persistir entre runs.
    mkdir -p "$WORKDIR/.store-cache/.built-packages" "$WORKDIR/.store-cache/store"
    TERMUX_BUILT_PACKAGES_DIRECTORY="/home/builder/termux-packages/.store-cache/.built-packages"
    TERMUX_STORE_DIR="/home/builder/termux-packages/.store-cache/store"
    # bs_rev del build system vendered (build-system/REVISION): store-lib.sh lo
    # usa para invalidar el manifest cacheado si el build system cambió.
    TERMUX_STORE_BS_REV="$(grep -m1 '^UPSTREAM_SHA=' "$SCRIPT_DIR/../build-system/REVISION" | cut -d= -f2 2>/dev/null || true)"
    TERMUX_STORE_BS_REV="${TERMUX_STORE_BS_REV:-desconocido}"
    TERMUX_DOCKER_EXEC_EXTRA_ARGS+=" --env TERMUX_BUILT_PACKAGES_DIRECTORY=$TERMUX_BUILT_PACKAGES_DIRECTORY"
    TERMUX_DOCKER_EXEC_EXTRA_ARGS+=" --env TERMUX_STORE_DIR=$TERMUX_STORE_DIR"
    TERMUX_DOCKER_EXEC_EXTRA_ARGS+=" --env TERMUX_STORE_BS_REV=$TERMUX_STORE_BS_REV"
fi

export TERMUX_STORE_ENABLED TERMUX_STORE_URL TERMUX_STORE_MODE TERMUX_DOCKER_EXEC_EXTRA_ARGS
echo "=== [gha-build] PREVTERMUX STORE ==="
echo "TERMUX_STORE_ENABLED=$TERMUX_STORE_ENABLED TERMUX_STORE_URL=$TERMUX_STORE_URL TERMUX_STORE_MODE=$TERMUX_STORE_MODE"
if [ "$STORE" = "on" ]; then
    export TERMUX_BUILT_PACKAGES_DIRECTORY TERMUX_STORE_DIR TERMUX_STORE_BS_REV
    echo "TERMUX_STORE_DIR=$TERMUX_STORE_DIR (host: $WORKDIR/.store-cache/store) TERMUX_BUILT_PACKAGES_DIRECTORY=$TERMUX_BUILT_PACKAGES_DIRECTORY (host: $WORKDIR/.store-cache/.built-packages) TERMUX_STORE_BS_REV=$TERMUX_STORE_BS_REV"
fi
echo "TERMUX_DOCKER_EXEC_EXTRA_ARGS=$TERMUX_DOCKER_EXEC_EXTRA_ARGS"

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
