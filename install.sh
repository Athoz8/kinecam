#!/usr/bin/env bash
# Kinecam installer (Arch / CachyOS). Safe to run again.
# Usage: ./install.sh [--autostart]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HOME/.cache/kinecam-build"
AUTOSTART=0
if [ "${1:-}" = "--autostart" ]; then AUTOSTART=1; fi

say() { printf "\n==> %s\n" "$*"; }
die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Run as a normal user, not root (sudo is used when needed)."
command -v pacman >/dev/null || die "Only Arch-based systems (pacman) are supported. See the README for manual steps."

say "Checking the running kernel"
KVER="$(uname -r)"
[ -d "/usr/lib/modules/$KVER" ] || die "Modules for the running kernel ($KVER) are gone after an update. Reboot, then run this script again."
[ -f "/usr/lib/modules/$KVER/pkgbase" ] || die "Cannot detect the kernel package for $KVER."
HEADERS="$(cat "/usr/lib/modules/$KVER/pkgbase")-headers"

say "Installing packages ($HEADERS and dependencies)"
PKGS=(base-devel git cmake "$HEADERS" v4l2loopback-dkms python-pyqt6)
if command -v nvidia-smi >/dev/null; then
  if pacman -Qq | grep -q "^opencl-nvidia"; then
    echo "NVIDIA OpenCL package already installed."
  else
    PKGS+=(opencl-nvidia)
  fi
else
  echo "No NVIDIA GPU detected: install an OpenCL runtime for your GPU (the depth stream needs OpenCL)."
fi
sudo pacman -S --needed "${PKGS[@]}" || die "pacman failed. If it reported 404 errors, run: sudo pacman -Syu   then run this script again."

say "libfreenect2"
if [ -e /usr/local/include/libfreenect2 ] || ls /usr/local/lib/libfreenect2.so* >/dev/null 2>&1; then
  die "An old libfreenect2 in /usr/local shadows the package. Move /usr/local/include/libfreenect2 and /usr/local/lib/libfreenect2.so* out of the way, then run this script again."
fi
if pacman -Q libfreenect2-git >/dev/null 2>&1 || pacman -Q libfreenect2 >/dev/null 2>&1; then
  echo "libfreenect2 is already installed."
else
  mkdir -p "$BUILD"
  cd "$BUILD"
  rm -rf libfreenect2-git
  git clone https://aur.archlinux.org/libfreenect2-git.git
  cd libfreenect2-git
  export CMAKE_POLICY_VERSION_MINIMUM=3.5
  makepkg -o -s --noconfirm
  grep -rl CL_ICDL_VERSION src/libfreenect2/src | xargs -r sed -i "s/CL_ICDL_VERSION/ICDL_VERSION_LOCAL/g"
  makepkg -e -f --noconfirm
  sudo pacman -U --noconfirm libfreenect2-git-[0-9]*.pkg.tar.*
  cd "$REPO"
fi

say "Virtual cameras (v4l2loopback)"
sudo tee /etc/modprobe.d/kinect-vcams.conf >/dev/null <<EOF
options v4l2loopback devices=4 video_nr=10,11,12,13 card_label="Kinect RGB,Kinect Depth,Kinect Cloud,Kinect IR" exclusive_caps=1,1,1,1
EOF
echo v4l2loopback | sudo tee /etc/modules-load.d/v4l2loopback.conf >/dev/null
if sudo modprobe -r v4l2loopback 2>/dev/null; then
  sudo modprobe v4l2loopback
else
  echo "v4l2loopback is in use. Close apps using cameras (OBS, browsers) and run: sudo modprobe -r v4l2loopback; sudo modprobe v4l2loopback"
fi

say "USB power-off rule (LEDs go off when idle)"
sudo tee /etc/udev/rules.d/66-kinect2-autosuspend.rules >/dev/null <<EOF
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02c4", TEST=="power/control", ATTR{power/control}="auto", ATTR{power/autosuspend_delay_ms}="2000"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=usb --attr-match=idVendor=045e --attr-match=idProduct=02c4 --action=add

say "Building the streamer"
g++ -O2 -o "$REPO/camera/kinect2v4l2_multi" "$REPO/camera/kinect2v4l2_multi.cpp" -lfreenect2

say "Microphone filter"
NODE=""
if command -v pactl >/dev/null; then
  NODE="$(pactl list short sources | grep -i NUI | cut -f2 | head -1 || true)"
fi
if [ -z "$NODE" ]; then
  echo "Kinect audio not found in PipeWire (plugged in, on USB 3.0?). Skipping the mic filter; run this script again with the Kinect connected."
else
  mkdir -p "$HOME/.config/pipewire/pipewire.conf.d"
  cat > "$HOME/.config/pipewire/pipewire.conf.d/kinect-mic.conf" <<EOF
context.modules = [
  { name = libpipewire-module-filter-chain
    args = {
      node.description = "Kinect Mic"
      media.name = "Kinect Mic"
      filter.graph = {
        nodes = [
          { type = builtin name = mix label = mixer control = { "Gain 1" = 8 "Gain 2" = 8 "Gain 3" = 8 "Gain 4" = 8 } }
        ]
        inputs = [ "mix:In 1" "mix:In 2" "mix:In 3" "mix:In 4" ]
        outputs = [ "mix:Out" ]
      }
      capture.props = {
        node.name = "capture.kinect_mic"
        audio.rate = 16000
        audio.channels = 4
        audio.position = [ FL FR FC LFE ]
        target.object = "$NODE"
        node.passive = true
      }
      playback.props = {
        node.name = "kinect_mic"
        media.class = Audio/Source
        audio.rate = 16000
        audio.channels = 1
        audio.position = [ MONO ]
      }
    }
  }
]
EOF
  systemctl --user restart pipewire pipewire-pulse wireplumber
fi

say "Tray launcher"
if [ -f "$HOME/.config/autostart/kinect-tray.desktop" ]; then AUTOSTART=1; fi
rm -f "$HOME/.local/bin/kinect-tray" "$HOME/.local/share/applications/kinect-tray.desktop" "$HOME/.config/autostart/kinect-tray.desktop"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
cat > "$HOME/.local/bin/kinecam" <<EOF
#!/usr/bin/env bash
export LIBVA_DRIVER_NAME=nonexistent
exec python "$REPO/tray/kinect-tray.py" "\$@"
EOF
chmod +x "$HOME/.local/bin/kinecam"
cat > "$HOME/.local/share/applications/kinecam.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Kinecam
Comment=Start and stop the Kinect v2 virtual cameras
Exec=$HOME/.local/bin/kinecam
Icon=$REPO/assets/logo.png
Terminal=false
Categories=AudioVideo;Video;
EOF
if [ "$AUTOSTART" -eq 1 ]; then
  mkdir -p "$HOME/.config/autostart"
  cp "$HOME/.local/share/applications/kinecam.desktop" "$HOME/.config/autostart/kinecam.desktop"
  echo "Tray will start at login."
fi

say "Done"
echo "Start the tray: run kinecam, or open Kinecam from the application menu."
echo "Autostart at login: ./install.sh --autostart"
echo "In apps, pick Kinect RGB / Depth / Cloud / IR as cameras and Kinect Mic as microphone."
