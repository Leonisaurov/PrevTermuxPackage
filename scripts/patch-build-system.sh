#!/usr/bin/env bash
# patch-build-system.sh — Adapta el build system moderno de termux-packages
# para compilar commits antiguos (2018-2023).
# Idempotente: puede ejecutarse múltiples veces sin efectos secundarios.
set -euo pipefail

REPO_DIR="${1:-$PWD}"  # Directorio del checkout de termux-packages
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/../patches"

echo "=== Aplicando parches al build system ==="

# 1. Parche buildorder.py (-dev → padre)
if ! grep -q "re.sub('-dev\$', '', dependency_value)" "$REPO_DIR/scripts/buildorder.py"; then
    echo "[1/17] Aplicando parche buildorder: -dev → padre"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/001-buildorder-dev-mapping.patch"
else
    echo "[1/17] Parche buildorder ya aplicado, saltando"
fi

# 2. Parche extract_dep_info.sh (normalización -dev)
if ! grep -q 'PKG=${PKG/-dev/}' "$REPO_DIR/scripts/build/termux_extract_dep_info.sh"; then
    echo "[2/17] Aplicando parche extract_dep_info: normalización -dev"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/002-extract-dep-info-dev.patch"
else
    echo "[2/17] Parche extract_dep_info ya aplicado, saltando"
fi

# 3. Parche setup_variables.sh (source de python/libllvm tolerante)
if ! grep -qF '# Extract _MAJOR_VERSION without sourcing' "$REPO_DIR/scripts/build/termux_step_setup_variables.sh"; then
    echo "[3/17] Aplicando parche setup_variables: source tolerante"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/003-setup-vars-fallback.patch"
else
    echo "[3/17] Parche setup_variables ya aplicado, saltando"
fi

# 4. Parche make_install.sh (setup rust automático para build.sh viejos)
if ! grep -q "Legacy compatibility: old build.sh files don't call termux_setup_rust" "$REPO_DIR/scripts/build/termux_step_make_install.sh"; then
    echo "[4/17] Aplicando parche make_install: termux_setup_rust automático"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/004-make-install-rust.patch"
else
    echo "[4/17] Parche make_install ya aplicado, saltando"
fi

# 5. Parche termux_setup_rust.sh (extraccion con grep + fallback)
if ! grep -q "Legacy compatibility: extract version with grep" "$REPO_DIR/scripts/build/setup/termux_setup_rust.sh"; then
    echo "[5/17] Aplicando parche setup_rust: extraccion con grep + fallback"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/005-termux-setup-rust.patch"
else
    echo "[5/17] Parche setup_rust ya aplicado, saltando"
fi

# 6. Parche start_build.sh (BUILD_IN_SRC acepta yes/true)
if ! grep -q 'Legacy compatibility: build.sh files from 2018 use "yes" instead of "true"' "$REPO_DIR/scripts/build/termux_step_start_build.sh"; then
    echo "[6/17] Aplicando parche start_build: BUILD_IN_SRC tolerante (yes/true)"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/006-start-build-build-in-src.patch"
else
    echo "[6/17] Parche start_build ya aplicado, saltando"
fi

# 7. Parche patch_package.sh (normalizar rutas ../pkg-ver/ en patches de 2018)
# Los patches viejos tienen headers "--- ../bat-0.7.1/Cargo.toml"; BusyBox patch
# falla buscando "bat-0.7.1/Cargo.toml" tras la extracción plana. GNU patch lo
# resuelve por fallback, pero BusyBox no, así que normalizamos antes de aplicar.
if ! grep -qF 'DEBUG: PATCH NORMALIZADO PARA' "$REPO_DIR/scripts/build/termux_step_patch_package.sh"; then
    echo "[7/17] Aplicando parche patch_package: normalizar rutas de patches legacy"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/007-patch-package-normalize-paths.patch"
else
    echo "[7/17] Parche patch_package ya aplicado, saltando"
fi

# 8. Parche build-package.sh (debug post-patch con marcadores)
# Patch 008 inserta marcadores "MARKER: >>>/<paso>" alrededor de los pasos del
# build para identificar cuál falla con exit 2 después de termux_step_patch_package.
if ! grep -qF 'MARKER: >>> patch_package' "$REPO_DIR/build-package.sh"; then
    echo "[8/17] Aplicando parche build-package: marcadores post-patch"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/008-post-patch-debug.patch"
else
    echo "[8/17] Parche build-package ya aplicado, saltando"
fi

# 9. Parche make_install.sh (debug: capturar stderr REAL del cargo install)
# El run 30615771833 confirmó que el exit 2 ocurre en termux_step_make_install
# sin output. El patch 009 envuelve el cargo install con "2>&1 | tee + PIPESTATUS"
# para que el stderr real quede en ${TERMUX_PKG_TMPDIR:-$TMPDIR}/cargo-install.log
# y, si falla, se impriman las últimas 40 líneas antes de continuar (el fallo natural sigue).
if ! grep -qF 'DEBUG-MI: Cargo.toml detectado' "$REPO_DIR/scripts/build/termux_step_make_install.sh"; then
    echo "[9/17] Aplicando parche make_install: debug stderr de cargo install"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/009-make-install-debug.patch"
else
    echo "[9/17] Parche make_install debug ya aplicado, saltando"
fi

# 10. Normalizar variables legacy en TODOS los build.sh (idempotente)
echo "[10/17] Normalizando variables legacy en build.sh..."
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
    # 'line_error'; expected 0, have 3". Se fuerza -std=gnu89 en CFLAGS (en
    # gnu89 los prototipos vacios siguen siendo K&R). Regla idempotente: tras la
    # 1a pasada la linea CFLAGS ya sigue a la ancla y el guard deja de matchear.
    # NOTA: usa N + guard de lookahead, no un s/// simple (que no seria
    # idempotente porque la ancla sola seguiria matcheando en una 2a pasada).
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
        -e '/^TERMUX_PKG_RM_AFTER_INSTALL="share\/man\/man1\/bashbug\.1 bin\/bashbug"$/{
N
/^TERMUX_PKG_RM_AFTER_INSTALL="share\/man\/man1\/bashbug\.1 bin\/bashbug"\nCFLAGS+=" -std=gnu89"$/!s|^TERMUX_PKG_RM_AFTER_INSTALL="share/man/man1/bashbug\.1 bin/bashbug"\n|TERMUX_PKG_RM_AFTER_INSTALL="share/man/man1/bashbug\.1 bin/bashbug"\nCFLAGS+=" -std=gnu89"\n|
}' \
        "$f"
done || true

# 11. Parche build-package.sh (PREFIX versionado via TERMUX_PREFIX_OVERRIDE)
# El patch 010 inserta en build-package.sh un bloque que, si la variable
# TERMUX_PREFIX_OVERRIDE está definida, re-deriva TERMUX__PREFIX y sub-variables
# hacia un prefijo versionado (después de la validación de properties.sh y del
# source de termux-setup-package-manager, antes de termux_step_setup_variables),
# y añade un post-procesado que mapea los shebangs/maps proot de vuelta al PREFIX
# real (/data/data/com.termux/files/usr).
if ! grep -qF 'Legacy compatibility: subversioned builds allow TERMUX_PREFIX_OVERRIDE' "$REPO_DIR/build-package.sh"; then
    echo "[11/17] Aplicando parche build-package: prefix versionado (TERMUX_PREFIX_OVERRIDE)"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/010-prefix-override.patch"
else
    echo "[11/17] Parche build-package prefix versionado ya aplicado, saltando"
fi

# 12. Parche make_install.sh (quitar --no-track del cargo install)
# El cargo de toolchains viejas (pre-1.41, anteriores a cargo 1.41.0; --no-track estabilizado el 2020-01-30, usadas por build.sh de 2018-2023)
# no soporta --no-track y aborta el install con "error: unexpected argument".
if ! grep -qF 'Legacy compatibility: remove --no-track for old cargo toolchains' "$REPO_DIR/scripts/build/termux_step_make_install.sh"; then
    echo "[12/17] Aplicando parche make_install: quitar --no-track del cargo install"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/011-remove-cargo-no-track.patch"
else
    echo "[12/17] Parche make_install --no-track ya aplicado, saltando"
fi

# 13. Parche install_license.sh (TERMUX_PKG_LICENSE* tolerantes bajo set -u)
# Si un build.sh viejo no define TERMUX_PKG_LICENSE o TERMUX_PKG_LICENSE_FILE,
# la funcion explotaba con "unbound variable" al ejecutarse bajo set -u.
if ! grep -qF ': "${TERMUX_PKG_LICENSE_FILE:=}"' "$REPO_DIR/scripts/build/termux_step_install_license.sh"; then
    echo "[13/17] Aplicando parche install_license: TERMUX_PKG_LICENSE* tolerantes bajo set -u"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/012-license-optional.patch"
else
    echo "[13/17] Parche install_license ya aplicado, saltando"
fi

# 14. Parche toolchain (conservar zlib.h del NDK)
# El toolchain moderno de termux borra zlib.h del sysroot del NDK; los paquetes
# viejos (2018) sin dep zlib necesitan ese header (p.ej. libgit2-sys de bat).
if ! grep -qF 'Legacy compatibility: keep NDK zlib.h for old packages without zlib dep' "$REPO_DIR/scripts/build/toolchain/termux_setup_toolchain_23c.sh" || \
   ! grep -qF 'Legacy compatibility: keep NDK zlib.h for old packages without zlib dep' "$REPO_DIR/scripts/build/toolchain/termux_setup_toolchain_29.sh"; then
    echo "[14/17] Aplicando parche toolchain: conservar zlib.h del NDK"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/013-toolchain-keep-zlib.patch"
else
    echo "[14/17] Parche toolchain zlib.h ya aplicado, saltando"
fi

# 15. Parche toolchain (desactivar outline-atomics / LSE para API level bajo)
# clang del NDK (toolchains 23c/29) habilita outline-atomics por defecto en
# aarch64, generando calls a helpers __aarch64_* que bionic con API 24 no
# provee ("undefined symbol: __aarch64_ldadd8_acq_rel", p.ej. libgit2-sys de
# bat al enlazar). -mno-outline-atomics solo se añade para TERMUX_ARCH=aarch64.
if ! grep -qF 'Legacy compatibility: disable outline-atomics (LSE) for old packages on API 24' "$REPO_DIR/scripts/build/toolchain/termux_setup_toolchain_23c.sh" || \
   ! grep -qF 'Legacy compatibility: disable outline-atomics (LSE) for old packages on API 24' "$REPO_DIR/scripts/build/toolchain/termux_setup_toolchain_29.sh"; then
    echo "[15/17] Aplicando parche toolchain: -mno-outline-atomics (LSE off)"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/014-toolchain-no-outline-atomics.patch"
else
    echo "[15/17] Parche toolchain outline-atomics ya aplicado, saltando"
fi

# 16. Parche make_install.sh (fail fast si cargo install falla)
# El patch 009 envuelve el cargo install con "2>&1 | tee + PIPESTATUS" para
# capturar el stderr real, pero su bloque || {...} no abortaba el build: el
# pipeline empaquetaba un prefix incompleto y el CI reportaba SUCCESS con
# paquete vacío. Este parche hace que un fallo real de cargo install
# (PIPESTATUS[0] != 0) termine el build con termux_error_exit.
if ! grep -qF 'Legacy compatibility: fail fast — propagate the real cargo install' "$REPO_DIR/scripts/build/termux_step_make_install.sh"; then
    echo "[16/17] Aplicando parche make_install: fail fast en cargo install"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/015-make-install-fail-fast.patch"
else
    echo "[16/17] Parche make_install fail fast ya aplicado, saltando"
fi

# 17. Parche toolchain (RUSTFLAGS de cargo alineados a páginas de 16KB)
# Los binarios Rust viejos se enlazan con max-page-size por defecto del NDK
# (4KB); en dispositivos con páginas de 16KB el loader los rechaza. La flag
# -C link-arg=-Wl,-z,max-page-size=16384 (solo target aarch64) alinea los
# segmentos a 16KB y es compatible con 4K y 16K.
if ! grep -qF 'Legacy compatibility: align Rust binaries to 16KB pages' "$REPO_DIR/scripts/build/toolchain/termux_setup_toolchain_23c.sh" || \
   ! grep -qF 'Legacy compatibility: align Rust binaries to 16KB pages' "$REPO_DIR/scripts/build/toolchain/termux_setup_toolchain_29.sh"; then
    echo "[17/17] Aplicando parche toolchain: RUSTFLAGS a páginas de 16KB"
    patch -p1 -d "$REPO_DIR" < "$PATCHES_DIR/016-rustflags-max-page-size.patch"
else
    echo "[17/17] Parche toolchain páginas 16KB ya aplicado, saltando"
fi

echo "=== Parches aplicados correctamente ==="
