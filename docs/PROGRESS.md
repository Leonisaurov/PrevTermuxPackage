# Progress Log — PrevTermuxPackage

> Documento de estado/progreso del proyecto — fecha: 2026-07-31

## Estado actual (2026-07-31)

### Resumen ejecutivo

- **Estado**: En desarrollo activo
- **Objetivo**: compilar commits antiguos de `termux-packages` con el build system moderno
- **Bloqueo actual**: exit 2 en `termux_step_make_install` al compilar `bat` (commit 2018)

## Arquitectura del sistema

- **CLI local**: `scripts/prev-termux` (fzf, gh, git) + `scripts/lib/discover.sh`
- **GHA workflow**: `.github/workflows/build-old-package.yml` (`workflow_dispatch`)
- **Resultado**: `.pkg.tar.xz` vía releases de GitHub

## Descubrimientos (whack-a-mole del build system)

### Problemas resueltos (7 parches + fixes de workflow)

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
| 14 | exit 2 en `termux_step_make_install` | EN INVESTIGACIÓN (ver abajo) | Patch 007 (parcial) |

### Parches creados (`patches/`)

- `001-buildorder-dev-mapping.patch`: `re.sub('-dev$','')` en `buildorder.py`
- `002-extract-dep-info-dev.patch`: `PKG=${PKG/-dev/}` en `extract_dep_info`
- `003-setup-vars-fallback.patch`: grep en vez de source para `python`/`libllvm`
- `004-make-install-rust.patch`: `termux_setup_rust` automático
- `005-termux-setup-rust.patch`: grep+fallback 1.75.0
- `006-start-build-build-in-src.patch`: `BUILD_IN_SRC` acepta `yes`/`true`
- `007-patch-package-normalize-paths.patch`: normaliza `../pkg-ver/` → `./` + DEBUG

### Script de parches

- `scripts/patch-build-system.sh`: idempotente, 7 parches + normalización legacy
- Aplica parches con `patch -p1`, verifica con grep, salta si ya aplicado

## Problema actual: exit 2 en `termux_step_make_install` (EN INVESTIGACIÓN)

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

## Pendientes

### Inmediatos

- [ ] Capturar stderr de `make_install` (`2>&1 | tee` en el patch 008, o revisar artefactos)
- [ ] Verificar si `termux_setup_rust` o `cargo install` falla
- [ ] Aplicar fix definitivo del exit 2 real
- [ ] Limpiar debug de patches 007 y 008 (dejar solo lo necesario)

### Pruebas de regresión

- [ ] `bat` (commit `e4f21355`) — build exitoso
- [ ] `which` (commit `ec22dc1`) — no romper lo que funcionaba
- [ ] `zig` (commit `6bd499e`) — compatibilidad amplia

### Documentación

- [ ] Actualizar `docs/build-system-internals.md` con hallazgos de rust/setup_rust/patches
- [ ] Documentar en README el flujo con parches
- [ ] Known Issues (commits < 2019 pueden tener incompatibilidades no cubiertas)

### Mejoras futuras

- [ ] Caché de builds (toolchain, LLVM)
- [ ] Manejar commits pre-2019 con más limitaciones (`develsplit` eliminado)
- [ ] Convertir `.deb` → `.pkg.tar.xz` como fallback

## Conclusión

El whack-a-mole reveló que el build system moderno y los commits 2018 son **MUY diferentes**. Los parches 001–007 cubren las incompatibilidades conocidas. Falta resolver el exit 2 de `termux_step_make_install` y validar con regresiones.

---

## 📌 Checkpoint (2026-07-31) — Trabajo movido a branch

Todo el trabajo del whack-a-mole quedó capturado en la branch:
**`experiment/whack-a-mole-build-system`** (66 commits, incluye parches 001-009, docs y workflow).

### Estado de la documentación

| Archivo | Qué cubre |
|---------|-----------|
| `docs/PROGRESS.md` (este) | Progreso completo: problemas resueltos, parches, problema actual, pendientes |
| `docs/build-system-internals.md` | Arquitectura interna del build system: variables legacy, termux_setup_rust, extracción, patches |
| `patches/*.patch` | Los 9 parches de compatibilidad (001-009) |
| `scripts/patch-build-system.sh` | Script idempotente que aplica los parches |

### Punto exacto donde quedó la investigación

- **Último run analizado**: 30615771833 — exit 2 identificado en `termux_step_make_install`
- **Parche 009 creado** (sin probar en CI): instrumenta make_install con `DEBUG-MI` + captura stderr del cargo install
- **Siguiente paso pendiente**: disparar build de bat con el patch 009 activo para capturar el stderr real de make_install

### Para retomar

```bash
# 1. Cambiar a la branch del experimento
git checkout experiment/whack-a-mole-build-system

# 2. Disparar build de bat con debug (patch 009 incluido)
gh workflow run build-old-package.yml -R Leonisaurov/PrevTermuxPackage \
  -f package_name=bat \
  -f git_ref=e4f2135503542a2924691975bcdcef85768139c0

# 3. Ver marcadores DEBUG-MI en el log
gh run view <RUN_ID> -R Leonisaurov/PrevTermuxPackage --log | grep "DEBUG-MI"

# 4. Aplicar fix definitivo + regresiones (which, zig) + limpiar debug
```

### Nota importante
- Los commits de este experimento están en la branch `experiment/whack-a-mole-build-system`
- `main` local tiene los commits pero `origin/main` NO fue pusheado con el último commit (0af5c81, patch 009)
- Si se quiere, se puede hacer PR de la branch a main, o mantenerla como referencia
