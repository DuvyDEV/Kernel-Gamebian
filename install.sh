#!/bin/bash
set -euo pipefail
exec > >(tee -i install.log)
exec 2>&1

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

# ===== 1) Repos oficiales (reescritura segura + multiarch i386)
echo "[*] Configurando repos oficiales con contrib/non-free/non-free-firmware"
cp -a /etc/apt/sources.list{,.bak}

cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${CODENAME} main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian ${CODENAME} main contrib non-free non-free-firmware

deb http://security.debian.org/debian-security ${CODENAME}-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security ${CODENAME}-security main contrib non-free non-free-firmware

deb http://deb.debian.org/debian ${CODENAME}-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian ${CODENAME}-updates main contrib non-free non-free-firmware
EOF

# Habilitar arquitectura i386 para compatibilidad (Steam, libs 32-bit)
dpkg --add-architecture i386 2>/dev/null || true

apt update

# ===== 2) Utilidades básicas (incluye sudo)
echo "[*] Instalando utilidades básicas"
apt install -y git nano sudo wget curl ca-certificates gpg xdg-utils

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
echo "[*] Agregando ${USERNAME} al grupo sudo"
usermod -a -G sudo "$USERNAME"

# ===== 4) Configurar repo redroot (stable exclusivo para trixie)
echo "[*] Configurando repo redroot (stable)"
install -d /usr/share/keyrings
curl -fsSL https://deb.redroot.cc/KEY.asc | tee /usr/share/keyrings/debian-redroot.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/debian-redroot.gpg] https://deb.redroot.cc/ stable main" \
  > /etc/apt/sources.list.d/debian-redroot.list

apt update

# ===== 5) GNOME + utilidades solicitadas
echo "[*] Instalando GNOME, utilidades y compresión"
apt install -y \
  gnome-shell gdm3 gnome-tweaks gnome-themes-extra \
  ffmpegthumbnailer power-profiles-daemon seahorse eog \
  xdg-user-dirs xdg-user-dirs-gtk \
  xdg-desktop-portal xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
  gnome-browser-connector gnome-text-editor gnome-disk-utility \
  gnome-shell-extension-prefs gnome-shell-extension-appindicator \
  gnome-shell-extension-dash-to-panel \
  hydrapaper \
  file-roller p7zip-full unrar zip unzip \
  fonts-noto fonts-noto-color-emoji fonts-noto-cjk fonts-noto-mono

# Crear carpetas XDG para el usuario final
runuser -l "$USERNAME" -c 'xdg-user-dirs-update'

# Habilitar arranque gráfico con GDM
echo "[*] Habilitando GDM y target gráfico"
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable gdm3 || true
  systemctl set-default graphical.target || true
fi

# ===== 5c) Inicio de sesión automático (GDM)
read -rp "¿Habilitar inicio de sesión automático en GDM para el usuario ${USERNAME}? [s/N]: " AUTOLOGIN
if [[ "${AUTOLOGIN:-N}" =~ ^[sS]$ ]]; then
  GDM_DAEMON_CONF="/etc/gdm3/daemon.conf"
  echo "[*] Configurando autologin en ${GDM_DAEMON_CONF}"
  cp -a "${GDM_DAEMON_CONF}"{,.bak}

  if grep -q '^\[daemon\]' "${GDM_DAEMON_CONF}"; then
    # Asegurar/ajustar claves dentro de [daemon]
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
  echo "    Nota: esto reduce la seguridad física; desactívalo editando ${GDM_DAEMON_CONF}."
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
runuser -l "$USERNAME" -c "gsettings set org.gnome.desktop.interface color-scheme '$UI_SCHEME'"
runuser -l "$USERNAME" -c "gsettings set org.gnome.desktop.interface gtk-theme '$GTK_THEME'"

# ===== 7) Kernel personalizado (redroot) + update-grub
echo
echo "== Selecciona kernel personalizado (redroot) =="
echo "1) AMD Zen3 (znver3)"
echo "2) Intel 11th Gen portátiles (tigerlake)"
echo "3) x86-64-v3 (genérico CPUs modernas)"
echo "4) x86-64 (genérico)"
read -rp "Opción [1-4] (por defecto 4): " KOPT
KOPT="${KOPT:-4}"
case "$KOPT" in
  1) KFLAV="znver3" ;;
  2) KFLAV="tigerlake" ;;
  3) KFLAV="x86-64-v3" ;;
  4|*) KFLAV="x86-64" ;;
esac
echo "[*] Instalando kernel linux-image-redroot-${KFLAV} + headers"
apt install -y "linux-image-redroot-${KFLAV}" "linux-headers-redroot-${KFLAV}"

echo "[*] Regenerando configuración de GRUB"
update-grub || true

# ===== 8) NVIDIA opcional (con update-grub posterior)
echo
read -rp "¿Instalar drivers NVIDIA (nvidia-open)? [s/N]: " NV
if [[ "${NV:-N}" =~ ^[sS]$ ]]; then
  echo "[*] Instalando keyring CUDA y nvidia-open"
  TMPDEB="$(mktemp -u /tmp/cuda-keyring_XXXX.deb)"
  wget -O "$TMPDEB" https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb
  dpkg -i "$TMPDEB" || { echo "dpkg falló. Revisa compatibilidad del keyring con trixie."; exit 1; }
  rm -f "$TMPDEB"
  apt update
  apt install -y nvidia-open
  echo "[*] Regenerando GRUB tras instalar NVIDIA"
  update-grub || true
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
    https://brave-browser-apt-release.s3.brave.com/brave-browser.sources
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
    # Variante según modo
    if [ "$UI_SCHEME" = "prefer-dark" ]; then
      APPLY_ICON_THEME="Papirus-Dark"
    else
      APPLY_ICON_THEME="Papirus" # (Papirus-Light existe; si prefieres específicamente light, usa Papirus-Light)
    fi
    ;;
  3)
    echo "[*] Instalando Tela Circle (script oficial, TODOS los colores)"
    TMPDIR="$(mktemp -d)"
    git clone --depth=1 https://github.com/vinceliuice/Tela-circle-icon-theme "$TMPDIR/Tela-circle-icon-theme"
    # Instalar todos los colores y versión "circle" en /usr/share/icons
    bash "$TMPDIR/Tela-circle-icon-theme/install.sh" -a -c -d /usr/share/icons
    rm -rf "$TMPDIR"
    echo "Colores disponibles para aplicar: standard black blue brown green grey orange pink purple red yellow manjaro ubuntu dracula nord"
    read -rp "Elige el color a aplicar (por defecto: standard): " TELA_COLOR
    TELA_COLOR="${TELA_COLOR:-standard}"
    if [ "$TELA_COLOR" = "standard" ]; then
      APPLY_ICON_THEME="Tela-circle"
    else
      APPLY_ICON_THEME="Tela-circle-${TELA_COLOR}"
    fi
    ;;
  *)
    echo "[*] Iconos por defecto de GNOME (sin cambios de tema)"
    ;;
esac

# Aplicar tema de iconos elegido (si corresponde)
if [ -n "$APPLY_ICON_THEME" ]; then
  runuser -l "$USERNAME" -c "gsettings set org.gnome.desktop.interface icon-theme '$APPLY_ICON_THEME'"
fi

# ===== 11) Segoe UI (opcional) + aplicar tipografías
echo
read -rp "¿Instalar la fuente Segoe UI (Windows 11)? [s/N]: " SEGOE
if [[ "${SEGOE:-N}" =~ ^[sS]$ ]]; then
  echo "[*] Instalando Segoe UI en el sistema"
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
    echo "  - Descargando $f"
    wget -q "${FONTS[$f]}" -O "${DEST_DIR}/$f"
    chmod 0644 "${DEST_DIR}/$f"
  done

  # Copiar a WINE si existe
  WINE_FONT_DIR="/home/${USERNAME}/.wine/drive_c/windows/Fonts"
  if [ -d "$WINE_FONT_DIR" ]; then
    echo "[*] Copiando fuentes a WINE de ${USERNAME}"
    install -d -m0755 "$WINE_FONT_DIR"
    cp -f "${DEST_DIR}/"* "$WINE_FONT_DIR"/
    chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.wine"
  fi

  echo "[*] Actualizando caché de fuentes"
  fc-cache -f "$DEST_DIR" || true

  # Ofrecer aplicar tipografías
  read -rp "¿Aplicar Segoe UI como tipografía de interfaz y títulos? (Monospace será Noto Mono 10) [s/N]: " APPLYFONT
  if [[ "${APPLYFONT:-N}" =~ ^[sS]$ ]]; then
    runuser -l "$USERNAME" -c "gsettings set org.gnome.desktop.interface font-name 'Segoe UI 11'"
    runuser -l "$USERNAME" -c "gsettings set org.gnome.desktop.interface document-font-name 'Segoe UI 11'"
    runuser -l "$USERNAME" -c "gsettings set org.gnome.desktop.interface monospace-font-name 'Noto Mono 10'"
    runuser -l "$USERNAME" -c "gsettings set org.gnome.desktop.wm.preferences titlebar-font 'Segoe UI Bold 11'"
    echo "[*] Tipografías aplicadas."
  fi
fi

# ===== 12) Opcional: Discord y/o Steam
echo
echo "== ¿Instalar Steam y/o Discord? =="
echo "1) Solo Discord"
echo "2) Solo Steam"
echo "3) Ambos"
echo "4) Ninguno (por defecto)"
read -rp "Opción [1-4] (por defecto 4): " GOPT
GOPT="${GOPT:-4}"

install_discord() {
  echo "[*] Instalando Discord"
  apt install -y discord
}

install_steam() {
  echo "[*] Instalando Steam"
  apt install -y steam-installer
}

case "$GOPT" in
  1) install_discord ;;
  2) install_steam ;;
  3) install_discord; install_steam ;;
  *) echo "[*] Omitiendo instalación de Discord/Steam" ;;
esac

echo
echo "======================================="
echo " Instalación finalizada."
echo " - Usuario en grupo sudo: ${USERNAME}"
echo " - Kernel redroot: ${KFLAV}"
echo " - GDM habilitado; target por defecto: graphical"
echo " - Modo UI: $( [ "$UI_SCHEME" = "prefer-dark" ] && echo 'Oscuro' || echo 'Claro' )"
echo " - Revisa install.log si algo falló."
echo " - Recomiendo reiniciar antes de iniciar sesión gráfica."
echo "======================================="
