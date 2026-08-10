# Style Guide: PrevTermuxPackage

> Guía de convenciones de la codebase — generada desde la investigación del código real (2026-08-09).

## Estructura del proyecto

```
PrevTermuxPackage/
├── .github/workflows/
│   └── build-old-package.yml     # Workflow GHA (workflow_dispatch) — build en la nube
├── build-system/                 # Build system PROPIO VENDERED (upstream de5ca479 + ~19 impl.)
│   ├── REVISION                  # SHA upstream, URL, fecha de import
│   ├── FORK.md                   # Tabla de implementaciones directas (# Legacy compatibility:)
│   └── .fork-files               # Archivos con implementaciones (abort-on-conflict)
├── docs/
│   ├── PROGRESS.md               # Estado/progreso, whack-a-mole del build system
│   └── build-system-internals.md # Catálogo de dependencias del build system + hallazgos de compatibilidad
├── patches/                      # REFERENCIA: 16 parches migrados 001–016 (ya NO se aplican)
├── scripts/
│   ├── prev-termux               # CLI principal (entrypoint; build/subinstall/install/switch/fetch/...)
│   ├── gha-prepare.sh            # Copia build-system/ vendered + store-lib + normalize-legacy-builds.sh
│   ├── gha-build.sh              # Build compartido (--format debian, --store, --subversioned, heavy)
│   ├── normalize-legacy-builds.sh# Normalización de build.sh históricos (FASE 1/2/2b/2c)
│   ├── deb2pkg.sh                # Convierte .deb → .pkg.tar.xz (pacman)
│   ├── store-lib.sh              # Hook PrevTermux Store (reutiliza deps del pool)
│   ├── store-publish.sh          # Publica deps/objetivos al pool (prev-termux-pool-<arch>)
│   ├── patch-build-system.sh     # REFERENCIA (aplicaba parches 001–016; ya NO se ejecuta)
│   └── lib/
│       ├── discover.sh           # Librería: descubrimiento de versiones + caché persistente
│       └── version-extract.sh    # Extracción canónica de TERMUX_PKG_VERSION
├── output/                       # Artifacts .pkg.tar.xz descargados (gitignored)
├── .cache-test/                  # Pruebas del sistema de caché (gitignored)
├── README.md
├── LICENSE                       # MIT
└── .gitignore                    # output/, .cache-test/, *.log, IDE
```

## Convenciones de código

- **Lenguaje**: Bash (scripts). `discover.sh` usa shebang `#!/data/data/com.termux/files/usr/bin/bash` (Termux); `prev-termux` y `patch-build-system.sh` usan `#!/usr/bin/env bash`.
- **Strict mode**: `set -euo pipefail` al inicio de los scripts ejecutables.
- **Nombrado**:
  - Funciones CLI: prefijo `cmd_` (`cmd_list`, `cmd_build`, `cmd_subinstall`, `cmd_status`, `cmd_cache`, `cmd_help`).
  - Funciones de librería: snake_case descriptivo (`discover_versions`, `extract_version`, `fzf_select`, `get_cached_repo`, `resolve_version_from_buildsh`, `clear_version_cache`, `cache_stats`).
  - Variables de entorno configurables: prefijo `PREV_TERMUX_` (`PREV_TERMUX_CACHE_DIR`, `PREV_TERMUX_CACHE_TTL`, `PREV_TERMUX_INSTALL_DIR`, `PREV_TERMUX_BIN_DIR`, `PREV_TERMUX_WORKFLOW_REF`, `PREV_TERMUX_REPO_FETCH_INTERVAL`) y `TERMUX_PACKAGES_REPO`.
- **Logging**: helpers con color ANSI — `info()` azul, `ok()` verde, `warn()` amarillo, `err()`/`die()` rojo. Colores definidos como `readonly RED/GREEN/YELLOW/BLUE/BOLD/NC`.
- **Layout de funciones**: comentario `# ─── nombre ───` como separador; cada función documenta Uso/Output/Retorno en el header.
- **Idempotencia**: los patches se verifican con `grep` antes de aplicar (`if ! grep -q ...; then patch; else skip`). El script `patch-build-system.sh` puede ejecutarse N veces.
- **Mensajes de error**: en `stderr` (`>&2`), con `die` para abortar. Salidas de error tipadas (0, 1, 2, 3, 10 según la función).

## APIs y contratos

### CLI (`scripts/prev-termux`)

| Comando | Descripción |
|---------|-------------|
| `list <pkg> [--refresh]` | Descubre versiones históricas + selector fzf + detalle |
| `build <pkg> [--commit <sha>] [--refresh] [--heavy] [--subversioned]` | Detecta run exitoso/en curso, pregunta antes de relanzar; descarga release existente o dispara workflow. `--subversioned` → `jobs=subversioned` |
| `subinstall [<pkg>|<file>]` | Descarga de GitHub (lista TODAS las versiones con fzf, luego elige subversion/normal) o extrae `.pkg.tar.xz` a `~/.local/opt/` + symlinks versionados |
| `install <pkg> [<version>] [--arch <arch>]` | Instala build NORMAL con el gestor detectado (pacman/apt, sin `-y`); selecciona versión con fzf |
| `switch [<pkg>]` | Cambia la versión subversionada activa: symlinks a `$PREFIX/bin`, marca `(actual)` |
| `fetch <pkg> [version] [--arch <arch>] [--subversioned] [--out <dir>]` | Descarga del pool de la PrevTermux Store (`prev-termux-pool-<arch>` + `manifest.json`) |
| `status [<pkg>]` | Últimos 20 runs del workflow con indicadores de color |
| `cache info` / `cache clear [--all|<pkg>]` | Estadísticas / limpieza del caché persistente |
| `help` | Ayuda |

### Workflow GHA inputs (`build-old-package.yml`)

| Input | Default | Opciones |
|-------|---------|----------|
| `package_name` | — | string (requerido) |
| `git_ref` | — | string (commit SHA de termux-packages) |
| `architecture` | `aarch64` | aarch64, arm, i686, x86_64 |
| `format` | `debian` | pacman, debian (el build SIEMPRE compila `.deb`; `deb2pkg.sh` convierte) |
| `build_mode` | `fast` | fast (`-I`), full (`-F`) |
| `heavy` | `false` | boolean (ZRAM 16GB + free disk para builds largos) |
| `use_store` | `true` | boolean (reutiliza deps del PrevTermux Store) |
| `jobs` | `both` | both, normal, subversioned (jobs a ejecutar; `timeout-minutes: 600`) |

### Contratos internos

- **Formato de salida de versiones** (cache/`discover_versions`): `version|commit_full|date|commit_short` (separador `|`, una línea por versión).
- **Cache file** (`~/.cache/prev-termux/versions/<pkg>.txt`): header `#` + líneas `version|commit|date|short`.
- **Repo bare**: `~/.cache/prev-termux/repo/termux-packages.git` con timestamp `.last_fetch`.
- **Tag de release**: `{package}-{version}-{sha7}` (ej: `which-2.25-ec22dc1`, `bash-5.2.37-a1b2c3d`).
- **Variables de entorno**: `GITHUB_REPOSITORY` (repo donde viven releases/workflow), `PREV_TERMUX_WORKFLOW_REF` (rama del workflow), `PREV_TERMUX_CACHE_DIR` (base del caché).
- **Dependencias locales**: `git`, `fzf`, `gh`, `jq` (verificadas con `check_deps`; `gh auth status` obligatorio).

## Patrones comunes

- **Caché persistente de 2 niveles** (`discover.sh`): repo bare con fetch periódico (24h) + archivos de versiones por paquete con TTL (7d). Fallback a caché stale si el descubrimiento falla.
- **Descubrimiento con pickaxe**: `git log --all -G "TERMUX_PKG_VERSION=" --format="%H|%ci|%h" -- packages/<pkg>/build.sh` (usa `-G` no `-S`). `--format` va ANTES de `--`.
- **Resolución de variables de build.sh**: `resolve_version_from_buildsh()` — parsea definiciones a tabla asociativa, resuelve `${VAR}`, `$VAR`, `${VAR%.*}`, `${VAR%%pattern}` recursivamente (máx 20 iteraciones). Duplicado en el step "Extract package version" del workflow (con `declare -A`).
- **Compatibilidad legacy** (el núcleo del proyecto):
  - **Build system vendered**: `build-system/` es byte-idéntico al upstream `de5ca479` salvo los archivos listados en `.fork-files` (~19 implementaciones directas con marca `# Legacy compatibility:`: 16 parches migrados 001–016, blindaje LLVM, hook del store, shim automake-N.N). `build-system/REVISION` guarda el SHA upstream; abort-on-conflict al actualizar.
  - Verificación de aplicación por marca: `grep -qF 'Legacy compatibility: ...'` antes de copiar/aplicar (idempotencia).
  - Normalización legacy en `scripts/normalize-legacy-builds.sh` (varias fases, sed idempotente): **FASE 1** renames (`BLACKLISTED_ARCHES→EXCLUDED_ARCHES`, `DEBDIR→OUTPUT_DIR`, `MAKE_PROCESSES→PKG_MAKE_PROCESSES`, `NO_DEVELSPLIT→NO_STATICSPLIT`, `=yes`→`=true`/`=no`→`=false`), URLs muertas (bintray/fossies) y checksums recomputados; **FASE 2** gnu89 bash; **FASE 2b/2c** `autoreconf -fi` (tar/util-linux).
- **Preparación del build en GHA** (`gha-prepare.sh`): copia `build-system/` al checkout del paquete histórico + copia `store-lib.sh` + ejecuta `normalize-legacy-builds.sh`. El runtime **NO descarga master ni aplica parches**; `patches/` y `patch-build-system.sh` son REFERENCIA.
- **PrevTermux Store**: `store-lib.sh` es hook en `termux_step_get_dependencies.sh` (consulta el pool `prev-termux-pool-<arch>` + `manifest.json` antes de recompilar una dep, también en `-F`/subversioned; caché del manifest por run); `store-publish.sh` publica deps solo `.deb` y objetivos `.deb` + `.pkg.tar.xz`.
- **Debug en CI (histórico, en `patches/` REFERENCIA)**: los parches 007/008/009 instrumentaban con `DEBUG VARS`, `SED EXIT`, `PATCH EXIT`, `MARKER: >>>/<paso>`. Debug **limpiado el 2026-08-10** (007/009 solo parte funcional; 008 DESCARTADO). Logs efímeros (`err.log`, `gita_err*.log`) quedan en raíz (gitignored).
- **Subinstalación portable**: extracción con `tar --strip-components` (intenta 5, luego 4, luego sin strip) + symlinks `<bin>-<version>`.

## Hallazgos de relocatabilidad (2026-07-31 — Fase 2: build versionado)

> ✅ **RESUELTO (2026-08-09)**: la estrategia se implementó como implementación **vendered** `TERMUX_PREFIX_OVERRIDE` en `build-system/build-package.sh` (marca `# Legacy compatibility:`) — re-deriva el prefix ANTES de sourcear el `build.sh` — y se **validó en CI**: `zig` 0.15.2 y 0.16.0 subversionado VERDE (runs `31303490256` / `31303490320`, `jobs=subversioned`, `heavy=true`). Los hallazgos de abajo son el análisis empírico que justificó la estrategia.

- **`TERMUX_PREFIX` se define en `scripts/properties.sh`** (línea 955-957): `TERMUX__PREFIX="$TERMUX__ROOTFS/..."` (canónico) + `TERMUX_PREFIX` (alias deprecado, sobrescrito incondicionalmente). Todas las sub-variables (`TERMUX__PREFIX__LIB_DIR`, `INCLUDE_DIR`, `CLASSICAL`, export `prefix`/`PREFIX` en setup_variables.sh:106-107) se derivan de `TERMUX__PREFIX`. Hay validators (`path_under_termux_rootfs`, `invalid_termux_prefix_paths`) y una función oficial `termux_build_props__set_termux_prefix_dir_and_sub_variables <prefix>`. Punto de inyección implementado: la implementación vendered `TERMUX_PREFIX_OVERRIDE` (re-deriva la raíz sin neutralizar validators).
- **termux-elf-cleaner**: elimina `DT_RPATH` SIEMPRE; conserva `DT_RUNPATH` si `api_level >= 24` (default `TERMUX_PKG_API_LEVEL=24`). Se invoca desde `termux_step_elf_cleaner.sh` (masajea `./bin/*`, `./lib/*`, `./opt/*`) salvo `TERMUX_PKG_NO_ELF_CLEANER=true`.
- **Runtime de Termux**: termux-app inyecta `LD_LIBRARY_PATH=$PREFIX/lib` y `LD_PRELOAD=libtermux-exec.so`. Precedencia del loader: `DT_RPATH` > `LD_LIBRARY_PATH` > `DT_RUNPATH`. Como termux no deja RPATH, un wrapper local con LD_LIBRARY_PATH antepuesto gana; patchelf `--set-rpath` genera RUNPATH que NO vence.
- **zig resuelve su std-lib** por `ZIG_LIB_DIR` (env) o subiendo directorios desde el exe buscando `lib/zig/` — no usa RPATH. El wrapper `bin/zig` de 0.15.2 es un script proot con `$TERMUX_PREFIX/lib/zig/zig` hardcoded (causa del bug de subversionado).
- **`patchelf` existe como paquete** en termux-packages (master v0.19.1; commit 6bd499e v0.18.0). No se usa en ningún script del build system.
- **No existe infraestructura de relocatability** en termux-packages (sin usos de patchelf/`$ORIGIN`/relocat en `scripts/`). Estrategia planeada: compilar con prefix versionado en GHA (no post-procesado).
- **RUNPATH del toolchain (cross-build)**: `termux_setup_toolchain_{23c,29}.sh:34` añade `LDFLAGS+=" -Wl,-rpath=$TERMUX__PREFIX__LIB_DIR"` (con `--enable-new-dtags` → RUNPATH) solo cuando `TERMUX_ON_DEVICE_BUILD=false`. Confirmado en `which` real: `RUNPATH [/data/data/com.termux/files/usr/lib]`. `termux_step_configure_autotools.sh:110` usa `--disable-rpath`.

## Observaciones

- **Entorno**: desarrollado/ejecutado en Termux (Android). CLI local corre en Termux; builds pesados corren en runners GHA (`ubuntu-latest`, contenedor `ghcr.io/termux/package-builder`).
- **Ramas**: `main` (estable) + `experiment/whack-a-mole-build-system` (experimental). Tags de prueba: `which-2.25-ec22dc1`, `bash-5.2.26-e4f2135`, `tar-1.35-8ca9404`.
- **Estado actual**: sistema vendered (`build-system/` byte-idéntico a `de5ca479` + ~19 impl. `# Legacy compatibility:`) + **PrevTermux Store** (pool por arquitectura) + **CLI rediseñada** (build/subinstall/install/switch/fetch). `zig` 0.15.2 y 0.16.0 subversionado **VERDE**. Pendiente: re-validar `bash@8ca9404` en CI (FASE 2c ya commiteada) y la regresión `bat@2f2adec`. Parches 007–009 (REFERENCIA) conservan instrumentación de debug pendiente de limpiar.
- **Tests de regresión** documentados en PROGRESS-OLD_PKGS.md: `which@1fcb6e8`, `bash@e4f2135`, `tar@8ca9404`, `zig@0.15.2/0.16.0` (subversionado), `bat@2f2adec` (pendiente).
- **Formato por defecto**: pacman (`.pkg.tar.xz`). El soporte `--format` no existe en commits antiguos — por eso el pipeline SIEMPRE compila `.deb` (formato universal) y `deb2pkg.sh` convierte a `.pkg.tar.xz`; el build system viene de `build-system/` vendered.
- **Repositorio GitHub**: `Leonisaurov/PrevTermuxPackage` (de los logs de gita).
