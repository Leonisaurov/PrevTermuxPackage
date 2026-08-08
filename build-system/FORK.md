# FORK.md — build-system vendered de PrevTermuxPackage

## Cabecera

- **Upstream**: termux/termux-packages
- **Upstream SHA**: `de5ca479b62d2b9b9435eabaa91618dba9c32fb4` (master)
- **Import date**: 2026-08-08
- **Estado**: import puro de `scripts/` + build-package.sh + ndk-patches + REVISION de master, con **16 implementaciones de compatibilidad legacy** + **blindaje LLVM** + **2 de PrevTermux Store** (fase B completada; fase 1 del Store terminada).

## Propósito del fork

El build system de termux-packages **master** no compila los paquetes históricos (commits 2018–2023) que se construyen en este repo. Cada diferencia con upstream está implementada **directamente** sobre el árbol (no como parches externos) y se marca con `# Legacy compatibility:` (hay greps externos que dependen de los marcadores, p.ej. `grep -q 'TERMUX_PREFIX_OVERRIDE'` en `gha-build.sh`).

## Tabla de implementaciones

| Id | Origen | Archivo | Descripción | Marcador |
|---|---|---|---|---|
| 001 | patch 001 | `scripts/buildorder.py` | Normaliza deps `*-dev` a su paquete padre (`re.sub('-dev$', ...)`) | `# Legacy compatibility: Handle dependencies on *-dev packages:` |
| 002 | patch 002 | `scripts/build/termux_extract_dep_info.sh` | `PKG=${PKG/-dev/}` | `# Legacy compatibility: Normalize *-dev packages to their parent` |
| 003 | patch 003 | `scripts/build/termux_step_setup_variables.sh` | Source tolerante de python/libllvm (grep en vez de sourcear) + fallbacks | `# Legacy compatibility: commits historicos (2018-2023) no tienen...` |
| 004 | patch 004 | `scripts/build/termux_step_make_install.sh` | `termux_setup_rust` automático cuando cargo no existe | `# Legacy compatibility: old build.sh files don't call termux_setup_rust` |
| 005 | patch 005 | `scripts/build/setup/termux_setup_rust.sh` | Extracción de versión con grep + fallback | `# Legacy compatibility: extract version with grep instead of sourcing` |
| 006 | patch 006 | `scripts/build/termux_step_start_build.sh` | `BUILD_IN_SRC` acepta `yes`/`true` | `# Legacy compatibility: build.sh files from 2018 use "yes" instead of "true"` |
| 007 | patch 007 | `scripts/build/termux_step_patch_package.sh` | Normalización `--- ../pkg-ver/` → `--- ./` + `patch --batch -p1` (sin debug) | `# Legacy compatibility: normalize diffs from old packages...` |
| 008 | ~~patch 008~~ | — | **DESCARTADO** (solo marcadores de debug, sin valor) | — |
| 009 | patch 009 | `scripts/build/termux_step_make_install.sh` | Estructura `( cargo install … \| tee cargo-install.log; exit ${PIPESTATUS[0]} )` (sin debug) | `# Legacy compatibility: capture cargo install output to a log...` |
| 010 | patch 010 | `build-package.sh` | Bloque `TERMUX_PREFIX_OVERRIDE` (re-deriva prefix + bootstrap symlinks) y `termux_step_fix_versioned_shebangs` | `# Legacy compatibility: subversioned builds allow TERMUX_PREFIX_OVERRIDE` |
| 011 | patch 011 | `scripts/build/termux_step_make_install.sh` | Quita `--no-track` del `cargo install` | `# Legacy compatibility: remove --no-track for old cargo toolchains` |
| 012 | patch 012 | `scripts/build/termux_step_install_license.sh` | Defaults `:=` + early-return sin licencia | `# Legacy compatibility: old build.sh files (2018-2023) don't always set...` |
| 013 | patch 013 | `scripts/build/toolchain/termux_setup_toolchain_23c.sh` y `_29.sh` | Conserva `zlib.h`/`zconf.h` del sysroot NDK | `# Legacy compatibility: keep NDK zlib.h for old packages without zlib dep` |
| 014 | patch 014 | ídem 23c/29 | `-mno-outline-atomics` (aarch64) | `# Legacy compatibility: disable outline-atomics (LSE) for old packages on API 24` |
| 015 | patch 015 | `scripts/build/termux_step_make_install.sh` | Fail-fast: `PIPESTATUS[0] != 0` → `termux_error_exit` | `# Legacy compatibility: fail fast — propagate the real cargo install exit code` |
| 016 | patch 016 | ídem 23c/29 | RUSTFLAGS con `-Wl,-z,max-page-size=16384` (aarch64) | `# Legacy compatibility: align Rust binaries to 16KB pages` |
| 017 | **nuevo** | `scripts/build/termux_step_get_dependencies.sh` | Hook PrevTermux Store: consulta el pool de releases antes de descargar/construir una dep, en ambos modos (-I y -F/subversioned); fallback silencioso si no hay hit. La librería `store-lib.sh` vive en `scripts/` (proyecto) y gha-prepare.sh la copia a `<tree>/scripts/store-lib.sh` | `# Legacy compatibility: PrevTermux Store — reutilizar deps ya compiladas` |
| 018 | **nuevo** | `scripts/build/termux_step_setup_variables.sh` | `TERMUX_BUILT_PACKAGES_DIRECTORY` respeta el entorno (`${VAR:-default}`) para poder mover el marker al árbol montado (`.store-cache`) | `# Legacy compatibility: PrevTermux Store — permitir mover el marker al árbol montado` |
| LLVM | **nuevo** | `scripts/build/termux_step_setup_variables.sh` | Blindaje: `TERMUX_LLVM_VERSION:-7.0.0`, `MAJOR_VERSION:-7` + case-guard anti-no-numérico antes de toda aritmética `$((...LLVM...))` | `# Legacy compatibility: commits historicos (2018-2023) no tienen packages/libllvm/build.sh` |

## Procedimiento resumido de vendor-update

1. Regenerar el árbol vendered desde el upstream SHA con el import (sparse checkout de `scripts/`, `build-package.sh`, `ndk-patches`, `REVISION`).
2. **Abort-on-conflict**: al actualizar `build-system/` a un nuevo SHA, cualquier conflicto de `patch`/merge sobre un archivo de `.fork-files` debe **abortar** (nunca resolver ciegamente) y re-portar a mano la implementación sobre el contexto nuevo.
3. Verificación post-import: `bash -n` sobre todos los `.sh` de `.fork-files`, grep de los marcadores `# Legacy compatibility:` y `TERMUX_PREFIX_OVERRIDE`.
4. El `diff -r` contra el upstream debe limitarse a: archivos de `.fork-files` + `REVISION` + `FORK.md` + `.fork-files`.
5. Nuevas incompatibilidades descubiertas → implementarlas directamente con su marcador y añadirlas a `.fork-files` + esta tabla.

## Archivos del fork

Listados en `.fork-files` (12 archivos con implementaciones).
