#!/bin/sh
# Installs kivi for the current user. Safe to run again; never uses sudo itself.
set -e
cd "$(dirname "$0")"
REPO=$PWD
PY=/usr/bin/python3
# the right package names and install command for this distro (apt, dnf or pacman)
install_cmd() { $PY -c 'import sys; from kivi import desktop; print(desktop.install_cmd(*sys.argv[1:]))' "$@"; }

wayland=""
[ -n "$WAYLAND_DISPLAY" ] && wayland=1

needs=""
$PY -c "import evdev" 2>/dev/null || needs="$needs evdev"
$PY -c "import gi; gi.require_version('Gtk', '4.0'); from gi.repository import Gtk" 2>/dev/null || needs="$needs gtk4"
$PY -c "import gi; gi.require_version('Adw', '1'); from gi.repository import Adw" 2>/dev/null || needs="$needs adwaita"
# on X11 kivi pastes through xclip; wl-clipboard can't reach an X11 clipboard
[ -z "$wayland" ] && ! command -v xclip >/dev/null 2>&1 && needs="$needs xclip"
if [ -n "$needs" ]; then
  echo "kivi needs a few packages first:"
  echo "  $(install_cmd $needs)"
  echo "then run ./install.sh again."
  exit 1
fi

mkdir -p ~/.local/bin ~/.config/systemd/user ~/.config/autostart \
  ~/.local/share/icons/hicolor/scalable/apps ~/.local/share/applications ~/.local/share/kivi
mkdir -p -m 700 ~/.config/kivi

chmod +x bin/kivi
ln -sfn "$REPO/bin/kivi" ~/.local/bin/kivi

install -m 644 data/kivi.svg ~/.local/share/icons/hicolor/scalable/apps/kivi.svg
# PNG sizes too: some menus and notification servers skip scalable SVGs
if command -v rsvg-convert >/dev/null; then
  for s in 16 22 24 32 48 64 128 256 512; do
    mkdir -p ~/.local/share/icons/hicolor/${s}x${s}/apps
    rsvg-convert -w $s -h $s data/kivi.svg -o ~/.local/share/icons/hicolor/${s}x${s}/apps/kivi.png
  done
fi
touch ~/.local/share/icons/hicolor
gtk-update-icon-cache -q -f -t ~/.local/share/icons/hicolor 2>/dev/null || true
# absolute Exec: ~/.local/bin isn't always on the session PATH
sed "s|^Exec=kivi |Exec=$HOME/.local/bin/kivi |" data/kivi.desktop > ~/.local/share/applications/ai.kivi.Linux.desktop
# LXQt, Xfce and friends never start graphical-session.target, so the service also gets started from here
sed "s|^Exec=kivi |Exec=$HOME/.local/bin/kivi |" data/kivi-autostart.desktop > ~/.config/autostart/ai.kivi.Linux.desktop
update-desktop-database -q ~/.local/share/applications 2>/dev/null || true
# KDE caches menu entries and icons in ksycoca; rebuild it so the menu picks up the icon now
command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 --noincremental >/dev/null 2>&1 || true

if [ ! -f ~/.config/kivi/config.toml ]; then
  cp config.example.toml ~/.config/kivi/config.toml
elif grep -q '^hotkey *=' ~/.config/kivi/config.toml; then
  echo "note: your config has v1 keys (hotkey/command_key); shortcuts now live under [shortcuts]."
  echo "      see config.example.toml, or change them in kivi settings → shortcuts."
fi
[ -f ~/.config/kivi/api_key ] && chmod 600 ~/.config/kivi/api_key

install -m 644 kivi.service ~/.config/systemd/user/kivi.service
systemctl --user daemon-reload
systemctl --user enable kivi.service >/dev/null 2>&1
systemctl --user restart kivi.service || echo "kivi did not start: journalctl --user -u kivi -n 30"

# --- what's still missing (all optional except keyboard access)
pkgs=""
if [ -n "$wayland" ]; then
  $PY -c "from kivi import desktop; exit(not desktop.layer_shell_available())" || pkgs="$pkgs layer-shell"
  command -v wl-copy >/dev/null 2>&1 || pkgs="$pkgs wl-clipboard"
fi

input_ok=""
for dev in /dev/input/event*; do
  [ -r "$dev" ] && { input_ok=1; break; }
done
# check the group database, not this session: a fresh usermod only shows up in `id` after re-login
in_group=""
getent group input | cut -d: -f4 | tr ',' '\n' | grep -qx "$USER" && in_group=1
session_group=""
id -nG | grep -qw input && session_group=1
uinput_ok=""
[ -w /dev/uinput ] && uinput_ok=1
uinput_rule=""
[ -f /etc/udev/rules.d/60-kivi-uinput.rules ] && uinput_rule=1

fix=""
[ -n "$pkgs" ] && fix="$(install_cmd $pkgs)"
if [ -z "$in_group" ]; then
  [ -n "$fix" ] && fix="$fix && "
  fix="${fix}sudo usermod -aG input \$USER"
fi
# /dev/uinput is root-only on most distros; this rule lets the input group type through it after reboots
if [ -z "$uinput_rule" ]; then
  [ -n "$fix" ] && fix="$fix && "
  fix="${fix}echo 'KERNEL==\"uinput\", GROUP=\"input\", MODE=\"0660\", OPTIONS+=\"static_node=uinput\"' | sudo tee /etc/udev/rules.d/60-kivi-uinput.rules >/dev/null && echo uinput | sudo tee /etc/modules-load.d/uinput.conf >/dev/null && sudo udevadm control --reload && sudo udevadm trigger /dev/uinput"
fi

echo
echo "kivi is installed. open it from your app menu, or run: kivi settings"
[ -s ~/.config/kivi/api_key ] || [ -n "$SARVAM_API_KEY" ] || \
  echo "  add your sarvam api key in kivi settings → api key (get one at dashboard.sarvam.ai)"
if [ -n "$fix" ]; then
  echo
  echo "one more step:"
  echo "  $fix"
fi
if [ -n "$in_group" ] && [ -z "$session_group" ]; then
  echo
  echo "you're in the input group, but this login predates it: log out and back in once to make it stick."
fi
if [ -z "$input_ok" ] || [ -z "$uinput_ok" ]; then
  echo
  echo "to use hotkeys right now without logging out (lasts until reboot):"
  [ -z "$input_ok" ] && echo "  sudo setfacl -m u:\$USER:rw /dev/input/event*"
  [ -z "$uinput_ok" ] && echo "  sudo setfacl -m u:\$USER:rw /dev/uinput"
  echo "  systemctl --user restart kivi"
fi
if [ -n "$input_ok" ]; then
  echo
  echo "hold right ctrl and talk. logs: journalctl --user -u kivi -f"
fi
