# Procedimiento de Acceso SSH — Infraestructura TI SIG
## Unidad para la Atención y Reparación Integral a las Víctimas

**Tarea:** SRV-3 | Sprint 2  
**Servidores con SSH:** srv-db-01 (10.0.10.2) · srv-files-01 (10.0.10.3)  
**Puerto SSH:** 2222 (no el estándar 22)  
**Autenticación:** Solo llave pública — sin contraseñas, sin root

---

## 1. Configuración inicial (una vez por integrante)

### Paso 1 — Verificar si ya tienes un par de llaves SSH

```bash
ls ~/.ssh/id_rsa.pub
```

Si el archivo existe, ya tienes un par de llaves y puedes saltar al Paso 3.

### Paso 2 — Generar el par de llaves (si no tienes)

```bash
ssh-keygen -t rsa -b 4096 -C "uv-infra-ti" -f ~/.ssh/id_rsa
# Presiona Enter dos veces para dejar la passphrase vacía (más práctico para el proyecto)
```

Esto crea dos archivos:
- `~/.ssh/id_rsa` → **llave privada** (NUNCA compartir, NUNCA subir al repo)
- `~/.ssh/id_rsa.pub` → **llave pública** (esta se instala en los contenedores)

### Paso 3 — Agregar la llave pública al .env

```bash
# Ver tu llave pública
cat ~/.ssh/id_rsa.pub

# Copiar la línea completa y pegarla en docker/.env:
SSH_PUBLIC_KEY=ssh-rsa AAAA...tu_llave_completa... uv-infra-ti
```

> ⚠️ `SSH_PUBLIC_KEY` va en el `.env` local (no se sube al repo).  
> Pedir el `.env` base al equipo por WhatsApp y agregar tu llave al final.

### Paso 4 — Rebuild con la llave instalada

```bash
cd /home/<tu_usuario>/Documents/uv-infra-ti/docker
podman-compose up -d --build srv-db-01 srv-files-01
```

---

## 2. Conectarse por SSH

### Conectar a srv-db-01 (Base de Datos)

```bash
# Desde el host — puerto 2222 mapeado al host
ssh -p 2222 uv_dbadmin@localhost

# Desde otro contenedor en vlan10 — IP directa
ssh -p 2222 uv_dbadmin@10.0.10.2
```

### Conectar a srv-files-01 (Archivos Samba)

```bash
# Desde el host — puerto 2223 mapeado al host
ssh -p 2223 uv_admin@localhost

# Desde otro contenedor en vlan10 — IP directa
ssh -p 2222 uv_admin@10.0.10.3
```

### Evitar el mensaje de verificación de host (entorno de desarrollo)

```bash
ssh -p 2222 -o StrictHostKeyChecking=no uv_dbadmin@localhost
```

---

## 3. Verificar que SSH está corriendo dentro del contenedor

```bash
# Ver que sshd está escuchando en 2222
podman exec srv-db-01 ss -tlnp | grep 2222
podman exec srv-files-01 ss -tlnp | grep 2222

# Ver el log de sshd
podman exec srv-db-01 journalctl -u sshd 2>/dev/null || \
    podman exec srv-db-01 cat /var/log/auth.log
```

---

## 4. Resumen de la configuración sshd_config aplicada

| Directiva | Valor | Motivo |
|-----------|-------|--------|
| `Port` | `2222` | Puerto alternativo — reduce escaneos automatizados |
| `PermitRootLogin` | `no` | Root no puede conectarse directamente por SSH |
| `PasswordAuthentication` | `no` | Solo llaves — elimina ataques de fuerza bruta |
| `PubkeyAuthentication` | `yes` | Autenticación por llave pública habilitada |
| `ChallengeResponseAuthentication` | `no` | Deshabilitado para mayor seguridad |
| `AllowUsers` | `uv_dbadmin` / `uv_admin` | Lista blanca explícita de usuarios permitidos |

---

## 5. Mapeo de puertos host → contenedor

| Contenedor | IP interna | Puerto host | Puerto contenedor | Usuario SSH |
|------------|------------|-------------|-------------------|-------------|
| srv-db-01 | 10.0.10.2 | 2222 | 2222 | uv_dbadmin |
| srv-files-01 | 10.0.10.3 | 2223 | 2222 | uv_admin |

> Los puertos 2222 y 2223 en el host son solo para desarrollo local.  
> En producción el acceso SSH sería directo por IP interna desde VLAN 20.

---

*Documento generado para Sprint 2 — SRV-3 | Proyecto Final Administración de Infraestructura TI | Universidad del Quindío 2026-1*
