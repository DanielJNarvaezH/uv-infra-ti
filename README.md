# uv-infra-ti
## Infraestructura TI — Sistema Integrado de Gestión (SIG)
### Unidad de Víctimas de Colombia

Proyecto Final — Administración de Infraestructura TI  
Universidad del Quindío | Semestre 2026-1

---

## 👥 Equipo

| Nombre | Usuario GitHub | Responsabilidades |
|--------|---------------|-------------------|
| Daniel Josué Narváez Hincapié | @DanielJNarvaezH | Red · Automatización · Monitoreo · HA · Doc. técnico |
| Juan Diego García Nieto | | Servicios · Docker Compose · Almacenamiento · Seguridad |
| David Felipe Pedraza Bedoya | | Servicios · Almacenamiento · Seguridad · Automatización · Video |

---

## 📁 Estructura del Repositorio

```
uv-infra-ti/
├── docs/          # Diagramas, documento técnico, runbooks
├── docker/        # Dockerfiles y docker-compose.yml
├── scripts/       # Scripts bash (backup, deploy, monitor, RAID, LVM, firewall)
├── config/        # Archivos de configuración de servicios
├── monitoring/    # Configuración Prometheus/Grafana
└── README.md
```

---

## 🛠️ Entorno de Trabajo

- **SO:** Linux nativo (Ubuntu, Fedora, Linux Mint, etc.) — sin WSL ni Docker Desktop
- **Runtime de contenedores:** Podman (drop-in replacement de Docker, aprobado por el docente)
- **Alias requerido:** `alias docker=podman`
- **Orquestación:** `podman-compose` en lugar de `docker compose`
- **Control de versiones:** git por terminal

---

## 🚀 Cómo desplegar

```bash
# 1. Clonar el repositorio
git clone https://github.com/DanielJNarvaezH/uv-infra-ti.git
cd uv-infra-ti

# 2. Configurar alias de Podman
alias docker=podman

# 3. Copiar variables de entorno
cp docker/.env.example docker/.env

# 4. Levantar todos los servicios
docker compose -f docker/docker-compose.yml up -d

# 5. Verificar que todos los contenedores están corriendo
docker ps
```

---

## 📝 Convenciones de Commits

Formato: `tipo: descripción corta`

| Tipo | Uso |
|------|-----|
| `feat` | Nueva funcionalidad o configuración |
| `fix` | Corrección de errores |
| `docs` | Cambios en documentación |
| `config` | Archivos de configuración |
| `script` | Scripts bash |
| `docker` | Dockerfiles o docker-compose |
| `security` | Configuraciones de seguridad |

**Ejemplos:**
```
feat: agregar Dockerfile para Nginx
config: configurar VLANs en diagrama de red
script: crear backup.sh con cron job
docs: agregar diagrama de red en /docs
```

---

## 📋 Cómo agregar archivos al repositorio

- **Scripts bash** → `/scripts/`
- **Dockerfiles** → `/docker/{servicio}/Dockerfile`
- **Configuraciones de servicios** → `/config/{servicio}/`
- **Documentación y diagramas** → `/docs/`
- **Configs de monitoreo** → `/monitoring/`

⚠️ **Nunca subir:** archivos `.env` con credenciales reales, claves SSH, certificados.

---

## 📅 Cronograma

| Sprint | Período | Foco |
|--------|---------|------|
| Sprint 1 | 27 abr – 03 may | Setup + Diseño de Red |
| Sprint 2 | 04 may – 10 may | Servicios + Docker |
| Sprint 3 | 11 may – 17 may | Almacenamiento + Seguridad + Automatización |
| Sprint 4 | 18 may – 21 may | Monitoreo + HA + Documentación Final |

---

## 🔗 Referencias

- [Unidad de Víctimas — SIG](https://www.unidadvictimas.gov.co/sistema-integrado-de-gestion-sig/)
- [Documentación Podman](https://docs.podman.io)
