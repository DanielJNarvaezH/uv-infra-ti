# Roles de Servidores — Infraestructura TI
## Unidad para la Atención y Reparación Integral a las Víctimas
### Sistema Integrado de Gestión (SIG)

**Proyecto:** Administración de Infraestructura TI  
**Equipo:** Daniel Josué Narváez Hincapié · Juan Diego García Nieto · David Felipe Pedraza Bedoya  
**Universidad del Quindío — Semestre 2026-1**  
**Tarea:** RED-4 | Sprint 1

---

## 1. Tabla de Roles de Servidores

| Nombre | IP | VLAN | Servicios que presta | Usuarios / Sistemas que lo consumen |
|--------|-----|------|----------------------|--------------------------------------|
| **srv-db-01** | 10.0.10.2 | VLAN 10 — Servidores | PostgreSQL (puerto 5432) · Base de datos `uv_sig` | srv-web-01, srv-web-02, srv-web-03 (lectura/escritura) · uv_dbadmin (administración) · backup.sh (pg_dump) · scripts de monitoreo |
| **srv-files-01** | 10.0.10.3 | VLAN 10 — Servidores | Samba (SMB/CIFS, puerto 445) · Share `/srv/uv_docs` | Funcionarios VLAN 20 (g_files) · uv_files_user · contenedor de archivos · backup.sh (compresión de docs) |
| **srv-ntp-01** | 10.0.10.4 | VLAN 10 — Servidores | NTP / chrony (UDP 123) · Sincronización horaria interna | Todos los servidores de VLAN 10, VLAN 20 y VLAN 30 · clientes DHCP que reciban la opción NTP |
| **srv-web-03** | 10.0.10.5 | VLAN 10 — Servidores | Nginx — Intranet SUMA (HTTP 80) · Portal interno de gestión documental y procesos SIG | Funcionarios VLAN 20 (Administración) · aplicaciones internas del SIG |
| **srv-dhcp-01** | 10.0.10.6 | VLAN 10 — Servidores | DHCP (UDP 67/68) · Asignación dinámica de IPs a VLAN 20 (10.0.20.2–254) y VLAN 30 (10.0.30.2–254) mediante relay inter-VLAN | Hosts de VLAN 20 (Administración) · Hosts de VLAN 30 (Usuarios internos) · router/switch con DHCP relay |
| **srv-web-01** | 10.0.40.2 | VLAN 40 — DMZ | Nginx — Portal ciudadano público (HTTP 80 / HTTPS 443) · Backend del balanceo de carga (upstream Nginx LB) | Ciudadanos / víctimas (Internet) · Nginx LB (srv-web-01 como upstream) · srv-db-01 (consultas BD) |
| **srv-dns-01** | 10.0.40.3 | VLAN 40 — DMZ | DNS autoritativo / BIND9 (UDP/TCP 53) · Zona `uv.local` con registros A para los 9 servidores | Todos los servidores internos · clientes VLAN 20 y VLAN 30 · scripts de despliegue (resolución por nombre) |
| **srv-smtp-01** | 10.0.40.4 | VLAN 40 — DMZ | SMTP / MailHog (puerto 25/587) · Interfaz web MailHog (HTTP 8025, solo VLAN 20) · Relay de correo de pruebas | Scripts de automatización (notificaciones) · uv_admin (interfaz web) · aplicaciones internas que envíen alertas |
| **srv-web-02** | 10.0.40.5 | VLAN 40 — DMZ | Nginx — Réplica del portal ciudadano (HTTP 80 / HTTPS 443) · Segunda instancia en el upstream del balanceo de carga | Ciudadanos / víctimas (Internet) · Nginx LB (srv-web-02 como upstream) · srv-db-01 (consultas BD) |

---

## 2. Fichas de Servidor — Detalle Técnico

### srv-db-01 — Servidor de Base de Datos
| Campo | Valor |
|-------|-------|
| **Hostname** | srv-db-01 |
| **IP estática** | 10.0.10.2 |
| **VLAN** | VLAN 10 — Servidores |
| **Imagen Docker** | postgres:16 |
| **Puerto expuesto** | 5432 (solo VLAN 10 → VLAN 20 por firewall) |
| **Base de datos** | `uv_sig` (usuario: `uv_admin`) |
| **Volumen persistente** | `/mnt/uv_db` (LVM: lv_db) |
| **Consumidores principales** | srv-web-01, srv-web-02, srv-web-03 (capa web) · uv_dbadmin · backup.sh |
| **Registro DNS** | `srv-db-01.uv.local → 10.0.10.2` |

**Justificación SIG:** El SIG de la Unidad de Víctimas gestiona procesos críticos como Registro y Valoración, Atención, Reparación Integral y Participación. La base de datos centraliza la información de víctimas, casos y atenciones. Su ubicación en VLAN 10 (segmento de servidores internos, no accesible desde Internet) y el uso de RAID 1 + LVM sobre `/mnt/uv_db` garantizan la integridad y disponibilidad de datos sensibles de la ciudadanía.

---

### srv-files-01 — Servidor de Archivos
| Campo | Valor |
|-------|-------|
| **Hostname** | srv-files-01 |
| **IP estática** | 10.0.10.3 |
| **VLAN** | VLAN 10 — Servidores |
| **Imagen Docker** | dperson/samba |
| **Puerto expuesto** | 445 (solo LAN, bloqueado desde DMZ e Internet) |
| **Share** | `/srv/uv_docs` (documentos institucionales del SIG) |
| **Volumen persistente** | `/mnt/uv_files` (LVM: lv_files) |
| **Permisos** | Grupos `g_files` (lectura/escritura) · SETGID + sticky bit en `/srv/uv_docs` |
| **Consumidores principales** | Funcionarios de VLAN 20 · uv_files_user · backup.sh |
| **Registro DNS** | `srv-files-01.uv.local → 10.0.10.3` |

**Justificación SIG:** El SIG publica caracterizaciones de procesos, políticas institucionales, mapas de riesgo y acuerdos de gestión. El servidor de archivos centraliza estos documentos bajo control de acceso por grupos, con SETGID para heredar permisos automáticamente en archivos nuevos y sticky bit para evitar eliminaciones accidentales entre usuarios.

---

### srv-ntp-01 — Servidor de Sincronización Horaria
| Campo | Valor |
|-------|-------|
| **Hostname** | srv-ntp-01 |
| **IP estática** | 10.0.10.4 |
| **VLAN** | VLAN 10 — Servidores |
| **Imagen Docker** | cturra/ntp |
| **Puerto expuesto** | UDP 123 (accesible desde VLAN 10, 20 y 30) |
| **Fuente de tiempo** | pool.ntp.org · zona America/Bogota |
| **Consumidores principales** | Todos los servidores internos · hosts de VLAN 20 y VLAN 30 |
| **Registro DNS** | `srv-ntp-01.uv.local → 10.0.10.4` |

**Justificación SIG:** La trazabilidad de los registros de atención y reparación a víctimas requiere marcas de tiempo precisas y coherentes en todos los sistemas. Un servidor NTP interno evita discrepancias horarias entre servicios que puedan invalidar logs, auditorías o firmas digitales de documentos del SIG.

---

### srv-web-03 — Servidor Web Interno (Intranet SUMA)
| Campo | Valor |
|-------|-------|
| **Hostname** | srv-web-03 |
| **IP estática** | 10.0.10.5 |
| **VLAN** | VLAN 10 — Servidores |
| **Imagen Docker** | nginx (configuración intranet) |
| **Puertos expuestos** | HTTP 80 (solo VLAN 10 y VLAN 20) |
| **Virtual host** | SUMA Intranet — gestión documental y procesos internos del SIG |
| **Consumidores principales** | Funcionarios de VLAN 20 · aplicaciones internas del SIG |
| **Registro DNS** | `srv-web-03.uv.local → 10.0.10.5` |

**Justificación SIG:** El SIG de la Unidad de Víctimas articula procesos estratégicos, misionales y de apoyo. La intranet (SUMA) permite a los funcionarios consultar caracterizaciones de procesos, acuerdos de gestión y políticas institucionales sin exponerlos a Internet, reduciendo la superficie de ataque sobre información sensible de operación interna.

---

### srv-dhcp-01 — Servidor DHCP
| Campo | Valor |
|-------|-------|
| **Hostname** | srv-dhcp-01 |
| **IP estática** | 10.0.10.6 |
| **VLAN** | VLAN 10 — Servidores |
| **Imagen Docker** | networkboot/dhcpd |
| **Puertos expuestos** | UDP 67/68 |
| **Rangos de asignación** | VLAN 20: 10.0.20.2–10.0.20.254 · VLAN 30: 10.0.30.2–10.0.30.254 |
| **Mecanismo** | DHCP relay inter-VLAN desde switch hacia VLAN 10 |
| **Consumidores principales** | Hosts de VLAN 20 (Administración) · Hosts de VLAN 30 (Usuarios internos) |
| **Registro DNS** | `srv-dhcp-01.uv.local → 10.0.10.6` |

**Justificación SIG:** Centralizar la asignación de IPs en VLAN 10 permite gestionar y auditar qué equipos acceden a la red de la Unidad, coherente con el control de acceso exigido por el Mapa de Riesgos Institucional. El relay inter-VLAN evita exponer el servidor DHCP a segmentos menos controlados.

---

### srv-web-01 — Servidor Web Público (Portal Ciudadano — Instancia 1)
| Campo | Valor |
|-------|-------|
| **Hostname** | srv-web-01 |
| **IP estática** | 10.0.40.2 |
| **VLAN** | VLAN 40 — DMZ |
| **Imagen Docker** | nginx (configuración portal público) |
| **Puertos expuestos** | HTTP 80 / HTTPS 443 (accesible desde Internet) |
| **Rol en HA** | Upstream 1 del balanceo de carga Nginx |
| **Consumidores principales** | Ciudadanos / víctimas del conflicto armado · Nginx LB · srv-db-01 |
| **Registro DNS** | `srv-web-01.uv.local → 10.0.40.2` |

**Justificación SIG:** El portal ciudadano es el canal digital principal de la Unidad de Víctimas para que las víctimas accedan a información sobre reparación, registro y atención. Su ubicación en DMZ (VLAN 40) aísla el tráfico público del segmento interno de servidores, limitando el impacto de un posible compromiso. Forma parte del balanceo de carga (HA) junto con srv-web-02.

---

### srv-dns-01 — Servidor DNS Autoritativo
| Campo | Valor |
|-------|-------|
| **Hostname** | srv-dns-01 |
| **IP estática** | 10.0.40.3 |
| **VLAN** | VLAN 40 — DMZ |
| **Imagen Docker** | internetsystemsconsortium/bind9 |
| **Puertos expuestos** | UDP/TCP 53 |
| **Zona** | `uv.local` — registros A para los 9 servidores |
| **Consumidores principales** | Todos los servidores internos · clientes VLAN 20 y VLAN 30 · scripts de deploy |
| **Registro DNS** | `srv-dns-01.uv.local → 10.0.40.3` |

**Registros A configurados:**

| Nombre DNS | IP |
|------------|-----|
| srv-web-01.uv.local | 10.0.40.2 |
| srv-web-02.uv.local | 10.0.40.5 |
| srv-web-03.uv.local | 10.0.10.5 |
| srv-db-01.uv.local | 10.0.10.2 |
| srv-files-01.uv.local | 10.0.10.3 |
| srv-ntp-01.uv.local | 10.0.10.4 |
| srv-dhcp-01.uv.local | 10.0.10.6 |
| srv-dns-01.uv.local | 10.0.40.3 |
| srv-smtp-01.uv.local | 10.0.40.4 |

**Justificación SIG:** La resolución de nombres interna elimina la dependencia de IPs hardcodeadas en scripts y configuraciones, facilitando el mantenimiento. Ubicarlo en DMZ permite que tanto los servidores internos como los servicios de cara al público puedan resolver nombres sin abrir el segmento de servidores VLAN 10 al exterior.

---

### srv-smtp-01 — Servidor de Correo (SMTP / MailHog)
| Campo | Valor |
|-------|-------|
| **Hostname** | srv-smtp-01 |
| **IP estática** | 10.0.40.4 |
| **VLAN** | VLAN 40 — DMZ |
| **Imagen Docker** | mailhog/mailhog |
| **Puertos expuestos** | 25/587 (SMTP, solo VLAN 20) · 8025 (interfaz web MailHog, solo VLAN 20) |
| **Función** | Relay de correo de pruebas · captura de notificaciones de scripts |
| **Consumidores principales** | Scripts de backup.sh / monitor.sh (alertas) · uv_admin (interfaz web 8025) |
| **Registro DNS** | `srv-smtp-01.uv.local → 10.0.40.4` |

**Justificación SIG:** Las notificaciones automáticas (resultados de backups, alertas de monitoreo) son clave para que los administradores respondan oportunamente ante incidentes, alineado con el plan de recuperación ante fallos. MailHog en entorno de pruebas evita el envío accidental de correos reales. La interfaz web queda restringida a VLAN 20 (Administración) por firewall.

---

### srv-web-02 — Servidor Web Público (Portal Ciudadano — Instancia 2)
| Campo | Valor |
|-------|-------|
| **Hostname** | srv-web-02 |
| **IP estática** | 10.0.40.5 |
| **VLAN** | VLAN 40 — DMZ |
| **Imagen Docker** | nginx (configuración portal público — réplica) |
| **Puertos expuestos** | HTTP 80 / HTTPS 443 (accesible desde Internet) |
| **Rol en HA** | Upstream 2 del balanceo de carga Nginx |
| **Consumidores principales** | Ciudadanos / víctimas del conflicto armado · Nginx LB · srv-db-01 |
| **Registro DNS** | `srv-web-02.uv.local → 10.0.40.5` |

**Justificación SIG:** Segunda instancia del portal ciudadano en el esquema de alta disponibilidad. El balanceador Nginx distribuye el tráfico entre srv-web-01 y srv-web-02 para garantizar continuidad de servicio ante la caída de una instancia, cumpliendo el requisito de disponibilidad para un servicio crítico al ciudadano (víctimas del conflicto armado).

---

## 3. Justificación Técnica Alineada con el SIG

### 3.1 Segmentación VLAN y el contexto institucional

La Unidad para las Víctimas opera bajo un SIG que articula **procesos estratégicos, misionales, de apoyo y de seguimiento/control**, con las víctimas del conflicto armado como eje central. Esta realidad institucional determina la segmentación de red:

- **VLAN 10 — Servidores internos:** Concentra los servicios críticos de procesamiento de datos (BD, archivos, NTP, DHCP). El aislamiento protege la información sensible de víctimas que el SIG gestiona en procesos como Registro y Valoración, Reparación Integral y Atención.

- **VLAN 20 — Administración:** Segmento de los funcionarios de la Unidad. Tiene acceso controlado a VLAN 10 (necesario para operar los servicios) pero está separado de VLAN 30 para reducir el riesgo de movimiento lateral identificado en el Mapa de Riesgos Institucional.

- **VLAN 30 — Usuarios internos:** Acceso restringido a los servicios mínimos necesarios. Recibe IPs dinámicas del DHCP relay y sincronización horaria de NTP.

- **VLAN 40 — DMZ:** Expone únicamente los servicios de cara al ciudadano y a Internet (portal web, DNS, SMTP). El aislamiento garantiza que un eventual compromiso de un servidor en DMZ no propague acceso directo a VLAN 10 donde reside la base de datos del SIG.

### 3.2 Alta disponibilidad para un servicio crítico al ciudadano

Las víctimas del conflicto armado dependen del portal web de la Unidad para acceder a información sobre su proceso de reparación. La duplicación del servidor web (srv-web-01 + srv-web-02) con balanceo de carga Nginx asegura continuidad ante fallos de hardware o de contenedor, alineado con la misión institucional de garantizar el goce efectivo de derechos.

### 3.3 Integridad y respaldo de datos

El proceso de **Registro y Valoración** del SIG concentra información irreemplazable sobre las víctimas. Por ello:

- srv-db-01 monta su almacenamiento sobre LVM (`lv_db`) encima de RAID 1 (`/dev/md0`), proporcionando redundancia de disco sin pérdida de datos ante fallo de un disco físico.
- El script `backup.sh` realiza `pg_dump` diario de `uv_sig` con retención de 7 días, proporcionando recuperabilidad (RPO ≤ 24h).

### 3.4 Gestión de usuarios y permisos especiales

El SIG identifica riesgos de corrupción y acceso no autorizado a información. La estructura de usuarios y permisos especiales refuerza este control:

- **SETUID** en el ejecutable de backup: permite que `backup.sh` acceda a PostgreSQL con privilegios de `uv_dbadmin` independientemente de quién lo invoque.
- **SETGID** en `/srv/uv_docs` (srv-files-01): los archivos nuevos heredan el grupo `g_files`, garantizando control de acceso consistente sobre documentos del SIG.
- **Sticky bit** en `/srv/uv_docs` y `/tmp`: impide que un usuario elimine archivos de otro, protegiéndo documentos institucionales compartidos.

---

## 4. Resumen de Arquitectura

```
Internet
    │
    ▼
[Firewall / Router de borde]
    │
    ├── VLAN 40 DMZ (10.0.40.0/24)
    │       ├── srv-web-01   10.0.40.2  Portal ciudadano (instancia 1)
    │       ├── srv-dns-01   10.0.40.3  DNS autoritativo (uv.local)
    │       ├── srv-smtp-01  10.0.40.4  SMTP / MailHog
    │       └── srv-web-02   10.0.40.5  Portal ciudadano (instancia 2)
    │
    ├── VLAN 10 Servidores (10.0.10.0/24)
    │       ├── srv-db-01    10.0.10.2  PostgreSQL (uv_sig)
    │       ├── srv-files-01 10.0.10.3  Samba (/srv/uv_docs)
    │       ├── srv-ntp-01   10.0.10.4  NTP / chrony
    │       ├── srv-web-03   10.0.10.5  Nginx Intranet SUMA
    │       └── srv-dhcp-01  10.0.10.6  DHCP relay → VLAN 20 y 30
    │
    ├── VLAN 20 Administración (10.0.20.0/24)
    │       └── Funcionarios / administradores (IPs dinámicas del DHCP)
    │
    └── VLAN 30 Usuarios internos (10.0.30.0/24)
            └── Usuarios generales de la Unidad (IPs dinámicas del DHCP)
```

---

*Documento generado para el Sprint 1 — RED-4 | Proyecto Final Administración de Infraestructura TI | Universidad del Quindío 2026-1*
