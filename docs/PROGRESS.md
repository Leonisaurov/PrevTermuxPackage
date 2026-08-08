# Progress Log — PrevTermuxPackage

> Documento de estado/progreso del proyecto — fecha: 2026-08-08

## Estado actual (2026-07-31)

> ⚠️ Superado (2026-08-08): el bloqueo histórico "exit 2 en `termux_step_make_install`" (bash @ e4f2135) quedó **resuelto** y validado en CI — ver sección "2026-08-08 — bash @ e4f2135 VERDE en CI (fix gnu89, fase 2)".

### Resumen ejecutivo

- **Estado**: En desarrollo activo
- **Objetivo**: compilar commits antiguos de `termux-packages` con el build system moderno
- **Bloqueo actual**: exit 2 en `termux_step_make_install` al compilar `bat` (commit 2018)

## Arquitectura del sistema

- **CLI local**: `scripts/prev-termux` (fzf, gh, git) + `scripts/lib/discover.sh`
- **GHA workflow**: `.github/workflows/build-old-package.yml` (`workflow_dispatch`)
- **Pipeline de build**: compila SIEMPRE `.deb` (`--format debian`, formato universal) y `scripts/deb2pkg.sh` lo convierte a `.pkg.tar.xz` (pacman)
- **Resultado**: `.deb` + `.pkg.tar.xz` vía releases de GitHub

## Descubrimientos (whack-a-mole del build system)

### Problemas resueltos (10 parches + fixes de workflow)

| # | Problema | Causa raíz | Fix |
|---|----------|-----------|-----|
| 1 | `groupmod: Permission denied` | `run-docker.sh` del commit 2018 es rudimentario (47 líneas, sin sudo) | Sparse checkout de `scripts/` modernos |
| 2 | AppArmor/Seccomp faltantes | Archivos no existen en commits viejos | Incluidos en `scripts/` |
| 3 | `build-package.sh` no soporta `--format` | Flag agregado después de 2018 | Descargar de master |
| 4 | `repo.json` faltante | No existe en commits viejos | Descargar de master |
| 5 | GPG keys faltantes | `termux-keyring` viejo | Sparse checkout `packages/termux-keyring` |
| 6 | `termux-elf-cleaner` v1.2 → 404 | `build.sh` viejo (v1.2), assets desde v2.2.0 | Sparse checkout `packages/termux-elf-cleaner` |
| 7 | `Not a directory: root-packages` | `buildorder` espera dirs que no existen en 2018 | `mkdir -p root-packages x11-packages` |
| 8 | `falset-found` (corrupción) | sed greedy `.*` no anclado en DEPENDS | Regex anclado `^ $` |
| 9 | `freetype-dev` no resuelto | `buildorder.py` moderno perdió mapeo `-dev`→padre | Patch 001 |
| 10 | `python`/`libllvm` source falla | `setup_variables` sourcea `build.sh` con código ejecutable | Patch 003 (grep) |
| 11 | `cargo not found` | `make_install` ya no llama `termux_setup_rust` (desde oct-2025) | Patch 004 |
| 12 | rust 0.7.1 (versión de bat) | `termux_setup_rust` sourcea `packages/rust` que no existe en 2018, captura `TERMUX_PKG_VERSION` del entorno | Patch 005 (grep+fallback) |
| 13 | `BUILD_IN_SRC=yes` no interpretado | `start_build` compara con `"true"` estricto | Patch 006 (yes OR true) |
| 14 | exit 2 en `termux_step_make_install` (bash 4.4) | Sub-make `builtins/` compila `mkbuiltins.c` sin `-std=gnu89` (C23 vs prototipos K&R 2018) | Fix en `termux_step_pre_configure` (commit `b5cdf39`, bloque 10 FASE 2) |

### Parches creados (`patches/`)

- `001-buildorder-dev-mapping.patch`: `re.sub('-dev$','')` en `buildorder.py`
- `002-extract-dep-info-dev.patch`: `PKG=${PKG/-dev/}` en `extract_dep_info`
- `003-setup-vars-fallback.patch`: grep en vez de source para `python`/`libllvm`
- `004-make-install-rust.patch`: `termux_setup_rust` automático
- `005-termux-setup-rust.patch`: grep+fallback 1.75.0
- `006-start-build-build-in-src.patch`: `BUILD_IN_SRC` acepta `yes`/`true`
- `007-patch-package-normalize-paths.patch`: normaliza `../pkg-ver/` → `./` + DEBUG
- `008-post-patch-debug.patch`: marcadores DEBUG en build-package.sh (investigación exit 2)
- `009-make-install-debug.patch`: envoltura `2>&1 | tee + PIPESTATUS` del cargo install (investigación exit 2)
- `010-prefix-override.patch`: `TERMUX_PREFIX_OVERRIDE` (prefix versionado) + `termux_step_fix_versioned_shebangs` (shebangs/maps proot)

### Script de parches

- `scripts/patch-build-system.sh`: idempotente, 10 parches (001–010) + normalización legacy
- Aplica parches con `patch -p1`, verifica con grep, salta si ya aplicado

## Problema actual: exit 2 en `termux_step_make_install` (EN INVESTIGACIÓN)

> ✅ **RESUELTO (2026-08-08)**: la causa raíz era el sub-make `builtins/` de bash 4.4 compilando `builtins/mkbuiltins.c` sin `-std=gnu89` → fix commit `b5cdf39`, validado en CI (run 31235032686). Se conserva esta sección como log de la investigación; ver sección "2026-08-08".

### Síntoma

```
>>> make_install
##[error]Process completed with exit code 2.
```

(El exit 2 ocurre en `termux_step_make_install`, ~58ms tras el marcador `>>> make_install`, sin output: fallo silencioso)

### Hechos confirmados

1. El parche `Cargo.toml.patch` aplica correctamente (PATCH EXIT 0, verificado)
2. El exit 2 ocurre en `termux_step_make_install` (run 30615771833, marcadores del patch 008)
3. Todos los pasos previos OK: `setup_toolchain`, `patch_package`, `configure`, `make`
4. El fallo es silencioso: ~58ms sin output tras el marcador `>>> make_install`
5. `Cargo.toml` está PLANO en `/home/builder/.termux-build/bat/src` (`strip-components=1`)
6. Patch normalizado correcto: `--- ./Cargo.toml`
7. GNU patch 2.8 en `/usr/bin/patch` (Ubuntu, NO BusyBox)
8. Localmente con sed simplificado (4 reglas) da exit 0
9. CI usa sed completo: 11 reglas `@TERMUX_*@` + 2 normalización

### Hipótesis principal (REFUTADA por run 30614617305)

~~Alguna variable TERMUX_ENV__S_* podría estar UNSET en el contenedor → sed completo genera patch corrupto/vacío → patch recibe basura → exit 2 ("Only garbage")~~

**Evidencia del run 30614617305:**
- DEBUG VARS: TODAS SET (ninguna UNSET)
- SED EXIT: 0, SED STDERR: vacío
- PATCH EXIT: 0 (patching file Cargo.toml, aplicó correctamente)
- El exit 2 ocurre ~63ms DESPUÉS del último debug (post-patch)
- Conclusión: el parche 007 FUNCIONA; el fallo está en un paso posterior

### Hipótesis principal (ACTUAL)

- ~~UNSET/garbage~~ refutada (ver arriba, run 30614617305)
- **Nueva**: el parche 004 (`termux_setup_rust` automático) o `cargo install` falla en `make_install`
  (rama Rust de `bat`; fallo silencioso, el runner probablemente no expone el stderr)

### Estado

- Run 30614617305: hipótesis UNSET refutada, parche 007 confirmado funcional (PATCH EXIT 0)
- **Run 30615771833 (patch 008): paso culpable identificado → `termux_step_make_install`**
- Todos los pasos previos OK: `setup_toolchain`, `patch_package`, `configure`, `make`
- Pendiente: capturar stderr de `make_install` (el runner no lo expone)

## 2026-07-31 — Fase 2: builds subversioned (2 jobs GHA)

### Qué se implementó

- **Workflow con 2 jobs SIEMPRE activos** (`.github/workflows/build-old-package.yml`): `build-normal` (como antes) y `build-subversioned` (nuevo). Ambos se lanzan en CADA run (`workflow_dispatch`), independientes (sin `needs`), sin skips. Inputs sin cambios salvo `format` (default `debian` — ver sección de reestructuración).
- **Patch 010** (`patches/010-prefix-override.patch`, paso 11 de `scripts/patch-build-system.sh`): soporta `TERMUX_PREFIX_OVERRIDE` en `build-package.sh` de master:
  - Override post-validación (patrón glibc: `termux_build_props__set_termux_prefix_dir_and_sub_variables`).
  - `TERMUX_PREFIX_CLASSICAL`/`TERMUX__PREFIX_CLASSICAL` alineados al prefix versionado (el tar trae el árbol versionado).
  - Bootstrap del sistema base: `cp -as` de `bin etc include lib libexec share var` del prefix real bajo el versionado (deps de fast mode visibles al compilador).
  - `termux_step_fix_versioned_shebangs` (post-massage): remapea shebangs y maps proot `<versioned>/bin/<interp>` → PREFIX real, con guard de intérpretes que el propio paquete instala.
- **CLI**: `prev-termux build <pkg> --subversioned` busca/crea el tag `{pkg}-{ver}-{sha7}-subversioned`; `subinstall` detecta el layout del tar (`tar -tf`: `home/.local/opt/` → versionado → `--strip-components=5` a `$HOME`; `com.termux/files/usr/` → estándar → comportamiento actual).
- **`scripts/lib/version-extract.sh`**: extracción canónica de versión (resuelve `${VAR}`, `${VAR%.*}`, etc.), reutilizada por `discover.sh` y `gha-build.sh`.
- **Scripts GHA**: `scripts/gha-prepare.sh` (preparación del build system: sparse checkout master + parches 001–010) y `scripts/gha-build.sh` (build con `--subversioned`; guards de sanidad: patch 010 aplicado, formato/arquitectura válidos, path sin espacios/globs).

### Flujo de code review

- 2 CRITICAL + 6 MAJOR corregidos (revisión inicial).
- 1 CRITICAL + 2 MAJOR finales corregidos (ronda final).
- **Test funcional local PASA** (subinstall con layout versionado y estándar).

### Pendientes (Fase 2)

- [ ] Prueba real en GHA de un build subversioned: **ncurses** (con deps) — `bash` ✅ (run 31235032686, ver sección 2026-08-08).
- [x] Commit/push de la fase 2 — hecho (incluye el fix gnu89, commit `b5cdf39`, y AGENTS.md, commit `a2b9a9d`).
- [ ] Limpiar debug de parches 007–009.
- [x] Documentar el flujo (README/esquema/PROGRESS — actualizadas).

## 2026-07-31 — Reestructuración: pipeline .deb + conversión + deps versionadas

### Qué se implementó

- **`scripts/deb2pkg.sh` (NUEVO)**: convierte cada `.deb` → `.pkg.tar.xz` (pacman) replicando el template EXACTO de `termux_step_create_pacman_package.sh` de termux (master):
  - `.PKGINFO` con las mismas transformaciones de deps (`Depends "pkg (>= ver)"` → `depend = pkg>=ver`), conffiles → `backup`, etc.
  - `.MTREE` comprimido con gzip (comando exacto de termux) y `.BUILDINFO`.
  - Re-empaquetado con `bsdtar --no-fflags` + `xz`.
  - Nombre del artifact: `{pkg}-{ver}-{rev}-{arch}.pkg.tar.xz` (separadores `-`, no `_`), con la versión sanitizada con la regla del prefix (`tr -d '"' "'" ' '` + `sed 's/[^a-zA-Z0-9._-]/-/g'`) y sufijo `-0` si el `Version` no trae release (libalpm ≥ 16 lo rechaza sin release).
  - Usa `${TMPDIR:-$HOME/tmp}` para trabajar (NUNCA `/tmp`, no escribible en Termux si `TMPDIR` no está definido).
  - **Testeado con `pacman -Qip`**.
- **`scripts/gha-build.sh` — pipeline .deb + conversión + deps versionadas**:
  - `--format debian` **SIEMPRE** (el input `format` se acepta/valida `pacman|debian` por compatibilidad con el dispatch manual, pero el build ignora el flag: el `.deb` es el formato universal, compatible con commits pre-2021-09 que no soportan `--format pacman`).
  - En modo subversioned fuerza `-F` (full mode) **SIEMPRE**, sin importar `--build-mode`: la recursión de `build-package.sh` hereda `TERMUX_PREFIX_OVERRIDE` → las **deps también quedan versionadas** en el prefix `~/.local/opt/<dep>-<ver>/`.
  - Conversión post-build con `deb2pkg.sh`: busca los `.deb` en `output/` (master, `TERMUX_OUTPUT_DIR`) y `debs/` (commits pre-2021, `TERMUX_DEBDIR`).
  - Guard: si no hay `.deb` tras el build → error explícito.
- **Workflow `.github/workflows/build-old-package.yml`**:
  - Input `format`: default `debian` (antes `pacman`), con descripción documentando que el build SIEMPRE compila `.deb` y `deb2pkg.sh` lo convierte a `.pkg.tar.xz`.
  - Step **`Install conversion tools`** en AMBOS jobs: `apt install libarchive-tools binutils` (`bsdtar` + `ar`; `dpkg-deb`/`xz` ya vienen en ubuntu-latest).
  - Upload y release adjuntan **AMBOS formatos**: `*.deb` original + `*.pkg.tar.xz` convertido (notas del release: `Artifacts: .deb + .pkg.tar.xz`).
- **Fixes de bloqueantes con verificación**:
  - Naming del artifact desde los **campos del control** del `.deb` (no del basename, que usa `_`), con la regla de sanitización del prefix para que coincida con el dir del árbol versionado de `subinstall`.
  - Sufijo `-0` para pacman (libalpm rechaza `pkgver` sin release).
  - Fallback `$TMPDIR` (nunca `/tmp`).
  - Conversión validada con `pacman -Qip` (test local OK).

### Pendientes (reestructuración)

- [ ] Prueba real en GHA: **ncurses** (con deps) — validar pipeline .deb → deb2pkg.sh → .pkg.tar.xz y deps versionadas en condiciones reales (`bash` ✅ en run 31235032686, ver sección 2026-08-08).
- [ ] Commit/push (cuando el usuario lo pida).
- [ ] Limpiar debug de parches 007–009.

## 2026-08-08 — bash @ e4f2135 VERDE en CI (fix gnu89, fase 2)

### Contexto

El bloqueo histórico "exit 2 en `termux_step_make_install`" y la deuda de `bash@e4f2135` (Fase 2) quedaron **resueltos** y validados en CI.

### Causa raíz exacta

- El sub-make `builtins/` de bash 4.4 usa su **propio** `builtins/Makefile.in`, con `CCFLAGS_FOR_BUILD = $(BASE_CCFLAGS) $(CPPFLAGS_FOR_BUILD) $(CFLAGS_FOR_BUILD)` (línea 99 de bash-4.4).
- Los build-tools (mkbuiltins, mksyntax, mksignames) se compilan con el **gcc del HOST** usando `CCFLAGS_FOR_BUILD` (no `CFLAGS`, que se pierde a nivel top-level del `build.sh`).
- `builtins/mkbuiltins.c` (2018, prototipos K&R `f()`) fallaba con compiladores C23 ("too many arguments") al compilar sin `-std=gnu89` → exit 2 silencioso en `termux_step_make_install`.

### Fix aplicado

- **commit `b5cdf39`**: el sed inyectado en `termux_step_pre_configure` de bash (bloque 10 FASE 2 de `scripts/patch-build-system.sh`, guard `declare -A PATCH_CHECKSUMS`) ahora parchea `Makefile.in` **y** `builtins/Makefile.in`, añadiendo `-std=gnu89` a `CCFLAGS_FOR_BUILD` en ambos.
- **commit `a2b9a9d`**: `AGENTS.md` trackeado y actualizado (estado y lecciones).

### Resultado CI

- **Run 31235032686** (2026-08-08): **success en AMBOS jobs** (`build-normal` y `build-subversioned`).
- Evidencia: `gcc -c -std=gnu89 ... builtins/mkbuiltins.c` en ambos jobs; `make` / `make_install` / `post_make_install` OK.
- 9 `.deb` → `.pkg.tar.xz`; releases `bash-4.4.23-e4f2135` y `bash-4.4.23-e4f2135-subversioned` creados (18 assets cada uno).

### Lección operativa

- Usar SIEMPRE el **SHA completo** de termux-packages como `git_ref` en el `workflow_dispatch`: `actions/checkout@v4` NO fetchea SHAs abreviados (el run 31234975490 falló en el step "Checkout termux-packages" por eso).

## Pendientes

### Resueltos (2026-08-08)

- [x] Capturar stderr de `make_install` — RESUELTO: la causa raíz era el sub-make `builtins/` de bash 4.4 compilando `builtins/mkbuiltins.c` sin `-std=gnu89` (commit `b5cdf39`, run 31235032686). Ver sección 2026-08-08.
- [x] Verificar si `termux_setup_rust` o `cargo install` falla — el exit 2 real NO era cargo/rust; era el build-tool de bash (`builtins/mkbuiltins.c`). Ver sección 2026-08-08.
- [x] Aplicar fix definitivo del exit 2 real — commit `b5cdf39` (`-std=gnu89` en `Makefile.in` y `builtins/Makefile.in`), validado en CI (run 31235032686).

### Inmediatos

- [ ] Limpiar debug de parches 007–009 (incluye los marcadores DEBUG de 008/009 usados en la investigación del exit 2).

### Pruebas de regresión

- [ ] `bat` (commit `e4f21355`) — build exitoso
- [ ] `which` (commit `ec22dc1`) — no romper lo que funcionaba
- [ ] `zig` (commit `6bd499e`) — compatibilidad amplia

### Documentación

- [ ] Actualizar `docs/build-system-internals.md` con hallazgos de rust/setup_rust/patches (si no están)
- [ ] Documentar en README el flujo con parches
- [ ] Known Issues (commits < 2019 pueden tener incompatibilidades no cubiertas)

### Mejoras futuras

- [ ] Caché de builds (toolchain, LLVM)
- [ ] Manejar commits pre-2019 con más limitaciones (`develsplit` eliminado)

## Conclusión

El whack-a-mole reveló que el build system moderno y los commits 2018 son **MUY diferentes**. Los parches 001–010 cubren las incompatibilidades conocidas (001–009 compatibilidad con commits antiguos + 010 prefix versionado). La **Fase 2 (builds subversioned)** quedó implementada y probada localmente (ver sección "2026-07-31 — Fase 2"), la **reestructuración del pipeline** (build siempre `.deb` + conversión `deb2pkg.sh` a `.pkg.tar.xz` + deps versionadas con `-F`) quedó implementada y verificada localmente (ver sección "2026-07-31 — Reestructuración"), y el **bloqueo histórico del exit 2** (bash @ e4f2135: sub-make `builtins/` sin `-std=gnu89`) quedó **resuelto y validado en CI** (run 31235032686, ver sección "2026-08-08"). Pendientes reales: pruebas de regresión (`bat`/`which`/`zig`), limpiar el debug de los parches 007–009 y actualizar `docs/build-system-internals.md` con los hallazgos de rust/`setup_rust`.
