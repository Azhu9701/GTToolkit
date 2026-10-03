# GT Volume Assistant (GTVolume)

<img src="docs/icon-128.png" width="96" alt="GT Volume Assistant icon" align="right">

[English](README.en.md) | 简体中文

A macOS menu bar volume controller built for the **HUAWEI MateView GT 27 monitor** (QSN-CBB / HWV), compatible with other displays and audio devices. It controls the monitor's **actual speaker volume** via DDC/CI — the same path as the monitor's physical buttons — and can take over the macOS volume keys to truly bridge the system's local volume management. Includes smart fan management.

Pure Swift, builds with Command Line Tools only (no Xcode project needed). The DDC path follows the protocol validated by [waydabber/m1ddc](https://github.com/waydabber/m1ddc). MIT licensed.

## Why this exists

When this monitor outputs audio over DisplayPort, macOS offers **no system volume control at all**:

- The CoreAudio device (QSN-CBB) exposes no `VolumeScalar`/`Mute` properties; `osascript get volume settings` reports `output volume:missing value`;
- The keyboard volume keys pop the system OSD but never change the monitor's speaker volume.

The only path to the monitor's amplifier is its DDC/CI interface (VCP `0x62` volume / `0x8D` mute). This app drives it through Apple Silicon's IOAVService API (same approach as MonitorControl and m1ddc), verified working on a Mac Studio over DisplayPort.

## Features

- Menu bar speaker icon + slider that controls the monitor's real speaker volume (live percentage, icon reflects volume/mute)
- Mute toggle (VCP `0x8D`; falls back to volume-0 when unsupported)
- **Monitor-side changes sync to the app within ~3s** (DDC polling catches physical-button adjustments)
- Auto-detects the HUAWEI display (manufacturer `HWV` / name match); pin any DDC display or CoreAudio device (Bluetooth, built-in speakers, …) from the device list
- "Follow system default output" mode: controls the default output directly, or maps it to the same-named display's speakers over DDC when the default output has no volume control (typical DP monitor case)
- **Take over the keyboard volume keys** (optional, requires Accessibility permission): intercept F1/F2/F3 and step the target volume by 5% — making the Mac's local volume keys actually work on the monitor
- **Smart fan management** (optional, one admin prompt on first enable): temperature-curve control, manual RPM sliders, overheat protection; fan mode persists across relaunches
- **Automatic DP-audio repair** (optional, one admin prompt to enable): a resident daemon silently probes the default output after every display wake and restarts the audio service automatically if it has wedged
- **One-click audio repair**: when the monitor wakes from sleep and DP audio wedges (playback fails with `AudioQueueStart failed`, system-wide silence), one menu click restarts the audio service (requires admin authorization)
- Reacts to display hot-plug and default-output changes; falls back to follow-default when a pinned device disappears
- Launch at login (SMAppService)
- No microphone or other intrusive permissions

## Smart fan management

macOS's stock fan policy is conservative. This app reads temperatures and fan speeds straight from the SMC and offers three modes:

- **System auto**: leave everything to macOS (default)
- **Smart curve**: drive fans from the hottest system sensor with three presets — Quiet (ramp from 62°C) / Balanced (55°C) / Performance (48°C); smooth slew-rate limiting (max 800 RPM per step) and hysteresis
- **Manual**: per-fan RPM sliders

Safety design:

- Writing fan-control keys (`F0Md`/`F0Tg`) requires root. The app embeds a tiny privileged helper, `gt-fanctl`; enabling control shows **one admin password prompt**. The helper accepts only whitelisted fan commands over a 0600 local socket
- RPM is always clamped to the SMC-reported [min, max] range; ≥90°C forces full speed in smart mode, ≥95°C forces full speed in any non-auto mode
- Quitting the app restores system auto; a dropped helper connection restores system auto immediately; the helper also clears any stale forced state at startup

## Automatic DP-audio repair

After the display wakes from sleep, macOS's DP audio driver occasionally wedges — the device exists and the amp is fine, but **no app can start an audio stream** (`AudioQueueStart failed ('stop')`), leaving the system silent until `sudo killall coreaudiod`. This feature automates it away:

- Click "音频自动修复" in the menu → the helper installs itself as a resident LaunchDaemon (`com.sounds.gtfanctl`, starts at boot, auto-restarted if it crashes). **One admin prompt, never again**
- After every display reconfiguration (including sleep/wake), the daemon silently starts a **zero-volume probe stream** on the default output: failure means wedged → it restarts the audio service and re-probes, up to 3 times
- The probe is inaudible and takes milliseconds; skipped while displays sleep; 45s cooldown prevents loops
- Clicking the same item again fully uninstalls the daemon

## Build & Run

```bash
./build.sh          # produces GTVolume.app
open GTVolume.app
```

Requires Xcode Command Line Tools (`xcode-select --install` if missing). Links the private CoreDisplay framework (SDK ships a tbd stub; resolved from the dyld shared cache at runtime).

For a distributable DMG: `./build-dmg.sh`.

Tip: move `GTVolume.app` into `/Applications` before enabling "Launch at Login"; if you move it later, toggle that option off and on again.

## Usage

![Menu screenshot](docs/screenshot-menu.png)

- Click the menu bar speaker icon and drag the slider
- "Display speakers (DDC)" section: check any display to pin it
- "Output devices" section: Bluetooth headsets, built-in speakers and other CoreAudio devices (volume goes through the system volume property, naturally in sync with the volume keys)
- "Take over keyboard volume keys": after enabling, the volume keys adjust the current target; the first enable prompts for Accessibility permission (System Settings → Privacy & Security → Accessibility → GTVolume)

## How it bridges into macOS volume management

The app reads/writes the output device's `kAudioDevicePropertyVolumeScalar` / `kAudioDevicePropertyMute` — the **same system state** the volume keys modify:

- **App → system**: moving the slider writes the target device's volume; Control Center / volume keys agree immediately
- **System → app**: `AudioObjectAddPropertyListenerBlock` listeners watch volume, mute, default-output changes and device hot-plug, refreshing the UI in real time

When the default output has no volume control (DP monitor audio), the app maps "follow system default" onto the same-named display and drives it via DDC; enabling the media-key tap routes the keyboard volume keys there too.

## Self-check tool

```bash
# Lists output devices & DDC displays, verifies volume read/write (write-back of the current value only)
swiftc -O -swift-version 5 Sources/AudioController.swift Sources/DDCController.swift tools/main.swift \
  -o /tmp/gt-audio-check -framework IOKit \
  -F "$(xcrun --show-sdk-path)/System/Library/PrivateFrameworks" -framework CoreDisplay
/tmp/gt-audio-check
```

## Project layout

```
Sources/AudioController.swift    # CoreAudio: device enumeration, volume/mute read-write, property listeners
Sources/DDCController.swift      # DDC/CI: display discovery, IOAVService I2C, VCP 0x62/0x8D
Sources/VolumeManager.swift      # Unified target model: follow-default / pinned audio device / pinned DDC display
Sources/SMCLite.swift            # SMC low level: key read-write, fan speeds, temperature discovery (shared with helper)
Sources/FanController.swift      # Smart fan management: temperature curve, modes, helper communication
Sources/FanHelperMain.swift      # gt-fanctl privileged helper (root): resident daemon, whitelisted commands, wake-probe auto-repair, auto-restore on disconnect
Sources/MediaKeyTap.swift        # CGEventTap media-key takeover (requires Accessibility)
Sources/MenuBarController.swift  # Menu bar UI: slider, device list, fan section, status icon, launch-at-login
Sources/main.swift               # Entry point
tools/main.swift                 # CLI self-check tool (volume path)
tools/smc_probe.swift            # CLI self-check tool (SMC fan/temperature keys)
Info.plist / build.sh / build-dmg.sh
```

## FAQ

- **Slider moves but no sound**: check the pinned target in the menu, and that the monitor's own volume/output source isn't at zero.
- **Volume keys do nothing**: enable "Take over keyboard volume keys" and grant Accessibility; the system OSD is suppressed while the tap is active — the menu bar icon is the feedback.
- **Need a second opinion**: the protocol matches [waydabber/m1ddc](https://github.com/waydabber/m1ddc); `m1ddc display 1 get volume` cross-checks values.
- **Fan control did not prompt / auth was cancelled**: the notice at the bottom of the menu explains it — click Smart or Manual again to retry. System auto mode never needs privileges.
- **System-wide silence after the monitor wakes**: wedged DP audio (playback fails with `AudioQueueStart failed`). Enable "音频自动修复" to auto-repair on every wake; or click "修复系统音频" to restart the audio service manually, or run `sudo killall coreaudiod`.
- **Fans stuck after a crash**: reopen the app — a "restore auto" entry appears in the menu (the helper also clears stale forced state on startup).

## License

MIT — see [LICENSE](LICENSE).
