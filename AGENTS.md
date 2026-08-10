# AGENTS.md — PrevTermuxPackage

> Guía compacta para agentes: estado verificado, reglas críticas de entorno, lecciones duras y comandos. Repo en español; actualizar este archivo al resolver bloques.

## Propósito y estado actual

Compila **versiones históricas** de paquetes de `termux/termux-packages` (commits 2018–2023) usando un **build system PROPIO vendered** en `build-system/`: árbol byte-idéntico al upstream `de5ca479` de termux-packages master + **~19 implementaciones directas** con marcador `# Legacy compatibility:` (16 parches migrados 001–016, blindaje LLVM, hook del store, shim automake-N.N). Metadata en `REVISION`, `FORK.md` y `.fork-files`. El runtime **YA NO descarga master ni aplica parches**: `scripts/gha-prepare.sh` copia el árbol vendered al árbol del paquete y llama a `scripts/normalize-legacy-builds.sh` (FASE 1 renames/URLs muertas/checksums; FASE 2 gnu89 bash; FASE 2b/2c `autoreconf -fi` tar/util-linux). `patches/` y `patch-build-system.sh` se conservan como **REFERENCIA** (no se ejecutan).

**PrevTermux Store**: pool de paquetes reutilizables en GitHub Releases por arquitectura (`prev-termux-pool-<arch>`) con `manifest.json`. `scripts/store-lib.sh` (hook en `termux_step_get_dependencies.sh`: reutiliza deps ya compiladas, también en `-F`/subversioned; caché del manifest por run), `scripts/store-publish.sh` (deps solo `.deb`; paquetes objetivo `.deb` + `.pkg.tar.xz`), input `use_store`, caché CI (`actions/cache` con clave por modo).

**CLI `prev-termux` rediseñado** (commits `5545998`, `8c85754`): `build` (detecta run exitoso/en curso, pregunta antes de relanzar, `--subversioned` → `jobs=subversioned`), `subinstall` (descarga de GitHub: lista TODAS las versiones con fzf, luego elige subversion/normal), `install` (nuevo; paquetes normales; detecta pacman/apt sin `-y`), `switch` (nuevo; TUI fzf entre versiones subversionadas, marca `(actual)`, symlinks a `$PREFIX/bin`), `fetch` (descarga del pool del store), `list`, `status`, `cache`, `help`. fzf opcional (fallback menú numerado).

**Workflow GHA** (`.github/workflows/build-old-package.yml`, `workflow_dispatch`): inputs `package_name`, `git_ref`, `architecture`, `format`, `build_mode`, `heavy`, `use_store`, `jobs` (`both|normal|subversioned`). 2 jobs con `timeout-minutes: 600`; serialización del pool con `needs` + `success()` (commit `a11a65b`).

**Estado CI VERIFICADO hoy:**
- `which@1fcb6e8` ✅, `bash@e4f2135` ✅, `tar@8ca9404` ✅.
- **`zig` 0.15.2 y 0.16.0 subversionado VERDE** (runs `31303490256` / `31303490320`; `jobs=subversioned`, `heavy=true`). `TERMUX_PREFIX_OVERRIDE` re-deriva el prefix ANTES de sourcear el `build.sh` → el wrapper proot (0.15.2) y los diffs `@TERMUX_PREFIX@` (0.16.0) quedan versionados sin parches manuales.
- **Pendiente**: `bash@8ca9404` (bash 5.3; FASE 2c util-linux commiteada en `ed86935` → relanzar CI) y `bat@2f2adec` (regresión, depende de bash).
- **SIGUIENTE PASO**: relanzar CI de `bash@8ca9404` (`gita notify`) para desbloquear `bat@2f2adec`; cerrar deuda: limpiar debug de parches 007–009 y pruebas de regresión (bat/which/zig).

## Reglas de entorno CRÍTICAS

Violarlas = desperdicio/riesgo de sesión.

- **NO compilar/ejecutar builds/cargo/gcc en local Termux** (riesgo OOM que mata la sesión). Verificación SOLO estática: `patch --dry-run --fuzz=0`, `bash -n`, grep, `git --git-dir=<bare> show`, sed/diff sobre copias en `$TMPDIR`. La validación real de ejecución se hace en CI (GitHub Actions).
- Monitorear CI con `gita notify build-old-package.yml` (bloquea hasta el final; **NO** polling con `gh run view`; **NO** `--progress`; **NO** envolver en timeout). Logs con `--tee`.
- `gh release delete-asset` está **bloqueado por permisos** → usar `gh release upload --clobber` para reemplazar assets.
- El workflow **NO actualiza releases existentes** ("Release already exists. Skipping") → corregir releases manualmente.
- Usar `$TMPDIR` (nunca `/tmp`).
- Tope de **360 min por job en repositorios públicos** de GHA: builds largos (zig ~280 min) necesitan `heavy=true` (ZRAM 16GB + free disk) y margen suficiente.

## Lecciones duras (whack-a-mole)

Evitar re-descubrir; cada ítem ya costó un fallo de CI.

- `set -euo pipefail` + pipelines `grep|head|tr` sobre archivos inexistentes abortan **SILENCIOSAMENTE** (exit 2) si no llevan `|| true` (parches 003/005).
- `cargo install --no-track` no existe en cargo < 1.41 (parche 011 lo quita).
- `TERMUX_PKG_LICENSE`/`TERMUX_PKG_LICENSE_FILE` usadas desnudas bajo `set -u` → parche 012 (defaults `:=` + early-return si no hay licencia).
- El toolchain moderno de termux **BORRA zlib.h del sysroot del NDK** (parche 013 lo conserva); clang NDK emite outline-atomics LSE por defecto en aarch64 → `__aarch64_*` undefined en API 24 (parche 014 `-mno-outline-atomics`); alinear binarios Rust a 16KB pages con `-Wl,-z,max-page-size=16384` en RUSTFLAGS (parche 016).
- URLs de source de 2018 muertas: `dl.bintray.com/termux/upstream/` (bintray cerrado 2021; Wayback sin capturas) → para ncurses-6.1-20180707 usar `ThomasDickey/ncurses-snapshots` git-archive (checksum RECOMPUTADO); `fossies.org` devuelve 410/401 → mirror byte-idéntico de Debian pool (`deb.debian.org/.../rxvt-unicode_9.22.orig.tar.bz2`, mismo hash). Sustituciones en la **FASE 1 de `normalize-legacy-builds.sh`**, junto a los renames legacy (BLACKLISTED_ARCHES→EXCLUDED_ARCHES, DEBDIR→OUTPUT_DIR, MAKE_PROCESSES→PKG_MAKE_PROCESSES, NO_DEVELSPLIT→NO_STATICSPLIT, `=yes`→`=true`/`=no`→`=false`).
- `PKG_CONFIG_LIBDIR` es una **LISTA separada por `:`** desde el commit 3f1be51372 (nov-2022); ncurses 2018 pasaba esa lista literal a `--with-pkg-config-libdir` y creaba un dir con `:` → fijar `--with-pkg-config-libdir=$TERMUX_PREFIX/lib/pkgconfig` (ruta única, como master).
- `TERMUX_PKG_EXTRA_MAKE_ARGS` se expande **SIN comillas** (`make ${VAR}`) → valores con espacios rompen make (field splitting; backslash-escape NO funciona en valores expandidos). No usar para flags con espacios; mejor parchear `Makefile.in` directamente.
- `CFLAGS` a nivel top-level del `build.sh` se **pierde** (clobbered por el setup del toolchain) → exportar CFLAGS dentro de `termux_step_pre_configure`.
- Los build-tools de bash 4.4 (mkbuiltins, mksyntax, mksignames) se compilan con el **gcc del HOST** usando `CCFLAGS_FOR_BUILD` (no CFLAGS); `mkbuiltins.c` se compila en el sub-make `builtins/` con su propio `builtins/Makefile.in`.
- Código C de 2018 (prototipos K&R `f()`) falla con compiladores C23 ("too many arguments") → `-std=gnu89`.
- `termux-am` (Gradle 4.1) no compila con Java 17 del runner → eliminar el token en las **listas DEPENDS** (`sed` de tokens, no solo dep única; commit `ac6ae52`); **NO** vaciarla (`TERMUX_PKG_DEPENDS=""` rompe buildorder: dep `''` no filtrada → "non-existing package ''").
- GNU patch: hunks con contexto desactualizado requieren fuzz=2; regenerar contra el estado real (p.ej. post-004) para `--fuzz=0` (parches 002/009).
- La normalización legacy es un `sed -i` grande en **varias fases** (FASE 1 global línea-a-línea + FASE 2 inserciones con lookahead `N`/guard/`P`/`D` + FASE 2b/2c `autoreconf -fi` por paquete) para que la línea siguiente a un ancla no pierda la normalización; los guards usan anclas **ÚNICAS** del build.sh objetivo (verificar con `git grep` antes de anclar).
- **Colisión de assets normal/subversioned**: `deb2pkg.sh` nombra **igual** ambos artifacts (`pkg-ver-rev-arch`); solo el tag distingue (`--skip-existing` dejaba la normal antigua) → descargar por el **tag correcto**.
- **GHA `needs` + skip propagado**: en modo `jobs=subversioned`, el job normal queda `skipped` y el skip se propaga al publicador del pool → anular con `success()` en la condición del job subversioned (commit `a11a65b`).
- **Tope 360 min en repo público de GHA**: zig subversioned ~280 min → margen ~80; usar `heavy=true` (ZRAM 16GB + free disk) para builds largos.
- **AppArmor del build system**: `deny /home/builder/termux-packages/[^o]**` deniega escritura a todo lo que no empiece por `o` → `.store-cache` necesita excepción `[^o.]` + `allow .store-cache/** rw` (commit `89861d4`).
- **Checksums recomputados**: codeberg regeneró el gzip de foot 1.22.3/1.25.0 (contenido byte-idéntico, hash distinto) → recomputar (commit `8f645d5`).
- **Tarballs históricos con `Makefile.in` de automake-N.N (1.16)**: el remake espurio del sub-make invoca `automake-1.16` que no existe en el runner → shim genérico `automake-N.N` → `automake` en `setup_variables` (commit `a750096`) + `autoreconf -fi` por paquete (tar = FASE 2b, util-linux = FASE 2c, mismatch automake 1.18.1 vs 1.16.5).

## Comandos clave

- Lanzar build en CI: `gh workflow run build-old-package.yml --ref main -f package_name=<pkg> -f git_ref=<sha-termux-packages> -f architecture=aarch64 -f format=debian -f build_mode=fast [-f jobs=subversioned] [-f use_store=true] [-f heavy=true]` y luego `gita notify --tee $TMPDIR/gita-run.log build-old-package.yml`.
- CLI local: `./scripts/prev-termux build|subinstall|install|switch|fetch|list|status|cache|help` (fzf opcional; fallback menú numerado).
- Verificar parches estáticamente: `patch -p1 --dry-run --fuzz=0 -d <árbol> < patches/0XX-*.patch`; `bash -n <script>`.
- Leer blobs del commit viejo: `git --git-dir=$HOME/.cache/prev-termux/repo/termux-packages.git show <sha>:<path>`.
- Revisar implementaciones vendered: `git grep -l 'Legacy compatibility:' build-system/`; metadata en `build-system/REVISION` y `build-system/FORK.md`.
- Flujo de trabajo de la sesión: **fixer → code-reviewer** (barrera sin CRITICAL/MAJOR) → **git-workflow** (commit+push+CI con gita) → **indexar hallazgos** en el knowledge graph (MCP memory).

## Convenciones del repo

- Commits con prefijos `fix:`, `docs:`, `debug:`, `feat:`, `refactor:`, `vendor:`; mensajes en español/inglés mixto (estilo del log actual: `feat: rediseño CLI prev-termux - build detecta runs, subinstall descarga de GitHub, install y switch nuevos`).
- Implementaciones vendered con marcas `# Legacy compatibility:` para idempotencia (`grep -qF` antes de aplicar/copiar).
- Scripts con `set -euo pipefail`; errores a `stderr`; idempotencia por verificación previa con grep.
- `build-system/` es byte-idéntico a upstream salvo los archivos listados en `.fork-files` (abort-on-conflict al actualizar upstream).
