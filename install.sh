#!/bin/bash
set -euo pipefail
exec > >(tee -i install.log)
exec 2>&1

# Diagnóstico de errores
trap 's=$?; echo "[!] Error en línea $LINENO: comando \"$BASH_COMMAND\" salió con $s" >&2' ERR

if [ "$(id -u)" -ne 0 ]; then
  echo "Este script debe ejecutarse como root."; exit 1
fi

# ===== Verificar Debian 13 (trixie)
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
if [ "$CODENAME" != "trixie" ]; then
  echo "Este script es solo para Debian 13 (trixie). Detectado: ${CODENAME:-desconocido}"
  exit 1
fi
echo "[*] Detectado Debian $CODENAME"

# ===== Reanudación tras reinicio (systemd + state file)
SCRIPT_PATH="$(readlink -f "$0")"
STATE_FILE="/var/lib/redroot-postinstall.state"
RESUME_MODE=""

setup_resume_service() {
  # $1 = modo de reanudación (p.ej. "nvidia")
  local mode="$1"
  install -d -m0755 "$(dirname "$STATE_FILE")"
  umask 077
  {
    echo "RESUME_FROM='$mode'"
    # Persistimos variables necesarias tras el reinicio
    echo "USERNAME='${USERNAME:-}'"
    echo "KFLAV='${KFLAV:-}'"
    echo "UI_SCHEME='${UI_SCHEME:-}'"
    echo "GTK_THEME='${GTK_THEME:-}'"
    echo "APPLY_FONTS='${APPLY_FONTS:-0}'"
    echo "CODENAME='${CODENAME:-}'"
  } > "$STATE_FILE"

  cat > /etc/systemd/system/redroot-postinstall-resume.service <<EOF
[Unit]
Description=Resume Debian post-install (redroot) after reboot
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash "$SCRIPT_PATH" --resume
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable redroot-postinstall-resume.service
}

clear_resume_service() {
  systemctl disable redroot-postinstall-resume.service 2>/dev/null || true
  rm -f /etc/systemd/system/redroot-postinstall-resume.service
  systemctl daemon-reload || true
  rm -f "$STATE_FILE"
}

# Si nos invoca systemd en modo reanudación
if [[ "${1:-}" == "--resume" && -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  RESUME_MODE="${RESUME_FROM:-}"
  echo "[*] Reanudando post-instalación desde fase: ${RESUME_MODE}"
fi

# ===== Verificar Secure Boot (robusto: mokutil o efivars)
secureboot_enabled() {
  if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state 2>/dev/null | grep -qi 'enabled' && return 0
  fi
  local efivar
  efivar="$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -n1)"
  if [ -n "$efivar" ]; then
    local val
    val="$(od -An -tx1 -j4 -N1 "$efivar" 2>/dev/null | tr -d ' \n')"
    [ "$val" = "01" ] && return 0
  fi
  return 1
}

if secureboot_enabled; then
  echo "[!] Secure Boot está ACTIVO. Este script requiere Secure Boot desactivado."
  echo "    Desactívalo en la BIOS/UEFI y vuelve a ejecutar."
  exit 1
fi

# =====================================================================
# ===================== [PRE-NVIDIA] INICIO ============================
# Este bloque corre sólo en la PRIMERA ejecución (antes del reinicio).
# Tras reanudar, se salta completo y retomamos desde NVIDIA.
# =====================================================================
if [[ -z "$RESUME_MODE" ]]; then

# ===== 1) Repos oficiales (reescritura segura + multiarch i386)
echo "[*] Configurando repos oficiales con contrib/non-free/non-free-firmware"
cp -a /etc/apt/sources.list{,.bak}
cat > /etc/apt/sources.list <<EOF
deb https://deb.debian.org/debian ${CODENAME} main contrib non-free non-free-firmware
deb-src https://deb.debian.org/debian ${CODENAME} main contrib non-free non-free-firmware

deb https://security.debian.org/debian-security ${CODENAME}-security main contrib non-free non-free-firmware
deb-src https://security.debian.org/debian-security ${CODENAME}-security main contrib non-free non-free-firmware

deb https://deb.debian.org/debian ${CODENAME}-updates main contrib non-free non-free-firmware
deb-src https://deb.debian.org/debian ${CODENAME}-updates main contrib non-free non-free-firmware
EOF

# Habilitar arquitectura i386 (Steam/libs 32-bit)
dpkg --add-architecture i386 2>/dev/null || true
apt update

# ===== 2) Utilidades básicas (incluye sudo)
echo "[*] Instalando utilidades básicas"
apt install -y git nano sudo wget curl ca-certificates gpg xdg-utils dconf-cli python3-minimal

# ===== 3) Determinar usuario y agregarlo a sudo
USERNAME="${SUDO_USER:-}"
if [ -z "${USERNAME}" ]; then
  CANDIDATE="$(getent passwd | awk -F: '$3>=1000 && $1!="nobody"{print $1; exit}')"
  if [ -n "$CANDIDATE" ]; then
    USERNAME="$CANDIDATE"
  else
    read -rp "Ingresa el NOMBRE_DE_USUARIO para agregar al grupo sudo: " USERNAME
  fi
fi
if ! id -u "$USERNAME" >/dev/null 2>&1; then
  echo "[!] El usuario '$USERNAME' no existe en el sistema."; exit 1
fi
echo "[*] Agregando ${USERNAME} al grupo sudo"
usermod -a -G sudo "$USERNAME"

# ===== 4) Configurar repo redroot (stable exclusivo para trixie)
echo "[*] Configurando repo redroot (stable)"
install -d /usr/share/keyrings
# De-armored para APT
curl -fsSL https://deb.redroot.cc/KEY.asc | gpg --dearmor | tee /usr/share/keyrings/debian-redroot.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/debian-redroot.gpg] https://deb.redroot.cc/ stable main" \
  > /etc/apt/sources.list.d/debian-redroot.list
apt update

# ===== 5) GNOME + utilidades solicitadas
echo "[*] Instalando GNOME, utilidades y compresión"
apt install -y \
  gdm3 gnome-shell gnome-console gnome-tweaks gnome-themes-extra \
  ffmpegthumbnailer power-profiles-daemon seahorse eog \
  xdg-user-dirs xdg-user-dirs-gtk \
  xdg-desktop-portal xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
  gnome-browser-connector gnome-text-editor gnome-disk-utility \
  gnome-shell-extension-prefs gnome-shell-extension-appindicator \
  gnome-shell-extension-dash-to-panel \
  hydrapaper fastfetch htop \
  file-roller p7zip-full unrar zip unzip \
  fonts-noto fonts-noto-color-emoji fonts-noto-cjk fonts-noto-mono

# Obtener el locale del sistema
if [ -f /etc/default/locale ]; then
    SYS_LOCALE=$(awk -F= '/^LANG=/{print $2}' /etc/default/locale | tr -d '"')
else
    SYS_LOCALE="es_ES.UTF-8"
fi
SYS_LANG="${SYS_LOCALE%%.*}"

# Asegurar paquete 'locales' y que el locale esté generado (idempotente)
echo "[*] Verificando y generando locale '${SYS_LOCALE}'"
apt-get update
apt-get install -y --no-install-recommends locales
# Si no existe la línea, la añadimos; si está comentada, la descomentamos
grep -qE "^[#\s]*${SYS_LOCALE//./\\.}(\s|$)" /etc/locale.gen || echo "${SYS_LOCALE} UTF-8" >> /etc/locale.gen
sed -i -E "s/^#\s*(${SYS_LOCALE//./\\.})(\s|$)/\1/" /etc/locale.gen
locale-gen
update-locale LANG="${SYS_LOCALE}"

# Escribir el idioma en el archivo de configuración del usuario
echo "[*] Escribiendo el locale en ~/.config/user-dirs.locale"
runuser -l "$USERNAME" -c "mkdir -p ~/.config && printf '%s\n' '${SYS_LANG}' > ~/.config/user-dirs.locale"

# Forzar la actualización de los nombres de las carpetas con el locale correcto
echo "[*] Actualizando carpetas de usuario con xdg-user-dirs-update --force"
runuser -l "$USERNAME" -c "LANG='${SYS_LOCALE}' xdg-user-dirs-update --force"

# Habilitar arranque gráfico con GDM
echo "[*] Habilitando GDM y target gráfico"
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable gdm3 || true
  systemctl set-default graphical.target || true
fi

# === UUIDs de extensiones (detección robusta) ===
if [ -d "/usr/share/gnome-shell/extensions/ubuntu-appindicators@ubuntu.com" ]; then
  APPINDICATOR_UUID="ubuntu-appindicators@ubuntu.com"
else
  APPINDICATOR_UUID="appindicatorsupport@gnome-shell-extensions.gcampax.github.com"
fi
DASH2P_UUID="dash-to-panel@jderose9.github.com"

# ===== 5c) Inicio de sesión automático (GDM)
read -rp "¿Habilitar inicio de sesión automático en GDM para el usuario ${USERNAME}? [s/N]: " AUTOLOGIN
if [[ "${AUTOLOGIN:-N}" =~ ^[sS]$ ]]; then
  GDM_DAEMON_CONF="/etc/gdm3/daemon.conf"
  echo "[*] Configurando autologin en ${GDM_DAEMON_CONF}"
  cp -a "${GDM_DAEMON_CONF}"{,.bak}
  if grep -q '^\[daemon\]' "${GDM_DAEMON_CONF}"; then
    if grep -qE '^[#\s]*AutomaticLoginEnable\s*=' "${GDM_DAEMON_CONF}"; then
      sed -i -E "s/^[#\s]*AutomaticLoginEnable\s*=.*/AutomaticLoginEnable=true/" "${GDM_DAEMON_CONF}"
    else
      sed -i "/^\[daemon\]/a AutomaticLoginEnable=true" "${GDM_DAEMON_CONF}"
    fi
    if grep -qE '^[#\s]*AutomaticLogin\s*=' "${GDM_DAEMON_CONF}"; then
      sed -i -E "s/^[#\s]*AutomaticLogin\s*=.*/AutomaticLogin=${USERNAME}/" "${GDM_DAEMON_CONF}"
    else
      sed -i "/^\[daemon\]/a AutomaticLogin=${USERNAME}" "${GDM_DAEMON_CONF}"
    fi
  else
    cat >> "${GDM_DAEMON_CONF}" <<EOF

[daemon]
AutomaticLoginEnable=true
AutomaticLogin=${USERNAME}
EOF
  fi
  echo "[*] Autologin habilitado para ${USERNAME}. (Copia de seguridad en daemon.conf.bak)"
fi

# ===== 6) Preferencia de Modo (Oscuro/Claro) para GNOME
echo
echo "== Preferencia de apariencia =="
echo "1) Modo Oscuro"
echo "2) Modo Claro"
read -rp "Opción [1-2] (por defecto 1): " THEMEOPT
THEMEOPT="${THEMEOPT:-1}"
if [ "$THEMEOPT" = "2" ]; then
  UI_SCHEME="default"; GTK_THEME="Adwaita"
else
  UI_SCHEME="prefer-dark"; GTK_THEME="Adwaita-dark"
fi

# ===== 6b) Microcode + firmware (ajustado)
echo "[*] Instalando firmware (NVIDIA/MediaTek) y microcode según CPU"

apt install -y firmware-nvidia-graphics firmware-mediatek

CPU_VENDOR="$(LC_ALL=C lscpu | awk -F: '/Vendor ID:/ {gsub(/^[ \t]+/, "", $2); print $2}')"
case "$CPU_VENDOR" in
  GenuineIntel)
    echo "[*] CPU Intel detectada -> instalando microcode y firmware Intel"
    apt install -y intel-microcode firmware-intel-graphics firmware-intel-misc
    ;;
  AuthenticAMD)
    echo "[*] CPU AMD detectada -> instalando microcode AMD"
    apt install -y amd64-microcode
    ;;
  *)
    echo "[!] No se detectó Intel ni AMD, se omite microcode"
    ;;
esac

# ===== 7) Kernel personalizado (redroot) + update-grub
echo
echo "== Selecciona kernel personalizado (redroot) =="
echo "1)  x86-64 (Baseline genérico)"
echo "2)  x86-64-v2 (CPUs ~2008+)"
echo "3)  x86-64-v3 (CPUs ~2013+)"
echo "4)  x86-64-v4 (Intel Skylake+, AMD Zen4+)"
echo "5)  znver1 (Ryzen 1000/2000, EPYC 7001)"
echo "6)  znver2 (Ryzen 3000/4000, EPYC 7002)"
echo "7)  znver3 (Ryzen 5000/6000, EPYC 7003)"
echo "8)  znver4 (Ryzen 7000/8000, EPYC 9004)"
echo "9)  znver5 (Ryzen 9000, EPYC 9005)"
echo "10) skylake (Intel 6ª a 9ª gen Desktop)"
echo "11) icelake-client (Intel 10ª gen Desktop)"
echo "12) tigerlake (Intel 11ª gen Portátiles)"
echo "13) rocketlake (Intel 11ª gen Desktop)"
echo "14) alderlake (Intel 12ª gen)"
echo "15) raptorlake (Intel 13ª/14ª gen)"
echo "16) arrowlake (Intel Core Ultra 200 Laptop)"
echo "17) arrowlake-s (Intel Core Ultra 200 Desktop)"
echo "18) meteorlake (Intel Core Ultra 100 Laptop)"
echo "19) lunarlake (Intel Core Ultra 200V Laptop)"
echo "20) auto-x86-64 (detecta automáticamente v2/v3/v4 según CPU)"
read -rp "Opción [1-20] (por defecto 1): " KOPT
KOPT="${KOPT:-1}"

case "$KOPT" in
  1)  KFLAV="x86-64" ;;
  2)  KFLAV="x86-64-v2" ;;
  3)  KFLAV="x86-64-v3" ;;
  4)  KFLAV="x86-64-v4" ;;
  5)  KFLAV="znver1" ;;
  6)  KFLAV="znver2" ;;
  7)  KFLAV="znver3" ;;
  8)  KFLAV="znver4" ;;
  9)  KFLAV="znver5" ;;
  10) KFLAV="skylake" ;;
  11) KFLAV="icelake-client" ;;
  12) KFLAV="tigerlake" ;;
  13) KFLAV="rocketlake" ;;
  14) KFLAV="alderlake" ;;
  15) KFLAV="raptorlake" ;;
  16) KFLAV="arrowlake" ;;
  17) KFLAV="arrowlake-s" ;;
  18) KFLAV="meteorlake" ;;
  19) KFLAV="lunarlake" ;;
  20)
    echo "[*] Detectando el nivel de arquitectura x86-64..."
    cpu_flags=$(lscpu)
    if echo "$cpu_flags" | grep -E -q "\bavx512f\b"; then
        KFLAV="x86-64-v4"
    elif echo "$cpu_flags" | grep -E -q "\bavx2\b" && echo "$cpu_flags" | grep -E -q "\bavx\b"; then
        KFLAV="x86-64-v3"
    elif echo "$cpu_flags" | grep -E -q "\bpopcnt\b" && echo "$cpu_flags" | grep -E -q "\bsse4_2\b"; then
        KFLAV="x86-64-v2"
    else
        KFLAV="x86-64"
    fi
    echo "[*] Nivel detectado: $KFLAV"
    ;;
  *)  KFLAV="x86-64" ;;
esac

echo "[*] Instalando kernel linux-image-redroot-${KFLAV} + headers"
apt install -y "linux-image-redroot-${KFLAV}" "linux-headers-redroot-${KFLAV}"
echo "[*] Regenerando configuración de GRUB"
update-grub || true
echo "[i] Kernel en ejecución actual: $(uname -r)"
echo "[i] Tras el reinicio, el módulo NVIDIA se construirá para el kernel nuevo."

fi
# =====================================================================
# ======================= [PRE-NVIDIA] FIN =============================
# =====================================================================

# ===== 8) NVIDIA opcional (con reanudación automática tras reinicio)
if [[ -z "$RESUME_MODE" ]]; then
  echo
  read -rp "¿Instalar drivers NVIDIA (nvidia-open)? Requiere reinicio previo. [s/N]: " NV
  if [[ "${NV:-N}" =~ ^[sS]$ ]]; then
    echo "[*] Preparando reanudación para instalar nvidia-open con el kernel recién instalado..."
    setup_resume_service "nvidia"
    echo "[*] Se reiniciará en 5 segundos para continuar automáticamente."
    sleep 5
    reboot
    exit 0
  else
    echo "[*] Omitiendo NVIDIA"
  fi
else
  if [[ "$RESUME_MODE" == "nvidia" ]]; then
    echo "[*] Fase reanudada: instalación de nvidia-open"
    TMPDEB="$(mktemp -u /tmp/cuda-keyring_XXXX.deb)"
    wget -O "$TMPDEB" https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb
    dpkg -i "$TMPDEB" || { echo "dpkg falló. Revisa compatibilidad del keyring con trixie."; exit 1; }
    rm -f "$TMPDEB"
    apt update
    apt install -y nvidia-open
    echo "[*] Regenerando GRUB tras instalar NVIDIA"
    update-grub || true
    echo "[*] Limpieza del modo reanudación (servicio y state file)"
    clear_resume_service
    RESUME_MODE=""
  fi
fi

# ===== 9) Navegador (Firefox ESR o Brave)
echo
echo "== Selecciona navegador =="
echo "1) Firefox ESR (Debian)"
echo "2) Brave"
read -rp "Opción [1-2] (por defecto 1): " BOPT
BOPT="${BOPT:-1}"
if [ "$BOPT" = "2" ]; then
  echo "[*] Instalando Brave"
  curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
    https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
  curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources \
    https://brave-browser-apt-release.s3.brave.com/brave-browser-apt-release.sources
  apt update
  apt install -y brave-browser
else
  echo "[*] Instalando Firefox ESR"
  apt install -y firefox-esr
fi

# ===== 10) Iconos: GNOME default / Papirus / Tela Circle
echo
echo "== Selecciona paquete de iconos =="
echo "1) Default de GNOME (no instalar temas extra)"
echo "2) Papirus (paquete Debian: papirus-icon-theme)"
echo "3) Tela Circle (via script oficial)"
read -rp "Opción [1-3] (por defecto 1): " ICONOPT
ICONOPT="${ICONOPT:-1}"

APPLY_ICON_THEME=""
case "$ICONOPT" in
  2)
    echo "[*] Instalando Papirus"
    apt install -y papirus-icon-theme
    if [ "${UI_SCHEME:-prefer-dark}" = "prefer-dark" ]; then
      APPLY_ICON_THEME="Papirus-Dark"
    else
      APPLY_ICON_THEME="Papirus-Light"
    fi
    ;;
  3)
    echo "[*] Instalando Tela Circle (script oficial, TODOS los colores)"
    TMPDIR="$(mktemp -d)"
    git clone --depth=1 https://github.com/vinceliuice/Tela-circle-icon-theme "$TMPDIR/Tela-circle-icon-theme"
    bash "$TMPDIR/Tela-circle-icon-theme/install.sh" -a -c -d /usr/share/icons
    rm -rf "$TMPDIR"

    echo "Colores disponibles: standard black blue brown green grey orange pink purple red yellow manjaro ubuntu dracula nord"
    read -rp "Elige el color a aplicar (por defecto: standard): " TELA_COLOR
    TELA_COLOR="${TELA_COLOR:-standard}"

    if [ "$TELA_COLOR" = "standard" ]; then
      if [ "${UI_SCHEME:-prefer-dark}" = "prefer-dark" ]; then
        APPLY_ICON_THEME="Tela-circle-dark"
      else
        APPLY_ICON_THEME="Tela-circle-light"
      fi
    else
      if [ "${UI_SCHEME:-prefer-dark}" = "prefer-dark" ]; then
        APPLY_ICON_THEME="Tela-circle-${TELA_COLOR}-dark"
      else
        APPLY_ICON_THEME="Tela-circle-${TELA_COLOR}-light"
      fi
    fi
    ;;
  *)
    echo "[*] Iconos por defecto de GNOME (Adwaita)"
    ;;
esac

# ===== 11) Segoe UI (opcional)
echo
read -rp "¿Instalar la fuente Segoe UI (Windows 11)? [s/N]: " SEGOE
APPLY_FONTS="${APPLY_FONTS:-0}"
if [[ "${SEGOE:-N}" =~ ^[sS]$ ]]; then
  echo "[*] Instalando Segoe UI en el sistema (origen no oficial; considera licencias)"
  DEST_DIR="/usr/share/fonts/Microsoft/TrueType/SegoeUI"
  install -d -m0755 "$DEST_DIR"
  declare -A FONTS=(
    [segoeui.ttf]="https://github.com/mrbvrz/segoe-ui/raw/master/font/segoeui.ttf?raw=true"
    [segoeuib.ttf]="https://github.com/mrbvrz/segoe-ui/raw/master/font/segoeuib.ttf?raw=true"
    [segoeuii.ttf]="https://github.com/mrbvrz/segoe-ui/raw/master/font/segoeuii.ttf?raw=true"
    [segoeuiz.ttf]="https://github.com/mrbvrz/segoe-ui/raw/master/font/segoeuiz.ttf?raw=true"
    [segoeuil.ttf]="https://github.com/mrbvrz/segoe-ui/raw/master/font/segoeuil.ttf?raw=true"
    [seguili.ttf]="https://github.com/mrbvrz/segoe-ui/raw/master/font/seguili.ttf?raw=true"
    [segoeuisl.ttf]="https://github.com/mrbvrz/segoe-ui/raw/master/font/segoeuisl.ttf?raw=true"
    [seguisli.ttf]="https://github.com/mrbvrz/segoe-ui/raw/master/font/seguisli.ttf?raw=true"
    [seguisb.ttf]="https://github.com/mrbvrz/segoe-ui/raw/master/font/seguisb.ttf?raw=true"
    [seguisbi.ttf]="https://github.com/mrbvrz/segoe-ui/raw/master/font/seguisbi.ttf?raw=true"
    [seguibl.ttf]="https://github.com/mrbvrz/segoe-ui/raw/master/font/seguibl.ttf?raw=true"
    [seguibli.ttf]="https://github.com/mrbvrz/segoe-ui/raw/master/font/seguibli.ttf?raw=true"
    [seguiemj.ttf]="https://github.com/mrbvrz/segoe-ui/raw/master/font/seguiemj.ttf?raw=true"
    [seguisym.ttf]="https://github.com/mrbvrz/segoe-ui/raw/master/font/seguisym.ttf?raw=true"
    [seguihis.ttf]="https://github.com/mrbvrz/segoe-ui/raw/master/font/seguihis.ttf?raw=true"
  )
  for f in "${!FONTS[@]}"; do
    wget -q "${FONTS[$f]}" -O "${DEST_DIR}/$f" && chmod 0644 "${DEST_DIR}/$f"
  done
  fc-cache -f "$DEST_DIR" || true
  APPLY_FONTS=1
fi

# ===== 12) Discord y/o Steam
echo
echo "== ¿Instalar Steam y/o Discord? =="
echo "1) Solo Discord"
echo "2) Solo Steam"
echo "3) Ambos"
echo "4) Ninguno (por defecto)"
read -rp "Opción [1-4] (por defecto 4): " GOPT
GOPT="${GOPT:-4}"
install_discord() { echo "[*] Instalando Discord"; apt install -y discord; }
install_steam()   { echo "[*] Instalando Steam";   apt install -y steam-installer; }
case "$GOPT" in
  1) install_discord ;;
  2) install_steam ;;
  3) install_discord; install_steam ;;
  *) echo "[*] Omitiendo instalación de Discord/Steam" ;;
esac

# ===== Fix para NetworkManager
echo
echo "[*] Corrigiendo configuración de NetworkManager"
NMCONF="/etc/NetworkManager/NetworkManager.conf"
if grep -q "^\[ifupdown\]" "$NMCONF"; then
  sed -i 's/^managed=false/managed=true/' "$NMCONF"
else
  cat >> "$NMCONF" <<EOF

[ifupdown]
managed=true
EOF
fi
systemctl restart NetworkManager || true

# ===== 13) APLICAR CONFIG (robusto): defaults del sistema + aplicación inmediata al usuario
echo "[*] Aplicando defaults de dconf (sistema) y ajustes para ${USERNAME}"

# Crear perfil dconf si no existe
install -d /etc/dconf/db/local.d
if [ ! -f /etc/dconf/profile/user ]; then
  cat >/etc/dconf/profile/user <<'EOF'
user-db:user
system-db:local
EOF
fi

# Defaults del sistema (se aplican en el próximo login)
DCONF_FILE="/etc/dconf/db/local.d/00-redroot"
{
  echo "[org/gnome/desktop/interface]"
  echo "color-scheme='${UI_SCHEME:-prefer-dark}'"
  echo "gtk-theme='${GTK_THEME:-Adwaita-dark}'"
  if [ -n "${APPLY_ICON_THEME:-}" ]; then
    echo "icon-theme='${APPLY_ICON_THEME}'"
  fi
  echo "font-antialiasing='rgba'"
  echo "font-rgba-order='rgb'"
  if [ "${APPLY_FONTS:-0}" -eq 1 ]; then
    echo "font-name='Segoe UI 11'"
    echo "document-font-name='Segoe UI 11'"
    echo "monospace-font-name='Noto Mono 10'"
  fi

  echo
  echo "[org/gnome/desktop/wm/preferences]"
  if [ "${APPLY_FONTS:-0}" -eq 1 ]; then
    echo "titlebar-font='Segoe UI Bold 11'"
  fi

  echo
  echo "[org/gnome/desktop/peripherals/mouse]"
  echo "accel-profile='flat'"

  echo
  echo "[org/gnome/desktop/peripherals/touchpad]"
  echo "accel-profile='flat'"

  echo
  echo "[org/gnome/desktop/background]"
  echo "picture-uri='file:///usr/share/backgrounds/redroot/default.png'"
  echo "picture-uri-dark='file:///usr/share/backgrounds/redroot/default.png'"
  
  echo
  echo "[org/gnome/shell]"
  echo "enabled-extensions=['${APPINDICATOR_UUID}','${DASH2P_UUID}']"
} > "$DCONF_FILE"

# Actualizar la BD de dconf de sistema
dconf update

# Aplicación inmediata al usuario (Wayland-safe con dbus-run-session)
runuser -l "$USERNAME" -c "dbus-run-session gsettings set org.gnome.desktop.interface color-scheme '${UI_SCHEME:-prefer-dark}'"
runuser -l "$USERNAME" -c "dbus-run-session gsettings set org.gnome.desktop.interface gtk-theme '${GTK_THEME:-Adwaita-dark}'"
if [ -n "${APPLY_ICON_THEME:-}" ]; then
  runuser -l "$USERNAME" -c "dbus-run-session gsettings set org.gnome.desktop.interface icon-theme '${APPLY_ICON_THEME}'"
fi
runuser -l "$USERNAME" -c "dbus-run-session gsettings set org.gnome.desktop.interface font-antialiasing 'rgba'"
runuser -l "$USERNAME" -c "dbus-run-session gsettings set org.gnome.desktop.interface font-rgba-order 'rgb'"

if [ "${APPLY_FONTS:-0}" -eq 1 ]; then
  runuser -l "$USERNAME" -c "dbus-run-session gsettings set org.gnome.desktop.interface font-name 'Segoe UI 11'"
  runuser -l "$USERNAME" -c "dbus-run-session gsettings set org.gnome.desktop.interface document-font-name 'Segoe UI 11'"
  runuser -l "$USERNAME" -c "dbus-run-session gsettings set org.gnome.desktop.interface monospace-font-name 'Noto Mono 10'"
  runuser -l "$USERNAME" -c "dbus-run-session gsettings set org.gnome.desktop.wm.preferences titlebar-font 'Segoe UI Bold 11'"
fi
runuser -l "$USERNAME" -c "dbus-run-session gsettings set org.gnome.desktop.peripherals.mouse accel-profile 'flat'"
runuser -l "$USERNAME" -c "dbus-run-session gsettings set org.gnome.desktop.peripherals.touchpad accel-profile 'flat' || true"

# === Activar extensiones para el usuario actual ===
runuser -l "$USERNAME" -c "dbus-run-session bash -lc '
if command -v gnome-extensions >/dev/null 2>&1; then
  gnome-extensions enable \"${APPINDICATOR_UUID}\" || true
  gnome-extensions enable \"${DASH2P_UUID}\" || true
else
  U1=\"${APPINDICATOR_UUID}\" U2=\"${DASH2P_UUID}\" python3 - <<\"PY\"
import ast, os, subprocess
uuids = [os.environ.get(\"U1\",\"\"), os.environ.get(\"U2\",\"\")]
cur = subprocess.check_output(
    [\"gsettings\",\"get\",\"org.gnome.shell\",\"enabled-extensions\"],
    text=True
).strip()
try:
    arr = list(ast.literal_eval(cur))
except Exception:
    arr = []
for u in uuids:
    if u and u not in arr:
        arr.append(u)
val = \"[\" + \", \".join(\"'\"+x+\"'\" for x in arr) + \"]\"
subprocess.check_call([\"gsettings\",\"set\",\"org.gnome.shell\",\"enabled-extensions\", val])
PY
fi
'"

# ===== Wallpaper personalizado (GNOME + GRUB)
echo "[*] Descargando y configurando wallpaper personalizado"
WALLPAPER_DIR="/usr/share/backgrounds/redroot"
WALLPAPER_FILE="${WALLPAPER_DIR}/default.png"

install -d "$WALLPAPER_DIR"
wget -qO "$WALLPAPER_FILE" "https://raw.githubusercontent.com/RedrootDEV/Debian-RedRoot/main/configs/default.png"

# Establecer wallpaper en GNOME para el usuario
runuser -l "$USERNAME" -c "dbus-run-session gsettings set org.gnome.desktop.background picture-uri 'file://$WALLPAPER_FILE'"
runuser -l "$USERNAME" -c "dbus-run-session gsettings set org.gnome.desktop.background picture-uri-dark 'file://$WALLPAPER_FILE'"

# Configurar el fondo en GRUB
GRUB_FILE="/etc/default/grub"
if grep -q '^GRUB_BACKGROUND=' "$GRUB_FILE"; then
  sed -i "s|^GRUB_BACKGROUND=.*|GRUB_BACKGROUND=\"$WALLPAPER_FILE\"|" "$GRUB_FILE"
else
  echo "GRUB_BACKGROUND=\"$WALLPAPER_FILE\"" >> "$GRUB_FILE"
fi

# Configurar GRUB oculto pero accesible con ESC
if grep -q '^GRUB_TIMEOUT_STYLE=' "$GRUB_FILE"; then
  sed -i "s|^GRUB_TIMEOUT_STYLE=.*|GRUB_TIMEOUT_STYLE=hidden|" "$GRUB_FILE"
else
  echo "GRUB_TIMEOUT_STYLE=hidden" >> "$GRUB_FILE"
fi

if grep -q '^GRUB_TIMEOUT=' "$GRUB_FILE"; then
  sed -i "s|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=3|" "$GRUB_FILE"
else
  echo "GRUB_TIMEOUT=3" >> "$GRUB_FILE"
fi

echo "[*] Regenerando configuración de GRUB oculto y con nuevo fondo"
update-grub || true

# ===== Limpieza final
echo
echo "[*] Realizando limpieza final"
apt autoremove --purge -y malcontent* yelp* debian-reference* zutty* plymouth* || true
apt clean
apt autoclean

# Limpieza defensiva de cualquier rastro de reanudación
clear_resume_service || true

# ===== Preguntar por reinicio
echo
read -rp "¿Quieres reiniciar el sistema ahora? [s/N]: " REBOOT
if [[ "${REBOOT:-N}" =~ ^[sS]$ ]]; then
  echo "[*] Reiniciando..."
  reboot
else
  echo "[*] Instalación finalizada, reinicia manualmente cuando lo desees."
fi

echo
echo "======================================="
echo " Instalación finalizada."
echo " - Usuario en grupo sudo: ${USERNAME}"
echo " - Kernel redroot: ${KFLAV:-no-seleccionado}"
echo " - GDM habilitado; target por defecto: graphical"
echo " - Modo UI: $( [ "${UI_SCHEME:-prefer-dark}" = "prefer-dark" ] && echo 'Oscuro' || echo 'Claro' )"
echo " - Revisa install.log si algo falló."
echo " - Recomiendo reiniciar antes de iniciar sesión gráfica."
echo "======================================="

