#!/usr/bin/env bash
# store-lib.sh — PrevTermux Store: librería de acceso al pool de paquetes
# reutilizables.
#
# El pool es un conjunto de GitHub Releases del repo, una por arquitectura,
# con tag `prev-termux-pool-<arch>` y un manifest.json como índice:
#
#   https://github.com/<owner>/<repo>/releases/download/prev-termux-pool-<arch>/manifest.json
#
# El hook de `termux_step_get_dependencies.sh` consulta el pool ANTES de
# intentar el repo oficial o el build local. Si algo falla (pool inexistente,
# sin hit, red caída, jq ausente, checksum erróneo) → return 1 → fallback
# silencioso al flujo normal. NUNCA rompe el build.
#
# Este archivo es código del PROYECTO (no del build system vendered): vive en
# scripts/store-lib.sh y gha-prepare.sh lo copia al árbol del paquete como
# <tree>/scripts/store-lib.sh. El hook de termux_step_get_dependencies lo
# sourcea vía $TERMUX_SCRIPTDIR/scripts/store-lib.sh ($TERMUX_SCRIPTDIR = raíz
# del árbol, build-package.sh:24).
#
# Es una librería (se sourcea, no se ejecuta): NO aplica `set -euo pipefail`.
# Debe ser robusta bajo el `set -euo pipefail` del llamador
# (build-package.sh), por eso TODA referencia a variable usa default
# (`${VAR:-...}`) para no abortar bajo `set -u`.
#
# Uso:
#   . store-lib.sh
#   store_try_fetch "<pkg>" "<arch>" "<ver>" "<normal|subversioned>"
#
# Esquema del manifest.json de cada pool:
#   {
#     "pool": "prev-termux-pool-aarch64",
#     "arch": "aarch64",
#     "entries": [
#       { "pkg": "libfoo", "ver": "1.2.3", "arch": "aarch64", "mode": "normal",
#         "sha256": "<sha256 del .deb>", "asset": "libfoo_1.2.3_aarch64.deb" }
#     ]
#   }
# El .deb del pool es el CANÓNICO {pkg}_{ver}_{arch}[_subversioned].deb; el
# .pkg.tar.xz se deriva con deb2pkg.sh (decisión de diseño del proyecto).

# PrevTermux Store — URL del manifest de un pool.
# TERMUX_STORE_URL permite override (p.ej. mirror file:// en tests); el default
# es la raíz de releases del repo (GITHUB_REPOSITORY).
store_manifest_url() {
	local arch="$1"
	echo "${TERMUX_STORE_URL:-https://github.com/${GITHUB_REPOSITORY:-unknown/unknown}/releases/download}/prev-termux-pool-${arch}/manifest.json"
}

# PrevTermux Store — URL de un asset (archivo) dentro de un pool.
store_asset_url() {
	local arch="$1" asset="$2"
	echo "${TERMUX_STORE_URL:-https://github.com/${GITHUB_REPOSITORY:-unknown/unknown}/releases/download}/prev-termux-pool-${arch}/${asset}"
}

# Descarga el manifest.json del pool <arch> con caché por run en
# $TERMUX_STORE_DIR (default: $TERMUX_TOPDIR/_store). El nombre de la caché
# incluye el arch: manifest-<arch>.json. Retorna 0 si ok; 1 (silencioso) si
# 404/vacío/red. Invalidación por bs_rev: si el manifest cacheado pertenece a
# un build system distinto del actual (TERMUX_STORE_BS_REV) se re-descarga.
store_manifest_get() {
	local arch="$1"
	local store_dir="${TERMUX_STORE_DIR:-${TERMUX_TOPDIR:-$HOME/.termux-build}/_store}"
	local manifest_file="$store_dir/manifest-${arch}.json"
	local url="" cached_bs_rev=""

	mkdir -p "$store_dir"

	# Caché por run: se reutiliza el manifest cacheado SOLO si su bs_rev
	# coincide con el build system actual (TERMUX_STORE_BS_REV, inyectado por
	# gha-build.sh desde build-system/REVISION). Si no se dispone de bs_rev
	# actual (desarrollo local), se reutiliza el cacheado tal cual
	# (comportamiento histórico).
	if [ -s "$manifest_file" ]; then
		if [ -n "${TERMUX_STORE_BS_REV:-}" ]; then
			cached_bs_rev="$(jq -r '.bs_rev // ""' "$manifest_file" 2>/dev/null || true)"
			if [ -n "$cached_bs_rev" ] && [ "$cached_bs_rev" = "$TERMUX_STORE_BS_REV" ]; then
				return 0
			fi
		else
			return 0
		fi
	fi

	url="$(store_manifest_url "$arch")"
	# Legacy compatibility: PrevTermux Store dependency fetch
	curl -fsSL --connect-timeout 15 --max-time 60 -o "$manifest_file" "$url" 2>/dev/null || {
		rm -f "$manifest_file"
		return 1
	}
	[ -s "$manifest_file" ] || {
		rm -f "$manifest_file"
		return 1
	}
	return 0
}

# Intenta satisfacer la dependencia <pkg>@<ver> desde el pool <arch>
# (mode: normal|subversioned). Retorna 0 si el artifact existe, se descarga,
# se verifica (sha256), se extrae al prefix y se escribe el marker del build
# system. Cualquier fallo → return 1 (el llamador sigue con repo oficial /
# build local). NO usa termux_error_exit: es un fallback opcional.
store_try_fetch() {
	local pkg="$1" arch="$2" ver="$3" mode="${4:-normal}"
	local store_dir="${TERMUX_STORE_DIR:-${TERMUX_TOPDIR:-$HOME/.termux-build}/_store}"
	local manifest="$store_dir/manifest-${arch}.json"
	local entry="" sha256="" asset="" url="" deb_file=""

	# 1. Manifest (caché por run)
	store_manifest_get "$arch" || return 1

	# 2. Buscar la entrada pkg+arch+ver+mode en el manifest
	if ! command -v jq >/dev/null 2>&1; then
		# jq ausente en el contenedor → fallback silencioso (sin parseo grep/sed)
		return 1
	fi
	# NOTA: se usa `jq -c` (compacto, una entrada por línea) para que `head -n 1`
	# seleccione la PRIMERA entrada completa; con `jq -r` (pretty-print
	# multilínea) head trunca en `{` y el re-parseo con jq falla con
	# "Unfinished JSON term at EOF".
	entry="$(jq -c ".entries[] | select(.pkg==\"${pkg}\" and .arch==\"${arch}\" and .ver==\"${ver}\" and .mode==\"${mode}\")" "$manifest" 2>/dev/null | head -n 1 || true)"
	if [ -z "$entry" ] && [ "$arch" != "all" ]; then
		# PrevTermux Store: deps platform-independent (arch "all") pueden estar
		# indexadas en el pool de la arquitectura del build.
		entry="$(jq -c ".entries[] | select(.pkg==\"${pkg}\" and .arch==\"all\" and .ver==\"${ver}\" and .mode==\"${mode}\")" "$manifest" 2>/dev/null | head -n 1 || true)"
	fi
	[ -n "$entry" ] || return 1

	sha256="$(printf '%s' "$entry" | jq -r '.sha256 // ""' 2>/dev/null || true)"
	asset="$(printf '%s' "$entry" | jq -r '.asset // ""' 2>/dev/null || true)"
	[ -n "$sha256" ] && [ -n "$asset" ] || return 1
	# Defensa: solo basename (el manifest nunca debe aportar un path)
	asset="$(basename "$asset")"
	# Legacy compatibility: epoch Debian en el nombre del asset (p.ej.
	# ca-certificates-java_1:2025.05.20_all.deb). store-publish.sh normaliza
	# ':' → '-' en el pool, pero si un manifest legacy/manual trae ':' el ':' rompe
	# la URL (store_asset_url) y curl falla silenciosamente → fallback al repo
	# oficial/build local. Se aplica el MISMO saneo aquí (idempotente; el match
	# del manifest es por .ver, nunca por nombre).
	asset="${asset//:/-}"

	# 3. Descargar el .deb y verificar sha256 (caché local del .deb incluida)
	mkdir -p "$store_dir"
	deb_file="$store_dir/${asset}"
	if [ ! -f "$deb_file" ]; then
		url="$(store_asset_url "$arch" "$asset")"
		curl -fsSL --connect-timeout 15 --max-time 300 -o "$deb_file" "$url" 2>/dev/null || {
			rm -f "$deb_file"
			return 1
		}
	fi
	if [ "$(sha256sum "$deb_file" | cut -d' ' -f1)" != "$sha256" ]; then
		rm -f "$deb_file"
		return 1
	fi

	# 4. Extraer el data.tar.xz al prefix — MISMO patrón que
	#    termux_step_get_dependencies (ar p ... data.tar.xz | tar xJ -C /)
	( cd "$store_dir" && ar p "$asset" "data.tar.xz" | \
		tar xJ --no-overwrite-dir --transform='s#^.$#data#' -C / ) || return 1

	# 5. Marker del build system: la dep queda "built" (mismo directorio que
	#    usa termux_step_get_dependencies / termux_package__is_package_version_built)
	mkdir -p "${TERMUX_BUILT_PACKAGES_DIRECTORY:-/data/data/.built-packages}"
	echo "$ver" > "${TERMUX_BUILT_PACKAGES_DIRECTORY:-/data/data/.built-packages}/${pkg}"
	return 0
}

# PrevTermux Store — modo del artifact (normal|subversioned). Lo fija
# gha-build.sh vía TERMUX_STORE_MODE; si no llega, lo deduce de
# TERMUX_PREFIX_OVERRIDE (subversioned); sino normal.
store_mode() {
	if [ -n "${TERMUX_STORE_MODE:-}" ]; then
		echo "$TERMUX_STORE_MODE"
	elif [ -n "${TERMUX_PREFIX_OVERRIDE:-}" ]; then
		echo "subversioned"
	else
		echo "normal"
	fi
}
