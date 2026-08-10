#!/usr/bin/env bash
# store-publish.sh — Publica los artifacts de un build de PrevTermuxPackage en
# el pool del PrevTermux Store.
#
# El pool es un GitHub Release por arquitectura (tag `prev-termux-pool-<arch>`)
# con un manifest.json como índice (mismo esquema que scripts/store-lib.sh):
#
#   { "pool": "prev-termux-pool-aarch64", "arch": "aarch64", "entries": [
#       { "pkg": "libfoo", "ver": "1.2.3", "arch": "aarch64", "mode": "normal",
#         "sha256": "...", "asset": "libfoo_1.2.3_aarch64.deb", "size": 12345,
#         "bs_rev": "...", "src_ref": "...", "target": false,
#         "pkg_tar": "libfoo_1.2.3_aarch64.pkg.tar.xz",
#         "pkg_tar_sha256": "..." }, ... ] }
#
# Clasificación:
#   - pkg == <package_name>  → paquete OBJETIVO: publica .deb + .pkg.tar.xz
#   - resto                   → dependencia: publica SOLO el .deb canónico
#
# En modo subversioned los assets del pool se RENOMBRAN con sufijo
# `_subversioned` (el build produce {pkg}_{ver}_{arch}.deb sin sufijo; el pool
# necesita distinguir normal vs subversioned dentro del MISMO release).
#
# Merge idempotente (read-modify-write) por clave (pkg|ver|arch|mode):
#   - clave existente con MISMO sha256 → skip (no re-subir)
#   - clave existente con sha256 distinto → reemplaza la entrada y re-subir con
#     `gh release upload --clobber` (NUNCA `gh release delete-asset`, bloqueado
#     por permisos en este repo)
#   - clave nueva → añade la entrada y subir
# El manifest.json se sube SIEMPRE al final (--clobber) para que nunca apunte a
# assets inexistentes. El script es re-ejecutable e idempotente.
#
# Uso:
#   ./scripts/store-publish.sh <tp-dir> <arch> <mode> <package_name> <package_version> \
#       [--bs-rev <rev>] [--src-git-ref <sha>] [--repo <owner/repo>]
#
#   <tp-dir>            raíz del checkout de termux-packages (busca output/ y
#                       debs/; también acepta pasar output/ o debs/ directo)
#   <arch>              aarch64|arm|i686|x86_64
#   <mode>              normal|subversioned
#   <package_name>      paquete objetivo del build (los demás .deb = deps)
#   <package_version>   versión del objetivo (solo informativa; el manifest usa
#                       la versión del control de cada .deb, que es la que el
#                       hook de store-lib.sh busca con DEP_VERSION)
#   --bs-rev            revisión del build system (default: UPSTREAM_SHA de
#                       build-system/REVISION)
#   --src-git-ref       commit de termux-packages que originó el build
#   --repo              repo GitHub owner/name (default: GITHUB_REPOSITORY o
#                       autodetección con `gh repo view`)
#
# Requiere: gh (autenticado), jq, dpkg-deb, sha256sum.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argumentos ──
TP_DIR=""
ARCH=""
MODE=""
PACKAGE_NAME=""
PACKAGE_VERSION=""
BS_REV=""
SRC_REF=""
REPO="${GITHUB_REPOSITORY:-}"

while [ $# -gt 0 ]; do
	case "$1" in
		--bs-rev)      BS_REV="${2:-}"; shift 2 ;;
		--src-git-ref) SRC_REF="${2:-}"; shift 2 ;;
		--repo)        REPO="${2:-}"; shift 2 ;;
		-*)
			echo "Error: argumento desconocido: $1" >&2
			exit 1
			;;
		*)
			if [ -z "$TP_DIR" ]; then
				TP_DIR="$1"
			elif [ -z "$ARCH" ]; then
				ARCH="$1"
			elif [ -z "$MODE" ]; then
				MODE="$1"
			elif [ -z "$PACKAGE_NAME" ]; then
				PACKAGE_NAME="$1"
			elif [ -z "$PACKAGE_VERSION" ]; then
				PACKAGE_VERSION="$1"
			else
				echo "Error: demasiados argumentos posicionales: $1" >&2
				exit 1
			fi
			shift
			;;
	esac
done

# ── Validaciones ──
[ -n "$TP_DIR" ] || { echo "Error: falta <tp-dir>" >&2; exit 1; }
[ -n "$ARCH" ] || { echo "Error: falta <arch>" >&2; exit 1; }
[ -n "$MODE" ] || { echo "Error: falta <mode> (normal|subversioned)" >&2; exit 1; }
[ -n "$PACKAGE_NAME" ] || { echo "Error: falta <package_name>" >&2; exit 1; }
[ -n "$PACKAGE_VERSION" ] || { echo "Error: falta <package_version>" >&2; exit 1; }
case "$MODE" in
	normal|subversioned) ;;
	*) echo "Error: mode inválido: '$MODE' (debe ser normal o subversioned)" >&2; exit 1 ;;
esac

for cmd in gh jq dpkg-deb sha256sum; do
	command -v "$cmd" >/dev/null 2>&1 || { echo "Error: falta '$cmd'" >&2; exit 1; }
done

# ── Repo y revisión del build system ──
if [ -z "$REPO" ] && command -v gh >/dev/null 2>&1; then
	REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
[ -n "$REPO" ] || {
	echo "Error: no se pudo determinar el repo (usa --repo <owner/repo> o GITHUB_REPOSITORY)" >&2
	exit 1
}

if [ -z "$BS_REV" ]; then
	REVISION_FILE="$SCRIPT_DIR/../build-system/REVISION"
	if [ -f "$REVISION_FILE" ]; then
		BS_REV="$(grep -m1 '^UPSTREAM_SHA=' "$REVISION_FILE" | cut -d= -f2 || true)"
	fi
fi
BS_REV="${BS_REV:-desconocido}"

# ── Recopilar .deb del árbol (output/ para master, debs/ para commits pre-2021;
#    también acepta pasar un dir de output directo) ──
[ -d "$TP_DIR" ] || { echo "Error: no existe el directorio: $TP_DIR" >&2; exit 1; }
shopt -s nullglob
DEBS=("$TP_DIR"/output/*.deb "$TP_DIR"/debs/*.deb "$TP_DIR"/*.deb)
shopt -u nullglob
if [ "${#DEBS[@]}" -eq 0 ]; then
	echo "Error: no hay .deb en '$TP_DIR' (buscó output/, debs/ y la raíz)" >&2
	exit 1
fi

# ── Staging (nunca /tmp; $TMPDIR en Termux) ──
TMP_BASE="${TMPDIR:-$HOME/tmp}"
mkdir -p "$TMP_BASE"
STAGING="$(mktemp -d "$TMP_BASE/store-publish.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

POOL_TAG="prev-termux-pool-$ARCH"
MANIFEST_FILE="$STAGING/manifest.json"

echo "=== [store-publish] Pool: $POOL_TAG (mode=$MODE, repo=$REPO, bs_rev=$BS_REV, src_ref=${SRC_REF:-n/a}) ==="

# ── Manifest previo (read) ──
POOL_EXISTS=0
if gh release view "$POOL_TAG" -R "$REPO" >/dev/null 2>&1; then
	POOL_EXISTS=1
	if gh release download "$POOL_TAG" -R "$REPO" --pattern manifest.json --dir "$STAGING" >/dev/null 2>&1 \
			&& [ -s "$MANIFEST_FILE" ] \
			&& jq -e '.entries | type == "array"' "$MANIFEST_FILE" >/dev/null 2>&1; then
		: # manifest previo válido
	else
		rm -f "$MANIFEST_FILE"
	fi
fi

if [ ! -f "$MANIFEST_FILE" ]; then
	jq -n --arg pool "$POOL_TAG" --arg arch "$ARCH" --arg bs_rev "$BS_REV" \
		'{pool:$pool, arch:$arch, bs_rev:$bs_rev, entries:[]}' > "$MANIFEST_FILE"
fi

# ── Procesar cada .deb ──
UPLOAD_ASSETS=()

for deb in "${DEBS[@]}"; do
	[ -f "$deb" ] || continue

	# 1. Campos del control (Package / Version / Architecture); fallback al
	#    nombre canónico {pkg}_{ver}_{arch}.deb si dpkg-deb falla.
	PKG=""
	VER=""
	DEB_ARCH=""
	CONTROL="$(dpkg-deb -f "$deb" Package Version Architecture 2>/dev/null || true)"
	if [ -n "$CONTROL" ]; then
		read -r PKG VER DEB_ARCH <<< "$CONTROL" || true
	fi
	if [ -z "$PKG" ] || [ -z "$VER" ] || [ -z "$DEB_ARCH" ]; then
		BASE="$(basename "$deb")"
		if [[ "$BASE" =~ ^(.+)_(.+)_(aarch64|arm|i686|x86_64|all)\.deb$ ]]; then
			PKG="${BASH_REMATCH[1]}"
			VER="${BASH_REMATCH[2]}"
			DEB_ARCH="${BASH_REMATCH[3]}"
		fi
	fi
	if [ -z "$PKG" ] || [ -z "$VER" ] || [ -z "$DEB_ARCH" ]; then
		echo "WARN: no se pudo leer el control de $deb (dpkg-deb falló y el nombre no es canónico); se omite." >&2
		continue
	fi

	# 2. Clasificar: paquete objetivo vs dependencia
	IS_TARGET="false"
	[ "$PKG" = "$PACKAGE_NAME" ] && IS_TARGET="true"

	# 3. Nombre del asset en el pool (con sufijo _subversioned en ese modo)
	ASSET="${PKG}_${VER}_${DEB_ARCH}"
	[ "$MODE" = "subversioned" ] && ASSET="${ASSET}_subversioned"
	ASSET="${ASSET}.deb"
	# Legacy compatibility: epoch Debian en VER (p.ej. ca-certificates-java_1:2025.05.20)
	# — GitHub Releases permite SUBIR assets con ':' pero NO re-descargarlos por URL
	# (el ':' rompe la URL del asset y `gh release download --pattern` falla). Se
	# normaliza ':' → '-' en el nombre del POOL (asset y pkg_tar derivado) para que
	# consumidores (store-lib.sh / prev-termux fetch) puedan descargarlos; el match
	# del manifest es por .ver (con epoch, intacto), nunca por nombre. Idempotente:
	# sin ':' el valor no cambia.
	ASSET="${ASSET//:/-}"

	PKG_TAR=""
	PKG_TAR_SHA=""
	if [ "$IS_TARGET" = "true" ]; then
		# Buscar el .pkg.tar.xz producido por deb2pkg.sh. Nombre esperado:
		# <pkg>-<ver-pacman>-<arch>.pkg.tar.xz (deb2pkg usa separadores '-' y
		# añade "-0" de revisión si la versión no la trae). Fallback: glob por
		# prefijo del paquete.
		VER_PAC="$(echo "$VER" | tr -d '"' | tr -d "'" | tr -d ' ' | sed 's/[^a-zA-Z0-9._-]/-/g')"
		if [[ ! "$VER_PAC" =~ -[0-9a-zA-Z]+$ ]]; then
			VER_PAC="${VER_PAC}-0"
		fi
		DEBDIR="$(dirname "$deb")"
		TAR_SRC=""
		[ -f "$DEBDIR/${PKG}-${VER_PAC}-${DEB_ARCH}.pkg.tar.xz" ] && TAR_SRC="$DEBDIR/${PKG}-${VER_PAC}-${DEB_ARCH}.pkg.tar.xz"
		if [ -z "$TAR_SRC" ]; then
			shopt -s nullglob
			for t in "$DEBDIR"/"${PKG}"-*.pkg.tar.xz; do TAR_SRC="$t"; break; done
			shopt -u nullglob
		fi
		if [ -n "$TAR_SRC" ] && [ -f "$TAR_SRC" ]; then
			PKG_TAR="${ASSET%.deb}.pkg.tar.xz"
			cp "$TAR_SRC" "$STAGING/$PKG_TAR"
			PKG_TAR_SHA="$(sha256sum "$STAGING/$PKG_TAR" | cut -d' ' -f1)"
		fi
	fi

	# 4. Staging: copiar el .deb con el nombre del pool
	STAGED_DEB="$STAGING/$ASSET"
	cp "$deb" "$STAGED_DEB"
	SHA="$(sha256sum "$STAGED_DEB" | cut -d' ' -f1)"
	SIZE="$(stat -c %s "$STAGED_DEB")"

	# 5. Merge read-modify-write por clave (pkg|ver|arch|mode)
	KEY="${PKG}|${VER}|${DEB_ARCH}|${MODE}"
	EXISTING="$(jq -c --arg p "$PKG" --arg v "$VER" --arg a "$DEB_ARCH" --arg m "$MODE" \
		'.entries[] | select(.pkg==$p and .ver==$v and .arch==$a and .mode==$m)' "$MANIFEST_FILE" 2>/dev/null | head -n 1 || true)"

	DO_UPLOAD="true"
	if [ -n "$EXISTING" ]; then
		EX_SHA="$(printf '%s' "$EXISTING" | jq -r '.sha256 // ""' 2>/dev/null || true)"
		if [ -n "$EX_SHA" ] && [ "$EX_SHA" = "$SHA" ]; then
			DO_UPLOAD="false"
		fi
	fi

	if [ "$DO_UPLOAD" = "true" ]; then
		# Eliminar entrada previa con la misma clave (si existe)
		jq --arg p "$PKG" --arg v "$VER" --arg a "$DEB_ARCH" --arg m "$MODE" \
			'del(.entries[] | select(.pkg==$p and .ver==$v and .arch==$a and .mode==$m))' \
			"$MANIFEST_FILE" > "$STAGING/manifest.tmp" && mv "$STAGING/manifest.tmp" "$MANIFEST_FILE"
		# Añadir la nueva entrada
		NEW_ENTRY="$(jq -nc --arg pkg "$PKG" --arg ver "$VER" --arg arch "$DEB_ARCH" --arg mode "$MODE" \
			--arg sha "$SHA" --arg asset "$ASSET" --arg size "$SIZE" --arg bs_rev "$BS_REV" \
			--arg src_ref "$SRC_REF" --arg target "$IS_TARGET" \
			--arg pkg_tar "$PKG_TAR" --arg pkg_tar_sha "$PKG_TAR_SHA" \
			'{pkg:$pkg, ver:$ver, arch:$arch, mode:$mode, sha256:$sha, asset:$asset, size:$size, bs_rev:$bs_rev, src_ref:$src_ref, target:($target=="true")} + (if ($pkg_tar != "" and $pkg_tar_sha != "") then {pkg_tar:$pkg_tar, pkg_tar_sha256:$pkg_tar_sha} else {} end)')"
		jq --argjson e "$NEW_ENTRY" '.entries += [$e]' "$MANIFEST_FILE" > "$STAGING/manifest.tmp" && mv "$STAGING/manifest.tmp" "$MANIFEST_FILE"
		UPLOAD_ASSETS+=("$STAGED_DEB")
		if [ "$IS_TARGET" = "true" ] && [ -n "$PKG_TAR" ]; then
			UPLOAD_ASSETS+=("$STAGING/$PKG_TAR")
		fi
		echo "PUBLISH $KEY sha256=$SHA target=$IS_TARGET"
	else
		echo "SKIP   $KEY (sin cambios, sha256=$SHA)"
	fi
done

# ── 6. Crear el release del pool si no existe ──
# Guard tolerante al race: los jobs build-normal y build-subversioned del
# workflow publican al MISMO pool (serializados con `needs`), pero si otro
# job lanza el `gh release create` justo después de nuestro `gh release view`,
# el create puede fallar con "already exists". Se tolera verificando de nuevo.
if [ "$POOL_EXISTS" -ne 1 ]; then
	if gh release view "$POOL_TAG" -R "$REPO" >/dev/null 2>&1; then
		POOL_EXISTS=1
		echo "=== [store-publish] Release '$POOL_TAG' ya existe (creado por otro job); se usa tal cual. ==="
	else
		echo "=== [store-publish] Creando release '$POOL_TAG'..."
		if ! gh release create "$POOL_TAG" -R "$REPO" \
			--title "PrevTermux Store pool ($ARCH)" \
			--notes "Pool de paquetes reutilizables del PrevTermux Store (arquitectura $ARCH). Indice en manifest.json (esquema de scripts/store-lib.sh)."; then
			if gh release view "$POOL_TAG" -R "$REPO" >/dev/null 2>&1; then
				POOL_EXISTS=1
				echo "=== [store-publish] Release '$POOL_TAG' creado por un job concurrente; se continúa. ==="
			else
				echo "Error: no se pudo crear el release '$POOL_TAG'" >&2
				exit 1
			fi
		fi
	fi
fi

# ── 7. Subir assets nuevos/modificados (--clobber; nunca delete-asset) ──
# Verificación post-subida: se re-descarga cada asset subido y se compara su
# sha256 contra el local ANTES de publicar el manifest (que SIEMPRE va al
# final). Si algo falla → error: el manifest local (aún sin publicar) queda
# descartado y el pool no apunta a assets corruptos/inexistentes.
if [ "${#UPLOAD_ASSETS[@]}" -gt 0 ]; then
	echo "=== [store-publish] Subiendo ${#UPLOAD_ASSETS[@]} asset(s) al pool..."
	gh release upload "$POOL_TAG" -R "$REPO" "${UPLOAD_ASSETS[@]}" --clobber

	VERIFY_DIR="$STAGING/verify"
	mkdir -p "$VERIFY_DIR"
	VERIFY_OK=1
	for asset in "${UPLOAD_ASSETS[@]}"; do
		name="$(basename "$asset")"
		expected="$(sha256sum "$asset" | cut -d' ' -f1)"
		# Guard defensivo: los nombres de asset del pool se normalizan al
		# construirlos (epoch Debian ':' → '-', ver sección 3), así que aquí no
		# debería llegar ningún nombre con ':'. Se conserva el skip por si un
		# pool subido manualmente/legacy trae ':' (GitHub Releases deja SUBIR
		# assets con ':' pero NO re-descargarlos por URL; el manifest usa el
		# sha256 local, así que la integridad queda garantizada sin
		# re-descargar).
		if [[ "$name" == *:* ]]; then
			echo "OK    '$name' verificado post-subida (skip re-descarga; nombre con ':' no re-descargable por GitHub Releases, sha256=$expected)"
			continue
		fi
		if ! gh release download "$POOL_TAG" -R "$REPO" --pattern "$name" --dir "$VERIFY_DIR" >/dev/null 2>&1; then
			echo "Error: no se pudo re-descargar '$name' para verificar post-subida" >&2
			VERIFY_OK=0
			break
		fi
		got="$(sha256sum "$VERIFY_DIR/$name" | cut -d' ' -f1)"
		if [ "$got" != "$expected" ]; then
			echo "Error: sha256 de '$name' difiere tras la subida (esperado $expected, obtenido $got)" >&2
			VERIFY_OK=0
			break
		fi
		echo "OK    '$name' verificado post-subida (sha256=$expected)"
	done
	if [ "$VERIFY_OK" -ne 1 ]; then
		echo "Error: verificación post-subida falló; el manifest no se publica." >&2
		exit 1
	fi
fi

# ── 8. Subir el manifest SIEMPRE al final (nunca apuntar a assets inexistentes) ──
echo "=== [store-publish] Subiendo manifest.json..."
gh release upload "$POOL_TAG" -R "$REPO" "$MANIFEST_FILE" --clobber

echo "=== [store-publish] Done. Entradas en manifest: $(jq '.entries | length' "$MANIFEST_FILE")"
