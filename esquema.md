# Esquema: PrevTermuxPackage — Constructor de versiones antiguas de Termux con subversionado relocatable

> Esquema conceptual actualizado — 2026-08-09. Fase 2 del proyecto: **builds versionados relocatables** (implementada y VALIDADA en GHA: `zig` 0.15.2/0.16.0 subversionado verde) + **reestructuración del pipeline: build system PROPIO vendered + PrevTermux Store + .deb universal + conversión + deps versionadas** (implementada).

## Propósito

Compilar **versiones antiguas de paquetes Termux** (commits 2018–2023) en formato `.pkg.tar.xz` (pacman), con un solo comando.

**Fase 2 (este esquema)**: resolver el problema de **convivencia de múltiples versiones** en el mismo dispositivo. Los paquetes Termux se compilan con `--prefix=$PREFIX` y los paths quedan **hardcoded** (wrappers, RPATH/RUNPATH, config, shebangs). Al extraer una versión vieja a `~/.local/opt/<pkg>-<ver>/`, sus binarios siguen cargando librerías del `$PREFIX` actual — que pueden ser de OTRA versión (ej: `zig-0.15.2 version` reporta 0.16.0 porque el wrapper de zig 0.15.2 llama a `$PREFIX/lib/zig/zig` del gestor de paquetes).

**Estrategia elegida (por el usuario)**: parchear los paquetes **en build-time (GHA)** para que se compilen con un **prefix versionado**: `$PREFIX_OLD = /data/data/com.termux/files/usr` → `$PREFIX_NEW = ~/.local/opt/<pkg>-<version>/`. Así los binarios ya salen "bien parchados" desde el origen y `subinstall` solo extrae.

**Para quién**: usuarios de Termux que necesitan varias versiones de un mismo paquete coexistiendo (p.ej. `zig` 0.15.2 y 0.16.0, `python` 3.10 y 3.12) sin que se pisen.

## El problema (evidencia investigada)

| Caso | Evidencia |
|------|-----------|
| Zig 0.15.2 (`6bd499e`) | `bin/zig` NO es binario: es un **wrapper proot** con `proot -b "$TERMUX_PREFIX/bin/env:/usr/bin/env" "$TERMUX_PREFIX/lib/zig/zig"`. Los paths absolutos quedan **hardcoded** → al ejecutar desde `~/.local/opt/`, llama al zig de `$PREFIX` (0.16.0) |
| Zig y std-lib | `src/main.zig`/`introspect.zig` (0.15.2): zig resuelve su std-lib por `ZIG_LIB_DIR` (env) o **subiendo directorios desde el exe** buscando `lib/zig/` — no por RPATH. El ELF es casi relocatable; el wrapper lo rompe |
| RPATH en Termux | `termux-elf-cleaner` **elimina DT_RPATH siempre**; conserva DT_RUNPATH solo si api≥24 (default). Los binarios Termux dependen de `LD_LIBRARY_PATH=$PREFIX/lib` que inyecta termux-app en runtime |
| Build system | termux-packages **NO tiene mecanismos de relocatability** (0 usos de patchelf/`$ORIGIN`/relocat en scripts/). `TERMUX_PREFIX` se define en **`scripts/properties.sh`** (`TERMUX__PREFIX` canónico + alias `TERMUX_PREFIX`); `setup_variables` solo lo exporta como `prefix`/`PREFIX` |
| Precedencia loader | RPATH > LD_LIBRARY_PATH > RUNPATH (glibc y bionic). Un `patchelf --set-rpath '$ORIGIN/../lib'` genera RUNPATH, que NO vence al `LD_LIBRARY_PATH=$PREFIX/lib` global |
| Zig 0.15.2 real (verificado empíricamente con readelf) | El ELF `usr/lib/zig/zig` es **ESTÁTICO** (158 MB): sin RPATH, RUNPATH, NEEDED ni INTERP; `strings` no muestra ningún path `/data/data/...`. Todo el hardcode de Termux vive en el wrapper `usr/bin/zig` (script sh 252 B con `proot -b "$PREFIX/bin/env:/usr/bin/env" "$PREFIX/lib/zig/zig"`) |
| which 2.25 real (verificado empíricamente) | ELF **dinámico**: `RUNPATH [/data/data/com.termux/files/usr/lib]`, `NEEDED libc.so`, embebe `/data/data/com.termux/files/usr/bin/bash`. El RUNPATH viene del toolchain: `LDFLAGS+=" -Wl,-rpath=$TERMUX__PREFIX__LIB_DIR"` (solo cross-build off-device, con `--enable-new-dtags` → RUNPATH) |
| Definición de TERMUX_PREFIX (rastreado) | Se define en **`scripts/properties.sh`** (línea 955-957): `TERMUX__PREFIX="$TERMUX__ROOTFS/..."` (canónico) y `TERMUX_PREFIX="$TERMUX__PREFIX"` (alias deprecado, sobrescrito INCONDICIONALMENTE). TODAS las sub-variables (`TERMUX__PREFIX__LIB_DIR`, `INCLUDE_DIR`, `TERMUX_PREFIX_CLASSICAL`, export `prefix`/`PREFIX`) se derivan de `TERMUX__PREFIX`. Hay **validators** (`path_under_termux_rootfs`, `invalid_termux_prefix_paths`) que rechazan un prefix fuera de la rootfs. Función oficial: `termux_build_props__set_termux_prefix_dir_and_sub_variables <prefix>` |

**Causa raíz**: el prefix único (`/data/data/com.termux/files/usr`) está incrustado en el paquete en build-time. Si se compila con OTRO prefix, todo lo que se incrusta apunta al nuevo árbol versionado → cada versión queda autocontenida en `~/.local/opt/<pkg>-<ver>/`.

## Componentes

- **CLI local rediseñado** (`scripts/prev-termux` + `scripts/lib/discover.sh` + `scripts/lib/version-extract.sh`): descubrimiento de versiones (pickaxe `git log -G` sobre repo bare persistente), selección fzf (fallback menú numerado), resolución de variables `${VAR%.*}`, chequeo de release existente → descarga o dispara GHA. Comandos (commits `5545998`, `8c85754`): `build` (detecta run exitoso/en curso, pregunta antes de relanzar, `--subversioned` → `jobs=subversioned`, `--heavy`), `subinstall` (descarga de GitHub: lista TODAS las versiones con fzf, luego elige subversion/normal), `install` (nuevo; paquetes normales; detecta pacman/apt sin `-y`), `switch` (nuevo; TUI entre versiones subversionadas, marca `(actual)`, symlinks a `$PREFIX/bin`), `fetch`, `list`, `status`, `cache`, `help`.
- **Build system PROPIO vendered** (`build-system/`): árbol byte-idéntico al commit `de5ca479` de termux-packages master + **~19 implementaciones directas** con marcador `# Legacy compatibility:` (16 parches migrados 001–016, blindaje LLVM, hook del store, shim automake-N.N). Metadata en `REVISION`, `FORK.md` y `.fork-files`. El runtime **YA NO descarga master ni aplica parches**: `gha-prepare.sh` copia el árbol y ejecuta `normalize-legacy-builds.sh` (FASE 1 renames/URLs muertas/checksums; FASE 2 gnu89 bash; FASE 2b/2c `autoreconf -fi` tar/util-linux). `patches/` y `patch-build-system.sh` quedan como REFERENCIA.
- **PrevTermux Store**: pool de paquetes reutilizables en GitHub Releases por arquitectura (`prev-termux-pool-<arch>`) con `manifest.json`. `scripts/store-lib.sh` (hook en `termux_step_get_dependencies.sh`: reutiliza deps ya compiladas, también en `-F`/subversioned; caché del manifest por run), `scripts/store-publish.sh` (deps solo `.deb`; paquetes objetivo `.deb` + `.pkg.tar.xz`), input `use_store`, caché CI.
- **Workflow GHA** (`.github/workflows/build-old-package.yml`): compilador en la nube con input `jobs` (`both|normal|subversioned`) y `timeout-minutes: 600`; el pool se serializa con `needs` + `success()` (commit `a11a65b`). Checkout del commit exacto + `scripts/gha-prepare.sh` (copia `build-system/` vendered + `store-lib.sh` + `normalize-legacy-builds.sh`) + step `Install conversion tools` (libarchive-tools + binutils) + `scripts/gha-build.sh` (build con `run-docker.sh`, flags `--store`, `--subversioned`, `heavy`). El job subversioned inyecta `TERMUX_PREFIX_OVERRIDE` al contenedor vía `TERMUX_DOCKER_EXEC_EXTRA_ARGS`, fuerza `-F` (deps versionadas) y publica su propio release `-subversioned` con ambos formatos (`.deb` + `.pkg.tar.xz`).
- **`scripts/deb2pkg.sh`**: conversión post-build `.deb` → `.pkg.tar.xz` (pacman) replicando el template exacto de termux (`.PKGINFO`, `.MTREE`, `.BUILDINFO`, re-empaquetado `bsdtar` + `xz`). Naming del artifact `{pkg}-{ver}-{rev}-{arch}.pkg.tar.xz` con la versión sanitizada con la regla del prefix (`tr` + `sed`) y sufijo `-0` si falta (libalpm). Testeado con `pacman -Qip`.
- **Capa de compatibilidad legacy**: la normalización de `build.sh` históricos vive en `normalize-legacy-builds.sh` (FASE 1 renames/URLs muertas/checksums, FASE 2 gnu89 bash, FASE 2b/2c `autoreconf -fi`); los 16 parches migrados son implementaciones directas con `# Legacy compatibility:` en `build-system/`. **Implementado**: `TERMUX_PREFIX_OVERRIDE` para prefix versionado (vendered en `build-package.sh`).
- **Caché persistente** (`~/.cache/prev-termux/`): repo bare + versiones por paquete (TTL 7d).
- **subinstall**: detecta el layout del tar (`home/.local/opt/` → versionado → `--strip-components=5` a `$HOME`; `com.termux/files/usr/` → estándar → comportamiento actual) y extrae el artifact versionado directo a `~/.local/opt/<pkg>-<ver>/` (el árbol ya trae el prefix correcto). Sin post-procesado local.

## Relaciones y Flujo

```
[Usuario] → prev-termux build <pkg> [--subversioned]
    │ 1. discover_versions (repo bare) → fzf → tag {pkg}-{ver}-{sha7}[-subversioned]
    │ 2. ¿release existe? → descarga directa ✅ | No → workflow_dispatch
    ▼
GHA build-old-package.yml → input jobs (both|normal|subversioned), timeout 600:
    ├─ build-normal        → release {pkg}-{ver}-{sha7}
    └─ build-subversioned  → release {pkg}-{ver}-{sha7}-subversioned (título "Subversioned: ...")
    Ambos comparten:
    │ 3. checkout commit exacto + gha-prepare.sh
    │      (copia build-system/ VENDERED byte-idéntico a de5ca479
    │       + store-lib.sh + normalize-legacy-builds.sh: FASE 1 renames/
    │       URLs muertas/checksums, FASE 2 gnu89 bash, FASE 2b/2c autoreconf)
    │ 3b. PrevTermux Store: store-lib.sh consulta pool prev-termux-pool-<arch>
    │      (manifest.json) antes de recompilar una dep — también en -F/subversioned
    │ 4. Install conversion tools: libarchive-tools (bsdtar) + binutils (ar)
    │ 5. gha-build.sh → version_extract (version-extract.sh) → run-docker.sh build-package.sh
    │ 6. build-package.sh SIEMPRE con --format debian (formato universal:
    │      commits pre-2021 solo producen .deb; el input format se valida pero se
    │      ignora para el build) en modo fast (-I) o full (-F) según --build-mode
    │ 7. SOLO build-subversioned: gha-build.sh --subversioned exporta
    │      TERMUX_PREFIX_OVERRIDE=/data/data/com.termux/files/home/.local/opt/<pkg>-<ver>
    │      TERMUX_DOCKER_EXEC_EXTRA_ARGS="--env TERMUX_PREFIX_OVERRIDE=..." → docker exec
    │      y fuerza -F (full mode) SIEMPRE → las DEPS también quedan versionadas
    │      (la recursión de build-package hereda TERMUX_PREFIX_OVERRIDE)
    │ 8. build-package.sh (implementación vendered # Legacy compatibility:)
    │      con TERMUX_PREFIX_OVERRIDE:
    │      • re-deriva el prefix ANTES de sourcear el build.sh → wrapper proot y
    │        diffs @TERMUX_PREFIX@ quedan versionados (validado: zig 0.15.2/0.16.0)
    │ 9. termux_step_fix_versioned_shebangs (post-massage):
    │      • shebangs y maps proot <versioned>/bin/{sh,bash,env,...} → PREFIX real
    │      • guard: intérpretes que el paquete instala (python3.12, lua5.4, ...) NO se remapean
    │ 10. deb2pkg.sh convierte CADA .deb (output/ o debs/ pre-2021) → .pkg.tar.xz
    │      (.PKGINFO/.MTREE/.BUILDINFO exactos de termux; bsdtar + xz)
    │ 11. upload-artifact + release: .deb + .pkg.tar.xz, tag {pkg}-{ver}-{sha7}[-subversioned]
    ▼
subinstall → detecta layout del tar:
    │  versionado → --strip-components=5 a $HOME → ~/.local/opt/<pkg>-<ver>/  ✅ autocontenido
    └  estándar   → comportamiento actual
```

Clave del flujo: **compilar con el sistema, instalar/embeber con el versionado**. Los `-I/-L` resuelven headers/libs contra el toolchain real; el `--prefix` versionado solo decide DÓNDE se instala y QUÉ rutas quedan incrustadas en el binario.

## Decisiones Clave

| Decisión | Elegida | Alternativas | Razón |
|----------|---------|--------------|-------|
| Dónde parchar | **Build-time en GHA** | Wrappers/patchelf post-procesado local | El usuario tiene acceso al pipeline de construcción; los binarios "salen bien parchados" y `subinstall` no necesita lógica |
| Origen del build system | **PROPIO vendered** en `build-system/` (byte-idéntico a `de5ca479` + ~19 impl. `# Legacy compatibility:`) | Sparse checkout de master + parches en runtime | El runtime no depende de la red ni de la deriva de master: `gha-prepare.sh` copia el árbol commiteado y `normalize-legacy-builds.sh` aplica la normalización legacy de forma determinista |
| Reuso de dependencias | **PrevTermux Store**: pool por arquitectura (`prev-termux-pool-<arch>` + `manifest.json`) con hook en `termux_step_get_dependencies.sh` | Recompilar siempre / `-I` desde APT | Los builds históricos reutilizan deps ya compiladas (también en `-F`/subversioned) y acortan los tiempos; el publish separa deps (`.deb`) de objetivos (`.deb` + `.pkg.tar.xz`) |
| Mecanismo | **`TERMUX_PREFIX_OVERRIDE` post-validación** (implementación vendered en `build-package.sh`): re-deriva el prefix ANTES de sourcear el `build.sh` (patrón glibc: `termux_build_props__set_termux_prefix_dir_and_sub_variables`) | Override de `TERMUX_PREFIX` (alias) o inyección en properties.sh + neutralizar validators | El override post-validación evita tocar properties.sh ni desactivar los validators. Al re-derivar ANTES de sourcear el `build.sh`, el wrapper proot y los diffs `@TERMUX_PREFIX@` quedan versionados sin parches manuales (validado con zig) |
| Compilación vs instalación | **El prefix versionado se propaga a todo** (compile + install + embed); el RUNPATH del toolchain apunta a `$VERSIONED/lib` | Separar -I/-L (sistema) de --prefix (versionado) | VERIFICADO: no hace falta desdoblar — configure usa `--prefix=$TERMUX_PREFIX` y `--disable-rpath`; el rpath (RUNPATH) lo añade el toolchain (`termux_setup_toolchain_29.sh:34`) derivado de `TERMUX__PREFIX__LIB_DIR`. Al versionar la raíz, compile, install y embed quedan coherentes |
| Libs propias del paquete | **RUNPATH automático**: el toolchain ya añade `-Wl,-rpath=$VERSIONED/lib` (confirmado en which real) | Añadir flags manuales | El RUNPATH se evalúa después del `LD_LIBRARY_PATH=$PREFIX/lib` global — solo suple libs que el sistema no tiene. Para zig (estático) no aplica |
| Shebangs y maps proot | **Post-procesado sed en GHA**: referencias a binarios de sistema → `$PREFIX` real | Dejarlos rotos / wrappers externos | `$VERSIONED_PREFIX/bin/sh` no existe (el shell es del sistema); el paquete debe apuntar a intérpretes reales |
| Identificación del artifact | **Sufijo `-subversioned` en tag/artifact/release** (job `build-subversioned`, activado con input `jobs`) | Mismo tag que el build normal | Un paquete igual (pkg+ver+sha) puede existir en build normal y en build versionado; deben distinguirse (y `deb2pkg.sh` nombra igual ambos artifacts → solo el tag distingue) |
| El ELF de zig y std-lib | Confiar en el walk relativo al exe + wrapper con path versionado correcto | ZIG_LIB_DIR forzado | Con el árbol versionado (`lib/zig/` junto al exe), zig encuentra su std-lib solo; el wrapper (build.sh) ya genera el path con `$TERMUX_PREFIX` → queda correcto |
| Formato de build | **SIEMPRE `--format debian`** + conversión `deb2pkg.sh` a `.pkg.tar.xz` | `--format pacman` cuando el commit lo soporta | Los commits **pre-2021-09 NO soportan `--format pacman`** (solo producen `.deb`); el `.deb` es el formato universal que generan TODOS los commits. La conversión replica el template exacto de termux (`.PKGINFO`/`.MTREE`/`.BUILDINFO`) y se valida con `pacman -Qip` |
| Deps versionadas | **Forzar `-F` (full mode) SIEMPRE en subversioned** | Compilar deps aparte con el mismo prefix / `-I` con deps del sistema | La recursión de `build-package.sh` **hereda `TERMUX_PREFIX_OVERRIDE`** del entorno → las deps caen automáticamente en el prefix versionado sin cambios extra. Coste: rebuild completo de la cadena (horas en cadenas grandes) |
| Artifacts publicados | **Ambos: `.deb` original + `.pkg.tar.xz` convertido** | Solo `.pkg.tar.xz` | El `.deb` es el artifact canónico del build y el `.pkg.tar.xz` el de entrega (`subinstall`/pacman); subir ambos permite inspeccionar el original y da un fallback |

> 🎯 **Coherencia con la codebase**: el `TERMUX_PREFIX_OVERRIDE` sigue el patrón idempotente de las implementaciones vendered (marca `# Legacy compatibility:` + grep-check). El workflow reutiliza los inputs del `workflow_dispatch` (`jobs`, `use_store`, `heavy`, `format` con default `debian`; el build SIEMPRE compila `.deb` y `deb2pkg.sh` lo convierte) y el tag `-subversioned` sigue el patrón de los tags actuales. Verificado contra `style.md`.

## Riesgos y Suposiciones

**Mitigados en la implementación (`TERMUX_PREFIX_OVERRIDE` vendered):**
- **Validators del prefix**: `path_under_termux_rootfs` / `invalid_termux_prefix_paths` no se neutralizan. El override se aplica **post-validación** (patrón glibc): `build-package.sh` re-deriva `TERMUX__PREFIX` y sub-variables con `termux_build_props__set_termux_prefix_dir_and_sub_variables "$TERMUX_PREFIX_OVERRIDE" "true"` después de que properties.sh validó el prefix estándar y se sourceó termux-setup-package-manager, antes de `termux_step_setup_variables`.
- **`TERMUX_PREFIX_CLASSICAL` y massage**: CLASSICAL se alinea con el prefix versionado (`TERMUX_PREFIX_CLASSICAL="$TERMUX_PREFIX_OVERRIDE"`, también `TERMUX__PREFIX_CLASSICAL`), de modo que el `.pkg.tar.xz` contiene el árbol versionado `data/data/.../home/.local/opt/<pkg>-<ver>/...` — el layout esperado por `subinstall`.
- **Deps en modo subversioned**: el bootstrap `cp -as` (symlinks de `bin etc include lib libexec share var` del prefix real bajo el versionado) se crea como base del árbol; las deps reales se resuelven con **`-F` forzado** (la recursión de `build-package.sh` hereda `TERMUX_PREFIX_OVERRIDE` y cada dep se recompila en el prefix versionado). El DESTDIR/massagedir es un árbol separado, así que el paquete producido nunca contiene este bootstrap.
- **Shebangs y maps proot**: `termux_step_fix_versioned_shebangs` (post-massage) remapea `<versioned>/bin/{sh,bash,env,...}` → PREFIX real, con guard de intérpretes que el propio paquete instala (`python3.12`, `lua5.4`, ...) y word boundary para no romper `sed-helper`/`python-config`.

**Abiertos (a futuro):**
- **Coste de `-F` en subversioned**: el modo subversioned fuerza `full mode` SIEMPRE (la recursión de `build-package.sh` hereda `TERMUX_PREFIX_OVERRIDE` y las deps caen en el prefix versionado). En cadenas de dependencias grandes, el rebuild completo de toda la cadena puede tardar **horas** en los runners gratuitos de GHA. *Mitigación*: fast mode (`-I`) sigue disponible en el build normal.
- **Write-through acotado del bootstrap**: `cp -as` crea symlinks; escribir a través de uno modifica el archivo del sistema base. Acotado porque el build escribe solo en DESTDIR/massagedir (árbol separado) y el bootstrap se limita a dirs de lectura (`bin etc include lib libexec share var`). *A futuro*: copia real en vez de symlink si se confirma algún write-through.
- **Fallback TMPDIR de `deb2pkg.sh`**: la conversión usa `${TMPDIR:-$HOME/tmp}` para trabajar (NUNCA `/tmp`, no escribible en Termux si `TMPDIR` no está definido). En GHA, si `TMPDIR` no está definido se usa `$HOME/tmp` — válido, pero el runner debe tener espacio suficiente para el árbol extraído del `.deb`.
- **Naming de artifacts**: el nombre del `.pkg.tar.xz` sale de los **campos del control** del `.deb` (`pkg-ver-rev-arch`), con la versión sanitizada con la regla del prefix (`tr` + `sed`) y sufijo `-0` si falta (libalpm). Riesgo: si un paquete no sigue la convención `pkg-ver-rev-arch` o su versión tiene caracteres inusuales, el nombre puede no coincidir con el dir del árbol versionado (`~/.local/opt/<pkg>-<ver>/`) que espera `subinstall`.
- **El artifact versionado NO es instalable con pacman**: paths `~/.local/opt/<pkg>-<ver>/` no corresponden al prefix del dispositivo. Es un artifact "portable" para `subinstall`. *Suposición*: el usuario entiende la distinción (modo normal vs `--subversioned`).
- **proot en zig 0.15.2 y wrappers similares**: el wrapper usa `proot -b "$PREFIX/bin/env:/usr/bin/env"`. La función de shebangs remapea `<versioned>/bin/env` → PREFIX real; otros paquetes con wrappers proot quedan cubiertos por la misma heurística (solo si el binario referencia está en la lista de intérpretes).
- **Scripts con paths en datos** (no solo shebang): si un paquete embebe `$TERMUX_PREFIX` en medio de un archivo de config (`etc/`), el post-procesado lo cubre solo si la referencia es a un binario de sistema de la lista de intérpretes. Casos exóticos requieren revisión manual.
- **Verificación empírica HECHA (2026-07-31)**: zig 0.15.2 real = ELF estático sin paths Termux (solo el wrapper `usr/bin/zig` tiene el hardcode) → el fix es regenerar el wrapper con el prefix versionado (ya lo hace el build.sh vía heredoc) + reescribir el map proot. which 2.25 real = RUNPATH `/data/data/.../usr/lib` → al versionar el prefix, el RUNPATH apuntará al versionado automáticamente.

## Estado

**Implementado (2026-07-31 — Fase 2):**
- [x] Concepto definido (fase 2: build versionado-relocatable en GHA)
- [x] Problema diagnosticado con evidencia (wrapper proot zig, elf-cleaner, precedencia loader, ZIG_LIB_DIR)
- [x] Verificación empírica del binario real (zig estático sin paths; which con RUNPATH; properties.sh como punto de inyección)
- [x] Workflow con jobs `both` (2 jobs: `build-normal` + `build-subversioned`), `normal` o `subversioned`; `timeout-minutes: 600`
- [x] **`TERMUX_PREFIX_OVERRIDE`** (implementación vendered en `build-package.sh`): re-deriva el prefix ANTES de sourcear el `build.sh` (patrón glibc), CLASSICAL alineado, bootstrap `cp -as`, post-procesado de shebangs/maps proot al PREFIX real con guard de intérpretes propios
- [x] CLI `--subversioned` (busca/crea tag `{pkg}-{ver}-{sha7}-subversioned`) y `subinstall` con layout auto-detectado (versionado → strip 5 a `$HOME`; estándar → comportamiento actual)
- [x] `scripts/lib/version-extract.sh` (extracción canónica de versión, reutilizada por discover.sh y gha-build.sh)
- [x] Scripts GHA: `gha-prepare.sh` (preparación build system vendered) y `gha-build.sh` (build con `--subversioned` y guards de sanidad)
- [x] Code review: 2 CRITICAL + 6 MAJOR corregidos; ronda final: 1 CRITICAL + 2 MAJOR corregidos
- [x] Test funcional local PASA

**Implementado (2026-08-09 — vendered + store + CLI rediseñada + zig verde):**
- [x] **Build system PROPIO vendered** (`build-system/` byte-idéntico a `de5ca479` + ~19 impl. `# Legacy compatibility:`; commit `5b518a5`); runtime sin descarga de master ni parches (`aac06f0`)
- [x] **PrevTermux Store**: pool `prev-termux-pool-<arch>` + `manifest.json`; `store-lib.sh` (hook en `termux_step_get_dependencies.sh`), `store-publish.sh`, input `use_store`, caché CI (`7938ce6`); AppArmor `[^o.]` resuelto (`89861d4`)
- [x] **`zig` 0.15.2 y 0.16.0 SUBVERSIONADO VERDE** (runs `31303490256` / `31303490320`; `jobs=subversioned`, `heavy=true`): `TERMUX_PREFIX_OVERRIDE` re-deriva el prefix ANTES de sourcear el `build.sh` → wrapper proot (0.15.2) y diffs `@TERMUX_PREFIX@` (0.16.0) versionados sin parches manuales
- [x] **CLI rediseñado** (`5545998`, `8c85754`): `build` detecta runs, `subinstall` descarga de GitHub (todas las versiones con fzf → elige subversion/normal), `install` (nuevo), `switch` (nuevo), `fetch` (pool del store), `list`, `status`, `cache`, `help`; fzf opcional
- [x] Fixes de compatibilidad: termux-am en listas DEPENDS (`ac6ae52`), shim automake-N.N (`a750096`), autoreconf tar/util-linux (`b90e831`, `ed86935`), checksums foot (`8f645d5`), workflow `jobs`+timeout (`e8be5f4`) y `success()` (`a11a65b`)

**Pendiente:**
- [ ] Re-validar `bash@8ca9404` en CI (bash 5.3; FASE 2c util-linux commiteada en `ed86935` → relanzar) → desbloquea `bat@2f2adec` (regresión)
- [ ] Limpiar debug de parches 007–009
- [ ] Commit/push (cuando el usuario lo pida)
- [x] Docs del flujo (README/esquema/PROGRESS/AGENTS/style — actualizadas)

## Notas para el Orquestador

1. **El caso zig es el test de oro — COMPLETADO (2026-08-09)**: `zig` 0.15.2 y 0.16.0 subversionado **VERDE** (runs `31303490256` / `31303490320`). Con el prefix versionado, el wrapper `bin/zig` de 0.15.2 apunta a `~/.local/opt/zig-0.15.2/lib/zig/zig` (correcto) y el walk relativo encuentra la std-lib. El usuario confirmó que 0.15.2 funciona.
2. **Mecanismo implementado**: se usa `TERMUX_PREFIX_OVERRIDE` (env) leída por `build-package.sh` para **re-derivar el prefix ANTES de sourcear el `build.sh`** (patrón glibc). La variable se inyecta al contenedor vía `TERMUX_DOCKER_EXEC_EXTRA_ARGS` desde `gha-build.sh --subversioned`. La implementación vive vendered en `build-system/` (marca `# Legacy compatibility:`), no como parche en runtime.
3. **Decisiones de flujo**: el workflow acepta `jobs` (`both|normal|subversioned`), `use_store`, `heavy` y `timeout-minutes: 600`. La publicación al pool del store se serializa con `needs` + `success()` (el skip de un job no bloquea la publicación del otro; commit `a11a65b`). `gha-prepare.sh` copia `build-system/` vendered + `store-lib.sh` y ejecuta `normalize-legacy-builds.sh`; `gha-build.sh` comparte el build (`--store`, `--subversioned`, `heavy`). `version-extract.sh` es la extracción canónica de versión.
4. **Deuda existente a conservar**: resolución de versión duplicada (discover.sh ↔ step `get_version` del workflow — mismo algoritmo, código duplicado); parches 007–009 con debug que limpiar; **relanzar CI de `bash@8ca9404`** (FASE 2c util-linux ya commiteada en `ed86935`) para desbloquear `bat@2f2adec` (regresión).
5. **Compatibilidad con el flujo actual**: el modo `subversioned` es OPT-IN en el CLI (`--subversioned` / `jobs=subversioned`) y publica su PROPIO release separado, así que los builds normales (`which`, `bash`, `tar`) no se rompen.
6. **PrevTermux Store**: reutiliza deps ya compiladas del pool (`prev-termux-pool-<arch>` + `manifest.json`) a través del hook `store-lib.sh` en `termux_step_get_dependencies.sh` (también en `-F`/subversioned); `store-publish.sh` publica deps solo `.deb` y objetivos `.deb` + `.pkg.tar.xz`. Mitiga el coste de `-F` en subversioned.
7. **Pipeline `.deb` + conversión**: el build SIEMPRE compila con `--format debian` (formato universal; los commits pre-2021 solo producen `.deb`); `deb2pkg.sh` convierte cada `.deb` a `.pkg.tar.xz` replicando el template exacto de termux. En subversioned se fuerza `-F` para versionar también las deps (la recursión hereda `TERMUX_PREFIX_OVERRIDE`). Ojo: `deb2pkg.sh` nombra igual ambos artifacts → siempre descargar por el tag correcto.
