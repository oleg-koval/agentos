#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---status}"
USER_NAME="${AGENTOS_USER:-$USER}"
AUTOLOGIN_CONF="/etc/plasmalogin.conf.d/20-agentos-autologin.conf"
KRDP_SERVICE="app-org.kde.krdpserver.service"
PORTAL_SERVICE="plasma-xdg-desktop-portal-kde.service"
KRDP_DATA_DIR="$HOME/.local/share/krdpserver"
KRDP_CERT="$KRDP_DATA_DIR/krdp.crt"
KRDP_KEY="$KRDP_DATA_DIR/krdp.key"
KRDP_OVERRIDE_DIR="$HOME/.config/systemd/user/${KRDP_SERVICE}.d"
KRDP_OVERRIDE="$KRDP_OVERRIDE_DIR/override.conf"

usage() {
  cat <<'EOF'
Usage: agentos-remote-desktop [--enable|--disable|--status]

--enable   Configure unattended Plasma Wayland login and KRDP sharing.
--disable  Remove AgentOS autologin and disable KRDP user service.
--status   Show current remote desktop state.

RDP authentication uses the Linux account in KRDP system-user mode. No RDP
password is stored by AgentOS.
EOF
}

case "$MODE" in
  --enable|--disable|--status) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

session_name() {
  if [[ -f /usr/share/wayland-sessions/plasma.desktop ]]; then
    echo plasma.desktop
  elif [[ -f /usr/share/wayland-sessions/plasmawayland.desktop ]]; then
    echo plasmawayland.desktop
  else
    return 1
  fi
}

status() {
  printf 'KRDP package: '
  command -v krdpserver >/dev/null 2>&1 && echo installed || echo missing
  printf 'KDE portal package: '
  pacman -Q xdg-desktop-portal-kde >/dev/null 2>&1 && echo installed || echo missing
  printf 'KDE portal service: '
  systemctl --user is-active "$PORTAL_SERVICE" 2>/dev/null || echo inactive
  printf 'Plasma Wayland session: '
  session_name 2>/dev/null || echo missing
  printf 'Plasma autologin: '
  if sudo test -f "$AUTOLOGIN_CONF" 2>/dev/null; then
    sudo awk -F= '/^User=/{u=$2} /^Session=/{s=$2} END{if(u) printf "%s (%s)\n",u,s; else print "configured"}' "$AUTOLOGIN_CONF"
  else
    echo disabled
  fi
  printf 'KRDP TLS certificate: '
  if [[ -s "$KRDP_CERT" && -s "$KRDP_KEY" ]]; then echo configured; else echo missing; fi
  printf 'KRDP capture mode: '
  if grep -Fq -- '--virtual-monitor 1920x1080@1' "$KRDP_OVERRIDE" 2>/dev/null; then
    if grep -Fq -- '--plasma' "$KRDP_OVERRIDE" 2>/dev/null; then echo 'plasma virtual-monitor (input-buggy)'; else echo 'virtual-monitor'; fi
  else
    echo 'default/portal'
  fi
  printf 'KRDP user service: '
  systemctl --user is-enabled "$KRDP_SERVICE" 2>/dev/null || echo disabled
  printf 'KRDP running: '
  systemctl --user is-active "$KRDP_SERVICE" 2>/dev/null || echo inactive
  printf 'System-user auth: '
  if grep -q '^SystemUserEnabled=true$' "$HOME/.config/krdpserverrc" 2>/dev/null; then echo enabled; else echo unknown-or-disabled; fi
  if command -v tailscale >/dev/null 2>&1; then
    printf 'Tailscale IPv4: '
    tailscale ip -4 2>/dev/null | head -n1 || true
  fi
}

if [[ "$MODE" == --status ]]; then
  status
  exit 0
fi

if [[ "$MODE" == --disable ]]; then
  systemctl --user disable --now "$KRDP_SERVICE" >/dev/null 2>&1 || true
  sudo rm -f "$AUTOLOGIN_CONF"
  rm -f "$HOME/.config/autostart-scripts/agentos-lock-after-login.sh"
  rm -rf "$KRDP_OVERRIDE_DIR"
  systemctl --user daemon-reload
  echo 'AgentOS unattended remote desktop disabled.'
  exit 0
fi

command -v krdpserver >/dev/null 2>&1 || {
  echo 'KRDP is not installed. Run sync-workstation first.' >&2
  exit 1
}
command -v kwriteconfig6 >/dev/null 2>&1 || {
  echo 'kwriteconfig6 not found. Plasma is not fully installed.' >&2
  exit 1
}
command -v openssl >/dev/null 2>&1 || {
  echo 'openssl is required to provision KRDP TLS.' >&2
  exit 1
}
pacman -Q xdg-desktop-portal-kde >/dev/null 2>&1 || {
  echo 'xdg-desktop-portal-kde is required for Plasma/KRDP screen sharing. Run sync-workstation first.' >&2
  exit 1
}
SESSION="$(session_name)" || {
  echo 'No Plasma Wayland session file found.' >&2
  exit 1
}

sudo install -d -m 755 /etc/plasmalogin.conf.d
sudo tee "$AUTOLOGIN_CONF" >/dev/null <<EOF
[Autologin]
User=$USER_NAME
Session=$SESSION
EOF
sudo chmod 644 "$AUTOLOGIN_CONF"
sudo systemctl set-default graphical.target
sudo systemctl enable plasmalogin.service >/dev/null

install -d -m 700 "$KRDP_DATA_DIR"
if [[ ! -s "$KRDP_CERT" || ! -s "$KRDP_KEY" ]]; then
  rm -f "$KRDP_CERT" "$KRDP_KEY"
  openssl req -nodes -new -x509 -newkey rsa:2048 \
    -keyout "$KRDP_KEY" \
    -out "$KRDP_CERT" \
    -days 825 \
    -subj "/CN=agentos-${HOSTNAME:-remote}" \
    >/dev/null 2>&1
fi
chmod 600 "$KRDP_KEY"
chmod 644 "$KRDP_CERT"
kwriteconfig6 --file krdpserverrc --group General --key Certificate "$KRDP_CERT"
kwriteconfig6 --file krdpserverrc --group General --key CertificateKey "$KRDP_KEY"
kwriteconfig6 --file krdpserverrc --group General --key SystemUserEnabled true
kwriteconfig6 --file krdpserverrc --group General --key MonitorMode workspace

if command -v flatpak >/dev/null 2>&1; then
  flatpak permission-set kde-authorized remote-desktop org.kde.krdpserver yes >/dev/null 2>&1 || true
fi

# KRDP 6.7 has an input regression when --plasma is combined with a virtual
# monitor: pointer motion works but clicks, wheel and keyboard do not. Running
# the virtual monitor without --plasma preserves full RDP input while still
# providing a deterministic headless canvas. Also make portal ordering explicit:
# the stock unit has the same dependency, but keeping it in the override prevents
# local packaging/service changes from starting KRDP before Plasma's portal.
mkdir -p "$KRDP_OVERRIDE_DIR"
cat > "$KRDP_OVERRIDE" <<EOF
[Unit]
After=$PORTAL_SERVICE plasma-core.target
Wants=$PORTAL_SERVICE

[Service]
NoNewPrivileges=false
ExecStart=
ExecStart=/usr/bin/krdpserver --virtual-monitor 1920x1080@1
EOF

# Older revisions locked the autologin session eight seconds after startup.
# That races KRDP/portal initialization and is unnecessary for the dedicated
# virtual-monitor workstation. Remove it during convergence.
rm -f "$HOME/.config/autostart-scripts/agentos-lock-after-login.sh"

systemctl --user daemon-reload
# The KDE portal is DBus/static-activated, so start it explicitly before KRDP
# when provisioning or repairing remote desktop.
systemctl --user start "$PORTAL_SERVICE" >/dev/null 2>&1 || true
systemctl --user enable "$KRDP_SERVICE" >/dev/null
systemctl --user reset-failed "$KRDP_SERVICE" >/dev/null 2>&1 || true
systemctl --user restart "$KRDP_SERVICE" >/dev/null 2>&1 || true

echo 'AgentOS unattended remote desktop enabled.'
echo "Boot flow: TPM unlock -> Plasma autologin -> KDE portal -> KRDP virtual monitor -> AgentOS Home."
echo 'Connect to the Tailscale IP on RDP port 3389 with your Linux username/password.'
status
