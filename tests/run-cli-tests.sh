#!/usr/bin/env bash
# Suite de tests de la CLI scripts/prev-termux.
# ----------------------------------------------------------------
# Harness de prueba: stubs de gh/fzf/pacman/apt, fixtures de releases/runs,
# HOME/PREFIX/INSTALL_DIR/BIN_DIR/CACHE_DIR aislados y la CLI sourceada sin
# main (para invocar cmd_* directamente).
#
# Uso:  bash tests/run-cli-tests.sh
#
# Cobertura (28 casos): build (4), subinstall (12), install (5),
# switch (5), fetch/help (2).
# ----------------------------------------------------------------
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/prev-termux"
TEST_DIR="$REPO/tests"
SUITE="${TMPDIR}/prev-termux-suite"

# ── Preparación del entorno aislado ────────────────────────────────────────────
rm -rf "$SUITE"
mkdir -p "$SUITE"
cp -r "$TEST_DIR/stubs"    "$SUITE/stubs-src"
cp -r "$TEST_DIR/fixtures" "$SUITE/fixtures"

# ── Copiar la CLI y quitar `main "$@"` (última línea) para sourcear funciones ──
mkdir -p "$SUITE/wt/lib"
sed '$d' "$SCRIPT" > "$SUITE/wt/prev-termux.sh"
cp "$REPO/scripts/lib/discover.sh"       "$SUITE/wt/lib/"
cp "$REPO/scripts/lib/version-extract.sh" "$SUITE/wt/lib/"

# ── Construir los dirs de stubs (variantes sin fzf / solo pacman / solo apt) ──
mk_bin() { # mk_bin <dir> <stub...>
    local d="$1"; shift
    mkdir -p "$d"
    local s
    for s in "$@"; do
        cp "$SUITE/stubs-src/$s" "$d/$s"
        chmod +x "$d/$s"
    done
}
mk_bin "$SUITE/bin"            gh fzf pacman apt
mk_bin "$SUITE/bin-nofzf"      gh pacman apt
mk_bin "$SUITE/bin-pm-pacman"  gh fzf pacman
mk_bin "$SUITE/bin-pm-apt"     gh fzf apt

# ── Tagmap + staging (binarios fake para los tars) ─────────────────────────────
cp "$SUITE/fixtures/tagmap.txt" "$SUITE/tagmap.txt"

mk_staging() {
    # Layout estándar: data/data/com.termux/files/usr/bin/<pkg>
    mkdir -p "$SUITE/staging/std/data/data/com.termux/files/usr/bin"
    local p
    for p in zig bat coreutils python libedit libpng16; do
        printf '#!/bin/sh\necho %s-ok\n' "$p" \
            > "$SUITE/staging/std/data/data/com.termux/files/usr/bin/$p"
        chmod +x "$SUITE/staging/std/data/data/com.termux/files/usr/bin/$p"
    done
    # Layout subversioned: data/data/com.termux/files/home/.local/opt/<pkg>-<ver>/bin/<pkg>
    local t pkg ver
    while IFS=$'\t' read -r t pkg ver; do
        [[ -z "$t" || "$t" == \#* ]] && continue
        mkdir -p "$SUITE/staging/sub/data/data/com.termux/files/home/.local/opt/${pkg}-${ver}/bin"
        printf '#!/bin/sh\necho %s-%s-ok\n' "$pkg" "$ver" \
            > "$SUITE/staging/sub/data/data/com.termux/files/home/.local/opt/${pkg}-${ver}/bin/$pkg"
        chmod +x "$SUITE/staging/sub/data/data/com.termux/files/home/.local/opt/${pkg}-${ver}/bin/$pkg"
    done < "$SUITE/tagmap.txt"
}
mk_staging

# ── Helpers del runner ─────────────────────────────────────────────────────────
pass=0; fail=0; cases_total=0; cases_ok=0
CASE=""
STUBS="$SUITE/bin"

check() { # check <desc> <cmd...>
    local desc="$1"; shift
    if "$@"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}

reset_case() {
    # NOTA: $SUITE/logs NO se borra para conservar la evidencia de cada caso.
    rm -rf "$SUITE/home/.local/opt" "$SUITE/home/.local/bin" "$SUITE/prefix/bin" \
           "$SUITE/cache" "$SUITE/fetch-out" "$SUITE/localfiles"
    mkdir -p "$SUITE/home/.local/opt" "$SUITE/home/.local/bin" "$SUITE/prefix/bin" \
             "$SUITE/cache" "$SUITE/logs"
    unset GH_RUNS GH_POOL_PKG GH_POOL_VER GH_POOL_MODE FZF_CHOICES FZF_PICK 2>/dev/null || true
    export PT_FAKE_ABSENT=""
    STUBS="$SUITE/bin"
    test_mocks() { :; }
}

pkg_fixture() { # pkg_fixture <pkg> → mapa pkg→fixture
    case "$1" in
        zig)       export GH_RELEASES="$SUITE/fixtures/releases-zig.json" ;;
        bat)       export GH_RELEASES="$SUITE/fixtures/releases-bat.json" ;;
        coreutils) export GH_RELEASES="$SUITE/fixtures/releases-coreutils.json" ;;
        python)    export GH_RELEASES="$SUITE/fixtures/releases-python.json" ;;
        libedit)   export GH_RELEASES="$SUITE/fixtures/releases-libedit.json" ;;
        subonly)   export GH_RELEASES="$SUITE/fixtures/releases-subonly.json" ;;
        *)         export GH_RELEASES="$SUITE/fixtures/releases-empty.json" ;;
    esac
}

choices() { # choices <texto-printf-%b> → archivo FIFO para el stub fzf
    printf '%b' "$1" > "$SUITE/choices"
    export FZF_CHOICES="$SUITE/choices"
}

stdin_text() { mkdir -p "$SUITE/logs/$CASE"; printf '%b' "$1" > "$SUITE/logs/$CASE/stdin"; }

invoke() { # invoke <fn> <args...>  (CASE define el nombre del caso)
    local fn="$1"; shift
    local logdir="$SUITE/logs/$CASE"
    mkdir -p "$logdir"
    [[ -f "$logdir/stdin" ]] || : > "$logdir/stdin"
    (
        set -u
        export HOME="$SUITE/home"
        export PREFIX="$SUITE/prefix"
        export PREV_TERMUX_CACHE_DIR="$SUITE/cache"
        export PREV_TERMUX_INSTALL_DIR="$HOME/.local/opt"
        export PREV_TERMUX_BIN_DIR="$HOME/.local/bin"
        export GITHUB_REPOSITORY="owner/PrevTermuxPackage"
        export PREV_TERMUX_WORKFLOW_REF="main"
        export GH_LOG="$logdir/gh.log" FZF_LOG="$logdir/fzf.log" PM_LOG="$logdir/pm.log"
        export GH_TAGMAP="$SUITE/tagmap.txt"
        export GH_STAGING_STD="$SUITE/staging/std"
        export GH_STAGING_SUB="$SUITE/staging/sub"
        export PATH="$STUBS:$PATH"
        # shellcheck disable=SC1090
        source "$SUITE/wt/prev-termux.sh" >/dev/null 2>&1
        # Ocultar comandos del sistema (fzf/pacman/apt reales de Termux) que
        # romperían la simulación: la CLI detecta fzf/pacman/apt con
        # `command -v`; PT_FAKE_ABSENT fuerza "no encontrado" para esos.
        command() {
            local c="${2:-}"
            if [[ "${1:-}" == "-v" && -n "$c" ]] && [[ " ${PT_FAKE_ABSENT:-} " == *" $c "* ]]; then
                return 1
            fi
            builtin command "$@"
        }
        if declare -F test_mocks >/dev/null 2>&1; then test_mocks; fi
        "$fn" "$@"
    ) < "$logdir/stdin" > "$logdir/out.log" 2> "$logdir/err.log"
    echo "$?" > "$logdir/rc"
}

log() { echo "$SUITE/logs/$CASE/$1"; }

run_case() {
    local name="$1" desc="$2" fn="$3"
    local before=$fail
    echo ""
    echo "=== $name: $desc ==="
    "$fn"
    if [[ $fail -eq $before ]]; then
        cases_ok=$((cases_ok + 1))
    fi
    cases_total=$((cases_total + 1))
}

# ═══════════════════════════════════════════════════════════════════════════════
# A. build
# ═══════════════════════════════════════════════════════════════════════════════

# A1: sin run previo → lanza directo (gh workflow run en GH_LOG)
t_a1_build_sin_run_lanza() {
    CASE=a1; reset_case; pkg_fixture zig
    test_mocks() { extract_version() { printf '1.0.0\n'; }; }
    invoke cmd_build zig --commit 1111111
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "workflow run registrado" grep -q "gh workflow run" "$(log gh.log)"
    check "package_name=zig en el dispatch" grep -q "package_name=zig" "$(log gh.log)"
    check "git_ref=1111111 en el dispatch" grep -q "git_ref=1111111" "$(log gh.log)"
    check "workflow enable previo" grep -q "gh workflow enable" "$(log gh.log)"
    check "no pregunta (sin run previo)" bash -c "! grep -q 'Hay una build' '$SUITE/logs/$CASE/err.log'"
}

# A2: run en curso + 'n' → no relanza
t_a2_build_run_curso_n() {
    CASE=a2; reset_case; pkg_fixture zig
    export GH_RUNS="$SUITE/fixtures/runs-ip.json"
    stdin_text 'n\n'
    test_mocks() { extract_version() { printf '1.0.0\n'; }; }
    invoke cmd_build zig --commit 1111111
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    # `read -p` omite el prompt con stdin no-tty; la detección del run en curso
    # se demuestra por la consulta de runs previos + la ausencia de dispatch.
    check "consulta runs previos (detección)" grep -q "gh run list" "$(log gh.log)"
    check "no relanza (sin workflow run)" bash -c "! grep -q 'gh workflow run' '$SUITE/logs/$CASE/gh.log'"
    check "mensaje de no relanzado" grep -q "Build no relanzada" "$(log out.log)"
}

# A3: run exitosa + 'n' → no relanza
t_a3_build_run_exitosa_n() {
    CASE=a3; reset_case; pkg_fixture zig
    export GH_RUNS="$SUITE/fixtures/runs-success.json"
    stdin_text 'n\n'
    test_mocks() { extract_version() { printf '1.0.0\n'; }; }
    invoke cmd_build zig --commit 1111111
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    # Mismo criterio que A2: la detección se demuestra por la consulta de runs
    # y la ausencia de dispatch (el prompt read -p no es visible en no-tty).
    check "consulta runs previos (detección)" grep -q "gh run list" "$(log gh.log)"
    check "no relanza (sin workflow run)" bash -c "! grep -q 'gh workflow run' '$SUITE/logs/$CASE/gh.log'"
    check "mensaje de no relanzado" grep -q "Build no relanzada" "$(log out.log)"
}

# A4: --subversioned → -f jobs=subversioned en GH_LOG
t_a4_build_subversioned_jobs() {
    CASE=a4; reset_case; pkg_fixture zig
    test_mocks() { extract_version() { printf '1.0.0\n'; }; }
    invoke cmd_build zig --commit 1111111 --subversioned
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "-f jobs=subversioned en el dispatch" grep -q "jobs=subversioned" "$(log gh.log)"
    check "workflow run registrado" grep -q "gh workflow run" "$(log gh.log)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# B. subinstall
# ═══════════════════════════════════════════════════════════════════════════════

# B1: lista AMBAS versiones (0.16.0 y 0.15.2) en el selector fzf
t_b1_subinstall_lista_ambas() {
    CASE=b1; reset_case; pkg_fixture zig
    choices "zig-0.16.0  [normal, subversioned]\nSubversion\n"
    invoke cmd_subinstall zig
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "lista 0.16.0 con sus modos" grep -q "zig-0.16.0  \[normal, subversioned\]" "$(log fzf.log)"
    check "lista 0.15.2 con sus modos" grep -q "zig-0.15.2  \[normal, subversioned\]" "$(log fzf.log)"
    check "diálogo de modo con Subversion/Normal" bash -c "grep -q '^Subversion$' '$SUITE/logs/$CASE/fzf.log' && grep -q '^Normal$' '$SUITE/logs/$CASE/fzf.log'"
}

# B2: pick 0.16.0 + modo Subversion → descarga tag subversioned y extrae bin/zig
t_b2_subinstall_pick_sub() {
    CASE=b2; reset_case; pkg_fixture zig
    choices "zig-0.16.0  [normal, subversioned]\nSubversion\n"
    invoke cmd_subinstall zig
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "descarga tag subversioned de 0.16.0" grep -q "release download zig-0.16.0-def4567-subversioned" "$(log gh.log)"
    check "extrae a .local/opt/zig-0.16.0/bin/zig" test -x "$SUITE/home/.local/opt/zig-0.16.0/bin/zig"
    check "crea symlink versionado zig-0.16.0" test -L "$SUITE/home/.local/bin/zig-0.16.0"
}

# B3: pick 0.15.2 + modo Normal → descarga tag normal de 0.15.2
t_b3_subinstall_pick_0152() {
    CASE=b3; reset_case; pkg_fixture zig
    choices "zig-0.15.2  [normal, subversioned]\nNormal\n"
    invoke cmd_subinstall zig
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "descarga tag normal de 0.15.2" grep -q "release download zig-0.15.2-abc1234 " "$(log gh.log)"
    check "NO descarga tag subversioned" bash -c "! grep -q 'zig-0.15.2-abc1234-subversioned' '$SUITE/logs/$CASE/gh.log'"
    check "extrae a .local/opt/zig-0.15.2/bin/zig" test -x "$SUITE/home/.local/opt/zig-0.15.2/bin/zig"
}

# B4: modo Normal → descarga tag normal (0.16.0)
t_b4_subinstall_modo_normal() {
    CASE=b4; reset_case; pkg_fixture zig
    choices "zig-0.16.0  [normal, subversioned]\nNormal\n"
    invoke cmd_subinstall zig
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "descarga tag normal de 0.16.0" grep -q "release download zig-0.16.0-def4567 " "$(log gh.log)"
    check "NO descarga tag subversioned" bash -c "! grep -q 'zig-0.16.0-def4567-subversioned' '$SUITE/logs/$CASE/gh.log'"
}

# B5: solo-normal (coreutils) + 'y' → warn "aún no se ha compilado subversionado"
t_b5_subinstall_solo_normal_warn() {
    CASE=b5; reset_case; pkg_fixture coreutils
    stdin_text 'y\n'
    invoke cmd_subinstall coreutils
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "warn 'aún no se ha compilado subversionado'" grep -q "aún no se ha compilado subversionado para la versión 9.5" "$(log out.log)"
    check "descarga tag normal de coreutils" grep -q "release download coreutils-9.5-ccc2222" "$(log gh.log)"
    check "extrae a .local/opt/coreutils-9.5/bin/coreutils" test -x "$SUITE/home/.local/opt/coreutils-9.5/bin/coreutils"
}

# B6: 'n' en solo-normal → no descarga
t_b6_subinstall_solo_normal_n() {
    CASE=b6; reset_case; pkg_fixture coreutils
    stdin_text 'n\n'
    invoke cmd_subinstall coreutils
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "cancela con 'Descarga cancelada'" grep -q "Descarga cancelada" "$(log out.log)"
    check "no descarga nada" bash -c "! grep -q 'release download coreutils' '$SUITE/logs/$CASE/gh.log'"
}

# B7: 1 versión (bat) → salta selector de versión y pregunta solo el modo
t_b7_subinstall_una_version() {
    CASE=b7; reset_case; pkg_fixture bat
    choices "Subversion\n"
    invoke cmd_subinstall bat
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "salta selector de versión" grep -q "Única versión disponible de 'bat': 0.7.1" "$(log out.log)"
    check "diálogo de modo con Subversion/Normal" bash -c "grep -q '^Subversion$' '$SUITE/logs/$CASE/fzf.log' && grep -q '^Normal$' '$SUITE/logs/$CASE/fzf.log'"
    check "no pasa labels de versión al selector" bash -c "! grep -q 'bat-0.7.1  \[' '$SUITE/logs/$CASE/fzf.log'"
    check "descarga tag subversioned de bat" grep -q "release download bat-0.7.1-aaa1111-subversioned" "$(log gh.log)"
}

# B8: fallback sin fzf → menú numerado (versión + modo)
t_b8_subinstall_sin_fzf_menu() {
    CASE=b8; reset_case; pkg_fixture zig
    STUBS="$SUITE/bin-nofzf"
    export PT_FAKE_ABSENT="fzf"
    stdin_text '1\n1\n'
    invoke cmd_subinstall zig
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "usa menú numerado (Opciones disponibles)" grep -q "Opciones disponibles:" "$(log err.log)"
    check "menú de modo con 1) Subversion 2) Normal" bash -c "grep -q '1) Subversion' '$SUITE/logs/$CASE/err.log' && grep -q '2) Normal' '$SUITE/logs/$CASE/err.log'"
    check "descarga tag subversioned de 0.16.0" grep -q "release download zig-0.16.0-def4567-subversioned" "$(log gh.log)"
    check "no invoca fzf" test ! -f "$SUITE/logs/$CASE/fzf.log"
}

# B9: colisión de prefijo (python vs python-numpy) → descarta y elige python
t_b9_subinstall_colision_prefijo() {
    CASE=b9; reset_case; pkg_fixture python
    choices "Subversion\n"
    invoke cmd_subinstall python
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "warn de colisión (comparte prefijo)" grep -q "comparte prefijo" "$(log out.log)"
    check "descarta la release con artifact python-numpy" grep -q "release download python-3.11.0-aaa1111-subversioned" "$(log gh.log)"
    check "prueba siguiente candidato y acierta" grep -q "release download python-3.11.0-ccc3333-subversioned" "$(log gh.log)"
    check "extrae el python correcto" test -x "$SUITE/home/.local/opt/python-3.11.0/bin/python"
}

# B10: extracción con pkg/ver verificados (libedit-20210216-3.1, ver con guiones)
t_b10_subinstall_libedit() {
    CASE=b10; reset_case; pkg_fixture libedit
    choices "Subversion\n"
    invoke cmd_subinstall libedit
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "extrae a .local/opt/libedit-20210216-3.1/bin/libedit" test -x "$SUITE/home/.local/opt/libedit-20210216-3.1/bin/libedit"
    check "no trunca la versión con guiones" test ! -e "$SUITE/home/.local/opt/libedit-20210216"
    check "symlink versionado completo" test -L "$SUITE/home/.local/bin/libedit-20210216-3.1"
}

# B11: archivo local con `_` (pool) parsea pkg/ver
t_b11_subinstall_archivo_local() {
    CASE=b11; reset_case
    mkdir -p "$SUITE/localfiles"
    tar -cf "$SUITE/localfiles/libpng16_1.6.43_all_subversioned.pkg.tar.xz" \
        -C "$SUITE/staging/std" "data/data/com.termux/files/usr/bin/libpng16"
    invoke cmd_subinstall "$SUITE/localfiles/libpng16_1.6.43_all_subversioned.pkg.tar.xz"
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "parsea pkg/ver del nombre con guiones bajos" test -x "$SUITE/home/.local/opt/libpng16-1.6.43/bin/libpng16"
}

# B12: symlink versionado creado en ~/.local/bin
t_b12_subinstall_symlink_versionado() {
    CASE=b12; reset_case; pkg_fixture bat
    choices "Subversion\n"
    invoke cmd_subinstall bat
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "symlink bat-0.7.1 existe" test -L "$SUITE/home/.local/bin/bat-0.7.1"
    check "symlink apunta a opt/bat-0.7.1/bin/bat" test "$(readlink -f "$SUITE/home/.local/bin/bat-0.7.1")" = "$SUITE/home/.local/opt/bat-0.7.1/bin/bat"
}

# ═══════════════════════════════════════════════════════════════════════════════
# C. install
# ═══════════════════════════════════════════════════════════════════════════════

# C1: solo-pacman → pacman -U SIN --noconfirm
t_c1_install_solo_pacman() {
    CASE=c1; reset_case; pkg_fixture zig
    STUBS="$SUITE/bin-pm-pacman"
    export PT_FAKE_ABSENT="apt"
    choices "zig-0.16.0  [normal, subversioned]\n"
    invoke cmd_install zig
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "pacman -U invocado" grep -q "^PACMAN -U " "$(log pm.log)"
    check "descarga tag normal de 0.16.0" grep -q "release download zig-0.16.0-def4567 " "$(log gh.log)"
    check "pacman NO recibe --noconfirm" bash -c "! grep -q -- '--noconfirm' '$SUITE/logs/$CASE/pm.log'"
}

# C2: solo-apt → apt install SIN -y
t_c2_install_solo_apt() {
    CASE=c2; reset_case; pkg_fixture zig
    STUBS="$SUITE/bin-pm-apt"
    export PT_FAKE_ABSENT="pacman"
    choices "zig-0.16.0  [normal, subversioned]\n"
    invoke cmd_install zig
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "apt install invocado" grep -q "^APT install " "$(log pm.log)"
    check "apt descarga .deb" grep -q "release download zig-0.16.0-def4567 " "$(log gh.log)"
    check "apt NO recibe -y" bash -c "! grep -qE -- '(-y|--noconfirm)( |$)' '$SUITE/logs/$CASE/pm.log'"
}

# C3: ambos gestores → pregunta (elige apt por stdin)
t_c3_install_ambos_pregunta() {
    CASE=c3; reset_case; pkg_fixture zig
    stdin_text 'apt\n'
    choices "zig-0.16.0  [normal, subversioned]\n"
    invoke cmd_install zig
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    # El prompt de read -p no es visible con stdin no-tty; la evidencia de la
    # pregunta es que, con AMBOS gestores visibles y stdin=apt, se usa apt.
    check "usa apt (respeta el stdin de la pregunta)" grep -q "^APT install " "$(log pm.log)"
    check "no usa pacman" bash -c "! grep -q '^PACMAN' '$SUITE/logs/$CASE/pm.log'"
}

# C4: versión exacta → descarga esa sin selector
t_c4_install_version_exacta() {
    CASE=c4; reset_case; pkg_fixture zig
    invoke cmd_install zig 0.15.2
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "descarga tag normal de 0.15.2" grep -q "release download zig-0.15.2-abc1234 " "$(log gh.log)"
    check "pacman -U con artifact de 0.15.2" grep -q "^PACMAN -U .*zig-0.15.2-0-aarch64.pkg.tar.xz" "$(log pm.log)"
    check "no invoca selector (sin fzf.log)" test ! -f "$SUITE/logs/$CASE/fzf.log"
}

# C5: sin release normal → die claro
t_c5_install_sin_release_normal() {
    CASE=c5; reset_case; pkg_fixture subonly
    invoke cmd_install bat
    check "rc=1 (die)" test "$(cat "$(log rc)")" = "1"
    check "mensaje claro 'No hay release normal'" grep -q "No hay release normal de 'bat'" "$(log err.log)"
    check "no invoca gestor" test ! -f "$SUITE/logs/$CASE/pm.log"
}

# ═══════════════════════════════════════════════════════════════════════════════
# D. switch
# ═══════════════════════════════════════════════════════════════════════════════

# D1: marca (actual) y cambia al elegir otra
t_d1_switch_marca_actual() {
    CASE=d1; reset_case
    local opt="$SUITE/home/.local/opt"
    mkdir -p "$opt/bat-0.7.1/bin" "$opt/bat-0.8.0/bin"
    printf '#!/bin/sh\necho bat\n' > "$opt/bat-0.7.1/bin/bat"; chmod +x "$opt/bat-0.7.1/bin/bat"
    printf '#!/bin/sh\necho bat\n' > "$opt/bat-0.8.0/bin/bat"; chmod +x "$opt/bat-0.8.0/bin/bat"
    ln -s "$opt/bat-0.7.1/bin/bat" "$SUITE/prefix/bin/bat"
    choices "bat-0.8.0\n"
    invoke cmd_switch bat
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "marca (actual) en el selector" grep -q "bat-0.7.1 (actual)" "$(log fzf.log)"
    check "symlink cambia a 0.8.0" test "$(readlink -f "$SUITE/prefix/bin/bat")" = "$opt/bat-0.8.0/bin/bat"
}

# D2: elegir otra → readlink correcto
t_d2_switch_readlink() {
    CASE=d2; reset_case
    local opt="$SUITE/home/.local/opt"
    mkdir -p "$opt/bat-0.7.1/bin" "$opt/bat-0.8.0/bin"
    printf '#!/bin/sh\necho bat\n' > "$opt/bat-0.7.1/bin/bat"; chmod +x "$opt/bat-0.7.1/bin/bat"
    printf '#!/bin/sh\necho bat\n' > "$opt/bat-0.8.0/bin/bat"; chmod +x "$opt/bat-0.8.0/bin/bat"
    ln -s "$opt/bat-0.7.1/bin/bat" "$SUITE/prefix/bin/bat"
    choices "bat-0.8.0\n"
    invoke cmd_switch bat
    check "readlink apunta a opt/bat-0.8.0/bin/bat" test "$(readlink "$SUITE/prefix/bin/bat")" = "$opt/bat-0.8.0/bin/bat"
    check "mensaje 'Versión activa de bat: bat-0.8.0'" grep -q "Versión activa de 'bat': bat-0.8.0" "$(log out.log)"
}

# D3: multi-binario → crea TODOS los symlinks
t_d3_switch_multi_binario() {
    CASE=d3; reset_case
    local opt="$SUITE/home/.local/opt"
    mkdir -p "$opt/mypkg-1.0/bin"
    local b
    for b in a b c; do
        printf '#!/bin/sh\necho %s\n' "$b" > "$opt/mypkg-1.0/bin/$b"
        chmod +x "$opt/mypkg-1.0/bin/$b"
    done
    choices "mypkg-1.0\n"
    invoke cmd_switch mypkg
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "crea symlink a" test -L "$SUITE/prefix/bin/a"
    check "crea symlink b" test -L "$SUITE/prefix/bin/b"
    check "crea symlink c" test -L "$SUITE/prefix/bin/c"
    check "todos apuntan a mypkg-1.0" bash -c "test \"\$(readlink -f '$SUITE/prefix/bin/a')\" = '$opt/mypkg-1.0/bin/a' && test \"\$(readlink -f '$SUITE/prefix/bin/c')\" = '$opt/mypkg-1.0/bin/c'"
}

# D4: sin versiones instaladas → die
t_d4_switch_sin_versiones() {
    CASE=d4; reset_case
    invoke cmd_switch bat
    check "rc=1 (die)" test "$(cat "$(log rc)")" = "1"
    check "mensaje claro" grep -q "No hay versiones subversionadas instaladas de 'bat'" "$(log err.log)"
}

# D5: fallback sin fzf → menú numerado
t_d5_switch_sin_fzf() {
    CASE=d5; reset_case
    STUBS="$SUITE/bin-nofzf"
    export PT_FAKE_ABSENT="fzf"
    local opt="$SUITE/home/.local/opt"
    mkdir -p "$opt/bat-0.7.1/bin" "$opt/bat-0.8.0/bin"
    printf '#!/bin/sh\necho bat\n' > "$opt/bat-0.7.1/bin/bat"; chmod +x "$opt/bat-0.7.1/bin/bat"
    printf '#!/bin/sh\necho bat\n' > "$opt/bat-0.8.0/bin/bat"; chmod +x "$opt/bat-0.8.0/bin/bat"
    ln -s "$opt/bat-0.7.1/bin/bat" "$SUITE/prefix/bin/bat"
    stdin_text '2\n'
    invoke cmd_switch bat
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "usa menú numerado" grep -q "Opciones disponibles:" "$(log err.log)"
    check "marca (actual) en el menú" grep -q "1) bat-0.7.1 (actual)" "$(log err.log)"
    check "elige la 2ª (0.8.0)" test "$(readlink -f "$SUITE/prefix/bin/bat")" = "$opt/bat-0.8.0/bin/bat"
}

# ═══════════════════════════════════════════════════════════════════════════════
# E. fetch / help
# ═══════════════════════════════════════════════════════════════════════════════

# E1: help muestra install/switch/fetch
t_e1_help() {
    CASE=e1; reset_case
    invoke cmd_help
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "muestra install" grep -q "install" "$(log out.log)"
    check "muestra switch" grep -q "switch" "$(log out.log)"
    check "muestra fetch" grep -q "fetch" "$(log out.log)"
    check "muestra subinstall" grep -q "subinstall" "$(log out.log)"
}

# E2: fetch con stub → descarga del pool y verifica sha256
t_e2_fetch_pool() {
    CASE=e2; reset_case
    export GH_POOL_PKG="zig" GH_POOL_VER="0.16.0" GH_POOL_MODE="normal"
    invoke cmd_fetch zig --out "$SUITE/fetch-out"
    check "rc=0" test "$(cat "$(log rc)")" = "0"
    check "descarga y verifica el .deb del pool" grep -q "Descargado y verificado" "$(log out.log)"
    check "asset .deb presente" test -f "$SUITE/fetch-out/zig_0.16.0_aarch64.deb"
    check "asset .pkg.tar.xz (objetivo) presente" test -f "$SUITE/fetch-out/zig_0.16.0_aarch64.pkg.tar.xz"
    check "consulta el manifest del pool" grep -q "release download prev-termux-pool-aarch64" "$(log gh.log)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════
run_case A1 "build sin run previo → lanza" t_a1_build_sin_run_lanza
run_case A2 "build run en curso + 'n' → no relanza" t_a2_build_run_curso_n
run_case A3 "build run exitosa + 'n' → no relanza" t_a3_build_run_exitosa_n
run_case A4 "build --subversioned → -f jobs=subversioned" t_a4_build_subversioned_jobs

run_case B1 "subinstall lista ambas versiones" t_b1_subinstall_lista_ambas
run_case B2 "subinstall pick 0.16.0 + Subversion" t_b2_subinstall_pick_sub
run_case B3 "subinstall pick 0.15.2 + Normal" t_b3_subinstall_pick_0152
run_case B4 "subinstall modo Normal → tag normal" t_b4_subinstall_modo_normal
run_case B5 "subinstall solo-normal warn" t_b5_subinstall_solo_normal_warn
run_case B6 "subinstall solo-normal 'n' → no descarga" t_b6_subinstall_solo_normal_n
run_case B7 "subinstall 1 versión → salta selector" t_b7_subinstall_una_version
run_case B8 "subinstall sin fzf → menú numerado" t_b8_subinstall_sin_fzf_menu
run_case B9 "subinstall colisión prefijo python" t_b9_subinstall_colision_prefijo
run_case B10 "subinstall libedit ver con guiones" t_b10_subinstall_libedit
run_case B11 "subinstall archivo local (pool)" t_b11_subinstall_archivo_local
run_case B12 "subinstall symlink versionado" t_b12_subinstall_symlink_versionado

run_case C1 "install solo-pacman sin --noconfirm" t_c1_install_solo_pacman
run_case C2 "install solo-apt sin -y" t_c2_install_solo_apt
run_case C3 "install ambos gestores → pregunta" t_c3_install_ambos_pregunta
run_case C4 "install versión exacta" t_c4_install_version_exacta
run_case C5 "install sin release normal → die" t_c5_install_sin_release_normal

run_case D1 "switch marca (actual)" t_d1_switch_marca_actual
run_case D2 "switch readlink correcto" t_d2_switch_readlink
run_case D3 "switch multi-binario" t_d3_switch_multi_binario
run_case D4 "switch sin versiones → die" t_d4_switch_sin_versiones
run_case D5 "switch sin fzf → menú numerado" t_d5_switch_sin_fzf

run_case E1 "help muestra comandos" t_e1_help
run_case E2 "fetch del pool con stub" t_e2_fetch_pool

echo ""
echo "==========================================="
echo "RESULTADO: $pass PASS / $fail FAIL"
echo "CASOS: $cases_ok/$cases_total OK"
echo "Suite dir: $SUITE"
exit 0
