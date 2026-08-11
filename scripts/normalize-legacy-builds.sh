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
    # ncurses 6.3 (neofetch@f5c8c3d, 2023) reintrodujo el patrón en
    # termux_step_pre_configure (L54 TERMUX_PKG_EXTRA_CONFIGURE_ARGS+=
    # " --with-pkg-config-libdir=$PKG_CONFIG_LIBDIR"). El run CI 31440108354
    # (main@50796a3, que YA contenía esta regla) falló igual: el configure recibió
    # la lista ':' literal ("pkg-config directory: .../lib/pkgconfig:.../share/
    # pkgconfig") y el "cd pkgconfig" del post_make_install falló ("No such file
    # or directory"), pese a que la regla matchea localmente (GNU sed 4.9). La
    # hipótesis es un sed silencioso/no aplicado en el árbol real del runner. Por
    # robustez la regla se ENDURECE: 'g' (todas las ocurrencias por línea) + una
    # variante que también cubre el valor ENTRE comillas (simple o doble). Esta
    # variante exige comilla a AMBOS lados del $PKG_CONFIG_LIBDIR para no consumir
    # la comilla de cierre del string de shell de la forma "+=" (un solo patrón
    # con ["' ]* final la rompería). Ambas son idempotentes.
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
    # Legacy compatibility: en termux-tools@8ca9404 (2023) termux-am NO es dep
    # unica sino un TOKEN dentro de una lista larga de DEPENDS
    # (TERMUX_PKG_DEPENDS="bzip2, coreutils, ..., termux-am (>= 0.8.0),
    # termux-am-socket (>= 1.5.0), termux-core, ..."), por lo que la regla de
    # linea anclada de arriba no matchea y buildorder intenta compilar termux-am
    # (Gradle 4.1 + Java 17 del runner: run CI 31296447772 de bash@8ca9404).
    # Estas reglas eliminan SOLO los tokens con version "termux-am (>= ...), "
    # y "termux-am-socket (>= ...), " dentro de listas. Son idempotentes (tras
    # la 1a pasada el token ya no esta presente) y seguras: el patron requiere
    # espacio literal tras "termux-am" (no colisiona con "termux-am-socket")
    # y el "(>= " solo aparece en DEPENDS. NO tocan el caso de dep unica.
    # Legacy compatibility: en termux-api@8ca9404 (2023) termux-am es el token
    # FINAL de la lista SIN coma trailing
    # (TERMUX_PKG_DEPENDS="bash, util-linux, termux-am (>= 0.8.0)"): los patrones
    # "..., " de arriba no lo matchean, asi que el token quedaba en la lista y
    # buildorder intentaria compilar termux-am. Esta regla elimina el token final
    # anclado al fin de linea; como el ultimo token de la lista va seguido de la
    # comilla de cierre de la variable, el patron captura y RESTAURA esa comilla:
    # s/, termux-am ([^)]*)"$/"/  ->  deja TERMUX_PKG_DEPENDS="bash, util-linux"
    # (sintaxis valida). Es idempotente y no colisiona con termux-tools (donde el
    # token va seguido de ", termux-core" y el ancla $ no matchea).
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
    # Legacy compatibility: codeberg REGENERO el empaquetado gzip de los
    # archives de foot 1.25.0 y 1.22.3 (mismo commit del tag; contenido del
    # source byte-identico verificado con diff -rq contra Wayback Machine), por
    # lo que el SHA256 historico del build.sh ya no coincide con el que codeberg
    # sirve hoy. Se actualiza el checksum al valor actual (RECOMPUTADO, como el
    # de ncurses-snapshots), verificado por doble descarga. Sin cambio de URL: el
    # archive de codeberg sigue vivo y es determinista. Bloquea la cadena de
    # regresiones via ncurses (terminfo de foot): bat@2f2adec (foot 1.25.0, run
    # CI "Wrong checksum ... 442a42d5") y bash@8ca9404 (foot 1.22.3, run CI
    # 31291105922 "Wrong checksum ... 1c9f09c1"). Idempotente: el sed no toca
    # nada si el SHA historico ya no esta presente.
    # Legacy compatibility: GNU REGENERO el empaquetado gzip de bash-5.3.tar.gz
    # (hash 0d5cd869 verificado en 3 mirrors distintos -- mirrors.kernel.org,
    # ftpmirror.gnu.org, mirror.csclub.uwaterloo.ca -- run CI 31357320573 de
    # bash@8ca9404: "Wrong checksum ... Expected 62dd49c ... Actual 0d5cd869").
    # Mismo caso que foot/codeberg y ncurses: mismo contenido, gzip regenerado.
    # El commit upstream 95f4e38b51 (bump 5.3.3) confirma el cambio con el mismo
    # SRCURL bash-${_MAIN_VERSION}.tar.gz: "the checksum of the base release
    # archive changed for some reason". RIESGO de contenido: no se pudo comparar
    # byte-a-byte con el tarball historico (62dd49c, no disponible en cache),
    # pero upstream acepto el nuevo hash sin cambios en el build.sh ni patches,
    # y el tar es valido (1603 entradas bajo bash-5.3/). Idempotente: el sed no
    # toca nada si el SHA historico ya no esta presente.
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
        -e 's|442a42d576ec72dd50f2d3faea8a664230a47bac79dc1eb6e7c9125ee76c130f|ee9d0e51295945157ecb33119cb2c79b276093d0fd342d959d78d772d505571c|g' \
        -e 's|1c9f09c119c5b24bd1934ce515e70f402b7d1b2c55f8218a16eddaa26e3f6fb0|2ac8ac8fb7646ac8d370dfc26bda2831ee951b4608d8783e9ec385a1b0ca3ff0|g' \
        -e 's|62dd49c44c399ed1b3f7f731e87a782334d834f08e098a35f2c87547d5dbb269|0d5cd86965f869a26cf64f4b71be7b96f90a3ba8b3d74e27e8e9d9d5550f31ba|g' \
        -e 's|--with-pkg-config-libdir=\$PKG_CONFIG_LIBDIR|--with-pkg-config-libdir=\$TERMUX_PREFIX/lib/pkgconfig|g' \
        -e 's|--with-pkg-config-libdir=["'\'']\$PKG_CONFIG_LIBDIR["'\'']|--with-pkg-config-libdir=\$TERMUX_PREFIX/lib/pkgconfig|g' \
        -e '/^TERMUX_PKG_DEPENDS="termux-am"$/d' \
        -e 's/termux-am-socket ([^)]*), //g' \
        -e 's/termux-am ([^)]*), //g' \
        -e 's/, termux-am ([^)]*)"$/"/' \
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

    # FASE 2b: tar 1.35 (commit 8ca9404, 2023) — fix remake espurio de
    # src/Makefile.in. Run CI 31293810431 fallo en make de tar con
    # "build-aux/missing: line 81: automake-1.16: command not found" (exit 127).
    # Causa raiz: el patch packages/tar/fix-linking-to-iconv.patch modifica
    # src/Makefile.am (anade "$(LIBINTL) $(LIBICONV)" a tar_LDADD); GNU patch lo
    # deja con mtime mas reciente que src/Makefile.in (generado con automake
    # 1.16 al empaquetar el tarball), y make dispara la regla automatica de
    # automake "src/Makefile.in: src/Makefile.am" a traves del wrapper
    # build-aux/missing. El runner no tiene automake-1.16 (setup-ubuntu.sh
    # instala el paquete 'automake' de ubuntu:26.04, cuyo binario versionado es
    # el de la version actual, no 1.16) y missing aborta. Master
    # (dd35c13e82, packages/tar/build.sh) resuelve lo mismo con
    # "autoreconf -fi" en termux_step_pre_configure: regenera los Makefile.in
    # desde los .am YA parcheados con el automake del sistema (la version
    # codificada pasa a ser la instalada y el remake espurio desaparece; ademas
    # propaga el cambio del patch al Makefile generado, sin lo cual el link de
    # tar quedaria sin -liconv). Se replica ese fix en el build.sh historico:
    # pre_configure corre con cwd=$TERMUX_PKG_SRCDIR despues de
    # termux_step_patch_package y antes de configure (build-package.sh:866-867).
    # Guard de 3 lineas (apertura + CPPFLAGS FORTIFY + LDFLAGS landroid-glob)
    # unico de tar: coreutils y m4 tambien tienen la linea CPPFLAGS
    # "-D__USE_FORTIFY_LEVEL=0" en pre_configure, pero no con la linea LDFLAGS
    # landroid-glob consecutiva. Idempotente: tras la 1a pasada la linea 2 ya es
    # "autoreconf -fi" y el guard deja de matchear en una 2a pasada.
    sed -i \
        -e '/^termux_step_pre_configure() {$/{
N
/^termux_step_pre_configure() {\n[[:space:]]*CPPFLAGS+=" -D__USE_FORTIFY_LEVEL=0"/{
N
/^termux_step_pre_configure() {\n[[:space:]]*CPPFLAGS+=" -D__USE_FORTIFY_LEVEL=0"\n[[:space:]]*LDFLAGS+=" -landroid-glob"/s@^termux_step_pre_configure() {\n@termux_step_pre_configure() {\nautoreconf -fi\n@
}
P
D
}' \
        "$f" || true

    # FASE 2c: util-linux 2.40.2 (commit 8ca9404, 2023) — fix remake espurio de
    # src/Makefile.in. Run CI 31299802531 fallo en make de util-linux con
    # "configure.ac:14: error: version mismatch. This is Automake 1.18.1, but the
    # definition used by this AM_INIT_AUTOMAKE comes from Automake 1.16.5."
    # (exit 63). El shim de automake (commit a750096) evito el "command not
    # found" pero el remake espurio de src/Makefile.in (disparado por la regla
    # automatica de automake via config/missing tras quedar src/Makefile.am con
    # mtime mas reciente que src/Makefile.in por el patch del paquete) invoca
    # automake-1.16 mientras el runner trae automake 1.18.1: mismatch de version.
    # Igual que tar (FASE 2b), se inyecta "autoreconf -fi" como 1a linea de
    # termux_step_pre_configure: regenera aclocal.m4, configure y TODA la
    # jerarquia de Makefile.in con el automake del sistema, eliminando el
    # mismatch y el remake espurio (tar PASO con este fix, run CI 31296109277).
    # pre_configure corre con cwd=$TERMUX_PKG_SRCDIR despues de
    # termux_step_patch_package y antes de configure (build-package.sh:866-867).
    # Guard de 3 lineas (apertura + case $TERMUX_ARCH_BITS + comentario prlimit)
    # unico de util-linux: git grep en 8ca9404 confirma que
    # 'case "$TERMUX_ARCH_BITS" in' y '#prlimit() is only available in 64-bit
    # bionic.' solo existen en packages/util-linux/build.sh (lineas 62-63). No
    # colisiona con el guard de tar (CPPFLAGS FORTIFY + LDFLAGS landroid-glob) ni
    # con el de bash (declare -A PATCH_CHECKSUMS): cada sed ancla en su paquete.
    # Idempotente: tras la 1a pasada la linea 2 ya es "autoreconf -fi" y el guard
    # deja de matchear en una 2a pasada.
    sed -i \
        -e '/^termux_step_pre_configure() {$/{
N
/^termux_step_pre_configure() {\n[[:space:]]*case "\$TERMUX_ARCH_BITS" in/{
N
/^termux_step_pre_configure() {\n[[:space:]]*case "\$TERMUX_ARCH_BITS" in\n[[:space:]]*#prlimit() is only available in 64-bit bionic\./s@^termux_step_pre_configure() {\n@termux_step_pre_configure() {\nautoreconf -fi\n@
}
P
D
}' \
        "$f" || true

    # Diagnóstico: si el patrón legacy sobrevive, la normalización no aplicó (el
    # sed falló silenciosamente o el patrón difiere). Log a stderr para debug en CI.
    grep -q -- '--with-pkg-config-libdir=$PKG_CONFIG_LIBDIR' "$f" 2>/dev/null \
        && echo "[normalize-legacy-builds] WARN: pkg-config-libdir NO normalizado en $f" >&2 \
        || true
done || true

# FASE 2e: bash 5.3 (commit 8ca9404, 2023) — fix gnu89 para build-tools HOST.
# Run CI 31359337356 fallo en el build-tool host mkbuiltins.o con:
#   ../bashansi.h:44:23: error: 'bool' cannot be defined via 'typedef'
#     typedef unsigned char bool;
#   note: 'bool' is a keyword with '-std=c23' onwards
#   make[1]: *** [Makefile:231: mkbuiltins.o] Error 1
# Mismo patron que bash 4.4 (FASE 2): los build-tools HOST (mkbuiltins.o y
# otros) los compila el gcc del host con su variable CCFLAGS_FOR_BUILD, NO con
# CFLAGS. En 4.4 el fallo eran los prototipos K&R; en 5.3 es el typedef de bool
# (C23 lo convierte en keyword). El make[1] del error es el sub-make de
# builtins/: la regla "Makefile:231" es builtins/Makefile.in L231
# "  $(CC_FOR_BUILD) -c $(CCFLAGS_FOR_BUILD) $<" (verificado en el tarball
# bash-5.3.tar.gz, hash 0d5cd869). El root Makefile.in L167 y
# builtins/Makefile.in L106 tienen la MISMA forma que 4.4
# "CCFLAGS_FOR_BUILD = $(BASE_CCFLAGS) $(CPPFLAGS_FOR_BUILD) $(CFLAGS_FOR_BUILD)",
# asi que el sed de la FASE 2 (anadir -std=gnu89 tras "CCFLAGS_FOR_BUILD =")
# aplica igual en ambos archivos: el Makefile raiz cubre mksyntax/mksignames y
# el de builtins/ compila mkbuiltins.o con SU propio CCFLAGS_FOR_BUILD.
# NO se puede anclar solo en pre_configure: bash 5.3 y readline 8.3
# (packages/readline/build.sh@8ca9404) tienen termux_step_pre_configure() { con
# el MISMO lookahead de 3 lineas (apertura + "(( _PATCH_VERSION == 0 )) &&
# return" + "local PATCH_NUM PATCHFILE"), asi que un sed generico inyectaria el
# fix en readline (que NO lo necesita: readline no compila mkbuiltins ni usa
# CCFLAGS_FOR_BUILD para su Makefile). Por eso esta fase va FUERA del while de
# la FASE 1/2/2b/2c (como la FASE 2d) con guard a nivel de archivo: el ancla
# '_MAIN_VERSION=5.3' es unico de packages/bash/build.sh@8ca9404 (git grep en
# 8ca9404: solo bash; readline usa _MAIN_VERSION=8.3) y el sed interno exige el
# lookahead "(( _PATCH_VERSION == 0 )) && return" propio de bash 5.x.
# El export CFLAGS va ANTES del "(( _PATCH_VERSION == 0 )) && return": bash 5.3
# trae _PATCH_VERSION=0, que hace early-return de pre_configure; si el fix
# quedara despues, nunca se ejecutaria. pre_configure corre con cwd=srcdir
# antes de configure (los Makefile.in ya existen en el tarball). Idempotente:
# tras la 1a pasada la linea 2 del pre_configure es "export CFLAGS=..." y el
# guard de archivo "! grep -qF" deja de matchear en una 2a pasada.
BASH53_BUILD_SH="$REPO_DIR/packages/bash/build.sh"
if [ -f "$BASH53_BUILD_SH" ] \
    && grep -qF '_MAIN_VERSION=5.3' "$BASH53_BUILD_SH" \
    && grep -qF 'termux_step_pre_configure() {' "$BASH53_BUILD_SH" \
    && ! grep -qF 'export CFLAGS="$CFLAGS -std=gnu89"' "$BASH53_BUILD_SH"; then
    sed -i \
        -e '/^termux_step_pre_configure() {$/{
N
/^termux_step_pre_configure() {\n[[:space:]]*(( _PATCH_VERSION == 0 )) && return/s@^termux_step_pre_configure() {\n@termux_step_pre_configure() {\nexport CFLAGS="$CFLAGS -std=gnu89"\nsed -i "/ -std=gnu89/! s|^CCFLAGS_FOR_BUILD *=|\& -std=gnu89|" Makefile.in builtins/Makefile.in\n@
P
D
}' \
        "$BASH53_BUILD_SH" || true
    echo "[normalize-legacy-builds] FASE 2e: bash 5.3 gnu89 inyectado en termux_step_pre_configure."
fi

# FASE 2d: util-linux 2.40.2 (commit 8ca9404, 2023) — fix colisión de
# schedutils/sched_attr.h con el sysroot del NDK r29 (API 24). Run CI
# 31353795462 fallo en el compile de util-linux (tras el autoreconf -fi de la
# FASE 2c, que SÍ completó) con:
#   schedutils/sched_attr.h:87:8: error: redefinition of 'sched_attr'
#     /sysroot/usr/include/linux/sched/types.h:12:8: note: previous definition
#   schedutils/sched_attr.h:108:12: error: static declaration of
#     'sched_setattr' follows non-static declaration
#     /sysroot/usr/include/sched.h:245:5: note: ... __INTRODUCED_IN(37)
#   (idem para sched_getattr)
# Causa raiz: el tarball de util-linux 2.40.2 trae su propio
# schedutils/sched_attr.h (struct sched_attr + wrappers estaticos
# sched_setattr/sched_getattr via syscall, para kernels viejos), pero el
# sysroot bionic del NDK r29 (API 24) AHORA declara esas mismas APIs en
# linux/sched/types.h y sched.h con __INTRODUCED_IN(37): el struct colisiona
# por redefinicion y las funciones estaticas siguen a una declaracion
# no-estatica. No se puede borrar el header (chrt.c lo incluye) ni desactivar
# solo el struct (uclampset.c usa los wrappers SIN guard #ifdef; master los
# mantiene). Master (de5ca479, packages/util-linux/schedutils-sched_attr.h.patch,
# aplicado sobre la MISMA util-linux 2.40.2) resuelve el bloqueo envolviendo el
# struct en "#ifndef __ANDROID__" (el sysroot ya lo define) y renombrando los
# wrappers a *_compat con "#define sched_setattr sched_setattr_compat" para que
# las llamadas de chrt/uclampset no colisionen con la declaracion de bionic ni
# linkeen contra el simbolo de libc introducido en API 37. Se VENDOREA ese
# patch byte-identico dentro del arbol del paquete (packages/util-linux/); el
# termux_step_patch_package del build system vendered lo aplica en el source
# extraido con "patch --batch -p1" (normaliza la cabecera "--- ../cache/..."
# a "--- ./..." automaticamente). No colisiona con los 13 patches historicos
# (toca solo schedutils/sched_attr.h) y se aplica ANTES del autoreconf -fi
# inyectado en FASE 2c (autoreconf no regenera headers planos). Guard de
# version: solo se escribe si el build.sh es util-linux 2.40.2@8ca9404
# (TERMUX_PKG_VERSION="2.40.2" + comentario prlimit unico); otros commits
# historicos con util-linux 2.32.1 (p.ej. e4f2135) NO reciben el patch (su
# sched_attr.h no colisiona y el patch no aplicaria). Idempotente: no escribe
# si el archivo ya existe (2a pasada = no-op).
UL_BUILD_SH="$REPO_DIR/packages/util-linux/build.sh"
if [ -f "$UL_BUILD_SH" ] \
    && grep -qF 'TERMUX_PKG_VERSION="2.40.2"' "$UL_BUILD_SH" \
    && grep -qF '#prlimit() is only available in 64-bit bionic.' "$UL_BUILD_SH" \
    && [ ! -f "$REPO_DIR/packages/util-linux/schedutils-sched_attr.h.patch" ]; then
    cat > "$REPO_DIR/packages/util-linux/schedutils-sched_attr.h.patch" <<'SCHED_ATTR_PATCH_EOF'
diff -u -r ../cache/util-linux-2.40.2/schedutils/sched_attr.h ./schedutils/sched_attr.h
--- ../cache/util-linux-2.40.2/schedutils/sched_attr.h	2024-01-31 10:02:15.742809948 +0000
+++ ./schedutils/sched_attr.h	2025-08-07 22:32:31.062558966 +0000
@@ -84,6 +84,7 @@
 #if defined (__linux__) && !defined(HAVE_SCHED_SETATTR) && defined(SYS_sched_setattr)
 # define HAVE_SCHED_SETATTR
 
+#ifndef __ANDROID__
 struct sched_attr {
 	uint32_t size;
 	uint32_t sched_policy;
@@ -104,16 +105,19 @@
 	uint32_t sched_util_min;
 	uint32_t sched_util_max;
 };
+#endif
 
-static int sched_setattr(pid_t pid, const struct sched_attr *attr, unsigned int flags)
+static int sched_setattr_compat(pid_t pid, const struct sched_attr *attr, unsigned int flags)
 {
 	return syscall(SYS_sched_setattr, pid, attr, flags);
 }
 
-static int sched_getattr(pid_t pid, struct sched_attr *attr, unsigned int size, unsigned int flags)
+static int sched_getattr_compat(pid_t pid, struct sched_attr *attr, unsigned int size, unsigned int flags)
 {
 	return syscall(SYS_sched_getattr, pid, attr, size, flags);
 }
+#define sched_setattr sched_setattr_compat
+#define sched_getattr sched_getattr_compat
 #endif
 
 /* the SCHED_DEADLINE is supported since Linux 3.14
SCHED_ATTR_PATCH_EOF
    echo "[normalize-legacy-builds] Vendored util-linux schedutils-sched_attr.h.patch (fix sched_attr vs NDK r29)."
fi

echo "=== [normalize-legacy-builds] Done. build.sh normalizados. ==="
