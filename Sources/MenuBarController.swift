import AppKit
import CoreAudio
import ServiceManagement

final class MenuBarController: NSObject, NSMenuDelegate, MediaKeyHandling {

    private let manager = VolumeManager.shared
    private let mediaKeyTap = MediaKeyTap.shared

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var menuIsOpen = false

    private var slider: NSSlider?
    private var percentLabel: NSTextField?
    private var muteItem: NSMenuItem?

    private var cachedMuted: Bool?

    // MARK: - 启动

    func install() {
        manager.resolveInitialTarget()
        manager.onUpdate = { [weak self] vol, muted in
            self?.refreshVolumeUI(vol: vol, muted: muted)
        }
        manager.onAudioChange = { [weak self] in
            self?.refreshVolumeUI(vol: nil, muted: nil)
        }
        manager.install()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        self.menu = menu

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "GT 音量助手"
        item.menu = menu
        statusItem = item

        mediaKeyTap.handler = self
        updateIcon()
    }

    // MARK: - UI 刷新

    private func refreshVolumeUI(vol: Float?, muted: Bool?) {
        if let muted { cachedMuted = muted }
        updateIcon(volume: vol, muted: muted)
        guard menuIsOpen else { return }
        let volume = vol ?? manager.volume()
        slider?.doubleValue = Double(volume ?? 0)
        slider?.isEnabled = manager.hasVolumeControl
        percentLabel?.stringValue = volume.map { percentText($0) } ?? "—"
        muteItem?.state = (muted ?? manager.isMuted() ?? false) ? .on : .off
    }

    private func updateIcon(volume: Float? = nil, muted: Bool? = nil) {
        guard let button = statusItem?.button else { return }
        let vol = volume ?? manager.volume()
        let isMuted = muted ?? (cachedMuted ?? manager.isMuted() ?? false)

        let symbolName: String
        if isMuted {
            symbolName = "speaker.slash.fill"
        } else if let vol {
            switch vol {
            case ..<0.01: symbolName = "speaker.slash.fill"
            case ..<0.34: symbolName = "speaker.wave.1.fill"
            case ..<0.67: symbolName = "speaker.wave.2.fill"
            default: symbolName = "speaker.wave.3.fill"
            }
        } else {
            symbolName = "speaker.wave.2.fill"
        }
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "音量")
    }

    private func percentText(_ volume: Float) -> String {
        "\(Int((volume * 100).rounded()))%"
    }

    private func modeText() -> String {
        guard let r = manager.resolved else { return "未找到可控制的音量目标" }
        let ddcNote: String
        if case .ddc = r.kind { ddcNote = " · DDC 直控显示器喇叭" } else { ddcNote = "" }
        if manager.pinned == .followDefault {
            return "跟随系统默认输出\(ddcNote)"
        }
        return r.isDefaultPath ? "已锁定该设备\(ddcNote)" : "已锁定该设备(非系统默认输出)"
    }

    // MARK: - 菜单构建

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func rebuildMenu() {
        guard let menu else { return }
        manager.refresh()

        let volume = manager.volume()
        let muted = manager.isMuted() ?? false
        cachedMuted = muted

        menu.removeAllItems()

        let header = NSMenuItem()
        header.view = makeHeaderView(name: manager.resolved?.displayName ?? "未找到输出设备",
                                     mode: modeText())
        menu.addItem(header)

        let row = NSMenuItem()
        row.view = makeSliderRow(volume: volume, controllable: manager.hasVolumeControl)
        menu.addItem(row)

        menu.addItem(.separator())

        let mute = NSMenuItem(title: "静音", action: #selector(toggleMute(_:)), keyEquivalent: "m")
        mute.target = self
        mute.state = muted ? .on : .off
        menu.addItem(mute)
        muteItem = mute

        let follow = NSMenuItem(title: "跟随系统默认输出", action: #selector(toggleFollow(_:)), keyEquivalent: "")
        follow.target = self
        follow.state = manager.pinned == .followDefault ? .on : .off
        menu.addItem(follow)

        if !manager.ddcDisplays.isEmpty {
            menu.addItem(.separator())
            let ddcTitle = NSMenuItem(title: "显示器喇叭(DDC)", action: nil, keyEquivalent: "")
            ddcTitle.isEnabled = false
            menu.addItem(ddcTitle)
            for ddc in manager.ddcDisplays {
                let item = NSMenuItem(title: ddcItemTitle(ddc), action: #selector(selectDDCDisplay(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: ddc.displayID)
                item.state = isResolvedDDC(ddc) ? .on : .off
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }

        let audioDevices = manager.controllableAudioDevices()
        if !audioDevices.isEmpty {
            menu.addItem(.separator())
            let audioTitle = NSMenuItem(title: "输出设备", action: nil, keyEquivalent: "")
            audioTitle.isEnabled = false
            menu.addItem(audioTitle)
            for device in audioDevices {
                let item = NSMenuItem(title: deviceTitle(device), action: #selector(selectAudioDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: device.id)
                if case .audio(let id)? = manager.resolved?.kind, id == device.id {
                    item.state = .on
                }
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let mediaKeys = NSMenuItem(title: "接管键盘音量键(需辅助功能权限)",
                                   action: #selector(toggleMediaKeyTap(_:)), keyEquivalent: "")
        mediaKeys.target = self
        mediaKeys.state = mediaKeyTap.isEnabled ? .on : .off
        menu.addItem(mediaKeys)

        let login = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self
        if #available(macOS 13.0, *) {
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            login.isEnabled = false
        }
        menu.addItem(login)

        let quit = NSMenuItem(title: "退出 GT 音量助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func ddcItemTitle(_ ddc: DDCDisplay) -> String {
        let maker = ddc.manufacturer ?? "DDC"
        return "\(ddc.productName) (\(maker))"
    }

    private func deviceTitle(_ device: OutputDevice) -> String {
        var parts: [String] = []
        if let maker = device.manufacturer, !maker.isEmpty { parts.append(maker) }
        if let transport = device.transport, !transport.isEmpty { parts.append(transport) }
        return parts.isEmpty ? device.name : "\(device.name) (\(parts.joined(separator: " · ")))"
    }

    private func isResolvedDDC(_ ddc: DDCDisplay) -> Bool {
        guard let r = manager.resolved, case .ddc(let d) = r.kind else { return false }
        return d.displayID == ddc.displayID
    }

    private func makeHeaderView(name: String, mode: String) -> NSView {
        let width: CGFloat = 300
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 46))

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.frame = NSRect(x: 14, y: 24, width: width - 28, height: 18)
        nameLabel.font = NSFont.boldSystemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        container.addSubview(nameLabel)

        let modeLabel = NSTextField(labelWithString: mode)
        modeLabel.frame = NSRect(x: 14, y: 7, width: width - 28, height: 15)
        modeLabel.font = NSFont.systemFont(ofSize: 11)
        modeLabel.textColor = .secondaryLabelColor
        container.addSubview(modeLabel)

        return container
    }

    private func makeSliderRow(volume: Float?, controllable: Bool) -> NSView {
        let width: CGFloat = 300
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 32))

        let slider = NSSlider(value: Double(volume ?? 0), minValue: 0, maxValue: 1,
                              target: self, action: #selector(sliderChanged(_:)))
        slider.frame = NSRect(x: 14, y: 6, width: width - 84, height: 20)
        slider.isContinuous = true
        slider.isEnabled = controllable
        container.addSubview(slider)
        self.slider = slider

        let label = NSTextField(labelWithString: volume.map { percentText($0) } ?? "—")
        label.frame = NSRect(x: width - 62, y: 9, width: 48, height: 16)
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.alignment = .right
        container.addSubview(label)
        percentLabel = label

        return container
    }

    // MARK: - 菜单动作

    @objc private func sliderChanged(_ sender: NSSlider) {
        let value = Float(sender.doubleValue)
        percentLabel?.stringValue = percentText(value)
        manager.setVolume(value) { [weak self] _ in
            self?.updateIcon()
        }
        if (cachedMuted ?? false) && value > 0 {
            manager.setMuted(false) { [weak self] _ in self?.updateIcon() }
            cachedMuted = false
            muteItem?.state = .off
        }
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        let muted = manager.isMuted() ?? false
        manager.setMuted(!muted) { [weak self] _ in
            self?.refreshVolumeUI(vol: nil, muted: nil)
        }
        sender.state = !muted ? .on : .off
        cachedMuted = !muted
        updateIcon(muted: !muted)
    }

    @objc private func toggleFollow(_ sender: NSMenuItem) {
        manager.pinned = .followDefault
        manager.refresh()
        rebuildMenu()
        updateIcon()
    }

    @objc private func selectDDCDisplay(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        manager.pinned = .ddcDisplay(CGDirectDisplayID(number.uint32Value))
        manager.refresh()
        rebuildMenu()
        updateIcon()
    }

    @objc private func selectAudioDevice(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        manager.pinned = .audioDevice(AudioDeviceID(number.uint32Value))
        manager.refresh()
        rebuildMenu()
        updateIcon()
    }

    @objc private func toggleMediaKeyTap(_ sender: NSMenuItem) {
        if mediaKeyTap.isEnabled {
            mediaKeyTap.disable()
        } else {
            if !mediaKeyTap.enable(promptIfNeeded: true) {
                NSSound.beep()
            }
        }
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .notFound: break
            default: try service.register()
            }
        } catch {
            NSSound.beep()
        }
        rebuildMenu()
    }

    // MARK: - 键盘音量键(MediaKeyHandling)

    func handleMediaKey(_ key: MediaKeyTap.Key) -> Bool {
        guard manager.hasTarget, manager.hasVolumeControl else { return false }
        switch key {
        case .up:
            manager.changeVolume(by: 0.05) { [weak self] new in
                self?.refreshVolumeUI(vol: new, muted: false)
            }
        case .down:
            manager.changeVolume(by: -0.05) { [weak self] new in
                self?.refreshVolumeUI(vol: new, muted: nil)
            }
        case .mute:
            let muted = manager.isMuted() ?? false
            manager.setMuted(!muted) { [weak self] _ in
                self?.refreshVolumeUI(vol: nil, muted: !muted)
            }
        }
        return true
    }
}
