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


# ─── discover_versions ─────────────────────────────────────────────────────────
# Descubre todas las versiones históricas de un paquete Termux.
#
# Uso: discover_versions <package_name> [repo_dir]
#
#   package_name  — Nombre del paquete (ej: 'python', 'nodejs')
#   repo_dir      — (Opcional) Ruta a un clone bare existente de termux-packages.
#                   Si no se provee, clona uno temporal y lo limpia al finalizar.
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
    local own_repo=0

    # ── Clonar repositorio si no se proveyó ──
    if [[ -z "$repo_dir" ]]; then
        repo_dir="$(mktemp -d "${TMPDIR}/termux-packages-bare.XXXXXX")"
        own_repo=1

        if ! git clone --bare --single-branch "$TERMUX_PACKAGES_REPO" "$repo_dir" 2>/dev/null; then
            echo "Error: failed to clone termux-packages repository" >&2
            rm -rf "$repo_dir"
            return 2
        fi
    fi

    # ── Verificar que el paquete existe ──
    if ! git -C "$repo_dir" cat-file -e "HEAD:packages/${pkg}/build.sh" 2>/dev/null; then
        echo "Error: package '${pkg}' not found in termux-packages" >&2
        [[ "$own_repo" -eq 1 ]] && rm -rf "$repo_dir"
        return 3
    fi

    # ── Buscar commits donde cambió la línea TERMUX_PKG_VERSION ──
    # Usamos -G (regex pickaxe) en lugar de -S (string count) porque -S solo
    # detecta cambios en el número de ocurrencias, pero NO detecta cambios
    # de valor (ej: "1.0" → "1.1") donde "TERMUX_PKG_VERSION=" sigue
    # apareciendo exactamente una vez.
    local log_output
    log_output="$(git -C "$repo_dir" log --all -G "^TERMUX_PKG_VERSION=" \
        -- "packages/${pkg}/build.sh" --format="%H|%ci|%h" 2>/dev/null)"

    if [[ -z "$log_output" ]]; then
        echo "Warning: no version changes found for package '${pkg}'" >&2
        [[ "$own_repo" -eq 1 ]] && rm -rf "$repo_dir"
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
        local version
        version="$(git -C "$repo_dir" show "${commit_hash}:packages/${pkg}/build.sh" 2>/dev/null | \
            grep "^TERMUX_PKG_VERSION=" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d ' ' || true)"

        if [[ -n "$version" ]]; then
            results+=("${version}|${commit_hash}|${commit_date}|${commit_short}")
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

    # ── Limpiar si clonamos nosotros ──
    [[ "$own_repo" -eq 1 ]] && rm -rf "$repo_dir"
    return 0
}


# ─── extract_version ───────────────────────────────────────────────────────────
# Extrae la versión TERMUX_PKG_VERSION de un commit específico.
#
# Uso: extract_version <commit_hash> <package_name> [repo_dir]
#
#   commit_hash   — Hash completo o abreviado del commit
#   package_name  — Nombre del paquete
#   repo_dir      — (Opcional) Ruta a un clone bare existente
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
    local own_repo=0

    if [[ -z "$repo_dir" ]]; then
        repo_dir="$(mktemp -d "${TMPDIR}/termux-packages-bare.XXXXXX")"
        own_repo=1

        if ! git clone --bare --single-branch "$TERMUX_PACKAGES_REPO" "$repo_dir" 2>/dev/null; then
            echo "Error: failed to clone termux-packages repository" >&2
            rm -rf "$repo_dir"
            return 2
        fi
    fi

    # Verificar que el commit existe
    if ! git -C "$repo_dir" cat-file -e "${commit_hash}:packages/${pkg}/build.sh" 2>/dev/null; then
        echo "Error: commit '${commit_hash}' or package '${pkg}' not found" >&2
        [[ "$own_repo" -eq 1 ]] && rm -rf "$repo_dir"
        return 1
    fi

    local version
    version="$(git -C "$repo_dir" show "${commit_hash}:packages/${pkg}/build.sh" 2>/dev/null | \
        grep "^TERMUX_PKG_VERSION=" | head -1 | cut -d= -f2 | tr -d '"' | tr -d ' ' || true)"

    [[ "$own_repo" -eq 1 ]] && rm -rf "$repo_dir"

    if [[ -z "$version" ]]; then
        echo "Error: could not extract TERMUX_PKG_VERSION for commit '${commit_hash}' package '${pkg}'" >&2
        return 1
    fi

    echo "$version"
    return 0
}


# ─── fzf_select ────────────────────────────────────────────────────────────────
# Usa fzf para seleccionar interactivamente una versión histórica.
# Muestra preview del build.sh en el commit seleccionado.
#
# Uso: fzf_select <package_name>
#
# Requiere: fzf instalado (pkg install fzf)
#
# Output (stdout): Línea seleccionada en formato:
#   version|commit_full|date|commit_short
#
# Retorno:
#   0 — Versión seleccionada exitosamente
#   1 — Selección cancelada o vacía
#   2 — Error al clonar el repositorio
#   10 — fzf no está instalado
#
fzf_select() {
    local pkg="${1:?Error: package name is required}"

    if ! command -v fzf &>/dev/null; then
        echo "Error: fzf is not installed. Install it with: pkg install fzf" >&2
        return 10
    fi

    # Crear repositorio temporal compartido para esta sesión de fzf
    # Se pasa a discover_versions para evitar un segundo clonado
    local repo_dir
    repo_dir="$(mktemp -d "${TMPDIR}/termux-packages-bare.XXXXXX")"

    if ! git clone --bare --single-branch "$TERMUX_PACKAGES_REPO" "$repo_dir" 2>/dev/null; then
        echo "Error: failed to clone termux-packages repository" >&2
        rm -rf "$repo_dir"
        return 2
    fi

    # Ejecutar discover_versions y pipear a fzf con preview
    # discover_versions recibe repo_dir para reutilizar el clone
    local selected
    selected="$(discover_versions "$pkg" "$repo_dir" | fzf \
        --delimiter='|' \
        --with-nth='1,3,4' \
        --preview "git -C ${repo_dir} show {2}:packages/${pkg}/build.sh 2>/dev/null || echo 'build.sh not available in this commit'" \
        --preview-window='right:60%' \
        --header='Select a version — preview shows build.sh at that commit' \
        2>/dev/null)"

    local fzf_exit=$?
    rm -rf "$repo_dir"

    if [[ $fzf_exit -eq 0 && -n "$selected" ]]; then
        echo "$selected"
        return 0
    fi

    return 1
}
