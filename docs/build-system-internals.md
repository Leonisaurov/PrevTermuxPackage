# Sistema de Build de termux-packages: Dependencias Internas

> Documento interno de PrevTermuxPackage — fecha: 2026-08-09

## Resumen

Cuando se compilan paquetes de commits ANTIGUOS de `termux-packages`, el build system moderno requiere archivos que el commit histórico no tiene. Este documento cataloga esos archivos y explica por qué fallan los builds.

El problema de fondo: `termux-packages` es un monorepo donde el build system y los paquetes **evolucionan al mismo ritmo**. Al hacer checkout de un commit antiguo para compilar una versión vieja de un paquete, también se hace checkout de la versión antigua del build system, que no contiene las dependencias que el `build-package.sh` moderno necesita.

**Solución actual (2026-08-09)**: el build system ya NO se descarga de master en runtime. Se vende un árbol completo byte-idéntico al master (`de5ca479`) en `build-system/` (commiteado en el repo) y `scripts/gha-prepare.sh` lo copia al checkout del paquete histórico; `scripts/normalize-legacy-builds.sh` normaliza los `build.sh` históricos (renames, URLs muertas, checksums, gnu89, `autoreconf -fi`). Ver [Solución Implementada](#solución-implementada).

## Arquitectura del Build System

### `build-package.sh` (raíz)

- Script principal que parsea el `build.sh` de cada paquete.
- Soportó `--format` (pacman/debian) desde cierto punto de la historia — los commits anteriores a ese punto fallan con `--format pacman`.
- Sourcea scripts de `scripts/utils/termux/package/`.
- Lee `repo.json` para configuración del repositorio (nombres, URLs, arquitecturas).
- Importa claves GPG de `packages/termux-keyring/` para verificar paquetes.

### `scripts/` (directorio completo)

El `build-package.sh` moderno depende de docenas de scripts. Archivos críticos:

| Archivo | Rol |
|---------|-----|
| `scripts/run-docker.sh` | Wrapper de Docker (221 líneas moderno vs 47 líneas antiguo) |
| `scripts/utils/docker/docker.sh` | Funciones auxiliares de Docker (dot-sourced) |
| `scripts/utils/termux/package/termux_package.sh` | Funciones de empaquetado |
| `scripts/profile.json` | Perfil seccomp de Docker |
| `scripts/profile-relaxed.apparmor` | Perfil AppArmor relajado |
| `scripts/profile-restricted.apparmor` | Perfil AppArmor restringido |
| `scripts/bin/build-package-dry-run-simulation.sh` | Solo para `--dry-run` |

### `repo.json` (raíz)

- Configuración del repositorio (nombres, URLs, arquitecturas).
- Leído por `jq` al inicio del build.
- No existe en commits antiguos; el `build-package.sh` moderno falla sin él.

### `packages/termux-keyring/`

Claves GPG de los firmantes del repositorio (9 claves en master):

- `2096779623.gpg`
- `agnostic-apollo.gpg`
- `grimler.gpg`
- `kcubeterm.gpg`
- `landfillbaby.gpg`
- `mradityaalok.gpg`
- `termux-autobuilds.gpg`
- `termux-pacman.gpg`
- `thunder-coding.gpg`

- `build.sh` — script del paquete termux-keyring.

### `packages/termux-elf-cleaner/` (dependencia de descarga externa)

El `scripts/build/termux_step_start_build.sh` moderno lee `packages/termux-elf-cleaner/build.sh` para obtener `TERMUX_PKG_VERSION` y descargar el binario desde GitHub Releases:

```
https://github.com/termux/termux-elf-cleaner/releases/download/v${VERSION}/termux-elf-cleaner
```

**Problema con commits antiguos**: el `build.sh` del commit antiguo tiene `TERMUX_PKG_VERSION=1.2`, pero los assets de los releases SOLO existen desde **v2.2.0** (dic 2023). El release v1.2 existe pero sin assets adjuntos → 404.

**Releases con assets**: v3.0.1 (actual), v3.0.0, v2.2.1, v2.2.0. Los v1.x–v2.1.x se distribuían compilando desde el tarball del tag, no con binarios adjuntos.

**Solución**: el árbol vendered incluye `packages/termux-elf-cleaner` (con el `build.sh` moderno v3.0.1) dentro de `build-system/`, de modo que el build descarga el binario correcto desde GitHub Releases.

**Checksum sha256** (hardcodeado en `termux_step_start_build.sh`):

```
59645fb25b84d11f108436e83d9df5e874ba4eb76ab62948869a23a3ee692fa7
```

## Problema con Commits Antiguos

Cada commit de `termux-packages` tiene SU PROPIA versión de estos archivos:

- Commits viejos: `run-docker.sh` de 47 líneas sin sudo/AppArmor (falla en GHA).
- Commits nuevos: `run-docker.sh` de 221 líneas con sudo/AppArmor/seccomp.

Al compilar un commit antiguo, la secuencia de fallos es:

1. Checkout del commit → scripts antiguos.
2. `groupmod: Permission denied` (sin sudo en GHA).
3. Faltan AppArmor profiles, `profile.json`, `repo.json`, claves GPG.

## Solución Implementada

**Ya NO se descarga master ni se aplican parches en runtime.** El build system es un árbol **PROPIO vendered** en `build-system/`:

1. Árbol byte-idéntico al commit `de5ca479` de `termux/termux-packages` (master), **commiteado** en el repo.
2. **~19 implementaciones directas** con marcador `# Legacy compatibility:` (16 parches migrados 001–016, blindaje LLVM, hook del store, shim automake-N.N) sobre los archivos listados en `build-system/.fork-files`.
3. Metadata del fork: `build-system/REVISION` (SHA upstream, URL, fecha de import) y `build-system/FORK.md` (tabla de implementaciones).
4. En el workflow, `scripts/gha-prepare.sh`:
   - Copia el árbol `build-system/` al árbol del paquete (checkout histórico del commit exacto).
   - Copia `scripts/store-lib.sh` (hook del PrevTermux Store).
   - Ejecuta `scripts/normalize-legacy-builds.sh`: **FASE 1** renames legacy (BLACKLISTED_ARCHES→EXCLUDED_ARCHES, DEBDIR→OUTPUT_DIR, MAKE_PROCESSES→PKG_MAKE_PROCESSES, NO_DEVELSPLIT→NO_STATICSPLIT, `=yes`→`=true`/`=no`→`=false`), URLs de source muertas (bintray, fossies) y checksums recomputados; **FASE 2** gnu89 bash; **FASE 2b/2c** `autoreconf -fi` (tar/util-linux).
5. `patches/` y `patch-build-system.sh` se conservan como **REFERENCIA** (ya NO se ejecutan).

> Histórico: antes de la reestructuración (commit `5b518a5`, `aac06f0`), el flujo hacía sparse checkout de `scripts/` + `packages/termux-keyring` desde master, descargaba `build-package.sh` y `repo.json` vía curl y aplicaba los parches en runtime. Ese flujo quedó reemplazado por el vendered.

## Evolución de run-docker.sh (47 → 221 líneas)

| Característica | 47 líneas (viejo) | 221 líneas (moderno) |
|----------------|-------------------|---------------------|
| sudo | No | Sí |
| AppArmor | No | Sí |
| Seccomp profile | No | Sí |
| pid_max | No | Sí |
| --init | No | Sí |
| Traps de limpieza | No | Sí |
| CI env var | No | Sí |

## Lecciones Aprendidas

- No descargar archivos individuales (gato y ratón): cada commit introduce o renombra archivos, y una lista fija de URLs siempre queda desactualizada.
- **Vender el árbol completo** (commiteado en el repo) elimina la dependencia de red y la deriva de master: `gha-prepare.sh` solo copia y `normalize-legacy-builds.sh` normaliza los `build.sh` históricos.
- El build system moderno es retrocompatible con `build.sh` antiguos (solo lee variables).
- Los flags `--format` y otras features se agregaron con el tiempo; no asumir que un commit viejo los soporta.

## Notas de Verificación (2026-07-30)

- `run-docker.sh` en master: 221 líneas — confirmado.
- Contiene: `sudo`, `--security-opt seccomp=.../profile.json`, `--security-opt apparmor=...`, `pid_max` (incl. soporte para kernels >= 6.14), `--init`, traps via `docker__setup_docker_exec_traps`, `CI` env var.
- `scripts/profile-relaxed.apparmor` y `scripts/profile.json` existen en master.

---

# Hallazgos de compatibilidad (2026-07-31, actualizado 2026-08-09)

## Resueltos (con evidencia/commit)

| Hallazgo | Estado | Evidencia |
|----------|--------|-----------|
| **Exit 2 silencioso** en pipelines `grep\|head\|tr` sobre archivos inexistentes (`set -euo pipefail`) | ✅ RESUELTO | `\|\| true` en los parches 003/005 (migrados a `build-system/`) |
| **Debug del parche 007** (imprimía `DEBUG VARS`, `SED EXIT`, `PATCH EXIT` para diagnosticar el exit 2) | ✅ RESUELTO | La causa era el exit 2 de `set -euo pipefail`; el debug quedó fuera del flujo (parches 007–009 = REFERENCIA) y se **limpió el 2026-08-10** (007/009 solo parte funcional; 008 marcado DESCARTADO) |
| **automake-1.16 ausente en el runner** (remake espurio de `Makefile.in` en sub-makes) | ✅ RESUELTO | Shim genérico `automake-N.N` → `automake` en `setup_variables` (commit `a750096`) + `autoreconf -fi` por paquete: tar = FASE 2b (`b90e831`), util-linux = FASE 2c (`ed86935`, mismatch automake 1.18.1 vs 1.16.5) |
| **Checksums recomputados** (foot 1.22.3/1.25.0: codeberg regeneró el gzip, contenido byte-idéntico) | ✅ RESUELTO | Commit `8f645d5`; sustitución en la FASE 1 de `normalize-legacy-builds.sh` |
| **`termux-am` transitiva en listas DEPENDS** (Gradle 4.1 vs Java 17 del runner) | ✅ RESUELTO | Commit `ac6ae52` (sed de tokens en las listas; NO vaciar `TERMUX_PKG_DEPENDS=""`) |
| **AppArmor del build system** (`deny /home/builder/termux-packages/[^o]**` bloqueaba `.store-cache`) | ✅ RESUELTO | Commit `89861d4` (excepción `[^o.]` + `allow .store-cache/** rw`) |
| **`sched_attr.h` de util-linux** (header faltante en el sysroot) | ✅ RESUELTO | FASE 2d; patch de master vendered en `build-system/` |
| **Subversionado relocatable** (wrapper proot zig, RUNPATH del toolchain) | ✅ RESUELTO | Implementación vendered `TERMUX_PREFIX_OVERRIDE` (re-deriva el prefix antes de sourcear el `build.sh`); zig 0.15.2/0.16.0 subversionado VERDE (runs `31303490256`/`31303490320`) |

## Variable `TERMUX_PKG_BUILD_IN_SRC` (2018 vs moderno)

- **2018**: los `build.sh` usan `TERMUX_PKG_BUILD_IN_SRC=yes` (formato antiguo `yes`/`no`).
- **Master**: `termux_step_start_build.sh` compara `[ "$TERMUX_PKG_BUILD_IN_SRC" = "true" ]` (estricto).
- **Fix**: patch 006 hace que `start_build` acepte `yes` **o** `true` (`[ = "true" ] || [ = "yes" ]`).
- **Impacto**: si no se activa, `TERMUX_PKG_BUILDDIR ≠ TERMUX_PKG_SRCDIR` → el build corre en un directorio vacío y falla de forma confusa.
- **Doble capa**: además del patch 006, el paso 8 de `scripts/patch-build-system.sh` normaliza globalmente `^TERMUX_PKG_*=yes$` → `=true` en todos los `build.sh` (regex anclada tras el bug `falset-found`). El patch es defensa extra para casos que el sed no cubre.

## `termux_setup_rust` (evolución)

- **2018**: `termux_step_make_install.sh` llamaba `termux_setup_rust` automáticamente si existía `Cargo.toml` en el source.
- **oct-2025 (commit `030d411c9b`)**: se eliminó la llamada automática; ahora falla con `termux_error_exit "cargo command is not found! Please add termux_setup_rust in package's build.sh!"` si `cargo` no está en `PATH`.
- **Fix**: patch 004 restaura el comportamiento legacy: si existe `Cargo.toml` y `cargo` no está instalado, llama `termux_setup_rust` automáticamente.
- **Master**: `termux_setup_rust` obtiene `TERMUX_RUST_VERSION` sourceando `packages/rust/build.sh` y leyendo `TERMUX_PKG_VERSION`.
- **Problema**: si `packages/rust/build.sh` no existe en el commit viejo (o contiene código ejecutable que falla al sourcear), capturaba `TERMUX_PKG_VERSION` del **entorno** → la versión del paquete actual (p. ej. `bat` → 0.7.1) en vez de la de rust.
- **Fix**: patch 005 usa `grep -oP '^TERMUX_PKG_VERSION=\K.+'` sobre `packages/rust/build.sh` + fallback a toolchain estable **1.75.0**.

## Extracción de fuentes (master)

- `termux_unpack_src_archive.sh`: `STRIP=1` por defecto → el primer tarball queda **PLANO** en `TERMUX_PKG_SRCDIR` (`strip-components=1`).
- Solo el **2º+ tarball** usa `STRIP=0` (descomprime con subdirectorios).
- Los `.zip` se extraen en un subdirectorio (comportamiento distinto a `.tar.*`).
- **Impacto**: con extracción plana, los patches generados con `diff -u -r` (rutas `../pkg-ver/file`) no matchean el directorio real.

## Aplicación de patches (master)

- `termux_step_patch_package.sh`: `cd $TERMUX_PKG_SRCDIR`, aplica **11 reglas sed** `@TERMUX_*@`, luego `patch -p1`.
- Los **patches de 2018** usan rutas `../pkg-ver/...` en los headers (generados con `diff -u -r`).
- **GNU patch** tiene un fallback que resuelve las rutas antiguas; **BusyBox patch no** lo tiene.
- **Fix**: patch 007 normaliza `--- ../pkg-ver/` → `--- ./` (y `+++`), y además **quita `--silent`** para poder ver el error real de GNU patch.
- El parche 007 incluía `DEBUG` (imprime `DEBUG VARS`, `SED EXIT`, `SED STDERR`, `PATCH EXIT`, `PATCH STDERR`) para diagnosticar el exit 2 en CI. **Resuelto**: la causa del exit 2 era el `set -euo pipefail` + pipelines sobre archivos inexistentes; los parches 007–009 son REFERENCIA y su debug se **limpió el 2026-08-10** (007/009 conservan solo la parte funcional; 008, 100% marcadores, marcado DESCARTADO).

## Sed completo del `termux_step_patch_package.sh` (11 reglas)

Las 11 sustituciones `@TERMUX_*@` que el `build-package.sh` moderno aplica a cada patch antes de pasarlo a GNU patch:

| # | Token | Reemplazado por |
|---|-------|-----------------|
| 1 | `@TERMUX_APP_PACKAGE@` | `${TERMUX_APP_PACKAGE}` |
| 2 | `@TERMUX_BASE_DIR@` | `${TERMUX_BASE_DIR}` |
| 3 | `@TERMUX_CACHE_DIR@` | `${TERMUX_CACHE_DIR}` |
| 4 | `@TERMUX_HOME@` | `${TERMUX_ANDROID_HOME}` |
| 5 | `@TERMUX_PREFIX@` | `${TERMUX_PREFIX}` |
| 6 | `@TERMUX_PREFIX_CLASSICAL@` | `${TERMUX_PREFIX_CLASSICAL}` |
| 7 | `@TERMUX_ENV__S_TERMUX@` | `${TERMUX_ENV__S_TERMUX}` |
| 8 | `@TERMUX_ENV__S_TERMUX_APP@` | `${TERMUX_ENV__S_TERMUX_APP}` |
| 9 | `@TERMUX_ENV__S_TERMUX_API_APP@` | `${TERMUX_ENV__S_TERMUX_API_APP}` |
| 10 | `@TERMUX_ENV__S_TERMUX_ROOTFS@` | `${TERMUX_ENV__S_TERMUX_ROOTFS}` |
| 11 | `@TERMUX_ENV__S_TERMUX_EXEC@` | `${TERMUX_ENV__S_TERMUX_EXEC}` |

Más 2 reglas de normalización de rutas agregadas por el patch 007:

- `s%^--- \.\./[^/]*/%--- ./%g`
- `s%^+++ \.\./[^/]*/%+++ ./%g`

**Exit 2 — RESUELTO**: la causa raíz verificada no era un token `TERMUX_ENV__S_*` sin expandir, sino el `set -euo pipefail` combinado con pipelines `grep|head|tr` sobre archivos inexistentes, que abortan **silenciosamente** con exit 2 si no llevan `|| true` (parches 003/005, migrados a `build-system/`).

---

# PrevTermux Store (2026-08-09)

Pool de paquetes reutilizables para acelerar builds históricos:

- **Pool por arquitectura** en GitHub Releases: tag `prev-termux-pool-<arch>` (p.ej. `prev-termux-pool-aarch64`) con `manifest.json` como índice.
- **`scripts/store-lib.sh`** — hook en `termux_step_get_dependencies.sh`: consulta el pool **antes** de recompilar una dependencia; reutiliza deps ya compiladas también en `-F`/subversioned; caché del manifest por run.
- **`scripts/store-publish.sh`** — publica al pool: dependencias solo `.deb` canónico; paquetes objetivo `.deb` + `.pkg.tar.xz`.
- **Input `use_store`** del workflow (default `true`); caché CI (`actions/cache`) con clave por modo (`prevstore-normal-*` / `prevstore-subversioned-*`) y `hashFiles('build-system/REVISION')`; publicación serializada con `needs` + `success()` (commit `a11a65b`).
- **CLI**: `prev-termux fetch` descarga del pool.
- AppArmor del contenedor requería excepción para `.store-cache` (commit `89861d4`).
