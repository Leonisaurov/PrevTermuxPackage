# Progress Log — Paquetes Históricos (PrevTermuxPackage)

> Documento de progreso del proyecto (build system vendered + PrevTermux Store) — fecha: 2026-08-09

## 1. Arquitectura actual (2026-08-08/09)

### Build system vendered (`build-system/`)

- Árbol **byte-idéntico** al commit `de5ca479b62d2b9b9435eabaa91618dba9c32fb4` de `termux/termux-packages` (master), COMMITEADO en el repo.
- **18 implementaciones directas** con marcador `# Legacy compatibility:` (16 parches migrados 001–016 + blindaje LLVM + 2 del PrevTermux Store 017/018; shim `automake-N.N` id 019 añadido en el commit `a750096`).
- Metadata del fork en `build-system/REVISION` (upstream SHA, URL, fecha de import), `build-system/FORK.md` (tabla de implementaciones) y `build-system/.fork-files` (12 archivos con implementaciones; abort-on-conflict al actualizar upstream).
- El runtime **ya NO descarga master** ni aplica parches externos: `gha-prepare.sh` copia el árbol vendered al árbol del paquete.

### PrevTermux Store

- **Pool de paquetes reutilizables** en GitHub Releases por arquitectura: tag `prev-termux-pool-<arch>` (p.ej. `prev-termux-pool-aarch64`), con `manifest.json` como índice.
- `scripts/store-lib.sh` (hook en `termux_step_get_dependencies.sh`: consulta el pool antes de recompilar una dep; reutiliza también en `-F`/subversioned; caché del manifest por run).
- `scripts/store-publish.sh` (publica deps SOLO `.deb` canónico; paquetes objetivo `.deb` + `.pkg.tar.xz`).
- `prev-termux fetch` (CLI local).
- Workflow con input `use_store` (default `true`); caché CI (`actions/cache`) con clave que incluye el modo (`prevstore-normal-*` / `prevstore-subversioned-*`) y `hashFiles('build-system/REVISION')`; serialización de publicación con `needs: build-normal` (línea 359 del workflow).

### `scripts/`

- `gha-prepare.sh` — copia `build-system/` al árbol + copia `store-lib.sh` + llama `normalize-legacy-builds.sh`. NO usa git clone ni curl.
- `gha-build.sh` — flag `--store`, envs `TERMUX_STORE_*`.
- `normalize-legacy-builds.sh` — normalización de `build.sh` históricos:
  - **FASE 1**: renames legacy (BLACKLISTED_ARCHES→EXCLUDED_ARCHES, DEBDIR→OUTPUT_DIR, MAKE_PROCESSES→PKG_MAKE_PROCESSES, NO_DEVELSPLIT→NO_STATICSPLIT, `=yes`→`=true`/`=no`→`=false`), URLs de source muertas (bintray, fossies), checksums recomputados.
  - **FASE 2**: gnu89 para bash 4.4 (inserciones con lookahead `N`/guard/`P`/`D`).
  - **FASE 2b**: `autoreconf -fi` en `pre_configure` para tar 1.35 (remake espurio de `src/Makefile.in`; automake-1.16 ausente en el runner).
  - **FASE 2c**: `autoreconf -fi` en `pre_configure` para util-linux 2.40.2 (mismatch automake 1.18.1 del runner vs 1.16.5 del tarball).
- `deb2pkg.sh` (`.deb` → `.pkg.tar.xz` pacman), `prev-termux`, `store-lib.sh`, `store-publish.sh`, `lib/discover.sh`, `lib/version-extract.sh`.
- `patches/` y `patch-build-system.sh` conservados como **REFERENCIA** (ya NO se ejecutan en runtime).

## 2. Commits de la sesión (en orden)

| Commit | Descripción |
|--------|-------------|
| `5b518a5` | vendor: import termux-packages build system @ de5ca479 (build-system/ vendered) |
| `aac06f0` | refactor: build system propio - gha-prepare sin master, normalize-legacy-builds, gha-build ajustado |
| `7938ce6` | feat: PrevTermux Store - pool de paquetes reutilizables (store-lib, store-publish, fetch, workflow) |
| `89861d4` | fix: store .store-cache Permission denied (AppArmor [^o.] + chmod defensivo) |
| `8f645d5` | fix: recomputar checksums foot 1.25.0/1.22.3 (codeberg regenero el gzip) |
| `b90e831` | fix: tar autoreconf -fi en pre_configure (remake espurio Makefile.in, automake-1.16 ausente) |
| `ac6ae52` | fix: termux-am transitiva en DEPENDS (Gradle/Java 17) - tokens en listas |
| `a750096` | fix: shim automake-N.N en setup_variables (remake espurio Makefile.in en sub-makes) |
| `ed86935` | fix: util-linux autoreconf -fi en pre_configure (mismatch automake 1.18.1 vs 1.16.5) — **FASE 2c, ya commiteado** |

## 3. Estado CI verificado

| Paquete @ git_ref | Resultado (ambos jobs) | Run | Notas |
|---|---|---|---|
| `which@1fcb6e8` | ✅ success | `31290337504` | Valida el fix AppArmor; releases + pool publicados |
| `bash@e4f2135` | ✅ success | `31291312681` | Fix gnu89 validado; 0 `Permission denied`; pool con 20 entradas |
| `tar@8ca9404` | ✅ success | `31296109277` | Fix autoreconf (FASE 2b) validado; releases + pool |
| `bash@8ca9404` | ❌ en desbloqueo | — | Superó `termux-am` (fix `ac6ae52` validado); topa en util-linux (mismatch automake) → **FASE 2c commiteada (`ed86935`), falta relanzar** |
| `bat@2f2adec` | ⏸️ en cola | — | Depende de `bash` |

- Logs de CI en `$TMPDIR/gita-*.log` (runs `31290337504`, `31291312681`, `31296109277`, `31293810431`, `31296447772`, `31297813819`, `31299802531`).

## 4. Lecciones duras nuevas (whack-a-mole)

- **AppArmor del build system**: `deny /home/builder/termux-packages/[^o]**` deniega escritura a todo menos lo que empieza por `o` → `.store-cache` necesita excepción `[^o.]` + `allow .store-cache/** rw` (commit `89861d4`).
- **codeberg regeneró el gzip** de foot 1.22.3/1.25.0 → checksum recomputado (contenido byte-idéntico, commit `8f645d5`).
- **`termux-am` transitiva en listas DEPENDS** (no solo dep única) → sed de tokens dentro de las listas (commit `ac6ae52`); **NO** vaciar la var (`TERMUX_PKG_DEPENDS=""` rompe buildorder).
- **Tarballs históricos con `Makefile.in` generados por automake-N.N (1.16)**: el remake espurio del sub-make invoca `automake-1.16` que no existe en el runner → fix por paquete `autoreconf -fi` en `pre_configure` (tar = FASE 2b, util-linux = FASE 2c) + shim genérico `automake-N.N` → `automake` en `setup_variables` (commit `a750096`).
- **El runner trae automake 1.18.1**; un tarball generado con 1.16.5 da "version mismatch" (exit 63) → `autoreconf -fi` regenera todo con la versión del sistema y elimina el mismatch.

## 5. Pendientes / siguientes pasos

- [ ] **Relanzar `bash@8ca9404`** en CI (FASE 2c ya commiteada en `ed86935`) → desbloquear `bat@2f2adec`.
- [ ] **SIGUIENTE GRAN OBJETIVO**: `zig` 0.15.2 y 0.16.0 **SUBVERSIONADO** (paths reemplazados a `~/.local/opt/zig-<ver>/`). Builds de ~5h cada una; se lanzarán sin monitoreo. Análisis del build system para asegurar build a la primera.
- [ ] Deuda: limpiar debug de parches 007–009; pruebas de regresión `bat`/`which`/`zig`; actualizar `docs/build-system-internals.md`.
- [ ] Ampliar la lista del shim `automake-N.N` (1.17/1.12) cuando aparezcan.
