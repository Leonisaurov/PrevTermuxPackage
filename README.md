# PrevTermuxPackage

> Compila versiones antiguas de paquetes Termux en un solo comando.

Sistema automatizado (GitHub Actions + CLI interactivo) para compilar versiones antiguas de paquetes Termux en formato `.pkg.tar.xz` (para pacman). Descubre versiones históricas desde el historial de `termux-packages`, te deja elegir con `fzf`, y descarga el artefacto si ya fue compilado o dispara un build en la nube si es la primera vez.

![GitHub Workflow Status](https://img.shields.io/badge/build-automated-brightgreen)
![License](https://img.shields.io/badge/license-MIT-blue)

---

## Requisitos previos

- Tener el proyecto en un **repositorio de GitHub**
- **gh CLI** autenticado (`gh auth status`)
- **fzf**, **jq**, **git** instalados en Termux
- `gh auth login` ejecutado previamente (el CLI verifica al inicio)
- El workflow GHA debe estar presente en `.github/workflows/` del repo

Instalación de dependencias locales:

```bash
pkg install fzf jq git gh
```

## Estructura del proyecto

```
PrevTermuxPackage/
├── .github/workflows/
│   └── build-old-package.yml    # Workflow GHA: 2 jobs (build-normal + build-subversioned)
├── output/                      # Artifacts descargados (.pkg.tar.xz)
├── patches/
│   ├── 001-buildorder-dev-mapping.patch
│   ├── 002-extract-dep-info-dev.patch
│   ├── 003-setup-vars-fallback.patch
│   ├── 004-make-install-rust.patch
│   ├── 005-termux-setup-rust.patch
│   ├── 006-start-build-build-in-src.patch
│   ├── 007-patch-package-normalize-paths.patch
│   ├── 008-post-patch-debug.patch
│   ├── 009-make-install-debug.patch
│   └── 010-prefix-override.patch    # Prefix versionado (TERMUX_PREFIX_OVERRIDE)
├── scripts/
│   ├── prev-termux              # CLI principal (entrypoint interactivo)
│   ├── gha-prepare.sh           # Prepara el build system (master + parches 001–010)
│   ├── gha-build.sh             # Build compartido (--format debian, --subversioned, conversión)
│   ├── deb2pkg.sh               # Convierte .deb → .pkg.tar.xz (pacman)
│   ├── patch-build-system.sh    # Aplica parches 001–010 (idempotente)
│   └── lib/
│       ├── discover.sh          # Descubrimiento de versiones + caché persistente
│       └── version-extract.sh   # Extracción canónica de TERMUX_PKG_VERSION
├── README.md
└── LICENSE
```

## Instalación

Clona el repositorio y da permisos de ejecución a los scripts:

```bash
git clone https://github.com/tu-usuario/PrevTermuxPackage.git
cd PrevTermuxPackage
chmod +x scripts/prev-termux scripts/lib/*.sh
```

## Cómo funciona

El flujo completo consta de seis etapas:

1. **Discover** — El script usa un clon **bare persistente** de `termux-packages` (con caché en `~/.cache/prev-termux/repo/`). Recorre el historial de git buscando commits donde cambió `TERMUX_PKG_VERSION` para el paquete solicitado mediante `git log -G`.
2. **Version cache** — Las versiones descubiertas se cachean en `~/.cache/prev-termux/versions/<paquete>.txt` con TTL configurable (7 días por defecto). El repo bare se sincroniza cada 24 h.
3. **Select** — Las versiones se presentan ordenadas por fecha en un selector `fzf`. Puedes filtrar escribiendo. El preview muestra el `build.sh` en ese commit.
4. **Release check** — Al seleccionar una versión, el script construye el tag `{package}-{version}-{sha7}` y consulta la API de GitHub Releases.
5. **Download** — Si ya existe un release con ese tag, descarga el `.pkg.tar.xz` directamente (instantáneo) a `output/`.
6. **Build** — Si no existe, dispara el workflow `build-old-package.yml` mediante `workflow_dispatch`. Cada run lanza **2 jobs en paralelo e independientes**: `build-normal` (paquete estándar, prefix del dispositivo) y `build-subversioned` (paquete con prefix versionado `~/.local/opt/<pkg>-<ver>/`, autocontenido). Cada job compila en los runners de GitHub usando `run-docker.sh` y publica su **propio release** (tag normal o `-subversioned`).

```
Discover (git log -G en bare repo persistente)
    ↓
Caché de versiones (TTL 7d)
    ↓
fzf (selector interactivo + preview build.sh)
    ↓
¿Ya existe release con tag {pkg}-{ver}-{sha7}[-subversioned]?
    ├── Sí → Descarga directa a output/ ✅
    └── No  → Dispara GHA workflow (2 jobs: normal + subversioned) → 2 Releases 🚀
```

## Comandos disponibles

| Comando | Descripción |
|---------|-------------|
| `./scripts/prev-termux list <package> [--refresh]` | Lista versiones disponibles con fzf. `--refresh` fuerza redescubrimiento |
| `./scripts/prev-termux build <package> [--refresh] [--subversioned]` | Selecciona versión con fzf y descarga o dispara build. `--refresh` fuerza redescubrimiento. `--subversioned` apunta al release/tag versionado (`-subversioned`) |
| `./scripts/prev-termux build <package> --commit <sha> [--subversioned]` | Build directo sin fzf usando un commit SHA específico |
| `./scripts/prev-termux subinstall [<file>]` | Extrae .pkg.tar.xz a `~/.local/opt/<pkg>-<ver>/` con symlinks versionados. Detecta el layout del tar (versionado vs estándar) automáticamente |
| `./scripts/prev-termux status [<package>]` | Muestra últimos 20 runs con indicadores de color: ✓ verde (success), ✗ rojo (failure), * amarillo (in progress), - gris (skipped), ○ gris (cancelled). Filtra por paquete si se especifica |
| `./scripts/prev-termux cache info` | Estadísticas del caché persistente (tamaño, edad, paquetes) |
| `./scripts/prev-termux cache clear [<package>]` | Limpia caché de un paquete (o todos si sin argumento) |
| `./scripts/prev-termux cache clear --all` | Limpia caché completo (incluyendo repo bare) |
| `./scripts/prev-termux help` | Muestra ayuda |

## Ejemplos de uso

### Listar versiones disponibles de un paquete

```bash
./scripts/prev-termux list bash
```

Muestra un selector interactivo con todas las versiones de `bash` registradas en el historial de `termux-packages`, ordenadas de más reciente a más antigua.

### Construir una versión antigua

```bash
./scripts/prev-termux build python
```

1. Abre `fzf` con versiones como `3.12.2`, `3.11.9`, `3.10.15`...
2. Seleccionas una.
3. Si ya existe el release → descarga directa.
4. Si no → dispara el workflow GHA, compila en la nube y crea el release.

### Build directo por commit SHA

```bash
./scripts/prev-termux build python --commit a1b2c3d
```

Omite el selector `fzf` y usa el commit SHA directamente para identificar la versión. Útil para scripts o automatización.

### Ver estado de builds recientes

```bash
# Todos los últimos 20 runs
./scripts/prev-termux status

# Filtrados por paquete
./scripts/prev-termux status python
```

Muestra los últimos 20 runs del workflow con indicadores de color:

| Indicador | Color | Estado |
|-----------|-------|--------|
| `✓` | Verde | Success |
| `✗` | Rojo | Failure |
| `*` | Amarillo | In progress |
| `-` | Gris | Skipped |
| `○` | Gris | Cancelled |

Si se especifica un nombre de paquete, filtra los runs que lo contengan (case-insensitive).

### Subinstall (extracción portable, sin pacman)

```bash
# Modo interactivo: elige artifact desde output/ con fzf
./scripts/prev-termux subinstall

# Modo directo: extrae un archivo específico
./scripts/prev-termux subinstall ./output/bat-0.24.0-0-aarch64.pkg.tar.xz
```

Extrae un `.pkg.tar.xz` a `~/.local/opt/<paquete>-<version>/` y crea symlinks versionados en `~/.local/bin/<bin>-<version>`. No usa `pacman -U` — es una extracción completamente portable. Detecta automáticamente el layout del tar: los artifacts **subversioned** (prefijo `home/.local/opt/`) se extraen a `~/.local/opt/<pkg>-<ver>/`, y los **estándar** (prefijo `com.termux/files/usr/`) con el comportamiento actual.

### Gestión de caché

```bash
# Estadísticas del caché persistente
./scripts/prev-termux cache info

# Limpiar caché de versiones de un paquete específico
./scripts/prev-termux cache clear python

# Limpiar todo el caché de versiones (conserva repo bare)
./scripts/prev-termux cache clear

# Limpiar caché completo (incluyendo repo bare de termux-packages)
./scripts/prev-termux cache clear --all
```

El sistema de caché mantiene un clon bare de `termux-packages` (ahorra ~1–2 GB por operación) y archivos de versiones por paquete con TTL configurable.

## Builds subversioned (versiones autocontenidas)

Cada paquete Termux se compila con `--prefix=$PREFIX` y las rutas quedan **incrustadas en build-time** (configure, RPATH/RUNPATH, wrappers, shebangs, maps proot). Por eso, al convivir varias versiones del mismo paquete, una versión antigua puede terminar cargando librerías (o binarios) de la versión actual.

El modo **subversioned** resuelve esto compilando la versión antigua **con su propio prefix versionado**:

```
~/.local/opt/<pkg>-<ver>/
  (en el dispositivo: /data/data/com.termux/files/home/.local/opt/<pkg>-<ver>/)
```

Todos los paths incrustados apuntan al árbol versionado → cada versión queda **autocontenida** en `~/.local/opt/<pkg>-<ver>/` y puede coexistir con otras sin pisarse.

Además, en modo subversioned las **dependencias también quedan versionadas**: `gha-build.sh` fuerza `-F` (full mode) **siempre**, sin importar el `build_mode` de entrada. La recursión de `build-package.sh` hereda `TERMUX_PREFIX_OVERRIDE` del entorno, así que la cadena de dependencias se recompila con el prefix versionado y cada dep cae en `~/.local/opt/<dep>-<ver>/`. El coste es un rebuild completo de toda la cadena (ver [Limitaciones](#limitaciones-conocidas)).

### Cuándo usarlo

- Necesitas **convivencia de versiones** del mismo paquete (p.ej. `zig` 0.15.2 y 0.16.0, `python` 3.10 y 3.12) sin que se pisen.
- Quieres que el artifact ya salga "parchado" desde el origen, sin post-procesado local.

### Tag y release

El job `build-subversioned` publica un release **propio** con tag:

```
{package}-{version}-{sha7}-subversioned
```

y título `Subversioned: {package} {version} ({sha7})`. El release adjunta **ambos formatos**: el `.pkg.tar.xz` convertido por `deb2pkg.sh` y el `.deb` original. El `.pkg.tar.xz` contiene el árbol versionado `data/data/com.termux/files/home/.local/opt/<pkg>-<ver>/...`.

### Uso

```bash
# Comprueba si existe el release subversioned de zig; si no, dispara el build
./scripts/prev-termux build zig --subversioned

# Extrae el artifact (layout auto-detectado):
#   versionado → se extrae a ~/.local/opt/zig-0.15.2/
#   estándar   → comportamiento actual
./scripts/prev-termux subinstall ./output/zig-0.15.2-0-aarch64.pkg.tar.xz
```

`subinstall` inspecciona el tar (`tar -tf`): si detecta el prefijo `home/.local/opt/` aplica la extracción versionada (`--strip-components=5` a `$HOME`); si detecta `com.termux/files/usr/` usa la extracción estándar.

## Formato de los paquetes

| Formato | Extensión | Uso en el pipeline |
|---------|-----------|--------------------|
| `debian` (compilación) | `.deb` | Formato de build **siempre** (universal) |
| `pacman` (entrega) | `.pkg.tar.xz` | Formato de entrega (`subinstall` / pacman), convertido desde el `.deb` |

El build system de `termux-packages` soporta ambos formatos mediante el flag `--format`, pero los commits **pre-2021-09** (p.ej. 2018) **no soportan `--format pacman`**: su build system solo genera `.deb`. Por eso el pipeline compila **siempre** con `--format debian` (el `.deb` es el formato que producen todos los commits) y, al final del build, `scripts/deb2pkg.sh` convierte cada `.deb` a `.pkg.tar.xz` (el formato que esperan `subinstall` y pacman). **Ambos formatos se suben al release** (`.deb` original + `.pkg.tar.xz` convertido).

### Por qué .deb universal + conversión

- Los commits de `termux-packages` anteriores a 2021-09 no tienen el flag `--format pacman`; compilar con él en esos commits falla. El `.deb`, en cambio, lo generan **todos** los commits.
- `deb2pkg.sh` replica el formato exacto del `.pkg.tar.xz` de termux (`.PKGINFO`, `.MTREE` y `.BUILDINFO` con el mismo template, `bsdtar` + `xz`) para que el artifact funcione con `subinstall` y sea validable con `pacman -Qip`.
- Nombre del artifact: `{pkg}-{ver}-{rev}-{arch}.pkg.tar.xz`, con la versión sanitizada con la regla del prefix (`tr` + `sed`) y sufijo `-0` si falta (libalpm rechaza `pkgver` sin release).

## Tags de Release

Cada versión compilada se publica con un tag único que permite detectar si ya fue construida:

```
{package}-{version}-{sha7}                        # build normal
{package}-{version}-{sha7}-subversioned           # build subversioned
```

Ejemplos:
- `bash-5.2.37-a1b2c3d`
- `bash-5.2.37-a1b2c3d-subversioned`
- `python-3.11.9-e4f5g6h`
- `nodejs-18.16.0-i7j8k9l`

Esto asegura que cada versión única tenga un tag único, y que el CLI distinga el build normal del subversioned (el script local puede determinar rápidamente si ya se compiló antes sin descargar el paquete).

## Workflow GHA (`build-old-package.yml`)

El workflow se dispara exclusivamente mediante `workflow_dispatch` (trigger manual desde la UI de GitHub o mediante `gh workflow run`) y acepta los siguientes inputs:

| Input | Descripción | Valor por defecto |
|-------|-------------|-------------------|
| `package_name` | Nombre del paquete a compilar | — |
| `git_ref` | Referencia (commit SHA) en termux-packages | — |
| `architecture` | Arquitectura destino | `aarch64` |
| `format` | Formato del paquete (aceptado: `pacman`/`debian`). **El build SIEMPRE compila `.deb`** (formato universal, compatible con commits pre-2021 que no soportan pacman); al final `deb2pkg.sh` convierte el `.deb` a `.pkg.tar.xz`. El input se mantiene por compatibilidad con el dispatch | `debian` |
| `build_mode` | Modo de build (`fast` o `full`) | `fast` |

Cada run lanza **2 jobs en paralelo, independientes y sin skips** (ambos disparados por `workflow_dispatch`, sin `needs`):

| Job | Qué compila | Artifact (ambos formatos) | Tag / Release |
|-----|-------------|----------|---------------|
| `build-normal` | Paquete estándar (prefix del dispositivo `/data/data/com.termux/files/usr`) | `<pkg>-<ver>-<arch>` (`.deb` + `.pkg.tar.xz`) | `{pkg}-{ver}-{sha7}` |
| `build-subversioned` | Paquete con prefix versionado `~/.local/opt/<pkg>-<ver>/` (deps versionadas, `-F` forzado) | `<pkg>-<ver>-<arch>-subversioned` (`.deb` + `.pkg.tar.xz`) | `{pkg}-{ver}-{sha7}-subversioned` (título "Subversioned: ...") |

Flujo interno (idéntico en ambos jobs, salvo las diferencias marcadas):
1. Clona el repo actual (PrevTermuxPackage) y `termux/termux-packages` en el commit exacto
2. Extrae `TERMUX_PKG_VERSION` del `build.sh` (con resolución de variables `${VAR%.*}`)
3. `./scripts/gha-prepare.sh` prepara el build system: sparse checkout de master (scripts, keyring, elf-cleaner, ndk-patches) + `patch-build-system.sh` aplica los parches 001–010
4. **Instala las herramientas de conversión**: `libarchive-tools` (`bsdtar`) y `binutils` (`ar`) — necesarias para `deb2pkg.sh` (step `Install conversion tools` en ambos jobs)
5. `./scripts/gha-build.sh` ejecuta `./scripts/run-docker.sh ./build-package.sh ...` (no usa `container:` directo) para levantar el contenedor `ghcr.io/termux/package-builder` con el NDK correcto
6. Compila el paquete **siempre con `--format debian`** (formato universal; el input `format` se valida pero se ignora para el build) con `-a <arquitectura>`, en modo `fast` (`-I`, instala dependencias) o `full` (`-F`, rebuild completo)
7. **Solo `build-subversioned`**: `gha-build.sh --subversioned` exporta `TERMUX_PREFIX_OVERRIDE=/data/data/com.termux/files/home/.local/opt/<pkg>-<ver>` e inyecta la variable al contenedor vía `TERMUX_DOCKER_EXEC_EXTRA_ARGS`. El patch 010 hace que `build-package.sh` compile con ese prefix versionado. Además fuerza **`-F` (full mode) SIEMPRE**: la recursión de `build-package.sh` hereda `TERMUX_PREFIX_OVERRIDE`, así que las dependencias también caen en el prefix versionado
8. **`deb2pkg.sh` convierte cada `.deb` a `.pkg.tar.xz`**: busca los `.deb` en `output/` (master) o `debs/` (commits pre-2021) y genera el `.pkg.tar.xz` (`.PKGINFO`, `.MTREE`, `.BUILDINFO`, re-empaquetado `bsdtar` + `xz`)
9. Sube **ambos formatos** (`.deb` original + `.pkg.tar.xz`) como GitHub Actions artifact (por si el release falla)
10. Genera el tag correspondiente (`{package}-{version}-{sha7}` o con sufijo `-subversioned`)
11. Crea un GitHub Release con el `.deb` y el `.pkg.tar.xz` adjuntos (solo si no existe ya)

### Flujo de release

- Cuando el **build es exitoso**, cada job crea su propio GitHub Release con su tag (normal o `-subversioned`).
- El **script local** (`prev-termux build`) consulta primero el tag según el modo: con `--subversioned` busca tags `{pkg}-{ver}-{sha7}-subversioned`; sin él, tags normales (excluyendo los subversioned).
- Si **no hay release**, dispara el workflow con `gh workflow run` y espera a que termine.
- El tag sigue el formato `{package}-{version}-{sha7}` (+ sufijo `-subversioned`), donde `sha7` son los primeros 7 caracteres del commit SHA en termux-packages.

## Variables de entorno configurables

| Variable | Descripción | Valor por defecto |
|----------|-------------|-------------------|
| `PREV_TERMUX_CACHE_DIR` | Directorio base del caché persistente (repo bare + versiones) | `~/.cache/prev-termux` |
| `PREV_TERMUX_INSTALL_DIR` | Directorio donde se extraen los paquetes con `subinstall` | `~/.local/opt` |
| `PREV_TERMUX_BIN_DIR` | Directorio donde se crean los symlinks versionados | `~/.local/bin` |
| `PREV_TERMUX_CACHE_TTL` | TTL del caché de versiones en segundos | `604800` (7 días) |
| `PREV_TERMUX_REPO_FETCH_INTERVAL` | Intervalo de fetch del repo bare en segundos | `86400` (24 h) |
| `PREV_TERMUX_WORKFLOW_REF` | Rama del repo donde está el workflow GHA | Auto-detectada (default branch) |
| `GITHUB_REPOSITORY` | Repo GitHub owner/name donde viven releases y workflow | Auto-detectado con `gh repo view` |
| `TERMUX_PACKAGES_REPO` | URL del repositorio termux-packages | `https://github.com/termux/termux-packages.git` |

Todas son opcionales. Los valores por defecto funcionan sin configuración adicional.

## Limitaciones conocidas

- **Checksum mismatches**: Algunos tarballs upstream cambian con el tiempo (reemplazos, actualizaciones de maintainer), causando errores de checksum en paquetes muy antiguos. Si el build falla por SHA256 mismatch, prueba con `build_mode: full` o busca un commit más reciente.
- **Compilación lenta**: Paquetes que involucran LLVM (zig, rust, llvm, rustc) pueden tomar horas en compilarse en los runners gratuitos de GHA. No hay límite de tiempo en GHA, pero el proceso puede ser muy extenso.
- **Dependencias**: Las dependencias se resuelven con `-I` (install) desde el repo oficial APT. Si una versión muy antigua requiere dependencias incompatibles, usa `build_mode: full` con el flag `-F` para rebuildear todo desde cero.
- **Sin builds paralelos por paquete/versión**: El workflow GHA compila un solo paquete por ejecución. Cada run lanza 2 jobs (normal + subversioned) en paralelo, pero no hay soporte para compilar múltiples versiones o paquetes a la vez.
- **Imagen Docker**: Solo existe la imagen `ghcr.io/termux/package-builder`. Si builds muy antiguos fallan por mismatch del NDK, considera construir una imagen custom (no soportado por defecto en este proyecto).
- **Coste de `-F` en subversioned**: el modo subversioned fuerza SIEMPRE `full mode` (`-F`) para que las dependencias queden versionadas (la recursión de `build-package.sh` hereda `TERMUX_PREFIX_OVERRIDE` y las deps caen en `~/.local/opt/<dep>-<ver>/`). En paquetes con cadenas de dependencias grandes, el rebuild completo de toda la cadena puede tardar horas en los runners gratuitos de GHA.
- **Artifact subversioned NO instalable con pacman**: el `.pkg.tar.xz` versionado contiene paths `~/.local/opt/<pkg>-<ver>/` que no corresponden al prefix del dispositivo. Es un artifact **portable para `subinstall`**, no para `pacman -U`.

## Arquitectura / Cómo funciona internamente

### `discover.sh` — descubrimiento de versiones

El corazón del sistema es la librería `scripts/lib/discover.sh`. Su función principal `discover_versions()` usa `git log -G` (pickaxe) sobre el repositorio `termux-packages` para encontrar commits donde cambió la línea `TERMUX_PKG_VERSION=` en `packages/<pkg>/build.sh`. A diferencia de `-S` (string count), `-G` detecta cambios de valor aunque el número de ocurrencias no varíe.

### Resolución de variables `${VAR%.*}`

Muchos `build.sh` de Termux usan variables intermedias como `_MAJOR=1`, `_MINOR=2`, y definen `TERMUX_PKG_VERSION="${_MAJOR}.${_MINOR}"`. La función `resolve_version_from_buildsh()` parsea todas las definiciones del `build.sh`, construye un tabla asociativa, y resuelve las variables recursivamente (hasta 20 iteraciones) soportando:

- `${VAR}` y `$VAR`
- `${VAR%pattern}` (eliminar sufijo)
- `${VAR%%pattern}` (eliminar sufijo largo)
- Anidamiento de variables

### Caché persistente

El sistema mantiene dos niveles de caché en `PREV_TERMUX_CACHE_DIR` (defecto: `~/.cache/prev-termux/`):

1. **Repo bare** (`repo/termux-packages.git`): Clon bare de `termux-packages` con fetch periódico cada `PREV_TERMUX_REPO_FETCH_INTERVAL` segundos. Esto evita clonar ~1–2 GB en cada operación. Si el repo está corrupto, se re-clona automáticamente.
2. **Version cache** (`versions/<pkg>.txt`): Lista de versiones descubiertas con metadatos (commit, fecha) y TTL configurable via `PREV_TERMUX_CACHE_TTL`. Se usa como fallback si el descubrimiento falla.

### GHA y `run-docker.sh`

El workflow `build-old-package.yml` no usa `container:` directamente. La preparación y el build están extraídos en `scripts/gha-prepare.sh` (sparse checkout de master + parches 001–010) y `scripts/gha-build.sh` (build compartido por ambos jobs). Este último ejecuta `./scripts/run-docker.sh ./build-package.sh ...` dentro del checkout de `termux-packages`, **siempre con `--format debian`** (formato universal; el input `format` se mantiene por compatibilidad del dispatch pero se ignora para el build). Esto levanta el contenedor `ghcr.io/termux/package-builder` con el NDK y las herramientas de compilación correctas. El script `run-docker.sh` maneja el mapeo de volúmenes y el entorno, e inyecta `TERMUX_DOCKER_EXEC_EXTRA_ARGS` al `docker exec` (donde `gha-build.sh --subversioned` pasa `TERMUX_PREFIX_OVERRIDE`). Tras el build, `deb2pkg.sh` convierte cada `.deb` de `output/` o `debs/` a `.pkg.tar.xz`.

### Flujo de release

Cuando el build es exitoso, cada job del workflow:
1. Extrae la versión del `build.sh` (con resolución de variables, vía `version-extract.sh`)
2. Genera el tag `{package}-{version}-{sha7}` (normal) o `{package}-{version}-{sha7}-subversioned`
3. Crea un GitHub Release con el `.deb` y el `.pkg.tar.xz` (convertido por `deb2pkg.sh`) adjuntos
4. El script local detecta releases existentes y descarga directo sin rebuildear (filtrando por modo normal/subversioned)
5. Si no hay release, dispara el workflow con `gh workflow run`

## Contribuir

PRs bienvenidos. Áreas de mejora:

- Soporte para más arquitecturas (`arm`, `i686`, `x86_64`) — actualmente probado principalmente en `aarch64`
- Builds en paralelo para múltiples versiones
- Interfaz TUI más rica
- Manejo automático de checksum mismatches (por ej., actualizar checksums desde el source upstream)

## Licencia

MIT
