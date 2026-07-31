# Style Guide: PrevTermuxPackage

> Guía de convenciones de la codebase — generada desde la investigación del código real (2026-07-31).

## Estructura del proyecto

```
PrevTermuxPackage/
├── .github/workflows/
│   └── build-old-package.yml     # Workflow GHA (workflow_dispatch) — build en la nube
├── docs/
│   ├── PROGRESS.md               # Estado/progreso, whack-a-mole del build system
│   └── build-system-internals.md # Catálogo de dependencias del build system + hallazgos de compatibilidad
├── patches/                      # LOS ARREGLOS: 9 patches al build system moderno (001–009)
├── scripts/
│   ├── prev-termux               # CLI principal (entrypoint, 760 líneas)
│   ├── patch-build-system.sh     # Aplica los 9 patches + normalización legacy (idempotente)
│   └── lib/
│       └── discover.sh           # Librería: descubrimiento de versiones + caché persistente (665 líneas)
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
| `build <pkg> [--commit <sha>] [--refresh] [--heavy]` | Descarga release existente o dispara workflow GHA |
| `subinstall [<pkg>|<file>]` | Extrae .pkg.tar.xz a `~/.local/opt/` + symlinks versionados |
| `status [<pkg>]` | Últimos 20 runs del workflow con indicadores de color |
| `cache info` / `cache clear [--all|<pkg>]` | Estadísticas / limpieza del caché persistente |
| `help` | Ayuda |

### Workflow GHA inputs (`build-old-package.yml`)

| Input | Default | Opciones |
|-------|---------|----------|
| `package_name` | — | string (requerido) |
| `git_ref` | — | string (commit SHA de termux-packages) |
| `architecture` | `aarch64` | aarch64, arm, i686, x86_64 |
| `format` | `pacman` | pacman, debian |
| `build_mode` | `fast` | fast (`-I`), full (`-F`) |
| `heavy` | `false` | boolean (ZRAM 16GB + free disk) |

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
  - Parches numerados `NNN-nombre.patch` en `patches/`, aplicados por `patch-build-system.sh` contra `scripts/` del build system moderno.
  - Verificación de aplicación por marca: `grep -q 'Legacy compatibility: ...'` — los parches insertan comentarios `Legacy compatibility: ...` que sirven de marca idempotente.
  - Normalización global de variables legacy en todos los `build.sh` (sed idempotente): `BLACKLISTED_ARCHES→EXCLUDED_ARCHES`, `DEBDIR→OUTPUT_DIR`, `MAKE_PROCESSES→PKG_MAKE_PROCESSES`, `NO_DEVELSPLIT→NO_STATICSPLIT`, `yes→true`/`no→false` (regex anclada `^\(TERMUX_PKG_[A-Z_]*\)=yes$`).
- **Sparse checkout de master** (en GHA, no en local): `--depth=1 --filter=blob:none --sparse` + `sparse-checkout set scripts packages/termux-keyring packages/termux-elf-cleaner ndk-patches`; `build-package.sh` y `repo.json` via curl. Reemplaza TODO el build system del commit viejo por el moderno.
- **Debug en CI**: patches 007/008/009 instrumentan con `DEBUG VARS`, `SED EXIT`, `PATCH EXIT`, `MARKER: >>>/<paso>`, `2>&1 | tee /tmp/cargo-install.log` + `PIPESTATUS[0]`. Logs efímeros (`err.log`, `gita_err*.log`) quedan en raíz (gitignored).
- **Subinstalación portable**: extracción con `tar --strip-components` (intenta 5, luego 4, luego sin strip) + symlinks `<bin>-<version>`.

## Hallazgos de relocatabilidad (2026-07-31 — para la Fase 2: build versionado)

- **`TERMUX_PREFIX` se define en `scripts/properties.sh`** (línea 955-957): `TERMUX__PREFIX="$TERMUX__ROOTFS/..."` (canónico) + `TERMUX_PREFIX` (alias deprecado, sobrescrito incondicionalmente). Todas las sub-variables (`TERMUX__PREFIX__LIB_DIR`, `INCLUDE_DIR`, `CLASSICAL`, export `prefix`/`PREFIX` en setup_variables.sh:106-107) se derivan de `TERMUX__PREFIX`. Hay validators (`path_under_termux_rootfs`, `invalid_termux_prefix_paths`) y una función oficial `termux_build_props__set_termux_prefix_dir_and_sub_variables <prefix>`. Punto de inyección para el patch 010: properties.sh + neutralizar validators.
- **termux-elf-cleaner**: elimina `DT_RPATH` SIEMPRE; conserva `DT_RUNPATH` si `api_level >= 24` (default `TERMUX_PKG_API_LEVEL=24`). Se invoca desde `termux_step_elf_cleaner.sh` (masajea `./bin/*`, `./lib/*`, `./opt/*`) salvo `TERMUX_PKG_NO_ELF_CLEANER=true`.
- **Runtime de Termux**: termux-app inyecta `LD_LIBRARY_PATH=$PREFIX/lib` y `LD_PRELOAD=libtermux-exec.so`. Precedencia del loader: `DT_RPATH` > `LD_LIBRARY_PATH` > `DT_RUNPATH`. Como termux no deja RPATH, un wrapper local con LD_LIBRARY_PATH antepuesto gana; patchelf `--set-rpath` genera RUNPATH que NO vence.
- **zig resuelve su std-lib** por `ZIG_LIB_DIR` (env) o subiendo directorios desde el exe buscando `lib/zig/` — no usa RPATH. El wrapper `bin/zig` de 0.15.2 es un script proot con `$TERMUX_PREFIX/lib/zig/zig` hardcoded (causa del bug de subversionado).
- **`patchelf` existe como paquete** en termux-packages (master v0.19.1; commit 6bd499e v0.18.0). No se usa en ningún script del build system.
- **No existe infraestructura de relocatability** en termux-packages (sin usos de patchelf/`$ORIGIN`/relocat en `scripts/`). Estrategia planeada: compilar con prefix versionado en GHA (no post-procesado).
- **RUNPATH del toolchain (cross-build)**: `termux_setup_toolchain_{23c,29}.sh:34` añade `LDFLAGS+=" -Wl,-rpath=$TERMUX__PREFIX__LIB_DIR"` (con `--enable-new-dtags` → RUNPATH) solo cuando `TERMUX_ON_DEVICE_BUILD=false`. Confirmado en `which` real: `RUNPATH [/data/data/com.termux/files/usr/lib]`. `termux_step_configure_autotools.sh:110` usa `--disable-rpath`.

## Observaciones

- **Entorno**: desarrollado/ejecutado en Termux (Android). CLI local corre en Termux; builds pesados corren en runners GHA (`ubuntu-latest`, contenedor `ghcr.io/termux/package-builder`).
- **Ramas**: `main` (estable) + `experiment/whack-a-mole-build-system` (experimental). Tag de prueba: `which-2.25-ec22dc1`.
- **Estado actual**: bloqueado resolviendo exit 2 en `termux_step_make_install` (build `bat` commit 2018, run 30615771833). Parches 007-009 son instrumentación de debug — hay que limpiarlos al resolver.
- **Tests de regresión** documentados en PROGRESS.md: `bat` (e4f21355), `which` (ec22dc1), `zig` (6bd499e).
- **Formato por defecto**: pacman (`.pkg.tar.xz`). El soporte `--format` no existe en commits antiguos — por eso se usa build-package.sh de master.
- **Repositorio GitHub**: `Leonisaurov/PrevTermuxPackage` (de los logs de gita).
