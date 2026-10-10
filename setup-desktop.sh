#!/usr/bin/env bash
# KDE Plasma 6 (Debian 13) desktop setup in a "Layan Dark + dock" style:
# - Layan theme (Plasma, colors, window decorations, Kvantum) + Layan-Dark GTK
# - Papirus-Dark icons, Inconsolata Nerd Font
# - Thin top panel (menu, global menu, clock, tray) + floating dock at the bottom
# - Transparent + blurred Konsole, Starship prompt, fastfetch when a terminal opens
#
# MUST be run from inside a KDE Plasma session (not TTY/SSH), as a regular user.
# Safe to re-run: anything already installed is skipped.
set -euo pipefail

# ----------------------------- Configuration -----------------------------
# Path to your own wallpaper image (empty = use the bundled Layan wallpaper)
WALLPAPER="${WALLPAPER:-}"
ICON_THEME="${ICON_THEME:-Papirus-Dark}"
# 1 = rebuild the panels (existing panels are REMOVED). Runs automatically only the first time.
RESET_LAYOUT="${RESET_LAYOUT:-0}"
# Which screens get the panel & dock:
#   primary = main screen only (priority 1, e.g. the laptop screen)
#   all     = every connected monitor
PANEL_SCREENS="${PANEL_SCREENS:-primary}"
# 1 = show fastfetch every time a terminal opens
FASTFETCH_ON_START="${FASTFETCH_ON_START:-1}"
# Apps in the dock (skipped automatically if not installed)
DOCK_APPS=(
  org.kde.discover.desktop
  org.kde.dolphin.desktop
  firefox-esr.desktop
  org.kde.konsole.desktop
  code.desktop
  systemsettings.desktop
  dbeaver-ce.desktop
  android-studio.desktop
  org.flameshot.Flameshot.desktop
)
# -----------------------------------------------------------------------

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
skip() { printf '    \033[0;33m- skip (already installed): %s\033[0m\n' "$*"; }
ok()   { printf '    \033[0;32m+ %s\033[0m\n' "$*"; }
warn() { printf '    \033[0;31m! %s\033[0m\n' "$*"; }
has_cmd()      { command -v "$1" >/dev/null 2>&1; }
is_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

if [ "$(id -u)" -eq 0 ]; then
  echo "Run as a regular user (not root)."; exit 1
fi
if ! pgrep -x plasmashell >/dev/null || ! has_cmd kwriteconfig6; then
  echo "This script must be run from inside a KDE Plasma 6 session."; exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SRC_DIR="$HOME/.local/src/desktop-themes"
MARKER="$HOME/.config/.setup-desktop-layout-done"
mkdir -p "$SRC_DIR" "$HOME/.local/share/fonts" "$HOME/.config"

kw() { kwriteconfig6 "$@"; }

# ============================ Backup ============================
log "Backing up current KDE configuration"
BACKUP="$HOME/kde-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
( cd "$HOME/.config" && tar -czf "$BACKUP" --ignore-failed-read \
    kdeglobals kwinrc plasmarc plasmashellrc konsolerc \
    plasma-org.kde.plasma.desktop-appletsrc gtk-3.0 Kvantum 2>/dev/null ) || true
ok "saved to $BACKUP"

# ============================ apt packages ============================
log "Supporting packages"
PKGS=()
for p in git curl unzip fontconfig python3 sassc qt-style-kvantum papirus-icon-theme \
         fastfetch appmenu-gtk3-module kde-config-gtk-style; do
  if is_installed "$p"; then skip "$p"; else PKGS+=("$p"); fi
done
# starship is in the Debian 13 repo; if not, it is installed via the official script
if ! has_cmd starship && apt-cache show starship >/dev/null 2>&1; then PKGS+=(starship); fi
if [ "${#PKGS[@]}" -gt 0 ]; then
  sudo apt-get update
  sudo apt-get install -y "${PKGS[@]}"
fi
if ! has_cmd starship; then
  mkdir -p "$HOME/.local/bin"
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"
  ok "starship installed to ~/.local/bin"
fi

# ============================ Layan theme ============================
clone_or_pull() { # url dir
  if [ -d "$2/.git" ]; then git -C "$2" pull -q --ff-only || true
  else git clone -q --depth 1 "$1" "$2"; fi
}

log "Layan KDE theme"
if ls "$HOME/.local/share/plasma/look-and-feel/" 2>/dev/null | grep -qi layan; then
  skip "Layan KDE"
else
  clone_or_pull https://github.com/vinceliuice/Layan-kde.git "$SRC_DIR/Layan-kde"
  ( cd "$SRC_DIR/Layan-kde" && ./install.sh )
  ok "Layan KDE installed"
fi

log "Layan GTK theme"
if ls "$HOME/.themes" 2>/dev/null | grep -qi '^Layan-Dark'; then
  skip "Layan GTK"
else
  clone_or_pull https://github.com/vinceliuice/Layan-gtk-theme.git "$SRC_DIR/Layan-gtk-theme"
  ( cd "$SRC_DIR/Layan-gtk-theme" && ./install.sh )
  ok "Layan GTK installed"
fi

# ============================ Fonts ============================
log "Inconsolata Nerd Font"
if fc-list | grep -qi 'Inconsolata Nerd Font'; then
  skip "Inconsolata Nerd Font"
else
  curl -fL --progress-bar \
    https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Inconsolata.zip \
    -o "$TMP/Inconsolata.zip"
  mkdir -p "$HOME/.local/share/fonts/InconsolataNerd"
  unzip -oq "$TMP/Inconsolata.zip" -d "$HOME/.local/share/fonts/InconsolataNerd"
  fc-cache -f >/dev/null
  ok "font installed"
fi
TERM_FONT="Inconsolata Nerd Font Mono"

# ============================ Apply theme ============================
log "Applying global theme"
pick() { grep -i "$1" | grep -iv light | head -1 | sed -E 's/^[[:space:]*-]+//; s/[[:space:]]*\(.*$//' || true; }

LNF="$(plasma-apply-lookandfeel -l 2>/dev/null | pick layan)"
if [ -n "$LNF" ]; then plasma-apply-lookandfeel -a "$LNF" >/dev/null 2>&1 && ok "look and feel: $LNF"; fi

DTHEME="$(plasma-apply-desktoptheme --list-themes 2>/dev/null | pick layan)"
if [ -n "$DTHEME" ]; then plasma-apply-desktoptheme "$DTHEME" >/dev/null 2>&1 && ok "plasma theme: $DTHEME"; fi

COLORS="$(plasma-apply-colorscheme --list-schemes 2>/dev/null | pick layan)"
if [ -n "$COLORS" ]; then plasma-apply-colorscheme "$COLORS" >/dev/null 2>&1 && ok "colors: $COLORS"; fi

# Icons
CHANGEICONS="$(find /usr/lib* -name plasma-changeicons -type f 2>/dev/null | head -1 || true)"
if [ -n "$CHANGEICONS" ]; then "$CHANGEICONS" "$ICON_THEME" >/dev/null 2>&1 || true
else kw --file kdeglobals --group Icons --key Theme "$ICON_THEME"; fi
ok "icons: $ICON_THEME"

# Kvantum (transparency effect for Dolphin, etc.)
KV_THEME="$(find "$HOME/.config/Kvantum" -maxdepth 2 -iname '*layan*dark*.kvconfig' 2>/dev/null \
            | head -1 | xargs -r basename | sed 's/\.kvconfig$//' || true)"
[ -n "$KV_THEME" ] || KV_THEME="$(ls "$HOME/.config/Kvantum" 2>/dev/null | grep -i layan | head -1 || true)"
if [ -n "$KV_THEME" ]; then
  kvantummanager --set "$KV_THEME" >/dev/null 2>&1 || {
    mkdir -p "$HOME/.config/Kvantum"
    printf '[General]\ntheme=%s\n' "$KV_THEME" > "$HOME/.config/Kvantum/kvantum.kvconfig"; }
  kw --file kdeglobals --group KDE --key widgetStyle kvantum
  ok "Kvantum: $KV_THEME"
else
  warn "Layan Kvantum theme not found, application style unchanged"
fi

# GTK
GTK_THEME="Layan-Dark"
dbus-send --session --dest=org.kde.GtkConfig --type=method_call /GtkConfig \
  org.kde.GtkConfig.setGtkTheme "string:$GTK_THEME" 2>/dev/null || true
for v in 3.0 4.0; do
  mkdir -p "$HOME/.config/gtk-$v"
  F="$HOME/.config/gtk-$v/settings.ini"
  [ -f "$F" ] || printf '[Settings]\n' > "$F"
  if grep -q '^gtk-theme-name=' "$F"; then sed -i "s/^gtk-theme-name=.*/gtk-theme-name=$GTK_THEME/" "$F"
  else sed -i "/^\[Settings\]/a gtk-theme-name=$GTK_THEME" "$F"; fi
done
has_cmd gsettings && gsettings set org.gnome.desktop.interface gtk-theme "$GTK_THEME" 2>/dev/null || true
ok "GTK: $GTK_THEME"

# ============================ Windows (KWin) ============================
log "Window decorations & effects"
AURORAE="$(ls "$HOME/.local/share/aurorae/themes" 2>/dev/null | grep -i layan | grep -iv light | head -1 || true)"
if [ -n "$AURORAE" ]; then
  kw --file kwinrc --group org.kde.kdecoration2 --key library org.kde.kwin.aurorae
  kw --file kwinrc --group org.kde.kdecoration2 --key theme "__aurorae__svg__$AURORAE"
  ok "decoration: $AURORAE"
fi
# Close/minimize/maximize buttons on the left, as in the reference image
kw --file kwinrc --group org.kde.kdecoration2 --key ButtonsOnLeft "XIA"
kw --file kwinrc --group org.kde.kdecoration2 --key ButtonsOnRight ""
kw --file kwinrc --group Plugins --key blurEnabled true
kw --file kwinrc --group Plugins --key contrastEnabled true
kw --file kwinrc --group Effect-blur --key BlurStrength 8
dbus-send --session --dest=org.kde.KWin --type=method_call /KWin org.kde.KWin.reconfigure 2>/dev/null || true
ok "blur & window buttons on the left"

# ============================ Wallpaper ============================
log "Wallpaper"
if [ -z "$WALLPAPER" ]; then
  WALLPAPER="$(find "$HOME/.local/share/wallpapers" -ipath '*layan*' \
               \( -iname '*.jpg' -o -iname '*.png' \) 2>/dev/null | sort | tail -1 || true)"
fi
if [ -n "$WALLPAPER" ] && [ -f "$WALLPAPER" ]; then
  plasma-apply-wallpaperimage "$WALLPAPER" >/dev/null 2>&1 && ok "$WALLPAPER"
else
  warn "wallpaper not found (set WALLPAPER=/path/image.jpg)"
fi

# ============================ Panel + dock ============================
log "Top panel & bottom dock"
if [ -f "$MARKER" ] && [ "$RESET_LAYOUT" != "1" ]; then
  skip "panel layout (run with RESET_LAYOUT=1 to rebuild)"
else
  LAUNCHERS=""
  for app in "${DOCK_APPS[@]}"; do
    if [ -f "/usr/share/applications/$app" ] || [ -f "$HOME/.local/share/applications/$app" ]; then
      LAUNCHERS+="${LAUNCHERS:+,}applications:$app"
    fi
  done

  read -r -d '' JS <<JSEOF || true
panels().forEach(function (p) { p.remove(); });

var mode = "$PANEL_SCREENS";
// In Plasma 6, screen number 0 = the screen with priority 1 (primary)
var targets = [];
if (mode === "all") { for (var i = 0; i < screenCount; i++) targets.push(i); }
else { targets.push(0); }

function placeOn(panel, screen) {
  try { panel.screen = screen; } catch (e) { print("cannot set screen: " + e); }
}

targets.forEach(function (scr) {
  var topPanel = new Panel;
  placeOn(topPanel, scr);
  topPanel.location = "top";
  topPanel.height = Math.round(gridUnit * 1.8);
  try { topPanel.floating = true; } catch (e) {}
  topPanel.addWidget("org.kde.plasma.kickoff");
  topPanel.addWidget("org.kde.plasma.appmenu");
  topPanel.addWidget("org.kde.plasma.panelspacer");
  var clock = topPanel.addWidget("org.kde.plasma.digitalclock");
  clock.currentConfigGroup = ["Appearance"];
  clock.writeConfig("showDate", true);
  clock.writeConfig("dateDisplayFormat", "BesideTime");
  // One system tray is enough, on the main screen only
  if (scr === 0) topPanel.addWidget("org.kde.plasma.systemtray");

  var dock = new Panel;
  placeOn(dock, scr);
  dock.location = "bottom";
  dock.height = Math.round(gridUnit * 3.4);
  dock.alignment = "center";
  try { dock.lengthMode = "fit"; } catch (e) {}
  try { dock.floating = true; } catch (e) {}
  dock.hiding = "dodgewindows";
  var tasks = dock.addWidget("org.kde.plasma.icontasks");
  tasks.currentConfigGroup = ["General"];
  tasks.writeConfig("launchers", "$LAUNCHERS");
  tasks.writeConfig("iconSpacing", 2);
  // Only show windows that are on this monitor
  tasks.writeConfig("showOnlyCurrentScreen", mode === "all");
  dock.addWidget("org.kde.plasma.marginsseparator");
  dock.addWidget("org.kde.plasma.trash");
});
JSEOF

  if dbus-send --session --print-reply --dest=org.kde.plasmashell --type=method_call \
       /PlasmaShell org.kde.PlasmaShell.evaluateScript "string:$JS" >/dev/null; then
    touch "$MARKER"; ok "panel & dock created"
  else
    warn "failed to build the panels via Plasma scripting"
  fi
fi

# ============================ Konsole ============================
log "Konsole (transparent + blur)"
KDIR="$HOME/.local/share/konsole"
mkdir -p "$KDIR"
if [ ! -f "$KDIR/LayanNight.colorscheme" ]; then
  cat > "$KDIR/LayanNight.colorscheme" <<'CS'
[General]
Description=Layan Night
Opacity=0.82
Blur=true

[Background]
Color=33,37,51
[BackgroundIntense]
Color=40,44,60
[Foreground]
Color=214,219,229
[ForegroundIntense]
Color=255,255,255

[Color0]
Color=40,44,52
[Color0Intense]
Color=110,118,135
[Color1]
Color=232,76,61
[Color1Intense]
Color=255,110,100
[Color2]
Color=46,204,113
[Color2Intense]
Color=90,230,150
[Color3]
Color=243,156,18
[Color3Intense]
Color=255,200,80
[Color4]
Color=61,174,233
[Color4Intense]
Color=110,200,255
[Color5]
Color=155,89,182
[Color5Intense]
Color=200,140,230
[Color6]
Color=26,188,156
[Color6Intense]
Color=80,220,190
[Color7]
Color=214,219,229
[Color7Intense]
Color=255,255,255
CS
  ok "color scheme LayanNight"
else
  skip "color scheme LayanNight"
fi

cat > "$KDIR/Layan.profile" <<PROFILE
[Appearance]
ColorScheme=LayanNight
Font=$TERM_FONT,11,-1,5,400,0,0,0,0,0,0,0,0,0,0,1

[General]
Name=Layan
Parent=FALLBACK/
TerminalMargin=12
TerminalCenter=true

[Scrolling]
ScrollBarPosition=2
PROFILE
kw --file konsolerc --group "Desktop Entry" --key DefaultProfile "Layan.profile"
ok "Konsole profile 'Layan' set as default"

# ============================ Prompt & fastfetch ============================
log "Prompt Starship + fastfetch"
mkdir -p "$HOME/.config"
if [ ! -f "$HOME/.config/starship.toml" ]; then
  python3 - "$HOME/.config/starship.toml" <<'PY'
import sys
arrow = "\ue0b0"
cfg = f'''add_newline = true
format = "$username[@](white)$hostname $directory[{arrow}](fg:#3daee9)$git_branch$git_status $character"

[username]
show_always = true
style_user = "white"
format = "[$user]($style)"

[hostname]
ssh_only = false
style = "white"
format = "[$hostname]($style)"

[directory]
style = "bg:#3daee9 fg:#1b1e2b bold"
format = "[ $path ]($style)"
truncation_length = 3
home_symbol = "~"

[git_branch]
format = " [$symbol$branch]($style)"
style = "#3daee9"

[character]
success_symbol = ""
error_symbol = "[✗](red)"
format = "$symbol"
'''
open(sys.argv[1], "w").write(cfg)
PY
  ok "~/.config/starship.toml"
else
  skip "starship.toml (yours is not overwritten)"
fi

if ! grep -q '# >>> setup-desktop >>>' "$HOME/.bashrc" 2>/dev/null; then
  {
    echo ''
    echo '# >>> setup-desktop >>>'
    echo 'export PATH="$HOME/.local/bin:$PATH"'
    if [ "$FASTFETCH_ON_START" = "1" ]; then
      echo 'case $- in *i*) command -v fastfetch >/dev/null && fastfetch ;; esac'
    fi
    echo 'command -v starship >/dev/null && eval "$(starship init bash)"'
    echo '# <<< setup-desktop <<<'
  } >> "$HOME/.bashrc"
  ok "~/.bashrc updated"
else
  skip "~/.bashrc"
fi

# ============================ Done ============================
echo
echo "===================================================="
echo "Done! Log out and back in so all changes are fully applied."
echo "Backup of the old configuration: $BACKUP"
echo "  Restore: tar -xzf $BACKUP -C ~/.config  (then log out/in)"
echo "Tips:"
echo "  - Own wallpaper     : WALLPAPER=~/Pictures/koi.jpg ./setup-desktop.sh"
echo "  - Rebuild panels    : RESET_LAYOUT=1 ./setup-desktop.sh"
echo "  - Dock on all screens: RESET_LAYOUT=1 PANEL_SCREENS=all ./setup-desktop.sh"
echo "  - Configure dock   : right-click the dock > Show Panel Configuration"
echo "===================================================="
