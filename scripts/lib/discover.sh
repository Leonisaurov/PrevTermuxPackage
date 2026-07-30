#!/data/data/com.termux/files/usr/bin/bash
#
# discover.sh — Librería para descubrir versiones históricas de paquetes Termux
#
# Proporciona funciones para buscar, extraer y seleccionar versiones
# históricas de paquetes desde el repositorio termux-packages.
#
# Uso (source):
#   source scripts/lib/discover.sh
#   discover_versions python
#   extract_version abc1234 python
#   fzf_select python
#
# Nota: No ejecutar directamente — es una librería para source.
#

# ─── Configuración ─────────────────────────────────────────────────────────────
# Repositorio de termux-packages (override via environment variable)
TERMUX_PACKAGES_REPO="${TERMUX_PACKAGES_REPO:-https://github.com/termux/termux-packages.git}"

# ─── Configuración de Caché Persistente ────────────────────────────────────────
# Directorio base del caché (override via environment variable)
export PREV_TERMUX_CACHE_DIR="${PREV_TERMUX_CACHE_DIR:-$HOME/.cache/prev-termux}"
# TTL del caché de versiones en segundos (7 días por defecto)
export PREV_TERMUX_CACHE_TTL="${PREV_TERMUX_CACHE_TTL:-604800}"
# Intervalo de fetch del repo bare en segundos (24 horas por defecto)
export PREV_TERMUX_REPO_FETCH_INTERVAL="${PREV_TERMUX_REPO_FETCH_INTERVAL:-86400}"


# ─── get_cache_dir ─────────────────────────────────────────────────────────────
# Retorna el directorio base de caché, creándolo si es necesario.
#
# Uso: cache_dir="$(get_cache_dir)"
#
# Output (stdout): Ruta absoluta al directorio de caché
#
get_cache_dir() {
    local cache_base="${PREV_TERMUX_CACHE_DIR}"
    mkdir -p "$cache_base/repo" "$cache_base/versions"
    echo "$cache_base"
}


# ─── get_cached_repo ───────────────────────────────────────────────────────────
# Retorna la ruta al repo bare cacheado de termux-packages.
#
# Si no existe, lo clona. Si existe y el último fetch fue hace más de
# PREV_TERMUX_REPO_FETCH_INTERVAL segundos, hace fetch.
# Si está corrupto, lo re-clona automáticamente.
#
# Uso: repo_dir="$(get_cached_repo)"
#
# Output (stdout): Ruta al repositorio bare cacheado
#
# Retorno:
#   0 — Éxito
#   1 — Error al clonar/fetchear el repositorio
#
get_cached_repo() {
    local cache_dir
    cache_dir="$(get_cache_dir)"
    local repo_path="${cache_dir}/repo/termux-packages.git"
    local now
    now=$(date +%s)

    # ── Si no existe, clonar ──
    if [[ ! -d "$repo_path" ]]; then
        echo "INFO: cloning termux-packages bare repo (first time)..." >&2
        echo "INFO: this may take a while (~1-2GB depending on network)" >&2
        if ! git clone --bare --single-branch "$TERMUX_PACKAGES_REPO" "$repo_path" 2>/dev/null; then
            echo "Error: failed to clone termux-packages repository" >&2
            echo "Hint: try setting PREV_TERMUX_CACHE_DIR to a different path (e.g., on external SD)" >&2
            rm -rf "$repo_path"
            return 1
        fi
        echo "$now" > "${repo_path}/.last_fetch"
        echo "$repo_path"
        return 0
    fi

    # ── Verificar integridad del repo existente ──
    if ! git -C "$repo_path" rev-parse --git-dir &>/dev/null; then
        echo "INFO: cached repo appears corrupt, re-cloning..." >&2
        rm -rf "$repo_path"
        if ! git clone --bare --single-branch "$TERMUX_PACKAGES_REPO" "$repo_path" 2>/dev/null; then
            echo "Error: failed to clone termux-packages repository" >&2
            echo "Hint: try setting PREV_TERMUX_CACHE_DIR to a different path (e.g., on external SD)" >&2
            rm -rf "$repo_path"
            return 1
        fi
        echo "$now" > "${repo_path}/.last_fetch"
        echo "$repo_path"
        return 0
    fi

    # ── Fetch periódico (solo si pasó el intervalo) ──
    local last_fetch_file="${repo_path}/.last_fetch"
    local needs_fetch=0

    if [[ -f "$last_fetch_file" ]]; then
        local last_fetch
        last_fetch=$(cat "$last_fetch_file")
        if (( now - last_fetch >= PREV_TERMUX_REPO_FETCH_INTERVAL )); then
            needs_fetch=1
        fi
    else
        needs_fetch=1
    fi

    if [[ $needs_fetch -eq 1 ]]; then
        echo "INFO: updating cached repo (git fetch --all --tags --prune)..." >&2
        if ! git -C "$repo_path" fetch --all --tags --prune 2>/dev/null; then
            echo "Warning: git fetch failed, using existing cached data" >&2
            # No actualizamos timestamp para reintentar en la próxima ejecución
        else
            echo "$now" > "$last_fetch_file"
        fi
    fi

    echo "$repo_path"
    return 0
}


# ─── get_cached_versions ───────────────────────────────────────────────────────
# Obtiene las versiones de un paquete, usando caché persistente si está fresco.
#
# Uso: get_cached_versions <package_name> [refresh]
#
#   package_name  — Nombre del paquete (ej: 'python', 'nodejs')
#   refresh       — (Opcional) 1 = forzar redescubrimiento, 0 = usar caché (default)
#
# Output (stdout): Una línea por versión en formato:
#   version|commit_full|date|commit_short
#
# Retorno:
#   0 — Éxito
#   1 — Falta el nombre del paquete
#   2 — Error al acceder al repositorio
#   3 — Paquete no encontrado
#
get_cached_versions() {
    local pkg="${1:?Error: package name is required}"
    local refresh="${2:-0}"
    local cache_dir
    cache_dir="$(get_cache_dir)"
    local cache_file="${cache_dir}/versions/${pkg}.txt"
    local now
    now=$(date +%s)

    # ── Si no es refresh y el caché existe, no está vacío y es fresco, usarlo ──
    if [[ "$refresh" != "1" && -f "$cache_file" && -s "$cache_file" ]]; then
        local file_mtime=0
        file_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || date -r "$cache_file" +%s 2>/dev/null || echo 0)
        local age=$((now - file_mtime))
        if [[ $age -lt $PREV_TERMUX_CACHE_TTL ]]; then
            echo "INFO: using cached versions for '${pkg}' (age: $((age / 86400))d)" >&2
            grep -v '^#' "$cache_file" 2>/dev/null
            return 0
        fi
        echo "INFO: cached versions for '${pkg}' expired (age: $((age / 86400))d)" >&2
    fi

    # ── Redescubrir ──
    if [[ "$refresh" == "1" ]]; then
        echo "INFO: forced refresh for '${pkg}'" >&2
    else
        echo "INFO: discovering versions for '${pkg}'..." >&2
    fi

    local versions
    versions="$(discover_versions "$pkg")"
    local discover_exit=$?

    if [[ $discover_exit -ne 0 ]]; then
        # Si el caché existe (aunque expirado), usarlo como fallback
        if [[ -f "$cache_file" && -s "$cache_file" ]]; then
            echo "Warning: discover failed, using stale cache for '${pkg}'" >&2
            grep -v '^#' "$cache_file" 2>/dev/null
            return 0
        fi
        return $discover_exit
    fi

    # ── Guardar resultado en caché ──
    local count=0
    if [[ -n "$versions" ]]; then
        count="$(echo "$versions" | grep -c '|' 2>/dev/null || echo 0)"
    fi
    {
        echo "# cached_at: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# package: ${pkg}"
        echo "# commit_count: ${count}"
        if [[ -n "$versions" ]]; then
            echo "$versions"
        fi
    } > "$cache_file"

    if [[ -n "$versions" ]]; then
        echo "$versions"
    fi
    return 0
}


# ─── discover_versions ─────────────────────────────────────────────────────────
# Descubre todas las versiones históricas de un paquete Termux.
#
# Uso: discover_versions <package_name> [repo_dir]
#
#   package_name  — Nombre del paquete (ej: 'python', 'nodejs')
#   repo_dir      — (Opcional) Ruta a un clone bare existente de termux-packages.
#                   Si no se provee, usa el caché persistente (get_cached_repo).
#
# Output (stdout): Una línea por versión en formato:
#   version|commit_full|date|commit_short
#
# Retorno:
#   0 — Éxito (puede retornar 0 incluso si no hay versiones)
#   1 — Falta el nombre del paquete
#   2 — Error al clonar el repositorio
#   3 — Paquete no encontrado en el repositorio
#
discover_versions() {
    local pkg="${1:?Error: package name is required}"
    local repo_dir="${2:-}"

    # ── Obtener repositorio (cacheado por defecto, o el provisto) ──
    if [[ -z "$repo_dir" ]]; then
        repo_dir="$(get_cached_repo)" || return 2
    fi

    # ── Verificar que el paquete existe ──
    if ! git -C "$repo_dir" cat-file -e "HEAD:packages/${pkg}/build.sh" 2>/dev/null; then
        echo "Error: package '${pkg}' not found in termux-packages" >&2
        return 3
    fi

    # ── Buscar commits donde cambió la línea TERMUX_PKG_VERSION ──
    # Usamos -G (regex pickaxe) en lugar de -S (string count) porque -S solo
    # detecta cambios en el número de ocurrencias, pero NO detecta cambios
    # de valor (ej: "1.0" → "1.1") donde "TERMUX_PKG_VERSION=" sigue
    # apareciendo exactamente una vez.
    # NOTA: --format debe ir ANTES de -- (separador de paths), si va después
    # git lo trata como un path en lugar de una opción de formato, causando
    # que el output use el formato default multi-línea sin separadores |.
    local log_output
    log_output="$(git -C "$repo_dir" log --all -G "TERMUX_PKG_VERSION=" \
        --format="%H|%ci|%h" -- "packages/${pkg}/build.sh" 2>/dev/null)"

    if [[ -z "$log_output" ]]; then
        echo "Warning: no version changes found for package '${pkg}'" >&2
        return 0
    fi

    # ── Procesar cada commit y extraer la versión ──
    local results=()
    local IFS=$'\n'
    for entry in $log_output; do
        local commit_hash="${entry%%|*}"
        local rest="${entry#*|}"
        local commit_date="${rest%%|*}"
        local commit_short="${rest#*|}"

        # Extraer versión del build.sh en ese commit
        local build_sh_for_version
        build_sh_for_version="$(git -C "$repo_dir" show "${commit_hash}:packages/${pkg}/build.sh" 2>/dev/null || true)"
        local version_raw
        version_raw="$(echo "$build_sh_for_version" | grep "^TERMUX_PKG_VERSION=" | head -1 | cut -d= -f2 || true)"
        local version
        if [[ -n "$version_raw" ]]; then
            version="$(resolve_version_from_buildsh "$version_raw" "$build_sh_for_version")" || version="$version_raw"
            if [[ -n "$version" ]]; then
                results+=("${version}|${commit_hash}|${commit_date}|${commit_hash:0:7}")
            fi
        fi
    done

    # ── Ordenar por fecha ascendente (más antiguo primero) ──
    local sorted_asc
    sorted_asc="$(printf '%s\n' "${results[@]}" | sort -t'|' -k3,3)"

    # ── Deduplicar: conservar el commit más antiguo para cada versión ──
    local -A seen_versions
    local deduped=()
    local IFS=$'\n'
    for line in $sorted_asc; do
        local ver="${line%%|*}"
        if [[ -z "${seen_versions[$ver]:-}" ]]; then
            seen_versions[$ver]=1
            deduped+=("$line")
        fi
    done

    # ── Ordenar por fecha descendente (más reciente primero) para salida ──
    printf '%s\n' "${deduped[@]}" | sort -t'|' -k3,3 -r

    return 0
}


# ─── resolve_version_from_buildsh ───────────────────────────────────────────────
# Resuelve variables tipo ${VAR} o $VAR en una línea de versión usando
# las definiciones del build.sh.
#
# Uso: resolve_version_from_buildsh <version_raw> <build_sh_content>
#
#   version_raw      — Línea extraída (ej: "${MAJOR}.${MINOR}")
#   build_sh_content — Contenido completo del build.sh para buscar variables
#
# Output (stdout): Versión resuelta (ej: "3.12.2")
#
# Retorno:
#   0 — Éxito
#   1 — No se pudieron resolver todas las variables
#
resolve_version_from_buildsh() {
    local version_raw="$1"
    local build_sh="$2"
    local resolved="$version_raw"
    local max_iter=10
    local iter=0

    # Quitar comillas
    resolved=$(echo "$resolved" | tr -d '"' | tr -d "'")

    # Resolver ${VAR} (con llaves)
    while [[ "$resolved" =~ \$\{([a-zA-Z_][a-zA-Z0-9_]*)\} ]] && [[ $iter -lt $max_iter ]]; do
        local var_name="${BASH_REMATCH[1]}"
        local var_value
        var_value=$(echo "$build_sh" | grep "^${var_name}=" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d ' ')
        if [[ -n "$var_value" ]]; then
            resolved="${resolved//\$\{${var_name}\}/${var_value}}"
        else
            break
        fi
        ((iter++))
    done

    # Resolver $VAR (sin llaves)
    while [[ "$resolved" =~ \$([a-zA-Z_][a-zA-Z0-9_]*) ]] && [[ $iter -lt $max_iter ]]; do
        local var_name="${BASH_REMATCH[1]}"
        local var_value
        var_value=$(echo "$build_sh" | grep "^${var_name}=" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d ' ')
        if [[ -n "$var_value" ]]; then
            resolved="${resolved//\$${var_name}/${var_value}}"
        else
            break
        fi
        ((iter++))
    done

    # Si después de resolver siguen apareciendo variables (no se pudieron resolver),
    # devolvemos error
    if [[ "$resolved" =~ \$\{?[a-zA-Z_] ]]; then
        return 1
    fi

    echo "$resolved"
    return 0
}


# ─── extract_version ───────────────────────────────────────────────────────────
# Extrae la versión TERMUX_PKG_VERSION de un commit específico.
#
# Uso: extract_version <commit_hash> <package_name> [repo_dir]
#
#   commit_hash   — Hash completo o abreviado del commit
#   package_name  — Nombre del paquete
#   repo_dir      — (Opcional) Ruta a un clone bare existente.
#                   Si no se provee, usa el caché persistente (get_cached_repo).
#
# Output (stdout): La versión extraída (ej: "1.2.3")
#
# Retorno:
#   0 — Éxito
#   1 — No se pudo extraer la versión
#   2 — Error al clonar el repositorio
#
extract_version() {
    local commit_hash="${1:?Error: commit hash is required}"
    local pkg="${2:?Error: package name is required}"
    local repo_dir="${3:-}"

    # ── Obtener repositorio (cacheado por defecto, o el provisto) ──
    if [[ -z "$repo_dir" ]]; then
        repo_dir="$(get_cached_repo)" || return 2
    fi

    # Verificar que el commit existe
    if ! git -C "$repo_dir" cat-file -e "${commit_hash}:packages/${pkg}/build.sh" 2>/dev/null; then
        echo "Error: commit '${commit_hash}' or package '${pkg}' not found" >&2
        return 1
    fi

    local build_sh_content
    build_sh_content="$(git -C "$repo_dir" show "${commit_hash}:packages/${pkg}/build.sh" 2>/dev/null || true)"
    if [[ -z "$build_sh_content" ]]; then
        echo "Error: commit '${commit_hash}' or package '${pkg}' not found" >&2
        return 1
    fi

    local version_raw
    version_raw="$(echo "$build_sh_content" | grep "^TERMUX_PKG_VERSION=" | head -1 | cut -d= -f2 || true)"

    if [[ -z "$version_raw" ]]; then
        echo "Error: could not extract TERMUX_PKG_VERSION for commit '${commit_hash}' package '${pkg}'" >&2
        return 1
    fi

    # Intentar resolver variables si las hay
    local version
    version="$(resolve_version_from_buildsh "$version_raw" "$build_sh_content")" || version="$version_raw"

    echo "$version"
    return 0
}


# ─── fzf_select ────────────────────────────────────────────────────────────────
# Usa fzf para seleccionar interactivamente una versión histórica.
# Muestra preview del build.sh en el commit seleccionado.
#
# Uso: fzf_select <package_name> [refresh]
#
#   package_name  — Nombre del paquete (ej: 'python', 'nodejs')
#   refresh       — (Opcional) 1 = forzar redescubrimiento, 0 = usar caché (default)
#
# Requiere: fzf instalado (pkg install fzf)
#
# Output (stdout): Línea seleccionada en formato:
#   version|commit_full|date|commit_short
#
# Retorno:
#   0 — Versión seleccionada exitosamente
#   1 — Selección cancelada o vacía
#   2 — Error al obtener el repositorio
#   10 — fzf no está instalado
#
fzf_select() {
    local pkg="${1:?Error: package name is required}"
    local refresh="${2:-0}"

    if ! command -v fzf &>/dev/null; then
        echo "Error: fzf is not installed. Install it with: pkg install fzf" >&2
        return 10
    fi

    # Obtener repositorio cacheado para el preview de fzf
    local repo_dir
    repo_dir="$(get_cached_repo)" || return 2

    # Obtener lista de versiones (con soporte de caché y refresh)
    local selected
    selected="$(get_cached_versions "$pkg" "$refresh" | fzf \
        --delimiter='|' \
        --with-nth='1,3,4' \
        --preview "git -C ${repo_dir} show {2}:packages/${pkg}/build.sh 2>/dev/null || echo 'build.sh not available in this commit'" \
        --preview-window='right:60%' \
        --header='Select a version — preview shows build.sh at that commit' \
        2>/dev/null)"

    local fzf_exit=$?

    if [[ $fzf_exit -eq 0 && -n "$selected" ]]; then
        echo "$selected"
        return 0
    fi

    return 1
}


# ─── clear_version_cache ───────────────────────────────────────────────────────
# Limpia el caché de versiones.
#
# Si se especifica un paquete, solo limpia ese. Si no, limpia TODO el caché
# de versiones (no borra el repo bare).
#
# Uso: clear_version_cache [package_name]
#
#   package_name  — (Opcional) Nombre del paquete a limpiar.
#                   Si no se provee, limpia todos los paquetes cacheados.
#
# Retorno:
#   0 — Éxito
#
clear_version_cache() {
    local pkg="${1:-}"
    local cache_dir
    cache_dir="$(get_cache_dir)"
    local versions_dir="${cache_dir}/versions"

    if [[ -n "$pkg" ]]; then
        local cache_file="${versions_dir}/${pkg}.txt"
        if [[ -f "$cache_file" ]]; then
            rm -f "$cache_file"
            echo "Cleared cache for package '${pkg}'" >&2
        else
            echo "No cache found for package '${pkg}'" >&2
        fi
    else
        if [[ -d "$versions_dir" ]]; then
            local count
            count="$(ls -1 "$versions_dir"/*.txt 2>/dev/null | wc -l)"
            rm -f "$versions_dir"/*.txt 2>/dev/null
            echo "Cleared all version cache (${count} packages)" >&2
        else
            echo "No version cache found" >&2
        fi
    fi

    return 0
}


# ─── cache_stats ───────────────────────────────────────────────────────────────
# Muestra estadísticas del sistema de caché persistente.
#
# Uso: cache_stats
#
cache_stats() {
    local cache_dir
    cache_dir="$(get_cache_dir)"
    local repo_path="${cache_dir}/repo/termux-packages.git"
    local versions_dir="${cache_dir}/versions"

    echo "=========================================="
    echo "  Prev Termux — Cache Statistics"
    echo "=========================================="
    echo ""
    echo "  Cache directory: ${cache_dir}"
    echo ""

    # ── Tamaño total del caché ──
    if [[ -d "$cache_dir" ]]; then
        local total_size
        total_size="$(du -sh "$cache_dir" 2>/dev/null | cut -f1)"
        echo "  Total size:       ${total_size:-N/A}"
    else
        echo "  Total size:       (empty)"
    fi

    # ── Repositorio bare ──
    if [[ -d "$repo_path" ]]; then
        local repo_size
        repo_size="$(du -sh "$repo_path" 2>/dev/null | cut -f1)"
        echo "  Bare repo size:   ${repo_size:-N/A}"

        local last_fetch_info="never"
        local last_fetch_file="${repo_path}/.last_fetch"
        if [[ -f "$last_fetch_file" ]]; then
            local last_fetch
            last_fetch=$(cat "$last_fetch_file" 2>/dev/null)
            local now
            now=$(date +%s)
            local age_secs=$((now - last_fetch))
            if [[ $age_secs -lt 60 ]]; then
                last_fetch_info="just now"
            elif [[ $age_secs -lt 3600 ]]; then
                last_fetch_info="$((age_secs / 60)) minutes ago"
            elif [[ $age_secs -lt 86400 ]]; then
                last_fetch_info="$((age_secs / 3600)) hours ago"
            else
                last_fetch_info="$((age_secs / 86400)) days ago"
            fi
        fi
        echo "  Last fetch:       ${last_fetch_info}"
    else
        echo "  Bare repo:        not cloned yet"
    fi

    # ── Paquetes cacheados ──
    if [[ -d "$versions_dir" ]]; then
        local pkg_files=("$versions_dir"/*.txt)
        if [[ -f "${pkg_files[0]}" ]]; then
            local pkg_count=${#pkg_files[@]}
            echo "  Cached packages:  ${pkg_count}"
            echo ""
            echo "  ── Package list ──"
            for f in "${pkg_files[@]}"; do
                if [[ -f "$f" ]]; then
                    local pkg_name
                    pkg_name="$(basename "$f" .txt)"
                    local cached_at
                    cached_at="$(grep "^# cached_at:" "$f" 2>/dev/null | cut -d' ' -f3- || echo "unknown")"
                    local ver_count
                    ver_count="$(grep -c '|' "$f" 2>/dev/null || echo 0)"
                    printf "    %-20s %s  (%d versions)\n" "${pkg_name}" "${cached_at}" "${ver_count}"
                fi
            done
        else
            echo "  Cached packages:  0"
        fi
    else
        echo "  Cached packages:  0"
    fi

    echo ""
    echo "=========================================="
}
