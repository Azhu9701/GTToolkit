import AppKit
import CoreAudio
import ServiceManagement

final class MenuBarController: NSObject, NSMenuDelegate, MediaKeyHandling {

    private let manager = VolumeManager.shared
    private let fan = FanController.shared
    private let models = ModelMonitor.shared
    private let mediaKeyTap = MediaKeyTap.shared

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var menuIsOpen = false

    private var slider: NSSlider?
    private var percentLabel: NSTextField?
    private var muteItem: NSMenuItem?
    private var fanTempItem: NSMenuItem?
    private var fanRPMItem: NSMenuItem?
    private var cachedMuted: Bool?
    private var lastModelStructure = ""
    private var modelValueItems: [(NSMenuItem, (ModelMonitor) -> String)] = []

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

        fan.onUpdate = { [weak self] in self?.refreshFanUI() }
        fan.start()

        models.onUpdate = { [weak self] in self?.refreshModelUI() }
        models.start()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        self.menu = menu

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "GT 工具箱"
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

    // MARK: - 风扇区

    private func refreshFanUI() {
        guard menuIsOpen else { return }
        fanTempItem?.title = fanTempLine()
        fanRPMItem?.title = fanRPMLine()
    }

    private func fanTempLine() -> String {
        guard fan.available else { return "风扇 · SMC 不可用" }
        if fan.hottestTemp > 0 {
            return String(format: "风扇 · 最高温度 %.1f°C (%@)", fan.hottestTemp, fan.hottestKey)
        }
        return "风扇 · 温度读取中…"
    }

    private func fanRPMLine() -> String {
        guard !fan.fans.isEmpty else { return "未发现风扇" }
        return fan.fans.map { String(format: "风扇%d %.0f RPM", $0.index + 1, $0.current) }.joined(separator: " · ")
    }

    // MARK: - 本地模型区

    private func refreshModelUI() {
        guard menuIsOpen else { return }
        // 结构变化(新增/关闭运行时、加载/卸载模型)才重建菜单;
        // 数值变化(GPU/CPU/倒计时)就地更新,避免每 5 秒重建打断鼠标交互。
        if models.structuralSignature != lastModelStructure {
            rebuildMenu()
            return
        }
        for (item, format) in modelValueItems {
            let text = format(models)
            if item.title != text { item.title = text }
        }
    }

    private func bytesText(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "—" }
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    private func remainText(_ date: Date?) -> String {
        guard let date else { return "常驻" }
        let secs = Int(date.timeIntervalSinceNow)
        if secs <= 0 { return "即将卸载" }
        if secs >= 3600 { return String(format: "%d 小时 %d 分", secs / 3600, (secs % 3600) / 60) }
        if secs >= 60 { return "\(secs / 60) 分 \(secs % 60) 秒" }
        return "\(secs) 秒"
    }

    private func buildModelSection(_ menu: NSMenu) {
        modelValueItems.removeAll()
        lastModelStructure = models.structuralSignature
        menu.addItem(.separator())

        let header = NSMenuItem(title: "本地模型", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let gpu = NSMenuItem(title: gpuLine(), action: nil, keyEquivalent: "")
        gpu.isEnabled = false
        gpu.indentationLevel = 1
        menu.addItem(gpu)
        modelValueItems.append((gpu, { _ in self.gpuLine() }))

        if models.localRuntimes.isEmpty {
            let none = NSMenuItem(title: "未检测到运行中的本地模型服务", action: nil, keyEquivalent: "")
            none.isEnabled = false
            none.indentationLevel = 1
            menu.addItem(none)

            let startSub = NSMenuItem(title: "启动服务", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for kind in [ModelMonitor.Kind.ollama, .lmstudio, .llamaCpp, .mlx] {
                let item = NSMenuItem(title: kind.title, action: #selector(startModelService(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = kind.rawValue
                sub.addItem(item)
            }
            startSub.submenu = sub
            startSub.indentationLevel = 1
            menu.addItem(startSub)
        } else {
            for rt in models.localRuntimes {
                let title = NSMenuItem(title: runtimeLine(rt.kind), action: nil, keyEquivalent: "")
                title.isEnabled = false
                title.indentationLevel = 1
                menu.addItem(title)
                let kind = rt.kind
                modelValueItems.append((title, { _ in self.runtimeLine(kind) }))

                if rt.loaded.isEmpty {
                    let idle = NSMenuItem(title: "已安装 \(rt.installed) 个模型 · 当前未加载",
                                          action: nil, keyEquivalent: "")
                    idle.isEnabled = false
                    idle.indentationLevel = 2
                    menu.addItem(idle)
                    continue
                }

                for m in rt.loaded {
                    let item = NSMenuItem(title: modelLine(m.name), action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    item.indentationLevel = 2
                    menu.addItem(item)
                    let name = m.name
                    modelValueItems.append((item, { _ in self.modelLine(name) }))

                    if rt.controllable {
                        let unload = NSMenuItem(title: "卸载「\(m.name)」", action: #selector(unloadModel(_:)), keyEquivalent: "")
                        unload.target = self
                        unload.representedObject = "local|\(rt.kind.rawValue)|\(m.name)"
                        unload.indentationLevel = 3
                        menu.addItem(unload)
                    } else {
                        let stop = NSMenuItem(title: "结束进程(释放内存)", action: #selector(terminateRuntime(_:)), keyEquivalent: "")
                        stop.target = self
                        stop.representedObject = rt.kind.rawValue
                        stop.indentationLevel = 3
                        menu.addItem(stop)
                    }
                }

                if rt.kind == .ollama, rt.loaded.count > 1 {
                    let all = NSMenuItem(title: "卸载全部", action: #selector(unloadAllModels(_:)), keyEquivalent: "")
                    all.target = self
                    all.indentationLevel = 2
                    menu.addItem(all)
                }
                if rt.kind == .ollama, !rt.loaded.isEmpty {
                    let keep = NSMenuItem(title: "续期保活 30 分钟", action: #selector(keepAliveModels(_:)), keyEquivalent: "")
                    keep.target = self
                    keep.indentationLevel = 2
                    menu.addItem(keep)
                }

                let open = NSMenuItem(title: "打开 \(rt.kind.title) 控制台", action: #selector(openModelConsole(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = rt.kind.rawValue
                open.indentationLevel = 2
                menu.addItem(open)
            }

            let inactive = [ModelMonitor.Kind.ollama, .lmstudio, .mlx, .llamaCpp]
                .filter { k in k.isInstalled && !models.localRuntimes.contains(where: { $0.kind == k }) }
            if !inactive.isEmpty {
                let startSub = NSMenuItem(title: "启动其他服务", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for kind in inactive {
                    let item = NSMenuItem(title: kind.title, action: #selector(startModelService(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = kind.rawValue
                    sub.addItem(item)
                }
                startSub.submenu = sub
                startSub.indentationLevel = 1
                menu.addItem(startSub)
            }
        }

        buildRemoteSection(menu)

        if let notice = models.notice {
            let n = NSMenuItem(title: "· \(notice)", action: nil, keyEquivalent: "")
            n.isEnabled = false
            menu.addItem(n)
        }
    }

    // MARK: - 远程模型区(局域网内的 Windows / Linux 推理机)

    private func buildRemoteSection(_ menu: NSMenu) {
        menu.addItem(.separator())

        let header = NSMenuItem(title: "远程模型", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if models.remoteRuntimes.isEmpty, models.offlineEndpoints.isEmpty {
            let none = NSMenuItem(title: "未添加远程主机 · 可监测 Windows 上的推理服务", action: nil, keyEquivalent: "")
            none.isEnabled = false
            none.indentationLevel = 1
            menu.addItem(none)
        }

        for rt in models.remoteRuntimes {
            let endpoint = rt.endpoint
            let title = NSMenuItem(title: remoteLine(endpoint), action: nil, keyEquivalent: "")
            title.isEnabled = false
            title.indentationLevel = 1
            menu.addItem(title)
            modelValueItems.append((title, { _ in self.remoteLine(endpoint) }))

            for m in rt.loaded {
                let item = NSMenuItem(title: remoteModelLine(endpoint, m.name), action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.indentationLevel = 2
                menu.addItem(item)
                let name = m.name
                modelValueItems.append((item, { _ in self.remoteModelLine(endpoint, name) }))

                if rt.controllable {
                    let unload = NSMenuItem(title: "卸载「\(m.name)」(远程)", action: #selector(unloadModel(_:)), keyEquivalent: "")
                    unload.target = self
                    unload.representedObject = "remote|\(endpoint)|\(m.name)"
                    unload.indentationLevel = 3
                    menu.addItem(unload)
                }
            }

            if rt.kind == .ollama, rt.loaded.count > 1 {
                let all = NSMenuItem(title: "卸载全部(远程)", action: #selector(unloadAllModels(_:)), keyEquivalent: "")
                all.target = self
                all.representedObject = endpoint
                all.indentationLevel = 2
                menu.addItem(all)
            }
            if rt.kind == .ollama, !rt.loaded.isEmpty {
                let keep = NSMenuItem(title: "续期保活 30 分钟(远程)", action: #selector(keepAliveModels(_:)), keyEquivalent: "")
                keep.target = self
                keep.representedObject = endpoint
                keep.indentationLevel = 2
                menu.addItem(keep)
            }
            if rt.kind == .llamaCpp {
                let web = NSMenuItem(title: "打开 llama.cpp 网页界面", action: #selector(openRemoteWeb(_:)), keyEquivalent: "")
                web.target = self
                web.representedObject = endpoint
                web.indentationLevel = 2
                menu.addItem(web)
            }

            let remove = NSMenuItem(title: "移除 \(endpoint)", action: #selector(removeRemoteHost(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = endpoint
            remove.indentationLevel = 2
            menu.addItem(remove)
        }

        for ep in models.offlineEndpoints {
            let line = NSMenuItem(title: "\(ep) · 离线", action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.indentationLevel = 1
            menu.addItem(line)

            let remove = NSMenuItem(title: "移除 \(ep)", action: #selector(removeRemoteHost(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = ep
            remove.indentationLevel = 2
            menu.addItem(remove)
        }

        let add = NSMenuItem(title: "添加远程主机…", action: #selector(addRemoteHost(_:)), keyEquivalent: "")
        add.target = self
        add.indentationLevel = 1
        menu.addItem(add)

        if models.scanning {
            let scan = NSMenuItem(title: "正在扫描局域网…", action: nil, keyEquivalent: "")
            scan.isEnabled = false
            scan.indentationLevel = 1
            menu.addItem(scan)
        } else {
            let scan = NSMenuItem(title: "扫描局域网", action: #selector(scanLAN(_:)), keyEquivalent: "")
            scan.target = self
            scan.indentationLevel = 1
            menu.addItem(scan)
        }
        for c in models.scanCandidates {
            let item = NSMenuItem(title: "添加 \(c.endpoint)(\(c.kindTitle))", action: #selector(addScanCandidate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.endpoint
            item.indentationLevel = 2
            menu.addItem(item)
        }
    }

    /// 远程主机概览行(数值型,就地刷新)。
    private func remoteLine(_ endpoint: String) -> String {
        guard let rt = models.remoteRuntimes.first(where: { $0.endpoint == endpoint }) else {
            return "\(endpoint) · 离线"
        }
        var s = "\(endpoint) · \(rt.kind.title)"
        if let v = rt.version, !v.isEmpty { s += " · v\(v)" }
        s += " · \(rt.loaded.count) 个已加载"
        return s
    }

    /// 远程已加载模型的信息行(数值型,就地刷新)。
    private func remoteModelLine(_ endpoint: String, _ name: String) -> String {
        guard let rt = models.remoteRuntimes.first(where: { $0.endpoint == endpoint }),
              let m = rt.loaded.first(where: { $0.name == name }) else { return "▸ \(name)" }
        var line = "▸ \(m.name)"
        if m.vramBytes > 0 { line += " · \(bytesText(m.vramBytes))" }
        if !m.meta.isEmpty { line += " · \(m.meta)" }
        line += " · \(remainText(m.expires))"
        return line
    }

    /// 运行时概览行(数值型,就地刷新)。
    private func runtimeLine(_ kind: ModelMonitor.Kind) -> String {
        guard let rt = models.runtimes.first(where: { $0.kind == kind }) else { return kind.title }
        var s = "\(kind.title) · 端口 \(rt.port)"
        if let proc = models.procs[kind] { s += " · CPU \(Int(proc.cpu))% · 内存 \(bytesText(proc.mem))" }
        if let v = rt.version, !v.isEmpty { s += " · v\(v)" }
        return s
    }

    /// 单个已加载模型的信息行(数值型,就地刷新)。
    private func modelLine(_ name: String) -> String {
        for rt in models.runtimes {
            guard let m = rt.loaded.first(where: { $0.name == name }) else { continue }
            var line = "▸ \(m.name)"
            if m.vramBytes > 0 { line += " · \(bytesText(m.vramBytes))" }
            if !m.meta.isEmpty { line += " · \(m.meta)" }
            line += " · \(remainText(m.expires))"
            return line
        }
        return "▸ \(name)"
    }


    private func gpuLine() -> String {
        let mem = models.memTotal > 0
            ? String(format: "内存 %.1f/%.0f GB", Double(models.memUsed) / 1_073_741_824, Double(models.memTotal) / 1_073_741_824)
            : ""
        return String(format: "GPU %d%% · %@ · 内存压力%@", Int(models.gpuUtil.rounded()), mem, models.memPressure)
    }

    private func buildFanSection(_ menu: NSMenu) {
        guard fan.available else { return }
        menu.addItem(.separator())

        let temp = NSMenuItem(title: fanTempLine(), action: nil, keyEquivalent: "")
        temp.isEnabled = false
        menu.addItem(temp)
        fanTempItem = temp

        let rpm = NSMenuItem(title: fanRPMLine(), action: nil, keyEquivalent: "")
        rpm.isEnabled = false
        menu.addItem(rpm)
        fanRPMItem = rpm

        if fan.needsRecovery {
            let rec = NSMenuItem(title: "⚠ 检测到手动状态残留,点击恢复自动", action: #selector(fanRecover(_:)), keyEquivalent: "")
            rec.target = self
            menu.addItem(rec)
        }

        let modes: [(String, FanController.Mode)] = [("系统自动", .systemAuto), ("智能温控", .smart), ("手动调速", .manual)]
        for (title, m) in modes {
            let item = NSMenuItem(title: title, action: #selector(setFanMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: m.rawValue)
            item.state = fan.mode == m ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }

        if fan.mode == .smart {
            for preset in FanController.presets {
                let item = NSMenuItem(title: preset.key, action: #selector(setFanPreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.key
                item.state = fan.presetKey == preset.key ? .on : .off
                item.indentationLevel = 2
                menu.addItem(item)
            }
        }

        if fan.mode == .manual {
            for fanInfo in fan.fans {
                let item = NSMenuItem()
                item.view = makeFanSliderRow(index: fanInfo.index)
                menu.addItem(item)
            }
        }

        if let notice = fan.notice {
            let n = NSMenuItem(title: "· \(notice)", action: nil, keyEquivalent: "")
            n.isEnabled = false
            menu.addItem(n)
        }
    }

    private func makeFanSliderRow(index: Int) -> NSView {
        let width: CGFloat = 300
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 30))

        let label = NSTextField(labelWithString: "风扇\(index + 1)")
        label.frame = NSRect(x: 14, y: 8, width: 54, height: 16)
        label.font = NSFont.systemFont(ofSize: 11)
        container.addSubview(label)

        let pct = index < fan.manualPct.count ? fan.manualPct[index] : 0
        let slider = NSSlider(value: Double(pct), minValue: 0, maxValue: 1,
                              target: self, action: #selector(fanSliderChanged(_:)))
        slider.frame = NSRect(x: 72, y: 5, width: width - 134, height: 20)
        slider.isContinuous = true
        slider.identifier = NSUserInterfaceItemIdentifier(String(index))
        container.addSubview(slider)

        let rpm = index < fan.fans.count ? Int(fan.fans[index].current) : 0
        let valueLabel = NSTextField(labelWithString: "\(Int(pct * 100))% · \(rpm)RPM")
        valueLabel.frame = NSRect(x: width - 92, y: 8, width: 82, height: 16)
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.identifier = NSUserInterfaceItemIdentifier("fanPct\(index)")
        container.addSubview(valueLabel)

        return container
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
        models.refreshNow(forceRemote: true)
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

        buildFanSection(menu)

        buildModelSection(menu)

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

        let fix = NSMenuItem(title: "修复系统音频(无声/假死)", action: #selector(resetAudioService(_:)), keyEquivalent: "")
        fix.target = self
        menu.addItem(fix)

        let auto = NSMenuItem(title: fan.autoRepairInstalled ? "音频自动修复:已启用 ✓" : "音频自动修复:未启用",
                              action: #selector(toggleAutoRepair(_:)), keyEquivalent: "")
        auto.target = self
        menu.addItem(auto)

        let quit = NSMenuItem(title: "退出 GT 工具箱", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

    // MARK: - 风扇动作

    @objc private func setFanMode(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber,
              let m = FanController.Mode(rawValue: number.intValue) else { return }
        fan.setMode(m)
        rebuildMenu()
    }

    @objc private func setFanPreset(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        fan.setPreset(key)
        rebuildMenu()
    }

    @objc private func fanRecover(_ sender: NSMenuItem) {
        _ = fan.recoverAuto()
        rebuildMenu()
    }

    @objc private func resetAudioService(_ sender: NSMenuItem) {
        fan.resetCoreAudio()
        rebuildMenu()
    }

    @objc private func toggleAutoRepair(_ sender: NSMenuItem) {
        let enabling = !fan.autoRepairInstalled
        fan.setAutoRepair(enabling) { [weak self] in
            self?.rebuildMenu()
        }
    }

    @objc private func fanSliderChanged(_ sender: NSSlider) {
        guard let idString = sender.identifier?.rawValue, let index = Int(idString) else { return }
        fan.setManual(index, sender.doubleValue)
        let rpm = index < fan.fans.count ? Int(fan.fans[index].current) : 0
        if let container = sender.superview,
           let label = container.subviews.compactMap({ $0 as? NSTextField })
               .first(where: { $0.identifier?.rawValue == "fanPct\(index)" }) {
            label.stringValue = "\(Int(sender.doubleValue * 100))% · \(rpm)RPM"
        }
    }

    // MARK: - 本地模型动作

    @objc private func unloadModel(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String else { return }
        let parts = payload.components(separatedBy: "|")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if parts.count == 3, parts[0] == "remote" {
                self.models.unloadRemoteModel(parts[1], name: parts[2])
            } else if parts.count == 3, parts[0] == "local", let kind = ModelMonitor.Kind(rawValue: parts[1]) {
                self.models.unloadModel(kind: kind, name: parts[2])
            }
        }
    }

    @objc private func terminateRuntime(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = ModelMonitor.Kind(rawValue: raw) else { return }
        let alert = NSAlert()
        alert.messageText = "结束 \(kind.title) 进程?"
        alert.informativeText = "将向该运行时的所有进程发送终止信号,正在进行的推理会中断。"
        alert.addButton(withTitle: "结束进程")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.models.terminate(kind)
        }
    }

    @objc private func unloadAllModels(_ sender: NSMenuItem) {
        let endpoint = sender.representedObject as? String
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.models.unloadAllOllama(endpoint: endpoint)
        }
    }

    @objc private func keepAliveModels(_ sender: NSMenuItem) {
        let endpoint = sender.representedObject as? String
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.models.keepAliveOllama("30m", endpoint: endpoint)
        }
    }

    @objc private func openModelConsole(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let rt = models.runtimes.first(where: { $0.kind.rawValue == raw }) else { return }
        models.openConsole(rt)
    }

    @objc private func startModelService(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = ModelMonitor.Kind(rawValue: raw) else { return }
        if !models.startService(kind) {
            models.notice = "无法启动 \(kind.title),请确认已安装"
        }
        rebuildMenu()
    }

    // MARK: - 远程模型动作

    @objc private func addRemoteHost(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "添加远程主机"
        alert.informativeText = "格式:IP 或主机名[:端口],如 192.168.1.23:11434。\n支持 Ollama(11434)、LM Studio(1234)、llama.cpp(8080)、vLLM(8000)。\nWindows 端需把服务监听改为 0.0.0.0,并在防火墙放行对应端口。"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "192.168.1.23:11434"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let spec = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else { return }
        if models.addRemoteEndpoint(spec) {
            models.refreshNow(forceRemote: true)
        } else {
            models.notice = "无法解析地址「\(spec)」"
        }
        rebuildMenu()
    }

    @objc private func removeRemoteHost(_ sender: NSMenuItem) {
        guard let ep = sender.representedObject as? String else { return }
        models.removeRemoteEndpoint(ep)
        rebuildMenu()
    }

    @objc private func scanLAN(_ sender: NSMenuItem) {
        if models.startScan() {
            rebuildMenu()
        }
    }

    @objc private func addScanCandidate(_ sender: NSMenuItem) {
        guard let ep = sender.representedObject as? String else { return }
        _ = models.addRemoteEndpoint(ep)
        models.clearScanCandidates()
        models.refreshNow(forceRemote: true)
        rebuildMenu()
    }

    @objc private func openRemoteWeb(_ sender: NSMenuItem) {
        guard let ep = sender.representedObject as? String,
              let (host, port) = ModelMonitor.Runtime.parseEndpoint(ep) else { return }
        if let url = URL(string: ModelMonitor.Runtime.httpBase(host: host, port: port)) {
            NSWorkspace.shared.open(url)
        }
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
