# OpenKinect v2 (tray edition)

Use an Xbox One Kinect (v2) on Linux as virtual webcams and a boosted microphone. A tray icon starts and stops everything, and stopping powers the sensor down (IR and logo LEDs off).

Fork of [BenGWeeks/openkinect-v2](https://github.com/BenGWeeks/openkinect-v2), which provides the original RGB-only `kinect2v4l2` streamer, the audio test scripts and the hardware notes. Built on [libfreenect2](https://github.com/OpenKinect/libfreenect2) and [v4l2loopback](https://github.com/umlaeute/v4l2loopback).

## Features

| Device | Node | Size | Content |
|---|---|---|---|
| Kinect RGB | `/dev/video10` | 1920x1080 | Color camera |
| Kinect Depth | `/dev/video11` | 512x424 | Viridis colormap, adaptive range (3rd to 97th percentile), temporal smoothing, flicker removal |
| Kinect Cloud | `/dev/video12` | 640x480 | Colored point cloud, slow rocking view (±0.5 rad around a pivot 1 m out) |
| Kinect IR | `/dev/video13` | 512x424 | Infrared, adaptive brightness |
| Kinect Mic | PipeWire source | mono 16 kHz | 4 mics mixed with gain, much louder than the raw device |

- One process (`camera/kinect2v4l2_multi`) feeds all cameras, since only one program can open the Kinect at a time. Depth uses the OpenCL pipeline (about 800 Hz on a GTX 1060 vs about 10 Hz on CPU).
- `tray/kinect-tray.py` (PyQt6): green icon = streaming, grey = stopped. Click toggles, menu has Start/Stop and Quit.
- Skeleton tracking is not included (libfreenect2 has none).

## Requirements

- Kinect v2 with its adapter, on a USB 3.0 port
- NVIDIA GPU with OpenCL (tested: GTX 1060; CUDA not needed)
- v4l2loopback, kernel headers matching your running kernel, PipeWire, Python 3, PyQt6
- Tested on CachyOS (Arch), KDE Plasma, Wayland. Other distros should work but are untested.

## Install (Arch / CachyOS)

**1. Packages** (use your kernel's headers, e.g. `linux-cachyos-headers`; check with `uname -r`)

```bash
sudo pacman -S --needed base-devel cmake v4l2loopback-dkms python-pyqt6 opencl-nvidia
sudo pacman -Syu   # sync first, or headers may 404
```

**2. libfreenect2** (AUR `libfreenect2-git` needs two fixes on current toolchains: CMake 4 rejects its old minimum version, and a local variable clashes with a macro in newer OpenCL headers)

```bash
yay -S libfreenect2-git   # fails at build; leaves the sources in place
cd ~/.cache/yay/libfreenect2-git
grep -rl CL_ICDL_VERSION src/libfreenect2/src | xargs sed -i 's/CL_ICDL_VERSION/ICDL_VERSION_LOCAL/g'
CMAKE_POLICY_VERSION_MINIMUM=3.5 makepkg -ef
sudo pacman -U libfreenect2-git-*.pkg.tar.zst
```

Remove any older copy in `/usr/local/include/libfreenect2` and `/usr/local/lib/libfreenect2.so*`, or the compiler will pick up the stale headers. (Ubuntu/Debian: build from source as in the original `scripts/install-kinect-v2.sh`.)

**3. Virtual cameras**

```bash
echo 'options v4l2loopback devices=4 video_nr=10,11,12,13 card_label="Kinect RGB,Kinect Depth,Kinect Cloud,Kinect IR" exclusive_caps=1,1,1,1' | sudo tee /etc/modprobe.d/kinect-vcams.conf
echo v4l2loopback | sudo tee /etc/modules-load.d/v4l2loopback.conf
sudo modprobe -r v4l2loopback; sudo modprobe v4l2loopback   # close apps using the cameras first
```

**4. USB power-off rule** (lets the sensor suspend when idle so the LEDs go off)

```bash
echo 'ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02c4", TEST=="power/control", ATTR{power/control}="auto", ATTR{power/autosuspend_delay_ms}="2000"' | sudo tee /etc/udev/rules.d/66-kinect2-autosuspend.rules
sudo udevadm control --reload-rules
```

**5. Build the streamer**

```bash
cd camera && g++ -O2 -o kinect2v4l2_multi kinect2v4l2_multi.cpp -lfreenect2
```

**6. Microphone** (`~/.config/pipewire/pipewire.conf.d/kinect-mic.conf`; replace the serial in `target.object` with yours from `pactl list short sources | grep NUI`, then `systemctl --user restart pipewire pipewire-pulse wireplumber`)

```
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
        target.object = "alsa_input.usb-Microsoft_Xbox_NUI_Sensor_<SERIAL>-02.analog-surround-40"
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
```

## Use

```bash
python tray/kinect-tray.py
```

Select "Kinect RGB / Depth / Cloud / IR" as video sources and "Kinect Mic" as audio in OBS, Zoom, browsers, etc. Add the script to KDE Autostart to have it at login. Use Quit (or Stop) to power the sensor down.

## Troubleshooting

| Problem | Fix |
|---|---|
| Crash or frozen video with VA-API errors (`vaGetImage`, `vaCreateImage`) | Run with `LIBVA_DRIVER_NAME=nonexistent` (the tray does this). For the viewer: `env LIBVA_DRIVER_NAME=nonexistent Protonect cl` |
| Segfault when stopping the original `kinect2v4l2` | The original `delete pipeline;` double-frees; it is removed here |
| Logo LED stays on after stopping | Step 4 rule missing, or an app still has the mic open (e.g. OBS minimized to tray). Quit it |
| `LIBUSB_ERROR_IO` / "No Kinect device found" after suspend | Re-authorize: `echo 0 \| sudo tee /sys/bus/usb/devices/<port>/authorized`, wait 2 s, write `1` |
| `modprobe -r v4l2loopback` says in use | Find holders with `sudo fuser -v /dev/video1*` and close them |
| `Kinect IR/Mixed/...` entries in OBS that do nothing | Leftovers from older configs; reload the module with the settings from step 3 |
| Cloud/Depth show trails | Temporal smoothing trades a little latency for less flicker |

## Layout

```
camera/   kinect2v4l2_multi.cpp (RGB+Depth+Cloud+IR), kinect2v4l2.cpp (original RGB-only)
tray/     kinect-tray.py
audio/    original test scripts
docs/     original notes (beamforming roadmap, troubleshooting)
```

## Status

Working: 4 cameras, boosted mic, tray control, LED power-off. Planned: installer script, shipped config files, autostart entry, adjustable colormap and cloud settings, beamforming (see `docs/BEAMFORMING-ROADMAP.md`).

## License

MIT, as in the original project. Not affiliated with Microsoft; Kinect is a trademark of Microsoft Corporation.
