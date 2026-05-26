# uv-infra-ti
## Infraestructura TI — Sistema Integrado de Gestión (SIG)
### Unidad para la Atención y Reparación Integral a las Víctimas

Proyecto Final — Administración de Infraestructura TI  
Universidad del Quindío | Semestre 2026-1

---

## 👥 Equipo

| Nombre | Responsabilidades |
|--------|-------------------|
| Daniel Josué Narváez Hincapié | Red · Automatización · Monitoreo · HA · Doc. técnico |
| Juan Diego García Nieto | Servicios · Docker Compose · Almacenamiento · Seguridad |
| David Felipe Pedraza Bedoya | Servicios · Almacenamiento · Seguridad · Automatización · Video |

---

## 📁 Estructura del Repositorio

```
uv-infra-ti/
├── docker/
│   ├── docker-compose.yml        # Orquestación de 11 servicios
│   ├── .env.example              # Variables de entorno (copiar a .env)
│   ├── db/                       # PostgreSQL 16 + SSH
│   ├── dhcp/                     # ISC DHCP Server
│   ├── dns/                      # BIND9 con zonas uv.local
│   ├── files/                    # Samba + SSH
│   ├── ntp/                      # chrony
│   ├── smtp/                     # MailHog
│   └── web/
│       ├── srv-web-01/           # Portal ciudadano (Nginx)
│       ├── srv-web-02/           # Portal RNI (Nginx)
│       ├── srv-web-03/           # Intranet SUMA (Nginx)
│       ├── srv-php-fpm/          # PHP-FPM 8.2 con pdo_pgsql
│       └── proxy/                # Nginx Proxy Manager
├── scripts/
│   ├── automation/
│   │   ├── backup.sh             # Backup diario (AUT-1)
│   │   └── deploy.sh             # Despliegue completo (AUT-2)
│   ├── security/
│   │   ├── firewall.sh           # Reglas UFW por VLAN (SEG-1)
│   │   ├── apply_password_policy.sh  # Política de contraseñas (SEG-3)
│   │   └── install_uv_policies.sh    # Sudoers (SEG-3)
│   ├── storage/
│   │   ├── setup_raid.sh         # RAID 1 con loop devices (ALM-1)
│   │   ├── setup_lvm.sh          # LVM sobre RAID (ALM-2)
│   │   └── verify_persistence.sh # Verificación de persistencia (ALM-3)
│   └── users.sh                  # Usuarios, grupos y permisos (SEG-2)
├── config/
│   └── uv_policies.sudoers       # Fragmento sudoers
├── docs/
│   ├── documento_tecnico.md      # Documento técnico principal
│   ├── alta_disponibilidad.md    # Estrategia HA (HA-1)
│   ├── almacenamiento.md         # Integración LVM + Docker (ALM-3)
│   ├── seguridad_usuarios.md     # Usuarios y permisos (SEG-2)
│   ├── roles_servidores.md       # Roles de cada servidor
│   ├── SSH_acceso.md             # Guía de acceso SSH
│   ├── diagrama_red.png          # Diagrama de red
│   └── diagrama_red.pkt          # Diagrama Cisco Packet Tracer
├── monitoring/                   # Configuración de monitoreo
└── README.md
```

---

## 🛠️ Entorno de Trabajo

- **SO:** Linux nativo (Ubuntu, Fedora, Linux Mint) — sin WSL ni Docker Desktop
- **Runtime:** Podman (drop-in replacement de Docker, aprobado por el docente)
- **Orquestación:** `podman-compose`
- **Control de versiones:** git por terminal

```bash
# Alias requerido (agregar a ~/.bashrc para persistencia)
alias docker=podman
```

---

## 🚀 Despliegue Rápido

```bash
# 1. Clonar el repositorio
git clone https://github.com/DanielJNarvaezH/uv-infra-ti.git
cd uv-infra-ti

# 2. Configurar variables de entorno
cp docker/.env.example docker/.env
# Editar docker/.env con las credenciales del equipo

# 3. Copiar keys.json del proxy (compartido por el equipo)
# docker/web/proxy/data/keys.json  ← colocar manualmente

# 4. Despliegue completo automático
sudo bash scripts/automation/deploy.sh

# O manualmente paso a paso:
cd docker
podman-compose up -d --build
```

### Verificar que todo esté corriendo

```bash
podman ps --format "table {{.Names}}\t{{.Status}}"
```

Todos los servicios deben aparecer como `healthy`.

### Acceder a los servicios

| Servicio | URL | Notas |
|---|---|---|
| Portal ciudadano | http://localhost:8082 | |
| Portal RNI | http://localhost:8083 | |
| Panel proxy | http://localhost:8081 | Admin: admin@example.com / changeme |
| MailHog UI | Puerto 8025 | Solo desde VLAN 20 |

---

## 🗄️ Almacenamiento (Ejecución manual en VM)

Los scripts de RAID y LVM están diseñados para ejecutarse en una **máquina virtual** o entorno controlado. **No ejecutar en máquina host real** (puede afectar el arranque).

```bash
# 1. Crear RAID 1 con discos virtuales
sudo bash scripts/storage/setup_raid.sh

# 2. Configurar LVM sobre el RAID
sudo bash scripts/storage/setup_lvm.sh

# 3. Verificar persistencia
sudo bash scripts/storage/verify_persistence.sh
```

---

## 🔒 Seguridad

```bash
# Aplicar reglas de firewall
sudo bash scripts/security/firewall.sh

# Crear usuarios y grupos del sistema
sudo bash scripts/users.sh

# Instalar políticas sudo
sudo bash scripts/security/install_uv_policies.sh

# Verificar firewall
sudo ufw status verbose
```

---

## 💾 Backup

```bash
# Ejecutar backup manual
sudo bash scripts/automation/backup.sh

# Ver log de backups
tail -f /var/log/uv_backup.log

# El cron job se configura automáticamente con deploy.sh
# Para configurarlo manualmente:
# sudo crontab -e
# 0 2 * * * /ruta/al/repo/scripts/automation/backup.sh >> /var/log/uv_backup.log 2>&1
```

---

## 📝 Convenciones de Commits

| Tipo | Uso |
|------|-----|
| `feat` | Nueva funcionalidad |
| `fix` | Corrección de errores |
| `docs` | Documentación |
| `config` | Configuración |
| `script` | Scripts bash |
| `docker` | Dockerfiles o compose |
| `security` | Seguridad |

---

## 🔗 Referencias

- [Unidad de Víctimas — SIG](https://www.unidadvictimas.gov.co/sistema-integrado-de-gestion-sig/)
- [Documentación Podman](https://docs.podman.io)
- [NTC-ISO 9001:2015](https://www.icontec.org)
