#!/usr/bin/env bash
#
# version-extract.sh — Extracción canónica de TERMUX_PKG_VERSION desde un build.sh
#
# Proporciona la función version_extract <build_sh_file>:
#   - Tolerante a espacios iniciales en la línea TERMUX_PKG_VERSION=
#   - Corta comentarios (# ...)
#   - Resuelve ${VAR}, $VAR, ${VAR%.*} y ${VAR%%pattern} usando las
#     definiciones del MISMO archivo (máximo 20 iteraciones).
#
# Uso (source):
#   source scripts/lib/version-extract.sh
#   version=$(version_extract path/to/build.sh)
#
# Nota: No ejecutar directamente — es una librería para source.
#

# ─── version_extract ──────────────────────────────────────────────────────────
# Extrae y resuelve TERMUX_PKG_VERSION del archivo build.sh.
#
# Uso: version_extract <build_sh_file>
#
# Output (stdout): Versión resuelta (ej: "3.12.2")
#
# Retorno:
#   0 — Éxito
#   1 — No se pudo extraer TERMUX_PKG_VERSION o quedaron variables sin resolver
#
version_extract() {
    local file="$1"
    local raw

    raw="$(grep -E '^[[:space:]]*TERMUX_PKG_VERSION=' "$file" 2>/dev/null | head -1 \
        | sed -E 's/^[[:space:]]*TERMUX_PKG_VERSION=//' \
        | cut -d'#' -f1 \
        | tr -d '"' | tr -d "'" \
        | sed 's/[[:space:]]*$//')"
    [[ -z "$raw" ]] && return 1

    # ── Fase 1: Extraer TODAS las definiciones del build.sh ──
    declare -A vars
    local name value
    while IFS='=' read -r name value; do
        name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -n "$name" && "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
            vars["$name"]="$value"
        fi
    done < <(grep -oP '^\s*[a-zA-Z_][a-zA-Z0-9_]*=.*' "$file" | head -100)

    # ── Fase 2: Resolver iterativamente (máximo 20 iteraciones) ──
    local resolved="$raw"
    local max_iter=20
    local iter=0
    while [[ $iter -lt $max_iter ]]; do
        local matched=0

        # ── ${VAR} con posible operación %pattern o %%pattern ──
        if [[ "$resolved" =~ \$\{([a-zA-Z_][a-zA-Z0-9_]*)([#%]?[^}]*)?\} ]]; then
            local full_match="${BASH_REMATCH[0]}"
            local var_name="${BASH_REMATCH[1]}"
            local var_op="${BASH_REMATCH[2]:-}"
            local var_value="${vars[$var_name]:-}"

            if [[ -n "$var_value" ]]; then
                # Limpiar comillas del valor
                var_value="${var_value//\"/}"
                var_value="${var_value//\'/}"

                # Si el valor contiene otra variable (${...}), resolverla primero
                if [[ "$var_value" =~ \$\{([a-zA-Z_][a-zA-Z0-9_]*)([#%]?[^}]*)?\} ]]; then
                    local inner_var="${BASH_REMATCH[1]}"
                    local inner_op="${BASH_REMATCH[2]:-}"
                    local inner_val="${vars[$inner_var]:-}"
                    inner_val="${inner_val//\"/}"
                    inner_val="${inner_val//\'/}"

                    if [[ -n "$inner_val" ]]; then
                        # Aplicar operación de bash: % (sufijo), %% (sufijo largo)
                        case "$inner_op" in
                            %.*)
                                inner_val="${inner_val%${inner_op#%}}"
                                ;;
                            %%.*)
                                inner_val="${inner_val%%${inner_op#%%}}"
                                ;;
                        esac
                        var_value="${var_value//\$\{${inner_var}${inner_op}\}/${inner_val}}"
                    fi
                fi

                # Aplicar la operación externa (de la referencia original)
                case "$var_op" in
                    %.*)
                        var_value="${var_value%${var_op#%}}"
                        ;;
                    %%.*)
                        var_value="${var_value%%${var_op#%%}}"
                        ;;
                esac

                resolved="${resolved//${full_match}/${var_value}}"
                matched=1
            fi
        fi

        # ── $VAR sin llaves (si no se resolvió ${...}) ──
        if [[ $matched -eq 0 && "$resolved" =~ \$([a-zA-Z_][a-zA-Z0-9_]*) ]]; then
            # Asegurar que no sea parte de ${VAR}
            if [[ "${BASH_REMATCH[0]}" != \$\{* ]]; then
                local var_name="${BASH_REMATCH[1]}"
                local var_value="${vars[$var_name]:-}"

                if [[ -n "$var_value" ]]; then
                    var_value="${var_value//\"/}"
                    var_value="${var_value//\'/}"
                    resolved="${resolved//\$"${var_name}"/${var_value}}"
                    matched=1
                fi
            fi
        fi

        # Si no se resolvió nada en esta iteración, salir
        [[ $matched -eq 0 ]] && break
        ((iter++))
    done

    # Verificar si quedaron variables sin resolver
    if [[ "$resolved" =~ \$\{?[a-zA-Z_] ]]; then
        return 1
    fi

    echo "$resolved"
    return 0
}
