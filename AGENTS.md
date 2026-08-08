# AGENTS.md — PrevTermuxPackage

> Guía compacta para agentes: estado verificado, reglas críticas de entorno, lecciones duras y comandos. Repo en español; actualizar este archivo al resolver bloques.

## Propósito y estado actual

Compila **versiones históricas** de paquetes de `termux/termux-packages` (commits 2018–2023) usando el **build system MODERNO de master** (sparse checkout de `scripts/` desde master en `gha-prepare.sh`), con **16 parches de compatibilidad** (`patches/001..016`) + un paso de normalización legacy en `scripts/patch-build-system.sh` (bloque 10: sed idempotente sobre todos los `build.sh`). El artifact subversioned usa un **prefix versionado** `~/.local/opt/<pkg>-<ver>` (`TERMUX_PREFIX_OVERRIDE`, parche 010) para instalar varias versiones sin colisión. Workflow único: `.github/workflows/build-old-package.yml` (`workflow_dispatch`; inputs `package_name`, `git_ref`, `architecture`, `format`, `build_mode`, `heavy`; 2 jobs independientes: `build-normal` y `build-subversioned`). `scripts/gha-build.sh` corre el build en Docker (`run-docker.sh`) siempre con `--format debian` y convierte `.deb`→`.pkg.tar.xz` con `scripts/deb2pkg.sh`. `scripts/lib/discover.sh` descubre versiones históricas vía `git log -G` sobre un clon bare (`~/.cache/prev-termux/repo/termux-packages.git`).

**Estado VERIFICADO hoy:**
- `bat@e4f2135` **compila**; sus releases `bat-0.7.1-e4f2135` y `-subversioned` fueron corregidos con el binario real.
- La build de `bash@e4f2135` (Fase 2) **completó el fix gnu89**: la cadena de deps completa pasa (command-not-found, libandroid-support, ncurses 6.1.20180707, readline 7.0.5, termux-tools) y el fallo en `make` de `builtins/mkbuiltins.c` (prototipos K&R `()` vs C23) queda cubierto. El sed inyectado en `termux_step_pre_configure` ahora parchea `Makefile.in` **y** `builtins/Makefile.in` (sub-make que compila `mkbuiltins.o` con su propio `CCFLAGS_FOR_BUILD`; bloque 10 FASE 2 de patch-build-system.sh). El commit `f4bcd53` era el fix parcial (solo `Makefile.in` raíz; `-std=gnu89` vía `export CFLAGS` + `CCFLAGS_FOR_BUILD *=`). Cambio verificado estáticamente, listo para commit; **validación en CI en curso**.
- **SIGUIENTE PASO**: validar el fix en CI (build de `bash@e4f2135` con `gita notify`) y cerrar la deuda pendiente: limpiar debug de parches 007-009 y pruebas de regresión (bat/which/zig).

## Reglas de entorno CRÍTICAS

Violarlas = desperdicio/riesgo de sesión.

- **NO compilar/ejecutar builds/cargo/gcc en local Termux** (riesgo OOM que mata la sesión). Verificación SOLO estática: `patch --dry-run --fuzz=0`, `bash -n`, grep, `git --git-dir=<bare> show`, sed/diff sobre copias en `$TMPDIR`. La validación real de ejecución se hace en CI (GitHub Actions).
- Monitorear CI con `gita notify build-old-package.yml` (bloquea hasta el final; **NO** polling con `gh run view`; **NO** `--progress`; **NO** envolver en timeout). Logs con `--tee`.
- `gh release delete-asset` está **bloqueado por permisos** → usar `gh release upload --clobber` para reemplazar assets.
- El workflow **NO actualiza releases existentes** ("Release already exists. Skipping") → corregir releases manualmente.
- Usar `$TMPDIR` (nunca `/tmp`).

## Lecciones duras (whack-a-mole)

Evitar re-descubrir; cada ítem ya costó un fallo de CI.

- `set -euo pipefail` + pipelines `grep|head|tr` sobre archivos inexistentes abortan **SILENCIOSAMENTE** (exit 2) si no llevan `|| true` (parches 003/005).
- `cargo install --no-track` no existe en cargo < 1.41 (parche 011 lo quita).
- `TERMUX_PKG_LICENSE`/`TERMUX_PKG_LICENSE_FILE` usadas desnudas bajo `set -u` → parche 012 (defaults `:=` + early-return si no hay licencia).
- El toolchain moderno de termux **BORRA zlib.h del sysroot del NDK** (parche 013 lo conserva); clang NDK emite outline-atomics LSE por defecto en aarch64 → `__aarch64_*` undefined en API 24 (parche 014 `-mno-outline-atomics`); alinear binarios Rust a 16KB pages con `-Wl,-z,max-page-size=16384` en RUSTFLAGS (parche 016).
- URLs de source de 2018 muertas: `dl.bintray.com/termux/upstream/` (bintray cerrado 2021; termux/distfiles NO tiene todo; Wayback sin capturas) → para ncurses-6.1-20180707 usar `ThomasDickey/ncurses-snapshots` git-archive (checksum RECOMPUTADO); `fossies.org` devuelve 410/401 → usar mirror byte-idéntico de Debian pool (`deb.debian.org/.../rxvt-unicode_9.22.orig.tar.bz2`, mismo hash). Sustituciones en el bloque 10 de patch-build-system.sh, junto a los renames legacy (BLACKLISTED_ARCHES→EXCLUDED_ARCHES, DEBDIR→OUTPUT_DIR, MAKE_PROCESSES→PKG_MAKE_PROCESSES, NO_DEVELSPLIT→NO_STATICSPLIT, `=yes`→`=true`/`=no`→`=false`).
- `PKG_CONFIG_LIBDIR` es una **LISTA separada por `:`** desde el commit 3f1be51372 (nov-2022); ncurses 2018 pasaba esa lista literal a `--with-pkg-config-libdir` y creaba un dir con `:` → fijar `--with-pkg-config-libdir=$TERMUX_PREFIX/lib/pkgconfig` (ruta única, como master).
- `TERMUX_PKG_EXTRA_MAKE_ARGS` se expande **SIN comillas** (`make ${VAR}`) → valores con espacios rompen make (field splitting; backslash-escape NO funciona en valores expandidos). No usar para flags con espacios; mejor parchear `Makefile.in` directamente.
- `CFLAGS` a nivel top-level del `build.sh` se **pierde** (clobbered por el setup del toolchain) → exportar CFLAGS dentro de `termux_step_pre_configure`.
- Los build-tools de bash 4.4 (mkbuiltins, mksyntax, mksignames) se compilan con el **gcc del HOST** usando `CCFLAGS_FOR_BUILD` (no CFLAGS); `mkbuiltins.c` se compila en el sub-make `builtins/` con su propio `builtins/Makefile.in`.
- Código C de 2018 (prototipos K&R `f()`) falla con compiladores C23 ("too many arguments") → `-std=gnu89`.
- `termux-am` (Gradle 4.1) no compila con Java 17 del runner → eliminar la línea de dep completa con `sed /^TERMUX_PKG_DEPENDS="termux-am"$/d`; **NO** vaciarla (`TERMUX_PKG_DEPENDS=""` rompe buildorder: dep `''` no filtrada → "non-existing package ''").
- GNU patch: hunks con contexto desactualizado requieren fuzz=2; regenerar contra el estado real (p.ej. post-004) para `--fuzz=0` (parches 002/009).
- El bloque 10 es un `sed -i` grande que evolucionó a **DOS fases** (FASE 1 normalización global línea-a-línea + FASE 2 inserciones con lookahead `N`/guard/`P`/`D`) para que la línea siguiente a un ancla no pierda la normalización; los guards usan anclas **ÚNICAS** del build.sh objetivo (verificar con `git grep` antes de anclar).

## Comandos clave

- Lanzar build en CI: `gh workflow run build-old-package.yml --ref main -f package_name=<pkg> -f git_ref=<sha-termux-packages> -f architecture=aarch64 -f format=debian -f build_mode=fast` y luego `gita notify --tee $TMPDIR/gita-run.log build-old-package.yml`.
- Verificar parches: `patch -p1 --dry-run --fuzz=0 -d <árbol> < patches/0XX-*.patch`; `bash -n <script>`.
- Leer blobs del commit viejo: `git --git-dir=$HOME/.cache/prev-termux/repo/termux-packages.git show <sha>:<path>`.
- Flujo de trabajo de la sesión: **fixer → code-reviewer** (barrera sin CRITICAL/MAJOR) → **git-workflow** (commit+push+CI con gita) → **indexar hallazgos** en el knowledge graph (MCP memory).

## Convenciones del repo

- Commits con prefijos `fix:`, `docs:`, `debug:`; mensajes en español/inglés mixto (estilo del log actual: `fix: bash 4.4 gnu89 via parche Makefile.in en pre_configure`).
- Parches con marcas `# Legacy compatibility:` para idempotencia (`grep -qF` en patch-build-system.sh antes de aplicar).
- Scripts con `set -euo pipefail`; errores a `stderr`; idempotencia por verificación previa con grep.
