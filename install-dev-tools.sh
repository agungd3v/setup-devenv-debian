#!/usr/bin/env bash
# Install dev tools on Debian 13 (trixie):
# Docker, VS Code, nvm + Node LTS, Python, PHP, MySQL (MariaDB), PostgreSQL, DBeaver, Android Studio, Flutter,
# Git, NetBird, Flameshot (Lightshot replacement), ngrok, Postman, Chrome, Ollama,
# NVIDIA driver (RTX 3050 hybrid)
# Safe to run repeatedly: components that are already installed are skipped.
set -euo pipefail

# ----------------------------- Configuration -----------------------------
# 1 = docker/mariadb/postgresql start automatically on boot
# 0 = do not start on boot (saves RAM), start manually: sudo systemctl start <name>
AUTOSTART_SERVICES=1
# Optional: force the Android Studio tarball URL if auto-detection fails
ANDROID_STUDIO_URL="${ANDROID_STUDIO_URL:-}"
AS_DIR="/opt/android-studio"
# Flutter SDK location (user-owned, so 'flutter upgrade' does not need sudo)
FLUTTER_DIR="$HOME/development/flutter"
# Postman (tarball, not in apt). Optional: force the download URL
POSTMAN_DIR="/opt/Postman"
POSTMAN_URL="${POSTMAN_URL:-}"
# 1 = install the proprietary NVIDIA driver (Optimus / PRIME offload), 0 = skip
INSTALL_NVIDIA="${INSTALL_NVIDIA:-1}"
# Optional: git identity (only set if not already in ~/.gitconfig)
GIT_NAME="${GIT_NAME:-}"
GIT_EMAIL="${GIT_EMAIL:-}"
# Optional: ngrok authtoken from https://dashboard.ngrok.com/get-started/your-authtoken
NGROK_AUTHTOKEN="${NGROK_AUTHTOKEN:-}"
# 1 = also create and start the minio/redis containers, 0 = only pull the images
START_DEV_CONTAINERS="${START_DEV_CONTAINERS:-1}"
# Redis: leave the password empty for no auth (dev default)
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
# MinIO: API on 9000, web console on 9001
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"
MINIO_API_PORT="${MINIO_API_PORT:-9000}"
MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"
# Ollama models land in /usr/share/ollama (on /) by default, which fills up a small
# root partition fast. Keep them on /home instead. It must NOT be inside
# /home/$USER: that is mode 0700, and the service runs as the 'ollama' user,
# which then cannot traverse into it.
OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-/home/ollama-models}"
# -----------------------------------------------------------------------

if [ "$(id -u)" -eq 0 ]; then
  echo "Run as a regular user (not root). The script calls sudo itself."
  exit 1
fi

ME="$USER"
ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
skip() { printf '    \033[0;33m- skip (already installed): %s\033[0m\n' "$*"; }
ok()   { printf '    \033[0;32m+ %s\033[0m\n' "$*"; }
warn() { printf '    \033[0;31m! %s\033[0m\n' "$*"; }

has_cmd()      { command -v "$1" >/dev/null 2>&1; }
is_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }
in_group()     { getent group "$1" | cut -d: -f4 | tr ',' '\n' | grep -qx "$ME"; }
# a host port is taken by something other than docker (e.g. MariaDB on 3306)
port_taken()   { ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }

# apt package queue: only packages that are not yet installed are added
PKGS=()
queue() {
  for p in "$@"; do
    if is_installed "$p"; then skip "$p"
    elif [[ " ${PKGS[*]} " != *" $p "* ]]; then PKGS+=("$p"); fi
  done
}
NEED_REBOOT=0

# ============================ Base packages ============================
log "Base packages"
sudo apt-get update
BASE=()
# zstd is needed by the Ollama installer (it ships .tar.zst and aborts without it)
for p in ca-certificates curl wget gnupg tar pciutils zstd; do is_installed "$p" || BASE+=("$p"); done
if [ "${#BASE[@]}" -gt 0 ]; then sudo apt-get install -y "${BASE[@]}"; else skip "base packages"; fi
sudo install -m 0755 -d /etc/apt/keyrings

REPO_ADDED=0

# ============================ Docker ============================
log "Docker"
if has_cmd docker; then
  skip "$(docker --version)"
else
  if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $CODENAME stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    REPO_ADDED=1; ok "Docker repo added"
  fi
  queue docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# ============================ VS Code ============================
log "VS Code"
if has_cmd code; then
  skip "VS Code $(code --version 2>/dev/null | head -1 || true)"
else
  if [ ! -f /etc/apt/sources.list.d/vscode.list ]; then
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor \
      | sudo tee /etc/apt/keyrings/microsoft.gpg >/dev/null
    echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
      | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
    REPO_ADDED=1; ok "VS Code repo added"
  fi
  queue code
fi

# ============================ Google Chrome ============================
log "Google Chrome"
if has_cmd google-chrome || has_cmd google-chrome-stable || is_installed google-chrome-stable; then
  # 'google-chrome --version' already prints the name, so do not prefix it again
  skip "$(google-chrome --version 2>/dev/null || echo 'Google Chrome')"
elif [ "$ARCH" != "amd64" ]; then
  warn "Google Chrome for Linux is amd64 only ($ARCH detected), skipped"
  warn "Alternative: sudo apt-get install chromium"
else
  # Same file name the google-chrome-stable package uses itself, so the
  # package takes over this entry later instead of adding a second one.
  if [ ! -f /etc/apt/sources.list.d/google-chrome.list ]; then
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor \
      | sudo tee /etc/apt/keyrings/google-chrome.gpg >/dev/null
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
      | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
    REPO_ADDED=1; ok "Google Chrome repo added"
  fi
  queue google-chrome-stable
fi

# ============================ DBeaver ============================
log "DBeaver"
if has_cmd dbeaver || is_installed dbeaver-ce; then
  skip "DBeaver"
else
  if [ ! -f /etc/apt/sources.list.d/dbeaver.list ]; then
    curl -fsSL https://dbeaver.io/debs/dbeaver.gpg.key | gpg --dearmor \
      | sudo tee /etc/apt/keyrings/dbeaver.gpg >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/dbeaver.gpg] https://dbeaver.io/debs/dbeaver-ce /" \
      | sudo tee /etc/apt/sources.list.d/dbeaver.list >/dev/null
    REPO_ADDED=1; ok "DBeaver repo added"
  fi
  queue dbeaver-ce
fi

# ============================ NetBird ============================
log "NetBird"
if has_cmd netbird; then
  skip "NetBird $(netbird version 2>/dev/null || true)"
else
  if [ ! -f /etc/apt/sources.list.d/netbird.list ]; then
    curl -fsSL https://pkgs.netbird.io/debian/public.key | gpg --dearmor \
      | sudo tee /etc/apt/keyrings/netbird.gpg >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/netbird.gpg] https://pkgs.netbird.io/debian stable main" \
      | sudo tee /etc/apt/sources.list.d/netbird.list >/dev/null
    REPO_ADDED=1; ok "NetBird repo added"
  fi
  queue netbird netbird-ui
fi

# ============================ ngrok ============================
log "ngrok"
if has_cmd ngrok; then
  skip "$(ngrok version 2>/dev/null || echo ngrok)"
else
  if [ ! -f /etc/apt/sources.list.d/ngrok.list ]; then
    curl -fsSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
      | sudo tee /etc/apt/keyrings/ngrok.asc >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/ngrok.asc] https://ngrok-agent.s3.amazonaws.com bookworm main" \
      | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null
    REPO_ADDED=1; ok "ngrok repo added"
  fi
  queue ngrok
fi

# ============================ NVIDIA driver ============================
log "NVIDIA driver (INSTALL_NVIDIA=$INSTALL_NVIDIA)"
if [ "$INSTALL_NVIDIA" -ne 1 ]; then
  skip "disabled via configuration"
elif ! lspci | grep -qi 'nvidia'; then
  warn "NVIDIA GPU not detected, skipping this section"
  INSTALL_NVIDIA=0
elif is_installed nvidia-driver; then
  skip "nvidia-driver"
else
  # The NVIDIA driver lives in contrib/non-free: enable them if not already
  if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    SRC=/etc/apt/sources.list.d/debian.sources
    if grep -E '^Components:' "$SRC" | grep -qvE 'contrib' || \
       grep -E '^Components:' "$SRC" | grep -qvE 'non-free( |$)'; then
      sudo cp "$SRC" "$SRC.bak"
      sudo sed -i -E '/^Components:/{/contrib/!s/$/ contrib/;/non-free( |$)/!s/$/ non-free/;/non-free-firmware/!s/$/ non-free-firmware/}' "$SRC"
      REPO_ADDED=1; ok "contrib non-free enabled in $SRC (backup: .bak)"
    fi
  fi
  if [ -f /etc/apt/sources.list ] && grep -qE '^deb(-src)?\s.*debian\.org' /etc/apt/sources.list; then
    SRC=/etc/apt/sources.list
    PAT='^deb(-src)?\s.*debian\.org'
    if grep -E "$PAT" "$SRC" | grep -qvE 'contrib' || grep -E "$PAT" "$SRC" | grep -qvE 'non-free( |$)'; then
      sudo cp "$SRC" "$SRC.bak"
      sudo sed -i -E "/$PAT/{/contrib/!s/\$/ contrib/;/non-free( |\$)/!s/\$/ non-free/;/non-free-firmware/!s/\$/ non-free-firmware/}" "$SRC"
      REPO_ADDED=1; ok "contrib non-free enabled in $SRC (backup: .bak)"
    fi
  fi
  queue linux-headers-amd64 nvidia-driver nvidia-settings firmware-misc-nonfree \
        switcheroo-control mokutil
  NEED_REBOOT=1
fi

# ============================ Languages & databases ============================
log "Git"
queue git

log "Flameshot (Lightshot is not available for Linux)"
queue flameshot

log "Python"
queue python3 python3-pip python3-venv python3-dev pipx

log "PHP + Composer"
queue php php-cli php-fpm php-mysql php-pgsql php-curl php-mbstring php-xml php-zip \
      php-gd php-intl php-bcmath composer

log "MariaDB (MySQL)"
queue default-mysql-server default-mysql-client

log "PostgreSQL"
queue postgresql postgresql-contrib

log "Flutter dependencies (including Linux desktop app builds)"
queue git unzip xz-utils zip libglu1-mesa \
      clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev

# ============================ Install apt packages ============================
log "Install apt packages"
if [ "${#PKGS[@]}" -gt 0 ]; then
  [ "$REPO_ADDED" -eq 1 ] && sudo apt-get update
  echo "    Will install: ${PKGS[*]}"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}"
else
  skip "all apt packages already installed"
fi

# ============================ Service ============================
log "Service (AUTOSTART_SERVICES=$AUTOSTART_SERVICES)"
for svc in docker mariadb postgresql; do
  if ! systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null | grep -q .; then
    continue
  fi
  if [ "$AUTOSTART_SERVICES" -eq 1 ]; then
    if systemctl is-enabled --quiet "$svc" && systemctl is-active --quiet "$svc"; then
      skip "$svc already active"
    else
      sudo systemctl enable --now "$svc"; ok "$svc enabled"
    fi
  else
    if systemctl is-enabled --quiet "$svc"; then
      sudo systemctl disable "$svc" >/dev/null 2>&1; ok "$svc no longer starts on boot"
    else
      skip "$svc already disabled on boot"
    fi
  fi
done

# ============================ Database credentials ============================
log "Set database user & password (dev only)"
if has_cmd mysql && systemctl is-active --quiet mariadb; then
  if mysql -uroot -proot -e "SELECT 1" >/dev/null 2>&1; then
    skip "MySQL root already uses password 'root'"
  else
    sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'root'; FLUSH PRIVILEGES;" \
      && ok "MySQL: root / root" || warn "failed to set MySQL password"
  fi
else
  skip "MariaDB is not active, MySQL password unchanged"
fi
if has_cmd psql && systemctl is-active --quiet postgresql; then
  if PGPASSWORD=postgres psql -h 127.0.0.1 -U postgres -tAc "SELECT 1" >/dev/null 2>&1; then
    skip "PostgreSQL postgres already uses password 'postgres'"
  else
    sudo -u postgres psql -qc "ALTER USER postgres WITH PASSWORD 'postgres';" \
      && ok "PostgreSQL: postgres / postgres" || warn "failed to set PostgreSQL password"
  fi
else
  skip "PostgreSQL is not active, PostgreSQL password unchanged"
fi

if getent group docker >/dev/null; then
  if in_group docker; then skip "$ME already in docker group"
  else sudo usermod -aG docker "$ME"; ok "$ME added to docker group"; fi
fi

# ============================ Docker images ============================
log "Docker images (minio, redis)"
# Only if docker already works without sudo (the docker group takes effect after re-login)
if has_cmd docker && docker info >/dev/null 2>&1; then
  for img in cgr.dev/chainguard/minio "$REDIS_IMAGE"; do
    if docker image inspect "$img" >/dev/null 2>&1; then
      skip "image $img"
    else
      docker pull "$img" && ok "image $img pulled" || warn "failed to pull $img"
    fi
  done
else
  skip "docker is not usable without sudo yet (log in again and re-run the script), skipping image pull"
fi

# ============================ Docker containers ============================
# 'docker pull' only downloads the image, it does not create a container.
# This section creates them (named volume for the data, restart unless-stopped).
log "Docker containers (START_DEV_CONTAINERS=$START_DEV_CONTAINERS)"
if [ "$START_DEV_CONTAINERS" -ne 1 ]; then
  skip "START_DEV_CONTAINERS=0, no containers created"
elif ! has_cmd docker || ! docker info >/dev/null 2>&1; then
  skip "docker is not usable without sudo yet (log in again and re-run the script)"
else
  # $1 = container name, rest = arguments for 'docker run'. Already existing = start only.
  ensure_container() {
    local name="$1"; shift
    if docker container inspect "$name" >/dev/null 2>&1; then
      if [ "$(docker container inspect -f '{{.State.Running}}' "$name")" = "true" ]; then
        skip "container $name already running"
      else
        docker start "$name" >/dev/null && ok "container $name started" \
          || warn "container $name exists but failed to start (docker logs $name)"
      fi
    else
      docker run -d --name "$name" --restart unless-stopped "$@" >/dev/null \
        && ok "container $name created" || warn "failed to create container $name"
    fi
  }

  # ---- MinIO ----
  if docker container inspect minio >/dev/null 2>&1 || ! port_taken "$MINIO_API_PORT"; then
    ensure_container minio \
      -p "$MINIO_API_PORT:9000" -p "$MINIO_CONSOLE_PORT:9001" \
      -e "MINIO_ROOT_USER=$MINIO_ROOT_USER" \
      -e "MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD" \
      -v minio-data:/data \
      cgr.dev/chainguard/minio server /data --console-address ":9001"
  else
    warn "port $MINIO_API_PORT is already in use, minio skipped (set MINIO_API_PORT=<other port>)"
  fi

  # ---- Redis ----
  if docker container inspect redis >/dev/null 2>&1 || ! port_taken "$REDIS_PORT"; then
    # appendonly = the data survives a container restart
    REDIS_ARGS=(redis-server --appendonly yes)
    if [ -n "$REDIS_PASSWORD" ]; then REDIS_ARGS+=(--requirepass "$REDIS_PASSWORD"); fi
    ensure_container redis \
      -p "$REDIS_PORT:6379" \
      -v redis-data:/data \
      "$REDIS_IMAGE" "${REDIS_ARGS[@]}"
  else
    warn "port $REDIS_PORT is already in use, redis skipped (set REDIS_PORT=<other port>)"
  fi
fi

# ============================ NVIDIA configuration (hybrid) ============================
if [ "$INSTALL_NVIDIA" -eq 1 ] && is_installed nvidia-driver; then
  log "NVIDIA configuration hybrid"
  # DRM modeset is required for KDE Plasma Wayland + PRIME offload
  MODCONF=/etc/modprobe.d/nvidia-drm-modeset.conf
  if [ -f "$MODCONF" ]; then
    skip "nvidia-drm modeset"
  else
    echo "options nvidia-drm modeset=1" | sudo tee "$MODCONF" >/dev/null
    sudo update-initramfs -u
    ok "nvidia-drm modeset=1 enabled"; NEED_REBOOT=1
  fi

  # 'prime-run <application>' runs an application on the RTX 3050
  if [ -x /usr/local/bin/prime-run ]; then
    skip "prime-run"
  else
    sudo tee /usr/local/bin/prime-run >/dev/null <<'PRIME'
#!/bin/sh
# Run an application using the NVIDIA GPU (PRIME render offload)
export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export __VK_LAYER_NV_optimus=NVIDIA_only
export VK_LOADER_DRIVERS_SELECT='nvidia*'
exec "$@"
PRIME
    sudo chmod +x /usr/local/bin/prime-run
    ok "'prime-run' command created"
  fi

  if systemctl list-unit-files switcheroo-control.service --no-legend 2>/dev/null | grep -q .; then
    systemctl is-enabled --quiet switcheroo-control || sudo systemctl enable --now switcheroo-control
  fi

  if has_cmd mokutil && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    warn "Secure Boot is ENABLED: the NVIDIA module must be signed to load."
    warn "Run: sudo mokutil --import /var/lib/dkms/mok.pub  (set a password),"
    warn "then reboot and choose 'Enroll MOK' on the blue screen. Or disable Secure Boot in the BIOS."
  fi
fi

# ============================ NetBird service ============================
if has_cmd netbird; then
  log "NetBird service"
  if systemctl list-unit-files netbird.service --no-legend 2>/dev/null | grep -q .; then
    skip "service netbird"
  else
    sudo netbird service install && sudo netbird service start && ok "netbird service installed"
  fi
fi

# ============================ Git config ============================
log "Git configuration"
if [ -n "$(git config --global user.name 2>/dev/null || true)" ]; then
  skip "git user.name = $(git config --global user.name)"
elif [ -n "$GIT_NAME" ]; then
  git config --global user.name "$GIT_NAME"; ok "git user.name set"
else
  warn "user.name is not set (set GIT_NAME or run: git config --global user.name \"Name\")"
fi
if [ -n "$(git config --global user.email 2>/dev/null || true)" ]; then
  skip "git user.email = $(git config --global user.email)"
elif [ -n "$GIT_EMAIL" ]; then
  git config --global user.email "$GIT_EMAIL"; ok "git user.email set"
else
  warn "user.email is not set (set GIT_EMAIL or run: git config --global user.email \"email\")"
fi
[ -n "$(git config --global init.defaultBranch 2>/dev/null || true)" ] || git config --global init.defaultBranch main

# ============================ ngrok authtoken ============================
if has_cmd ngrok; then
  log "ngrok authtoken"
  if [ -f "$HOME/.config/ngrok/ngrok.yml" ] && grep -q 'authtoken' "$HOME/.config/ngrok/ngrok.yml"; then
    skip "authtoken already saved"
  elif [ -n "$NGROK_AUTHTOKEN" ]; then
    ngrok config add-authtoken "$NGROK_AUTHTOKEN" && ok "authtoken saved"
  else
    warn "no authtoken yet (set NGROK_AUTHTOKEN or run: ngrok config add-authtoken <token>)"
  fi
fi

# ============================ nvm + Node LTS ============================
log "nvm + Node.js LTS (without sudo)"
export NVM_DIR="$HOME/.nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  skip "nvm"
else
  NVM_VER="$(curl -fsSL https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')"
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VER}/install.sh" | bash
  ok "nvm $NVM_VER installed"
fi

# nvm is not compatible with 'set -eu', so turn it off temporarily
set +eu +o pipefail
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
if [ "$(nvm version default 2>/dev/null)" != "N/A" ] && [ -n "$(nvm version default 2>/dev/null)" ]; then
  skip "Node $(nvm version default) (default)"
else
  nvm install --lts
  nvm alias default 'lts/*'
fi
set -euo pipefail

# ============================ Android Studio ============================
log "Android Studio"
if [ -x "$AS_DIR/bin/studio" ] || [ -x "$AS_DIR/bin/studio.sh" ] || has_cmd android-studio; then
  skip "Android Studio ($AS_DIR)"
else
  if [ -z "$ANDROID_STUDIO_URL" ]; then
    ANDROID_STUDIO_URL="$(curl -fsSL https://developer.android.com/studio \
      | grep -oP 'https://[^"'\'' ]*android-studio-[^"'\'' ]*-linux\.tar\.gz' | head -1 || true)"
  fi

  if [ -z "$ANDROID_STUDIO_URL" ]; then
    warn "Failed to auto-detect the Android Studio download link."
    warn "Re-run with: ANDROID_STUDIO_URL='<.tar.gz link>' $0"
  else
    echo "    Downloading: $ANDROID_STUDIO_URL"
    curl -fL --progress-bar "$ANDROID_STUDIO_URL" -o "$TMP/android-studio.tar.gz"
    sudo tar -xzf "$TMP/android-studio.tar.gz" -C /opt
    ok "extracted to $AS_DIR"

    LAUNCHER="$AS_DIR/bin/studio"
    [ -x "$LAUNCHER" ] || LAUNCHER="$AS_DIR/bin/studio.sh"
    ICON="$AS_DIR/bin/studio.svg"
    [ -f "$ICON" ] || ICON="$AS_DIR/bin/studio.png"

    sudo ln -sf "$LAUNCHER" /usr/local/bin/android-studio
    sudo tee /usr/share/applications/android-studio.desktop >/dev/null <<DESKTOP
[Desktop Entry]
Version=1.0
Type=Application
Name=Android Studio
Comment=Android IDE
Exec="$LAUNCHER" %f
Icon=$ICON
Categories=Development;IDE;
Terminal=false
StartupWMClass=jetbrains-studio
StartupNotify=true
DESKTOP
    ok "menu shortcut & 'android-studio' command created"
  fi
fi

# KVM access so the Android emulator is fast
if getent group kvm >/dev/null; then
  if in_group kvm; then skip "$ME already in kvm group"
  else sudo usermod -aG kvm "$ME"; ok "$ME added to kvm group (emulator)"; fi
fi

# Android SDK environment variables (the SDK is downloaded via the Android Studio setup wizard)
if grep -q 'ANDROID_HOME' "$HOME/.profile" 2>/dev/null; then
  skip "ANDROID_HOME di ~/.profile"
else
  cat >> "$HOME/.profile" <<'PROFILE'

# Android SDK
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin"
PROFILE
  ok "ANDROID_HOME added to ~/.profile"
fi

# ============================ Flutter ============================
log "Flutter (channel stable)"
if [ -x "$FLUTTER_DIR/bin/flutter" ] || has_cmd flutter; then
  skip "Flutter ($( [ -x "$FLUTTER_DIR/bin/flutter" ] && echo "$FLUTTER_DIR" || command -v flutter ))"
else
  mkdir -p "$(dirname "$FLUTTER_DIR")"
  git clone https://github.com/flutter/flutter.git -b stable "$FLUTTER_DIR"
  ok "Flutter cloned to $FLUTTER_DIR"
  # Download the Dart SDK & bundled tools once up front
  "$FLUTTER_DIR/bin/flutter" --version
  ok "Flutter ready"
fi

if grep -q 'development/flutter/bin' "$HOME/.profile" 2>/dev/null; then
  skip "Flutter PATH in ~/.profile"
else
  cat >> "$HOME/.profile" <<'PROFILE'

# Flutter
export PATH="$HOME/development/flutter/bin:$PATH"
PROFILE
  ok "Flutter PATH added to ~/.profile"
fi

# ============================ Postman ============================
log "Postman"
if [ -x "$POSTMAN_DIR/Postman" ] || has_cmd postman; then
  skip "Postman ($( [ -x "$POSTMAN_DIR/Postman" ] && echo "$POSTMAN_DIR" || command -v postman ))"
else
  if [ -z "$POSTMAN_URL" ]; then
    case "$ARCH" in
      amd64) POSTMAN_URL="https://dl.pstmn.io/download/latest/linux_64" ;;
      arm64) POSTMAN_URL="https://dl.pstmn.io/download/latest/linux_arm64" ;;
      *)     POSTMAN_URL="" ;;
    esac
  fi

  if [ -z "$POSTMAN_URL" ]; then
    warn "Postman provides no build for $ARCH, skipped"
    warn "Re-run with: POSTMAN_URL='<.tar.gz link>' $0"
  else
    echo "    Downloading: $POSTMAN_URL"
    if curl -fL --progress-bar "$POSTMAN_URL" -o "$TMP/postman.tar.gz"; then
      # the tarball contains a top-level Postman/ directory
      sudo tar -xzf "$TMP/postman.tar.gz" -C /opt
      ok "extracted to $POSTMAN_DIR"

      sudo ln -sf "$POSTMAN_DIR/Postman" /usr/local/bin/postman
      sudo tee /usr/share/applications/postman.desktop >/dev/null <<DESKTOP
[Desktop Entry]
Version=1.0
Type=Application
Name=Postman
Comment=API development and testing
Exec=$POSTMAN_DIR/Postman %U
Icon=$POSTMAN_DIR/app/resources/app/assets/icon.png
Categories=Development;WebDevelopment;
Terminal=false
StartupWMClass=Postman
StartupNotify=true
DESKTOP
      ok "menu shortcut & 'postman' command created"
    else
      warn "failed to download Postman"
    fi
  fi
fi

# ============================ Go ============================
log "Go"
if [ -x /usr/local/go/bin/go ] || has_cmd go; then
  skip "Go ($( [ -x /usr/local/go/bin/go ] && /usr/local/go/bin/go version || go version ))"
else
  GO_VER="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)"
  GO_ARCH="$ARCH"; [ "$ARCH" = "armhf" ] && GO_ARCH="armv6l"
  curl -fsSL "https://go.dev/dl/${GO_VER}.linux-${GO_ARCH}.tar.gz" -o "/tmp/${GO_VER}.tar.gz"
  sudo tar -C /usr/local -xzf "/tmp/${GO_VER}.tar.gz"
  rm -f "/tmp/${GO_VER}.tar.gz"
  ok "$GO_VER installed in /usr/local/go"
fi

if grep -q '/usr/local/go/bin' "$HOME/.profile" 2>/dev/null; then
  skip "Go PATH in ~/.profile"
else
  cat >> "$HOME/.profile" <<'PROFILE'

# Go
export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"
PROFILE
  ok "Go PATH added to ~/.profile"
fi

# ============================ Ollama ============================
log "Ollama"
if has_cmd ollama; then
  skip "Ollama $(ollama --version 2>/dev/null | grep -oP 'version is \K.*' || true)"
else
  # The official installer puts the binary in /usr/local/bin, creates the 'ollama'
  # system user and installs ollama.service. With an NVIDIA driver already present
  # it detects nvidia-smi and exits without touching the CUDA driver.
  curl -fsSL https://ollama.com/install.sh | sh && ok "Ollama installed" || warn "failed to install Ollama"
fi

# The installer enables the service itself, so honour AUTOSTART_SERVICES here too
if systemctl list-unit-files ollama.service --no-legend 2>/dev/null | grep -q .; then
  if [ "$AUTOSTART_SERVICES" -eq 1 ]; then
    if systemctl is-enabled --quiet ollama && systemctl is-active --quiet ollama; then
      skip "ollama already active"
    else
      sudo systemctl enable --now ollama; ok "ollama enabled"
    fi
  else
    if systemctl is-enabled --quiet ollama; then
      sudo systemctl disable ollama >/dev/null 2>&1; ok "ollama no longer starts on boot"
    else
      skip "ollama already disabled on boot"
    fi
  fi
fi

# Point the model store at $OLLAMA_MODELS_DIR via a drop-in, so an Ollama
# upgrade (which rewrites ollama.service) does not lose the setting.
if getent passwd ollama >/dev/null \
   && systemctl list-unit-files ollama.service --no-legend 2>/dev/null | grep -q .; then
  OLLAMA_OVERRIDE=/etc/systemd/system/ollama.service.d/override.conf
  if grep -qs "OLLAMA_MODELS=$OLLAMA_MODELS_DIR" "$OLLAMA_OVERRIDE"; then
    skip "ollama models dir ($OLLAMA_MODELS_DIR)"
  else
    sudo install -o ollama -g ollama -m 0755 -d "$OLLAMA_MODELS_DIR"
    sudo install -m 0755 -d /etc/systemd/system/ollama.service.d
    sudo tee "$OLLAMA_OVERRIDE" >/dev/null <<CONF
[Service]
Environment="OLLAMA_MODELS=$OLLAMA_MODELS_DIR"
CONF
    sudo systemctl daemon-reload
    if systemctl is-active --quiet ollama; then sudo systemctl restart ollama; fi
    ok "ollama models dir -> $OLLAMA_MODELS_DIR"
  fi
fi

# ============================ Summary ============================
set +e
echo
echo "================ Installed versions ================"
has_cmd git      && git --version
has_cmd docker   && docker --version
has_cmd code     && echo "VS Code $(code --version | head -1)"
has_cmd google-chrome && google-chrome --version
echo "nvm $(nvm --version) | node $(node -v) | npm $(npm -v)"
has_cmd python3  && python3 --version
has_cmd php      && php --version | head -1
has_cmd composer && composer --version 2>/dev/null | head -1
has_cmd mysql    && mysql --version
has_cmd psql     && psql --version
is_installed dbeaver-ce && dpkg -s dbeaver-ce | grep '^Version' | sed 's/^/dbeaver-ce /'
[ -f "$AS_DIR/product-info.json" ] && \
  echo "Android Studio $(grep -oP '"version":\s*"\K[^"]+' "$AS_DIR/product-info.json" | head -1)"
[ -x "$FLUTTER_DIR/bin/flutter" ] && "$FLUTTER_DIR/bin/flutter" --version 2>/dev/null | head -1
[ -x /usr/local/go/bin/go ] && /usr/local/go/bin/go version
has_cmd netbird   && echo "NetBird $(netbird version 2>/dev/null)"
has_cmd ngrok     && ngrok version
has_cmd flameshot && flameshot --version 2>/dev/null | head -1
has_cmd ollama    && ollama --version 2>/dev/null | head -1
[ -f "$POSTMAN_DIR/app/resources/app/package.json" ] && \
  echo "Postman $(grep -oP '"version":\s*"\K[^"]+' "$POSTMAN_DIR/app/resources/app/package.json" | head -1)"
is_installed nvidia-driver && dpkg -s nvidia-driver | grep '^Version' | sed 's/^/nvidia-driver /'
has_cmd nvidia-smi && nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null
if has_cmd docker && docker info >/dev/null 2>&1; then
  CONTAINERS="$(docker ps -a --filter name=minio --filter name=redis \
    --format '  {{.Names}}: {{.Status}} ({{.Ports}})' 2>/dev/null)"
  [ -n "$CONTAINERS" ] && { echo "Docker containers:"; echo "$CONTAINERS"; }
fi
echo "================================================="
echo "Done. Log out and back in (or reboot) so that:"
echo "  - 'docker' works without sudo"
echo "  - the Android emulator can use KVM"
echo "  - ANDROID_HOME is picked up"
echo "  - the Flutter PATH is picked up"
echo
[ "$NEED_REBOOT" -eq 1 ] && echo ">>> REBOOT required to activate the NVIDIA driver. Check with: nvidia-smi"
echo
echo "Next steps:"
echo "  1. Open Android Studio and finish the setup wizard (downloads the SDK)."
echo "  2. Di SDK Manager > SDK Tools, tick 'Android SDK Command-line Tools'."
echo "  3. Di Settings > Plugins, install the Flutter plugin (Dart comes with it)."
echo "  4. Run: flutter doctor --android-licenses   then   flutter doctor"
echo "  5. NetBird: sudo netbird up   (or open 'NetBird' from the menu)"
echo "  6. Flameshot: bind the PrintScreen key in System Settings > Shortcuts"
echo "     to the command: flameshot gui"
echo "  7. Use the RTX 3050: prime-run <application>, or right-click an app in the KDE menu"
echo "     > 'Run using dedicated graphics card'"
echo "  8. MinIO console: http://localhost:$MINIO_CONSOLE_PORT ($MINIO_ROOT_USER / $MINIO_ROOT_PASSWORD)"
echo "  9. Redis: redis-cli -h 127.0.0.1 -p $REDIS_PORT   (or: docker exec -it redis redis-cli)"
echo " 10. Ollama models are stored in $OLLAMA_MODELS_DIR (not on /)."
echo "     It ships without models. Pull one first, e.g.: ollama pull llama3.2"
echo "     then: ollama run llama3.2   | API: http://localhost:11434"
