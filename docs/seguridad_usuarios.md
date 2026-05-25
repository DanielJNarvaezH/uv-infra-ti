# Seguridad — Gestión de Usuarios, Grupos y Permisos Especiales

**Proyecto:** Infraestructura TI — Unidad para la Atención y Reparación Integral a las Víctimas  
**Tarea:** SEG-2  
**Script:** `scripts/users.sh`

---

## 1. Usuarios del Sistema

| Usuario | UID | Shell | Propósito |
|---|---|---|---|
| `uv_admin` | 2001 | `/bin/bash` | Administrador general — acceso SSH a `srv-files-01` |
| `uv_webmaster` | 2002 | `/bin/bash` | Administrador web — gestión de `srv-php-fpm` |
| `uv_dbadmin` | 2003 | `/bin/bash` | Administrador de BD — acceso SSH a `srv-db-01` |
| `uv_files_user` | 2004 | `/usr/sbin/nologin` | Usuario de servicio Samba — sin shell de login |

---

## 2. Grupos del Sistema

| Grupo | GID | Descripción |
|---|---|---|
| `g_admins` | 2000 | Administradores generales — acceso privilegiado |
| `g_web` | 2010 | Administradores web — gestión de contenido |
| `g_db` | 2020 | Administradores de base de datos |
| `g_files` | 1050 | Usuarios del servidor de archivos Samba |

---

## 3. Asignación de Usuarios a Grupos

| Usuario | Grupo principal | Grupos secundarios |
|---|---|---|
| `uv_admin` | `g_admins` | `g_files` |
| `uv_webmaster` | `g_web` | `g_admins` |
| `uv_dbadmin` | `g_db` | `g_admins` |
| `uv_files_user` | `g_files` | — |

---

## 4. Permisos Especiales

### 4.1 SETUID — `chmod u+s`

**Archivo:** `/usr/local/bin/uv-backup.sh`

```bash
chmod u+s /usr/local/bin/uv-backup.sh
# Verificar: ls -la /usr/local/bin/uv-backup.sh
# Resultado esperado: -rwsrwxr-x (la 's' en posición de ejecutable de propietario)
```

**Función:** Permite que cualquier usuario ejecute el script de backup con los privilegios del propietario (root), sin necesidad de sudo. Útil para backups programados desde cron bajo usuarios no privilegiados.

---

### 4.2 SETGID — `chmod g+s`

**Directorio:** `/srv/uv_docs`

```bash
chmod g+s /srv/uv_docs
# Verificar: ls -ld /srv/uv_docs
# Resultado esperado: drwxrwsr-x (la 's' en posición de ejecutable de grupo)
```

**Función:** Todo archivo o subdirectorio creado dentro de `/srv/uv_docs` hereda automáticamente el grupo del directorio (`g_files`). Garantiza que todos los miembros del grupo puedan acceder a los archivos compartidos sin importar qué usuario los creó.

---

### 4.3 Sticky Bit — `chmod +t`

**Directorios:** `/tmp` y `/srv/uv_docs`

```bash
chmod +t /tmp
chmod +t /srv/uv_docs
# Verificar: ls -ld /tmp /srv/uv_docs
# Resultado esperado: drwxrwxrwt (la 't' al final)
```

**Función:** Solo el propietario de un archivo puede eliminarlo, aunque otros usuarios tengan permisos de escritura en el directorio. Previene que un usuario borre archivos de otros en directorios compartidos.

---

## 5. Cómo Aplicar la Configuración

El script `scripts/users.sh` aplica toda la configuración de forma idempotente (puede ejecutarse múltiples veces sin errores):

```bash
# Dentro de un contenedor específico:
podman exec -it srv-db-01    bash /opt/uv-infra-ti/users.sh
podman exec -it srv-files-01 bash /opt/uv-infra-ti/users.sh
podman exec -it srv-php-fpm  bash /opt/uv-infra-ti/users.sh

# O en el host directamente:
sudo bash scripts/users.sh
```

---

## 6. Verificación

```bash
# Verificar grupos
getent group g_admins g_web g_db g_files

# Verificar usuarios y sus grupos
id uv_admin
id uv_webmaster
id uv_dbadmin
id uv_files_user

# Verificar permisos especiales
ls -la /usr/local/bin/uv-backup.sh   # debe tener 's' en owner execute
ls -ld /srv/uv_docs                   # debe tener 's' en group execute y 't' al final
ls -ld /tmp                           # debe tener 't' al final
```

---

## 7. Referencia de Bits Especiales

| Bit | Octal | Efecto en archivo | Efecto en directorio |
|---|---|---|---|
| SETUID | `4000` | Ejecuta como propietario del archivo | Sin efecto significativo |
| SETGID | `2000` | Ejecuta como grupo del archivo | Archivos hijos heredan el grupo |
| Sticky | `1000` | Sin efecto en Linux moderno | Solo el propietario puede borrar |

## 8. Política de contraseñas

- Longitud mínima: 12 caracteres.
- Caducidad: 90 días (PASS_MAX_DAYS = 90).
- Requisitos recomendados: mezcla de mayúsculas, minúsculas, dígitos y símbolos; historial de contraseñas (p. ej. remember=5); edad mínima 7 días.
- Ejemplo de configuración (Debian/Ubuntu):
  1. Instalar módulo de calidad de contraseñas:
     sudo apt update && sudo apt install -y libpam-pwquality
  2. Forzar longitud mínima en /etc/pam.d/common-password:
     password requisite pam_pwquality.so retry=3 minlen=12 difok=3
  3. Establecer caducidad por defecto en /etc/login.defs:
     PASS_MAX_DAYS 90
     PASS_MIN_DAYS 7
     PASS_WARN_AGE 14
  4. Aplicar a usuarios existentes:
     for u in uv_admin uv_webmaster uv_dbadmin; do sudo chage -M 90 -m 7 -W 14 $u; done

Ajustar estos valores según la política organizacional y validar en entorno de staging antes de aplicar en producción.

