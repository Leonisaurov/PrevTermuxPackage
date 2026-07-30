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
├── scripts/
│   ├── prev-termux              # CLI principal (entrypoint interactivo)
│   └── lib/
│       ├── discover.sh          # Descubrimiento de versiones (git log)
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

El flujo completo consta de cinco etapas:

1. **Discover** — El script clona (o reusa) `termux-packages` y recorre el historial de git buscando commits donde cambió `TERMUX_PKG_VERSION` para el paquete solicitado.
2. **Select** — Las versiones encontradas se presentan ordenadas por fecha en un selector `fzf`. Puedes filtrar escribiendo.
3. **Cache check** — Al seleccionar una versión, el script construye el tag de release con el formato `{package}-{version}-{sha7}` y consulta la API de GitHub Releases.
4. **Download** — Si ya existe un release con ese tag, descarga el `.pkg.tar.xz` directamente (instantáneo).
5. **Build** — Si no existe, dispara el workflow `build-old-package.yml` mediante `workflow_dispatch`, que compila el paquete en los runners de GitHub y publica el artefacto como release.

```
Discover (git log termux-packages)
    ↓
fzf (selector interactivo de versiones)
    ↓
¿Ya existe release con tag {pkg}-{ver}-{sha7}?
    ├── Sí → Descarga directa ✅
    └── No  → Dispara GHA build → Release 🚀
```

## Comandos disponibles

| Comando | Descripción |
|---------|-------------|
| `./scripts/prev-termux list <package>` | Lista versiones disponibles con fzf |
| `./scripts/prev-termux build <package>` | Selecciona versión con fzf y descarga o dispara build |
| `./scripts/prev-termux build <package> --commit <sha>` | Build directo sin fzf |
| `./scripts/prev-termux status` | Muestra estado de builds recientes |
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

El workflow se dispara mediante `workflow_dispatch` y acepta los siguientes inputs:

| Input | Descripción | Valor por defecto |
|-------|-------------|-------------------|
| `package_name` | Nombre del paquete a compilar | — |
| `git_ref` | Referencia (commit SHA) en termux-packages | — |
| `architecture` | Arquitectura destino | `aarch64` |
| `format` | Formato del paquete | `pacman` |
| `build_mode` | Modo de build (`normal` o `full`) | `normal` |

Flujo interno:
1. Corre en el contenedor `ghcr.io/termux/termux-packages:latest`
2. Ejecuta `./build-package.sh --format pacman -a aarch64 -I <package>`
3. Sube el artifact generado
4. Crea un GitHub Release con el `.pkg.tar.xz` usando el tag `{package}-{version}-{sha7}`

## Limitaciones conocidas

- **Clonado recurrente**: El clonado de `termux-packages` (~1–2 GB) ocurre cada vez que usas `list` o `build`. Se recomienda mantener un clon persistente para acelerar las operaciones.
- **Dependencias**: Las dependencias se resuelven con `-I` (install) desde el repo oficial APT. Si una versión muy antigua requiere dependencias incompatibles, usa `build_mode: full` con el flag `-F` para rebuildear todo desde cero.
- **Imagen Docker**: Solo existe una imagen `latest` de `termux-packages`. Si builds muy antiguos fallan por mismatch del NDK, considera construir una imagen custom (no soportado por defecto en este proyecto).

## Contribuir

PRs bienvenidos. Áreas de mejora:

- Cache persistente de `termux-packages` para evitar clonados repetidos
- Soporte para más arquitecturas (`arm`, `i686`, `x86_64`)
- Builds en paralelo para múltiples versiones
- Interfaz TUI más rica

## Licencia

MIT
