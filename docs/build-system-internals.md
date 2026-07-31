# Sistema de Build de termux-packages: Dependencias Internas

> Documento interno de PrevTermuxPackage — fecha: 2026-07-30

## Resumen

Cuando se compilan paquetes de commits ANTIGUOS de `termux-packages` usando el build system MODERNO, faltan archivos que el sistema moderno requiere. Este documento cataloga esos archivos y explica por qué fallan los builds.

El problema de fondo: `termux-packages` es un monorepo donde el build system y los paquetes **evolucionan al mismo ritmo**. Al hacer checkout de un commit antiguo para compilar una versión vieja de un paquete, también se hace checkout de la versión antigua del build system, que no contiene las dependencias que el `build-package.sh` moderno necesita.

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

**Solución**: el sparse checkout incluye `packages/termux-elf-cleaner` para copiar el `build.sh` moderno (v3.0.1).

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

En el workflow, antes de compilar:

1. Sparse checkout de `scripts/` + `packages/termux-keyring` desde master.
2. Descargar `build-package.sh` desde master.
3. Descargar `repo.json` desde master.
4. Reemplazar los archivos del commit antiguo con los modernos.

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
- Usar sparse checkout para directorios completos.
- El build system moderno es retrocompatible con `build.sh` antiguos (solo lee variables).
- Los flags `--format` y otras features se agregaron con el tiempo; no asumir que un commit viejo los soporta.

## Notas de Verificación (2026-07-30)

- `run-docker.sh` en master: 221 líneas — confirmado.
- Contiene: `sudo`, `--security-opt seccomp=.../profile.json`, `--security-opt apparmor=...`, `pid_max` (incl. soporte para kernels >= 6.14), `--init`, traps via `docker__setup_docker_exec_traps`, `CI` env var.
- `scripts/profile-relaxed.apparmor` y `scripts/profile.json` existen en master.
