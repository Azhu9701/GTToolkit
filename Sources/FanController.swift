import Foundation
import AppKit
import Darwin

/// 智能风扇管理:SMC 直读温度与转速,风扇控制键(F0Md/F0Tg)的写入需要 root,
/// 通过内嵌特权助手 gt-fanctl(本地 socket 白名单命令)完成。
/// 安全策略:转速钳制在 [Fmin, Fmax];连接断开助手自动恢复系统自动;退出 App 兜底恢复。
final class FanController: NSObject {
    static let shared = FanController()

    enum Mode: Int {
        case systemAuto = 0
        case smart
        case manual
    }

    struct Preset {
        let key: String
        let start: Double    // 开始升速温度
        let full: Double     // 达到满速温度
        let floor: Double    // 最低转速占比
    }

    static let presets: [Preset] = [
        Preset(key: "安静", start: 62, full: 85, floor: 0.00),
        Preset(key: "均衡", start: 55, full: 78, floor: 0.05),
        Preset(key: "性能", start: 48, full: 70, floor: 0.15),
    ]

    struct FanSnapshot {
        var index: Int
        var current: Double
        var min: Double
        var max: Double
        var forced: Bool
    }

    private let smc = SMCLite.Connection()
    private(set) var available = false
    private(set) var fans: [FanSnapshot] = []
    private(set) var tempKeys: [(key: String, type: String)] = []
    private(set) var hottestTemp: Double = 0
    private(set) var hottestKey = ""
    private(set) var mode: Mode = .systemAuto
    private(set) var presetKey = "均衡"
    private(set) var manualPct: [Double] = []
    private(set) var connected = false
    private(set) var needsRecovery = false   // 启动时发现残留的强制模式
    private(set) var notice: String?

    var onUpdate: (() -> Void)?

    private var timer: Timer?
    private var sockFD: Int32 = -1
    private var lastTargetRPM: [Double] = []
    private var emergencyActive = false

    private var socketPath: String { "/tmp/gt-fanctl-\(getuid()).sock" }
    private var helperPath: String {
        Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("gt-fanctl").path ?? "gt-fanctl"
    }

    /// 常驻守护(launchd)是否已安装——安装后唤醒自动修复生效,且风扇控制不再弹授权。
    var autoRepairInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.sounds.gtfanctl.plist")
    }

    // MARK: - 生命周期

    func start() {
        available = smc.openSMC()
        guard available else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.tempKeys = self.smc.discoverTemperatureKeys()
            self.refreshFans()

            // 恢复上次的风扇模式(常驻守护在位时静默完成,否则提示手动开启)
            let savedMode = Mode(rawValue: UserDefaults.standard.integer(forKey: "gtFanMode")) ?? .systemAuto
            if savedMode != .systemAuto {
                if self.autoRepairInstalled, self.ensureHelper() {
                    self.mode = savedMode
                    self.presetKey = UserDefaults.standard.string(forKey: "gtFanPreset") ?? self.presetKey
                    if let pct = UserDefaults.standard.array(forKey: "gtFanManualPct") as? [Double],
                       pct.count == self.fans.count {
                        self.manualPct = pct
                    }
                    for f in self.fans { self.queueSend("MODE \(f.index) 1") }
                    self.lastTargetRPM = self.fans.map { $0.current }
                    if self.mode == .smart { self.applySmart() }
                } else {
                    self.notice = "上次的风扇模式未自动恢复,请重新开启"
                }
            } else if self.fans.contains(where: { $0.forced }) {
                self.needsRecovery = true
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.timer == nil else { return }
                self.timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
                self.onUpdate?()
            }
        }
    }

    /// 退出 App 时调用:恢复系统自动再断开(有 2 秒 socket 超时兜底)。
    func shutdown() {
        if connected {
            helperQueue.sync { [weak self] in
                guard let self else { return }
                _ = self.send("ALLAUTO")
                self.closeSocket()
            }
        }
        smc.closeSMC()
    }

    private func poll() {
        refreshFans()
        readHottestTemp()
        if mode == .smart { applySmart() }
        checkEmergency()
        onUpdate?()
    }

    // MARK: - 读取

    private func refreshFans() {
        var result: [FanSnapshot] = []
        let count = min(Int(smc.readUInt8("FNum") ?? 0), 8)
        for i in 0..<count {
            result.append(FanSnapshot(index: i,
                                      current: smc.readRPM("F\(i)Ac") ?? 0,
                                      min: smc.readRPM("F\(i)Mn") ?? 0,
                                      max: smc.readRPM("F\(i)Mx") ?? 0,
                                      forced: (smc.readUInt8("F\(i)Md") ?? 0) == 1))
        }
        fans = result
    }

    private func readHottestTemp() {
        var best = 0.0
        var bestKey = ""
        for (key, type) in tempKeys {
            guard let b = smc.read(key), let v = SMCLite.decodeTemp(type, b), v > best else { continue }
            best = v
            bestKey = key
        }
        hottestTemp = best
        hottestKey = bestKey
    }

    // MARK: - 模式

    func setMode(_ m: Mode) {
        switch m {
        case .systemAuto:
            if connected {
                helperQueue.async { [weak self] in
                    guard let self else { return }
                    _ = self.send("ALLAUTO")
                    self.closeSocket()
                }
            }
            mode = .systemAuto
            notice = nil
            needsRecovery = false
        case .smart, .manual:
            guard ensureHelper() else {
                notice = "风扇控制需要管理员授权(取消或失败)"
                onUpdate?()
                return
            }
            mode = m
            notice = nil
            needsRecovery = false
            for fan in fans { queueSend("MODE \(fan.index) 1") }
            lastTargetRPM = fans.map { $0.current }
            if m == .manual {
                manualPct = fans.map { min(max(($0.current - $0.min) / max($0.max - $0.min, 1), 0), 1) }
            } else {
                applySmart()
            }
        }
        saveState()
        onUpdate?()
    }

    func setPreset(_ key: String) {
        presetKey = key
        if mode == .smart {
            lastTargetRPM = fans.map { $0.current }
            applySmart()
        }
        saveState()
        onUpdate?()
    }

    func setManual(_ index: Int, _ pct: Double) {
        guard mode == .manual, index < fans.count, index < manualPct.count else { return }
        manualPct[index] = min(max(pct, 0), 1)
        let fan = fans[index]
        let rpm = fan.min + (fan.max - fan.min) * manualPct[index]
        queueSend("RPM \(index) \(Int(rpm.rounded()))")
        setLastTarget(index, rpm)
        saveState()
    }

    /// 启动时发现残留强制状态时的恢复入口(需要授权)。
    func recoverAuto() -> Bool {
        guard ensureHelper() else {
            notice = "恢复自动模式需要管理员授权"
            onUpdate?()
            return false
        }
        queueSend("ALLAUTO")
        helperQueue.async { [weak self] in self?.closeSocket() }
        needsRecovery = false
        mode = .systemAuto
        onUpdate?()
        return true
    }

    /// 重启系统音频服务,修复 DP 音频假死导致的系统级无声(播放报 AudioQueueStart failed)。
    /// 首次使用会弹一次管理员授权;重启后所有正在播放的流会中断,重新播放即可。
    @discardableResult
    func resetCoreAudio() -> Bool {
        guard ensureHelper() else {
            notice = "修复音频需要管理员授权"
            onUpdate?()
            return false
        }
        queueSend("AUDIO-RESET")
        notice = "已请求重启音频服务,几秒后重新播放即可"
        onUpdate?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.notice == "已请求重启音频服务,几秒后重新播放即可" {
                self?.notice = nil
                self?.onUpdate?()
            }
        }
        return true
    }

    // MARK: - 智能温控

    private func applySmart() {
        guard let preset = FanController.presets.first(where: { $0.key == presetKey }) else { return }
        var frac = (hottestTemp - preset.start) / (preset.full - preset.start)
        frac = min(max(frac, 0), 1)
        frac = max(frac, preset.floor)
        if hottestTemp >= 90 { frac = 1 }   // 高温保护

        for fan in fans {
            let span = max(fan.max - fan.min, 1)
            var target = fan.min + span * frac
            let last = fan.index < lastTargetRPM.count ? lastTargetRPM[fan.index] : fan.current
            target = min(max(target, last - 800), last + 800)   // 每步限速 800 RPM,避免转速跳变
            target = min(max(target, fan.min), fan.max)
            if abs(target - last) < 40 { continue }             // 迟滞,避免频繁写入
            queueSend("RPM \(fan.index) \(Int(target.rounded()))")
            setLastTarget(fan.index, target)
        }
    }

    /// 手动/智能模式下的高温兜底:≥95°C 直接全速。
    private func checkEmergency() {
        guard mode != .systemAuto else { return }
        if hottestTemp >= 95 {
            for fan in fans { queueSend("RPM \(fan.index) \(Int(fan.max))") }
            if !emergencyActive {
                emergencyActive = true
                notice = "高温保护(\(String(format: "%.0f", hottestTemp))°C):已全速"
            }
        } else if emergencyActive, hottestTemp < 90 {
            emergencyActive = false
            notice = nil
        }
    }

    private func setLastTarget(_ index: Int, _ rpm: Double) {
        while lastTargetRPM.count <= index { lastTargetRPM.append(0) }
        lastTargetRPM[index] = rpm
    }

    // MARK: - 状态持久化(App 重启后恢复上次风扇模式)

    private func saveState() {
        let d = UserDefaults.standard
        d.set(mode.rawValue, forKey: "gtFanMode")
        d.set(presetKey, forKey: "gtFanPreset")
        d.set(manualPct, forKey: "gtFanManualPct")
    }

    // MARK: - 特权助手通信
    //
    // 所有 socket 收发都在 helperQueue(串行)上执行。助手可能被音频探测等
    // 长操作占住不读数据,阻塞式 send 会把调用线程冻住——曾经把主线程卡死、
    // 菜单完全无响应的主因。绝不能在主线程直接调 send(_:)。

    private let helperQueue = DispatchQueue(label: "gt.fanctl-client", qos: .userInitiated)
    private var consecutiveFailures = 0

    private func ensureHelper() -> Bool {
        if connected { return true }
        if connectSocket() {
            connected = true
            return true
        }
        if autoRepairInstalled {
            // 常驻守护由 launchd 拉起(KeepAlive),等待重连即可,绝不弹窗
            var waited = 0.0
            while waited < 5.0 {
                usleep(300_000)
                waited += 0.3
                if connectSocket() {
                    connected = true
                    return true
                }
            }
            notice = "守护进程未响应,可尝试重新启用音频自动修复"
            return false
        }
        guard spawnHelper() else {
            notice = "授权取消或失败"
            return false
        }
        var waited = 0.0
        while waited < 3.0 {
            if connectSocket() {
                connected = true
                return true
            }
            usleep(100_000)
            waited += 0.1
        }
        notice = "助手连接失败"
        return false
    }

    /// 弹出管理员授权并拉起 root 助手(AuthorizationExecuteWithPrivileges)。
    // MARK: - 特权执行(标准管理员授权弹窗)

    private func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func appLog(_ s: String) {
        let line = "(\(Date())) \(s)\n"
        let p = "/tmp/gt-fanctl-app.log"
        if let fh = FileHandle(forWritingAtPath: p) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            fh.closeFile()
        } else {
            try? line.write(toFile: p, atomically: true, encoding: .utf8)
        }
    }

    /// 通过 osascript 管理员授权以 root 执行 shell 命令(会弹标准密码框)。
    private func runAsRoot(_ command: String) -> (ok: Bool, stderr: String) {
        let script = "do shell script \"\(command)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        guard (try? p.run()) != nil else {
            return (false, "osascript 无法启动")
        }
        p.waitUntilExit()
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, err.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func spawnHelper() -> Bool {
        guard FileManager.default.fileExists(atPath: helperPath) else {
            notice = "助手程序缺失(gt-fanctl)"
            return false
        }
        // 守护常驻不退出,后台化并丢弃输出,让 osascript 立即返回
        let (ok, err) = runAsRoot("\(shQuote(helperPath)) daemon \(shQuote(socketPath)) \(getuid()) > /dev/null 2>&1 &")
        appLog("spawnHelper ok=\(ok) err=\(err)")
        if !ok, notice == nil { notice = "授权取消或失败: \(err)" }
        return ok
    }

    /// 启用/停用音频自动修复:把助手安装为常驻 LaunchDaemon(唤醒后自动探测修复),或卸载。
    func setAutoRepair(_ enabled: Bool, completion: (() -> Void)? = nil) {
        appLog("toggle autoRepair enabled=\(enabled)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: self.helperPath) else {
                DispatchQueue.main.async {
                    self.notice = "助手程序缺失(gt-fanctl)"
                    self.onUpdate?()
                    completion?()
                }
                return
            }
            let cmd = enabled
                ? "\(self.shQuote(self.helperPath)) install \(getuid()) \(self.shQuote(self.helperPath))"
                : "\(self.shQuote(self.helperPath)) uninstall"
            let (ok, err) = self.runAsRoot(cmd)
            self.appLog("install ok=\(ok) err=\(err)")

            var notice: String
            if !ok {
                notice = "授权失败: \(err.isEmpty ? "已取消" : err)"
            } else if enabled {
                var waited = 0.0
                while waited < 4.0, !self.autoRepairInstalled {
                    usleep(200_000)
                    waited += 0.2
                }
                notice = self.autoRepairInstalled
                    ? "音频自动修复已启用(每次唤醒后自动检测)"
                    : "安装未确认,详见 /tmp/gt-fanctl-install.log"
            } else {
                notice = "音频自动修复已关闭"
            }
            DispatchQueue.main.async {
                self.notice = notice
                self.onUpdate?()
                completion?()
            }
        }
    }

    private func connectSocket() -> Bool {
        guard sockFD < 0 else { return true }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < 104 else { close(fd); return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: UInt8.self, capacity: 104) { p in
                for (i, b) in pathBytes.enumerated() { p[i] = b }
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return false
        }
        // 收发超时:助手被长操作占住时命令在 2 秒内失败重试,而不是无限阻塞
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        sockFD = fd
        return true
    }

    /// 把命令投递到后台串行队列执行(需要按序的多条命令各自 queueSend 即可,
    /// helperQueue 是串行的)。自动重连:断线后下一条命令会尝试重新连接。
    private func queueSend(_ line: String) {
        helperQueue.async { [weak self] in
            guard let self else { return }
            if !self.connected { self.connected = self.connectSocket() }
            _ = self.send(line)
        }
    }

    /// 同步发送。只能在 helperQueue 上调用(shutdown 走 helperQueue.sync 例外)。
    @discardableResult
    private func send(_ line: String) -> Bool {
        guard sockFD >= 0 else { return false }
        var bytes = Array((line + "\n").utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { p in
                Darwin.send(sockFD, p.baseAddress! + sent, bytes.count - sent, 0)
            }
            guard n > 0 else {
                handleSendFailure()
                return false
            }
            sent += n
        }
        consecutiveFailures = 0
        return true
    }

    /// 仅在 helperQueue 上调用。超时/断连先关 socket 逼助手段开时自行恢复自动;
    /// 连续多次失败才在 UI 上降级,避免助手短暂忙碌导致模式来回跳。
    private func handleSendFailure() {
        closeSocket()
        consecutiveFailures += 1
        if consecutiveFailures == 3, mode != .systemAuto {
            mode = .systemAuto
            notice = "助手持续无响应,已恢复系统自动"
            DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
        }
    }

    private func closeSocket() {
        guard sockFD >= 0 else { return }
        close(sockFD)
        sockFD = -1
        connected = false
    }
}
