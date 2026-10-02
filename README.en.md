# GT Volume Assistant (GTVolume)

[English](README.en.md) | 简体中文

![GT 音量助手菜单截图](docs/screenshot-menu.png)

A macOS menu bar volume controller built for the **HUAWEI MateView GT 27 monitor** (QSN-CBB / HWV), compatible with other displays and audio devices. It controls the monitor's **actual speaker volume** via DDC/CI — the same path as the monitor's physical buttons — and can take over the macOS volume keys to truly bridge the system's local volume management.

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
- Reacts to display hot-plug and default-output changes; falls back to follow-default when a pinned device disappears
- Launch at login (SMAppService)
- No microphone or other intrusive permissions

## Build & Run

```bash
./build.sh          # produces GTVolume.app
open GTVolume.app
```

Requires Xcode Command Line Tools (`xcode-select --install` if missing). Links the private CoreDisplay framework (SDK ships a tbd stub; resolved from the dyld shared cache at runtime).

For a distributable DMG: `./build-dmg.sh`.

Tip: move `GTVolume.app` into `/Applications` before enabling "Launch at Login"; if you move it later, toggle that option off and on again.

## Usage

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
Sources/MediaKeyTap.swift        # CGEventTap media-key takeover (requires Accessibility)
Sources/MenuBarController.swift  # Menu bar UI: slider, device list, status icon, launch-at-login
Sources/main.swift               # Entry point
tools/main.swift                 # CLI self-check tool
Info.plist / build.sh / build-dmg.sh
```

## FAQ

- **Slider moves but no sound**: check the pinned target in the menu, and that the monitor's own volume/output source isn't at zero.
- **Volume keys do nothing**: enable "Take over keyboard volume keys" and grant Accessibility; the system OSD is suppressed while the tap is active — the menu bar icon is the feedback.
- **Need a second opinion**: the protocol matches [waydabber/m1ddc](https://github.com/waydabber/m1ddc); `m1ddc display 1 get volume` cross-checks values.

## License

MIT — see [LICENSE](LICENSE).
