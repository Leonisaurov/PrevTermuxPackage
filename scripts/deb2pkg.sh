#!/usr/bin/env bash
# deb2pkg.sh — Convierte un .deb de termux-packages a .pkg.tar.xz (pacman).
#
# El pipeline de PrevTermuxPackage compila SIEMPRE en formato .deb (formato
# universal, compatible con commits pre-2021 de termux-packages que solo
# producen .deb) y este script convierte el .deb a .pkg.tar.xz (para
# subinstall / pacman) al final del build.
#
# La conversión replica EXACTAMENTE el formato de
#   termux-packages/scripts/build/termux_step_create_pacman_package.sh
# (master):
#   - .PKGINFO con los mismos campos y las mismas transformaciones:
#       * Depends "pkg (>= ver)"  ->  "depend = pkg>=ver"  (mismo sed/awk)
#       * Conffiles del .deb      ->  "backup = <path sin '/' inicial>"
#   - .MTREE comprimido con gzip (el comando exacto de termux).
#   - Empaquetado con bsdtar --no-fflags + xz (COMPRESS=xz de termux).
#
# Uso:
#   deb2pkg.sh <file.deb> [--out-dir <dir>]
#
# Produce <basename-sin-.deb>.pkg.tar.xz en el mismo directorio del .deb
# (o en --out-dir).
set -euo pipefail

# ── Argumentos ──
DEB=""
OUT_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --out-dir) OUT_DIR="${2:?--out-dir requiere un valor}"; shift 2 ;;
        -*) echo "Error: argumento desconocido: $1" >&2; exit 1 ;;
        *) DEB="$1"; shift ;;
    esac
done

[ -n "$DEB" ] || { echo "Uso: deb2pkg.sh <file.deb> [--out-dir <dir>]" >&2; exit 1; }
[ -f "$DEB" ] || { echo "Error: no existe el archivo: $DEB" >&2; exit 1; }

OUT_DIR="${OUT_DIR:-$(dirname "$DEB")}"
mkdir -p "$OUT_DIR"
# OUTFILE se computa DESPUÉS de leer el control (PKGNAME/PKGVER/ARCH):
# el nombre del artifact sale de los CAMPOS del control, no del basename
# del .deb (que usa '_' en el .deb pero subinstall espera separadores '-').

# ── 1. Validar el .deb: ar t debe contener control.tar.* y data.tar.* ──
MEMBERS="$(ar t "$DEB")"
CONTROL_MEMBER="$(printf '%s\n' "$MEMBERS" | tr -d '/' | grep -oE '^control\.tar\.(xz|gz)$' | head -n 1 || true)"
DATA_MEMBER="$(printf '%s\n' "$MEMBERS" | tr -d '/' | grep -oE '^data\.tar\.(xz|gz)$' | head -n 1 || true)"

[ -n "$CONTROL_MEMBER" ] || {
    echo "Error: '$DEB' no contiene control.tar.* (miembros: $MEMBERS)" >&2
    exit 1
}
[ -n "$DATA_MEMBER" ] || {
    echo "Error: '$DEB' no contiene data.tar.* (miembros: $MEMBERS)" >&2
    exit 1
}

# ── 2. Extraer a $TMPDIR (fallback $HOME/tmp, escribible en Termux y GHA;
#       NUNCA /tmp, que no es escribible en Termux si TMPDIR no está definido) ──
# mktemp no crea el directorio base: si $HOME/tmp no existe (p.ej. GHA con
# HOME=/home/runner) hay que crearlo primero.
TMP_BASE="${TMPDIR:-$HOME/tmp}"
mkdir -p "$TMP_BASE"
TMP="$(mktemp -d "$TMP_BASE/deb2pkg.XXXXXX")"
mkdir -p "$TMP/control" "$TMP/data"
trap 'rm -rf "$TMP"' EXIT

ar p "$DEB" "$CONTROL_MEMBER" > "$TMP/control.tar"
ar p "$DEB" "$DATA_MEMBER" > "$TMP/data.tar"

# ── 3. Control: extraer y leer el archivo 'control' (+ conffiles si existe) ──
tar xf "$TMP/control.tar" -C "$TMP/control"
CONTROL_FILE="$TMP/control/control"
[ -f "$CONTROL_FILE" ] || {
    echo "Error: '$CONTROL_MEMBER' de '$DEB' no contiene el archivo 'control'" >&2
    exit 1
}

# ── 4. Data: extraer (preserva estructura ./data/data/com.termux/...) ──
tar xf "$TMP/data.tar" -C "$TMP/data"

# Tamaño instalado, igual que termux: du -bs del árbol (ANTES de escribir
# .PKGINFO/.MTREE para que el "size" refleje solo el contenido del paquete).
INSTALL_SIZE="$(du -bs "$TMP/data" | cut -f 1)"

# ── Helpers de parseo del control (campos tipo "Field: value") ──
# Valor de la primera línea de un campo (Description: solo la primera línea).
get_control_field() {
    sed -n "s/^${1}:[[:space:]]*//p" "$CONTROL_FILE" | head -n 1
}
# Valor completo de un campo incluyendo líneas de continuación (los campos
# de dependencias pueden estar envueltos), unidas con un espacio.
get_control_multi() {
    awk -v field="$1" '
        index($0, field ":") == 1 {
            in_field = 1
            val = substr($0, length(field) + 2)
            sub(/^[ \t]+/, "", val)
            next
        }
        in_field && /^[ \t]/ { val = val " " $0; next }
        in_field { exit }
        END {
            if (in_field) { gsub(/^[ \t]+|[ \t]+$/, "", val); print val }
        }
    ' "$CONTROL_FILE"
}

PKGNAME="$(get_control_field "Package")"
# PKGVER cruda del control (p.ej. "5.1.16-0" o "1.2.3~beta").
PKGVER="$(get_control_field "Version" | tr -d '[:space:]')"
# Sanitización unificada de la versión — MISMA regla del prefix versionado
# (gha-build.sh / CLI): tr -d '"' "'" ' ' + sed 's/[^a-zA-Z0-9._-]/-/g'.
# Necesaria para que el nombre del artifact coincida con el dir del árbol
# versionado (~/.local/opt/<pkg>-<ver-sanitizada>) y subinstall extraiga al
# target correcto. p.ej. "1.2.3~beta" → "1.2.3-beta".
PKGVER="$(echo "$PKGVER" | tr -d '"' | tr -d "'" | tr -d ' ' | sed 's/[^a-zA-Z0-9._-]/-/g')"
# pacman (libalpm >= 16) rechaza un pkgver sin sufijo de release. termux
# SIEMPRE publica "ver-0" (o "ver-<revision>"): el .deb usa solo "ver" cuando
# el paquete no tiene TERMUX_PKG_REVISION (TERMUX_PKG_FULLVERSION_FOR_PACMAN
# = "${TERMUX_PKG_VERSION}-${TERMUX_PKG_REVISION:-0}"). Replicamos esa regla:
# si el Version (ya sanitizado) termina en "-<alnum>" (revision), se usa tal
# cual; si no, se añade "-0". El NOMBRE del artifact usa la MISMA versión que
# el .PKGINFO para que el parseo de subinstall (pkg/version) coincida con el
# dir del árbol versionado.
if [[ ! "$PKGVER" =~ -[0-9a-zA-Z]+$ ]]; then
    PKGVER="${PKGVER}-0"
fi
PKGDESC="$(get_control_field "Description")"
HOMEPAGE="$(get_control_field "Homepage")"
PACKAGER="$(get_control_field "Maintainer")"
ARCH="$(get_control_field "Architecture")"
# Nombre del artifact estilo pacman de termux: <pkg>-<ver>-<rev>-<arch>
# (separadores '-' — el .deb usa '_', pero subinstall espera '-').
# PKGVER ya trae la revisión (o el "-0") y la misma sanitización del prefix.
OUTFILE="$OUT_DIR/${PKGNAME}-${PKGVER}-${ARCH}.pkg.tar.xz"
BUILDDATE="$(date +%s)"

DEPENDS="$(get_control_multi "Depends")"
CONFLICTS="$(get_control_multi "Conflicts")"
BREAKS="$(get_control_multi "Breaks")"
PROVIDES="$(get_control_multi "Provides")"
REPLACES="$(get_control_multi "Replaces")"
RECOMMENDS="$(get_control_multi "Recommends")"
SUGGESTS="$(get_control_multi "Suggests")"
LICENSE="$(get_control_field "License")"

CONFFILE_LIST=""
[ -f "$TMP/control/conffiles" ] && CONFFILE_LIST="$(cat "$TMP/control/conffiles")"

# ── 5. Generar <data>/.PKGINFO — formato EXACTO de termux ──
# Transformación de deps idéntica a termux_step_create_pacman_package.sh:
#   tr ',' '\n' | sed 's|(||g; s|)||g; s| ||g; s|>>|>|g; s|<<|<|g'
#   | awk '{ printf "depend = " $1; if (($1 ~ /</ || $1 ~ />/ || $1 ~ /=/) && $1 !~ /-/) printf "-0"; printf "\n" }'
{
    echo "pkgname = $PKGNAME"
    echo "pkgbase = $PKGNAME"
    echo "pkgver = $PKGVER"
    echo "pkgdesc = $PKGDESC"
    [ -n "$HOMEPAGE" ] && echo "url = $HOMEPAGE"
    echo "builddate = $BUILDDATE"
    echo "packager = $PACKAGER"
    echo "size = $INSTALL_SIZE"
    echo "arch = $ARCH"

    if [ -n "$LICENSE" ]; then
        tr ',' '\n' <<< "$LICENSE" | awk '{ printf "license = %s\n", $0 }'
    fi

    if [ -n "$REPLACES" ]; then
        tr ',' '\n' <<< "$REPLACES" | sed 's|(||g; s|)||g; s| ||g; s|>>|>|g; s|<<|<|g' | awk '{ printf "replaces = " $1; if ( ($1 ~ /</ || $1 ~ />/ || $1 ~ /=/) && $1 !~ /-/ ) printf "-0"; printf "\n" }'
    fi

    if [ -n "$CONFLICTS" ]; then
        tr ',' '\n' <<< "$CONFLICTS" | sed 's|(||g; s|)||g; s| ||g; s|>>|>|g; s|<<|<|g' | awk '{ printf "conflict = " $1; if ( ($1 ~ /</ || $1 ~ />/ || $1 ~ /=/) && $1 !~ /-/ ) printf "-0"; printf "\n" }'
    fi

    if [ -n "$BREAKS" ]; then
        tr ',' '\n' <<< "$BREAKS" | sed 's|(||g; s|)||g; s| ||g; s|>>|>|g; s|<<|<|g' | awk '{ printf "conflict = " $1; if ( ($1 ~ /</ || $1 ~ />/ || $1 ~ /=/) && $1 !~ /-/ ) printf "-0"; printf "\n" }'
    fi

    if [ -n "$PROVIDES" ]; then
        tr ',' '\n' <<< "$PROVIDES" | sed 's|(||g; s|)||g; s| ||g; s|>>|>|g; s|<<|<|g' | awk '{ printf "provides = " $1; if ( ($1 ~ /</ || $1 ~ />/ || $1 ~ /=/) && $1 !~ /-/ ) printf "-0"; printf "\n" }'
    fi

    if [ -n "$DEPENDS" ]; then
        tr ',' '\n' <<< "$DEPENDS" | sed 's|(||g; s|)||g; s| ||g; s|>>|>|g; s|<<|<|g' | awk '{ printf "depend = " $1; if ( ($1 ~ /</ || $1 ~ />/ || $1 ~ /=/) && $1 !~ /-/ ) printf "-0"; printf "\n" }' | sed 's/|.*//'
    fi

    if [ -n "$RECOMMENDS" ]; then
        tr ',' '\n' <<< "$RECOMMENDS" | awk '{ printf "optdepend = %s\n", $1 }'
    fi

    if [ -n "$SUGGESTS" ]; then
        tr ',' '\n' <<< "$SUGGESTS" | awk '{ printf "optdepend = %s\n", $1 }'
    fi

    # Conffiles del .deb: "backup = <ruta sin el '/' inicial>" — igual que
    # termux (${TERMUX_PREFIX_CLASSICAL:1}/...): el path queda relativo a la
    # raíz del paquete (data/data/com.termux/files/usr/...).
    if [ -n "$CONFFILE_LIST" ]; then
        while IFS= read -r conffile; do
            [ -n "$conffile" ] || continue
            echo "backup = ${conffile#/}"
        done <<< "$CONFFILE_LIST"
    fi
} > "$TMP/data/.PKGINFO"

# Build metadata (.BUILDINFO) — mismo formato que termux (opcional para pacman,
# pero forma parte del paquete termux real y del template).
{
    echo "format = 2"
    echo "pkgname = $PKGNAME"
    echo "pkgbase = $PKGNAME"
    echo "pkgver = $PKGVER"
    echo "pkgarch = $ARCH"
    echo "packager = $PACKAGER"
    echo "builddate = $BUILDDATE"
} > "$TMP/data/.BUILDINFO"

# ── 6. Generar <data>/.MTREE — comando EXACTO de termux ──
# termux comprime el .MTREE con gzip y lo empaqueta DENTRO del árbol, en la
# raíz del paquete (junto a .PKGINFO y data/...), excluyéndose a sí mismo.
(
    cd "$TMP/data"
    shopt -s dotglob globstar
    printf '%s\0' **/* | bsdtar -cnf - --format=mtree \
        --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
        --null --files-from - --exclude .MTREE | \
        gzip -c -f -n > .MTREE
)

# ── 7. Re-empaquetar: tar del árbol con .PKGINFO/.MTREE + data/..., xz ──
# Igual que termux: bsdtar --no-fflags + $COMPRESS (xz -c -z -).
(
    cd "$TMP/data"
    shopt -s dotglob globstar
    printf '%s\0' **/* | bsdtar --no-fflags -cnf - --null --files-from - | \
        xz -c -z - > "$OUTFILE"
)

echo "Convertido: $OUTFILE"
echo "Contenido:"
bsdtar -tf "$OUTFILE" | head -n 20 || true

# ── 8. Limpieza ──
# (trap EXIT ya elimina $TMP)
