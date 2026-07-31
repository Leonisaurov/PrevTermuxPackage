# Progress Log — PrevTermuxPackage

> Documento de estado/progreso del proyecto — fecha: 2026-07-31

## Estado actual (2026-07-31)

### Resumen ejecutivo

- **Estado**: En desarrollo activo
- **Objetivo**: compilar commits antiguos de `termux-packages` con el build system moderno
- **Bloqueo actual**: exit 2 al aplicar `Cargo.toml.patch` de `bat` (commit 2018)

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
| 14 | `Cargo.toml.patch` exit 2 | EN INVESTIGACIÓN (ver abajo) | Patch 007 (parcial) |

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

## Problema actual: exit 2 en `Cargo.toml.patch` (EN INVESTIGACIÓN)

### Síntoma

```
Applying patch: Cargo.toml.patch
patching file Cargo.toml
##[error]Process completed with exit code 2.
```

(exit 2 de GNU patch = fatal, sin mensaje visible pese a quitar `--silent`)

### Hechos confirmados

1. `Cargo.toml` está PLANO en `/home/builder/.termux-build/bat/src` (`strip-components=1`)
2. Patch normalizado correcto: `--- ./Cargo.toml`
3. GNU patch 2.8 en `/usr/bin/patch` (Ubuntu, NO BusyBox)
4. `--batch` no resuelve
5. Localmente con sed simplificado (4 reglas) da exit 0
6. CI usa sed completo: 11 reglas `@TERMUX_*@` + 2 normalización

### Hipótesis principal

Alguna variable `TERMUX_ENV__S_*` podría estar **UNSET** en el contenedor → el sed completo genera patch corrupto/vacío → patch recibe basura → exit 2 (*"Only garbage"*)

### Estado

- Run **30614617305** lanzado con debug que imprime: `DEBUG VARS` (valores/unset), `SED EXIT`, `SED STDERR`, `PATCH EXIT`, `PATCH STDERR`
- Resultado **SIN VERIFICAR aún**

## Pendientes

### Inmediatos

- [ ] Verificar log del run 30614617305 (debug de stderr)
- [ ] Aplicar fix definitivo del exit 2
- [ ] Limpiar debug del patch 007 (dejar solo lo necesario)

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

El whack-a-mole reveló que el build system moderno y los commits 2018 son **MUY diferentes**. Los parches 001–007 cubren las incompatibilidades conocidas. Falta resolver el exit 2 del patch de paquetes y validar con regresiones.
