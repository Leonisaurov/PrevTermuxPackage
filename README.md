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
│   └── build-old-package.yml    # Workflow GHA (workflow_dispatch)
├── output/                      # Artifacts descargados (.pkg.tar.xz)
├── scripts/
│   ├── prev-termux              # CLI principal (entrypoint interactivo)
│   └── lib/
│       ├── discover.sh          # Descubrimiento de versiones + caché persistente
│       └── build.sh             # Helpers de build (opcional)
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
6. **Build** — Si no existe, dispara el workflow `build-old-package.yml` mediante `workflow_dispatch`, que compila el paquete en los runners de GitHub usando `run-docker.sh` y publica el artefacto como release.

```
Discover (git log -G en bare repo persistente)
    ↓
Caché de versiones (TTL 7d)
    ↓
fzf (selector interactivo + preview build.sh)
    ↓
¿Ya existe release con tag {pkg}-{ver}-{sha7}?
    ├── Sí → Descarga directa a output/ ✅
    └── No  → Dispara GHA workflow → run-docker.sh build → Release 🚀
```

## Comandos disponibles

| Comando | Descripción |
|---------|-------------|
| `./scripts/prev-termux list <package>` | Lista versiones disponibles con fzf |
| `./scripts/prev-termux build <package>` | Selecciona versión con fzf y descarga o dispara build |
| `./scripts/prev-termux build <package> --commit <sha>` | Build directo sin fzf |
| `./scripts/prev-termux subinstall [<file>]` | Extrae .pkg.tar.xz a `~/.local/opt/` con symlinks versionados |
| `./scripts/prev-termux status` | Muestra estado de builds recientes |
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
./scripts/prev-termux status
```

Muestra los workflows disparados recientemente, su estado (pendiente, en curso, completado, fallido) y enlaces al release si está disponible.

### Subinstall (extracción portable, sin pacman)

```bash
# Modo interactivo: elige artifact desde output/ con fzf
./scripts/prev-termux subinstall

# Modo directo: extrae un archivo específico
./scripts/prev-termux subinstall ./output/bat-0.24.0-0-aarch64.pkg.tar.xz
```

Extrae un `.pkg.tar.xz` a `~/.local/opt/<paquete>-<version>/` y crea symlinks versionados en `~/.local/bin/<bin>-<version>`. No usa `pacman -U` — es una extracción completamente portable.

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

## Formato de los paquetes

| Formato | Extensión | Sistema de paquetes |
|---------|-----------|---------------------|
| `pacman` (por defecto) | `.pkg.tar.xz` | pacman/xbps |
| `debian` | `.deb` | apt/dpkg |

El build system de `termux-packages` soporta ambos formatos mediante el flag `--format`. Por defecto se usa `pacman`.

## Tags de Release

Cada versión compilada se publica con un tag único que permite detectar si ya fue construida:

```
{package}-{version}-{sha7}
```

Ejemplos:
- `bash-5.2.37-a1b2c3d`
- `python-3.11.9-e4f5g6h`
- `nodejs-18.16.0-i7j8k9l`

Esto asegura que cada versión única tenga un tag único y el script local pueda determinar rápidamente si ya se compiló antes sin descargar el paquete.

## Workflow GHA (`build-old-package.yml`)

El workflow se dispara mediante `workflow_dispatch` (o automáticamente en `push`/`pull_request`, aunque la build real solo corre en `workflow_dispatch`) y acepta los siguientes inputs:

| Input | Descripción | Valor por defecto |
|-------|-------------|-------------------|
| `package_name` | Nombre del paquete a compilar | — |
| `git_ref` | Referencia (commit SHA) en termux-packages | — |
| `architecture` | Arquitectura destino | `aarch64` |
| `format` | Formato del paquete | `pacman` |
| `build_mode` | Modo de build (`fast` o `full`) | `fast` |

Flujo interno:
1. Clona el repo actual (PrevTermuxPackage) y `termux/termux-packages` en el commit exacto
2. Extrae `TERMUX_PKG_VERSION` del `build.sh` (con resolución de variables `${VAR%.*}`)
3. Ejecuta `./scripts/run-docker.sh ./build-package.sh ...` (no usa `container:` directo) para levantar el contenedor `ghcr.io/termux/package-builder` con el NDK correcto
4. Compila el paquete con `--format <formato> -a <arquitectura>` en modo `fast` (`-I`, instala dependencias) o `full` (`-F`, rebuild completo)
5. Sube el artifact generado como GitHub Actions artifact (por si el release falla)
6. Genera el tag `{package}-{version}-{sha7}`
7. Crea un GitHub Release con el `.pkg.tar.xz` adjunto (solo si no existe ya)

### Flujo de release

- Cuando el **build es exitoso** en GHA, se crea automáticamente un GitHub Release con el `.pkg.tar.xz` y el tag versionado.
- El **script local** (`prev-termux build`) primero consulta si ya existe un release con ese tag. Si existe, descarga directo (sin rebuildear).
- Si **no hay release**, dispara el workflow con `gh workflow run` y espera a que termine.
- El tag sigue el formato `{package}-{version}-{sha7}`, donde `sha7` son los primeros 7 caracteres del commit SHA en termux-packages.

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
- **Sin builds paralelos**: El workflow GHA compila un solo paquete por ejecución. No hay soporte para builds paralelos de múltiples versiones o paquetes.
- **Imagen Docker**: Solo existe la imagen `ghcr.io/termux/package-builder`. Si builds muy antiguos fallan por mismatch del NDK, considera construir una imagen custom (no soportado por defecto en este proyecto).

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

El workflow `build-old-package.yml` no usa `container:` directamente. En su lugar, ejecuta `./scripts/run-docker.sh ./build-package.sh ...` dentro del checkout de `termux-packages`. Esto levanta el contenedor `ghcr.io/termux/package-builder` con el NDK y las herramientas de compilación correctas. El script `run-docker.sh` maneja el mapeo de volúmenes y el entorno.

### Flujo de release

Cuando el build es exitoso, el workflow:
1. Extrae la versión del `build.sh` (con resolución de variables)
2. Genera el tag `{package}-{version}-{sha7}`
3. Crea un GitHub Release con el `.pkg.tar.xz` adjunto
4. El script local detecta releases existentes y descarga directo sin rebuildear
5. Si no hay release, dispara el workflow con `gh workflow run`

## Contribuir

PRs bienvenidos. Áreas de mejora:

- Soporte para más arquitecturas (`arm`, `i686`, `x86_64`) — actualmente probado principalmente en `aarch64`
- Builds en paralelo para múltiples versiones
- Interfaz TUI más rica
- Manejo automático de checksum mismatches (por ej., actualizar checksums desde el source upstream)

## Licencia

MIT
