#!/usr/bin/env bash
# normalize-legacy-builds.sh — Normaliza los build.sh HISTÓRICOS (2018-2023)
# para que el build system VENDERED (build-system/, árbol de master de5ca479)
# pueda compilarlos sin fallar.
#
# No es build system: es PREPARACIÓN del paquete histórico. Se ejecuta tras
# copiar el vendered (ver gha-prepare.sh) y antes del build.
#
# Extraído del bloque [10/17] de scripts/patch-build-system.sh (que se conserva
# como referencia documental pero ya NO se ejecuta en runtime).
#
# Uso:
#   ./scripts/normalize-legacy-builds.sh <dir_arbol_paquete>
#
#   p.ej. ./scripts/normalize-legacy-builds.sh "$PWD/termux-packages"
#
# Idempotente: puede ejecutarse múltiples veces sobre el mismo árbol sin efectos
# secundarios (cada regla verifica/sed no toca nada si el patrón ya no existe).
set -euo pipefail

REPO_DIR="${1:-$PWD}"  # Directorio del árbol del paquete histórico

if [ ! -d "$REPO_DIR" ]; then
    echo "Error: el directorio del árbol del paquete no existe: $REPO_DIR" >&2
    exit 1
fi

echo "=== [normalize-legacy-builds] Normalizando variables legacy en build.sh ==="

# FASE 1 + FASE 2 (ver comentarios por regla abajo).
find "$REPO_DIR/packages" "$REPO_DIR/root-packages" "$REPO_DIR/x11-packages" \
    -name build.sh 2>/dev/null | while read -r f; do
    # Legacy compatibility: ncurses 6.1.20180707 (commit e4f2135, 2018) usaba
    # una URL de dl.bintray.com (cerrado en 2021 -> 404). Se sustituye por el
    # snapshot equivalente del repo de desarrollo de ncurses (mismo arbol del
    # 2018-07-07, commit b69347e) y su hash SHA256. Regla idempotente: sed no
    # toca nada si el patron ya no esta presente en el build.sh.
    # Legacy compatibility: la 2a fuente (rxvt-unicode via fossies.org) devuelve
    # HTTP 410/401 desde 2024. Se sustituye por el mirror byte-idéntico de Debian
    # pool (mismo contenido, hash SHA256 e94628e9 sin cambios).
    # Legacy compatibility: el build system moderno define PKG_CONFIG_LIBDIR como
    # una LISTA separada por ':' (lib/pkgconfig:share/pkgconfig) desde el commit
    # 3f1be51372 (nov-2022). Los build.sh de 2018 pasaban esa lista literal a
    # --with-pkg-config-libdir y ncurses creaba un directorio con ':' en el nombre,
    # por lo que el "cd pkgconfig" del post_make_install fallaba ("No such file or
    # directory"). Se fija la ruta única $TERMUX_PREFIX/lib/pkgconfig como hace master.
    # Legacy compatibility: termux-am 0.2 (2018) se compila con Gradle 4.1
    # (gradle-4.1-all.zip), que no soporta el Java 17.0.19 del runner de GitHub
    # ("Could not determine java version from '17.0.19'") y el build del paquete
    # falla. termux-am es una app Android auxiliar, no necesaria en runtime para
    # bash, asi que se ELIMINA la linea completa TERMUX_PKG_DEPENDS de
    # termux-tools. No basta con vaciarla (TERMUX_PKG_DEPENDS=""): buildorder.py
    # hace re.split(',|\|', '') que produce [''] y reporta la dep inexistente
    # "Package termux-tools depends on non-existing package ''". En el commit
    # e4f2135 la dep solo existe como TERMUX_PKG_DEPENDS="termux-am" (linea
    # exacta, sin lista), por eso la regla borra la linea anclada; es
    # idempotente: tras la primera pasada el patron ya no esta presente y sed
    # no toca nada mas.
    # Legacy compatibility: bash 4.4.23 (commit e4f2135, 2018) se compila con
    # prototipos C estilo K&R (void line_error(); static char *xmalloc();). El
    # compilador moderno (C23/clang nuevo) interpreta "()" como "(void)" y el
    # make de builtins/mkbuiltins.c falla con "too many arguments to function
    # 'line_error'; expected 0, have 3". Se fuerza -std=gnu89 (en gnu89 los
    # prototipos vacios siguen siendo K&R) en DOS frentes (diagnostico del run
    # 31223484353: la CFLAGS top-level era clobbered y no llegaba a ningun
    # compile, y grep -c gnu89 = 0):
    # 1) Los build-tools HOST (mkbuiltins.c y otros) los compila el Makefile de
    #    bash con la variable CCFLAGS_FOR_BUILD (gcc del host), NO con CFLAGS.
    #    NOTA (run 31230538553): NO se puede inyectar -std=gnu89 via
    #    TERMUX_PKG_EXTRA_MAKE_ARGS: el build system la expande SIN comillas
    #    (make -j N ${VAR}) y el field splitting de bash divide el valor por
    #    espacios ("make: invalid option -- 'D'"); los backslashes NO escapan
    #    el espacio en una expansion sin comillas (verificado con GNU make 4.4.1:
    #    mismo error con y sin backslash). La solucion es parchear los Makefile.in
    #    (configure los transforma en Makefile) en pre_configure con
    #    "sed -i '/ -std=gnu89/! s|^CCFLAGS_FOR_BUILD *=|& -std=gnu89|' Makefile.in builtins/Makefile.in":
    #    anhade -std=gnu89 justo tras "CCFLAGS_FOR_BUILD =" sin tocar el resto
    #    de la linea (ambos archivos usan la misma forma
    #    "CCFLAGS_FOR_BUILD = $(BASE_CCFLAGS) $(CPPFLAGS_FOR_BUILD) $(CFLAGS_FOR_BUILD)",
    #    linea 152 del Makefile.in raiz y linea 99 de builtins/Makefile.in en
    #    bash-4.4, verificadas con tar -xzOf del tarball). El sed inyectado recibe
    #    AMBOS archivos porque el sub-make builtins/ compila mkbuiltins.o (el
    #    archivo que falla: "too many arguments to function 'line_error'") con SU
    #    PROPIO CCFLAGS_FOR_BUILD definido en builtins/Makefile.in, NO con el del
    #    Makefile raiz; ese es el frente 2 del fix (el frente 1, Makefile.in raiz,
    #    ya cubria mksyntax/mksignames/buildsignames.o). Ambos archivos existen
    #    siempre: son parte del tarball bash-4.4 (tar -tzf bash-4.4.tar.gz
    #    confirma bash-4.4/builtins/Makefile.in). pre_configure corre antes de
    #    configure y con cwd=srcdir, asi que ambos Makefile.in ya existen. La
    #    FASE 1 tambien borra la linea TERMUX_PKG_EXTRA_MAKE_ARGS="CCFLAGS_FOR_BUILD=..." por
    #    si una version anterior de este script la dejo (make la re-dividiria y
    #    fallaria con el mismo error).
    # 2) El cross-compile usa CFLAGS, pero la definicion a top-level del
    #    build.sh se evalua al sourcear (antes del setup del toolchain) y es
    #    sobrescrita despues; por eso se exporta DENTRO de
    #    termux_step_pre_configure (que corre despues del setup del toolchain).
    #    El guard declara que la siguiente linea es "declare -A PATCH_CHECKSUMS"
    #    (unico de bash; la ancla termux_step_pre_configure sola existe en 76
    #    paquetes), y se usa P+D para que la linea consumida por N reciba su
    #    ciclo normal (no rompe el build.sh de otros paquetes).
    #    Evidencia en e4f2135 (packages/bash/build.sh): L25
    #    TERMUX_PKG_RM_AFTER_INSTALL="share/man/man1/bashbug.1 bin/bashbug",
    #    L26 blank, L27 "termux_step_pre_configure () {", L28 tab +
    #    "declare -A PATCH_CHECKSUMS" (INMEDIATA: solo indentacion tab entre
    #    ambas, sin blank lines ni comentarios; el [[:space:]]* del guard la
    #    tolera). bash NO define TERMUX_PKG_EXTRA_MAKE_ARGS ni CCFLAGS_FOR_BUILD
    #    en ningun punto (git grep, e4f2135).
    # El bloque se ejecuta en DOS seds: FASE 1 = normalizacion global (s///
    # linea a linea, sin N; toda linea pasa por todas las reglas), FASE 2 =
    # inserciones con lookahead (N + guard + P/D). Asi, la linea que queda
    # justo tras una ancla (p.ej. un TERMUX_PKG_*=yes tras RM_AFTER) ya quedo
    # normalizada (=true) en la FASE 1 antes de que la FASE 2 la consuma con N.
    # Ambas fases son idempotentes (N + guard de lookahead): tras la 1a pasada
    # la linea ya esta presente y el guard deja de matchear en una 2a pasada.
    # FASE 1: normalizacion global linea a linea.
    sed -i \
        -e 's/TERMUX_PKG_BLACKLISTED_ARCHES=/TERMUX_PKG_EXCLUDED_ARCHES=/g' \
        -e 's/TERMUX_DEBDIR/TERMUX_OUTPUT_DIR/g' \
        -e 's/TERMUX_MAKE_PROCESSES/TERMUX_PKG_MAKE_PROCESSES/g' \
        -e 's/TERMUX_PKG_NO_DEVELSPLIT/TERMUX_PKG_NO_STATICSPLIT/g' \
        -e 's/^\(TERMUX_PKG_[A-Z_]*\)=yes$/\1=true/g' \
        -e 's/^\(TERMUX_PKG_[A-Z_]*\)=no$/\1=false/g' \
        -e 's|https://dl\.bintray\.com/termux/upstream/ncurses-\${TERMUX_PKG_VERSION:0:3}-\${TERMUX_PKG_VERSION:4}\.tgz|https://github.com/ThomasDickey/ncurses-snapshots/archive/b69347e952d596f8a3799b11a28080f8fd716511.tar.gz|g' \
        -e 's|78c92a14f3640582dcc69ea90b2043d6f08327be5ee1ad4c98ee7135565e5dfa|d6e9758d3b51dbaa582b1cdf6a2749e29bc6b03638b05be8b974a0cdb6fdf019|g' \
        -e 's|https://fossies\.org/linux/misc/rxvt-unicode-\${TERMUX_PKG_VERSION\[1\]}\.tar\.bz2|https://deb.debian.org/debian/pool/main/r/rxvt-unicode/rxvt-unicode_${TERMUX_PKG_VERSION[1]}.orig.tar.bz2|g' \
        -e 's|--with-pkg-config-libdir=\$PKG_CONFIG_LIBDIR|--with-pkg-config-libdir=\$TERMUX_PREFIX/lib/pkgconfig|' \
        -e '/^TERMUX_PKG_DEPENDS="termux-am"$/d' \
        -e '/^TERMUX_PKG_EXTRA_MAKE_ARGS="CCFLAGS_FOR_BUILD=/d' \
        "$f" || true
    # FASE 2: inserciones con lookahead (N + guard + P/D).
    sed -i \
        -e '/^termux_step_pre_configure () {$/{
N
/^termux_step_pre_configure () {\n[[:space:]]*declare -A PATCH_CHECKSUMS/s@^termux_step_pre_configure () {\n@termux_step_pre_configure () {\nexport CFLAGS="$CFLAGS -std=gnu89"\nsed -i "/ -std=gnu89/! s|^CCFLAGS_FOR_BUILD *=|\& -std=gnu89|" Makefile.in builtins/Makefile.in\n@
P
D
}' \
        "$f" || true
done || true

echo "=== [normalize-legacy-builds] Done. build.sh normalizados. ==="
