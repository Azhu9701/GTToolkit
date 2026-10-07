import Foundation
import CoreAudio
import CoreGraphics

/// 统一音量目标管理:把「系统默认输出」映射到 CoreAudio 设备音量,
/// 或(设备无音量控制时,如 DP 显示器)映射到对应显示器的 DDC 喇叭控制。
final class VolumeManager: NSObject {
    static let shared = VolumeManager()

    enum TargetID: Equatable {
        case followDefault
        case audioDevice(AudioDeviceID)
        case ddcDisplay(CGDirectDisplayID)
    }

    struct Resolved {
        enum Kind {
            case audio(AudioDeviceID)
            case ddc(DDCDisplay)
        }
        let kind: Kind
        let displayName: String
        let isDefaultPath: Bool
    }

    private let audio = AudioController.shared
    private(set) var ddcDisplays: [DDCDisplay] = []
    var pinned: TargetID = .followDefault
    private(set) var resolved: Resolved?

    /// vol/muted 为 nil 表示设备结构变了需要重新读取;有值 = DDC 轮询快照。
    var onUpdate: ((Float?, Bool?) -> Void)?
    var onAudioChange: (() -> Void)?

    private var observedAudio: AudioDeviceID = 0
    private var lastDDCSnapshot: (vol: Int, muted: Int)?
    private var pollCount = 0

    // MARK: - 生命周期

    func install() {
        audio.observeSystem(
            onDefaultChange: { [weak self] in DispatchQueue.main.async { self?.refreshAndNotify() } },
            onDeviceListChange: { [weak self] in DispatchQueue.main.async { self?.refreshAndNotify() } })
        startPolling()
    }

    /// 首次启动:优先锁定华为显示器;若它已是默认输出则跟随默认。
    func resolveInitialTarget() {
        refresh()
        let defaultResolved = resolveDefault()
        let huaweiDDC = ddcDisplays.first { d in
            let maker = (d.manufacturer ?? "").lowercased()
            let name = d.productName.lowercased()
            return maker == "hwv" || name.contains("huawei") || name.contains("mateview")
        }
        if let hw = huaweiDDC {
            if case .ddc(let d)? = defaultResolved?.kind, d.displayID == hw.displayID {
                pinned = .followDefault
            } else {
                pinned = .ddcDisplay(hw.displayID)
            }
        } else {
            pinned = .followDefault
        }
        resolve()
    }

    func refresh() {
        ddcDisplays = DDCDisplay.discover()
        resolve()
    }

    private let discoveryQueue = DispatchQueue(label: "gt.ddc-discovery", qos: .userInitiated)

    /// 异步重发现显示器。DDCDisplay.discover(建 IOAVService、走 IORegistry)在主线程
    /// 同步执行会卡数百毫秒——显示器睡眠/切源时更久,是「点击菜单没反应」的主因,
    /// 严禁在菜单打开等交互路径上同步调用。
    func refreshAsync(_ completion: (() -> Void)? = nil) {
        discoveryQueue.async { [weak self] in
            let displays = DDCDisplay.discover()
            DispatchQueue.main.async {
                guard let self else { completion?(); return }
                self.ddcDisplays = displays
                self.resolve()
                completion?()
            }
        }
    }

    private func refreshAndNotify() {
        refreshAsync { [weak self] in self?.onUpdate?(nil, nil) }
    }

    // MARK: - 目标解析

    private func resolve() {
        switch pinned {
        case .followDefault:
            resolved = resolveDefault()
        case .audioDevice(let id):
            guard audio.allOutputDevices().contains(where: { $0.id == id }) else {
                pinned = .followDefault
                resolve()
                return
            }
            resolved = Resolved(kind: .audio(id), displayName: audio.deviceName(id),
                                isDefaultPath: id == audio.defaultOutputDeviceID())
        case .ddcDisplay(let did):
            guard let ddc = ddcDisplays.first(where: { $0.displayID == did }) else {
                pinned = .followDefault
                resolve()
                return
            }
            resolved = Resolved(kind: .ddc(ddc), displayName: ddc.productName, isDefaultPath: false)
        }
        syncAudioObservation()
    }

    private func resolveDefault() -> Resolved? {
        guard let def = audio.defaultOutputDeviceID() else { return nil }
        if audio.hasVolumeControl(def) {
            return Resolved(kind: .audio(def), displayName: audio.deviceName(def), isDefaultPath: true)
        }
        // 默认输出无音量控制(典型:DP 显示器音频)→ 映射到同名显示器喇叭(DDC)
        let name = audio.deviceName(def)
        if let ddc = matchDisplay(forAudioDeviceName: name) {
            return Resolved(kind: .ddc(ddc), displayName: ddc.productName, isDefaultPath: true)
        }
        return Resolved(kind: .audio(def), displayName: name, isDefaultPath: true)
    }

    private func matchDisplay(forAudioDeviceName name: String) -> DDCDisplay? {
        let lower = name.lowercased()
        if let exact = ddcDisplays.first(where: { $0.productName.lowercased() == lower }) { return exact }
        if let huawei = ddcDisplays.first(where: {
            let productName = $0.productName.lowercased()
            let maker = ($0.manufacturer ?? "").lowercased()
            return productName.contains("huawei") || productName.contains("mateview")
                || maker.contains("hwv") || maker.contains("huawei")
        }) { return huawei }
        return ddcDisplays.count == 1 ? ddcDisplays[0] : nil
    }

    private func syncAudioObservation() {
        var id: AudioDeviceID = 0
        if let r = resolved, case .audio(let a) = r.kind { id = a }
        if id != observedAudio {
            observedAudio = id
            audio.observe(deviceID: id) { [weak self] in
                DispatchQueue.main.async { self?.onAudioChange?() }
            }
        }
    }

    // MARK: - 音量操作

    var hasTarget: Bool { resolved != nil }

    /// 有音量控制的 CoreAudio 输出设备(无音量控制的 DP 显示器设备由 DDC 部分覆盖)。
    func controllableAudioDevices() -> [OutputDevice] {
        audio.allOutputDevices().filter { audio.hasVolumeControl($0.id) }
    }

    var hasVolumeControl: Bool {
        guard let r = resolved else { return false }
        switch r.kind {
        case .audio(let id): return audio.hasVolumeControl(id)
        case .ddc: return true
        }
    }

    func volume() -> Float? {
        guard let r = resolved else { return nil }
        switch r.kind {
        case .audio(let id): return audio.volume(of: id)
        case .ddc(let d): return d.volume()
        }
    }

    /// 供菜单/图标等交互路径使用的缓存读数:音频设备直读(CoreAudio 属性,微秒级),
    /// DDC 用最近一次轮询快照——避免在主线程做同步 I2C 读(单次可达数百毫秒)。
    func cachedVolume() -> Float? {
        guard let r = resolved else { return nil }
        switch r.kind {
        case .audio(let id): return audio.volume(of: id)
        case .ddc(let d):
            guard let snap = lastDDCSnapshot, snap.vol >= 0 else { return nil }
            return Float(snap.vol) / 100
        }
    }

    func cachedMuted() -> Bool? {
        guard let r = resolved else { return nil }
        switch r.kind {
        case .audio(let id): return audio.isMuted(id)
        case .ddc(let d):
            guard let snap = lastDDCSnapshot else { return nil }
            if snap.muted >= 0 { return snap.muted == 1 }
            return snap.vol == 0   // 不支持静音控制时以音量 0 视为静音
        }
    }

    func setVolume(_ v: Float, completion: ((Bool) -> Void)? = nil) {
        guard let r = resolved else { completion?(false); return }
        switch r.kind {
        case .audio(let id):
            let ok = audio.setVolume(v, of: id)
            if ok, audio.isMuted(id) == true { audio.setMuted(false, of: id) }
            completion?(ok)
        case .ddc(let d):
            enqueueDDCVolume(v, display: d, completion: completion)
        }
    }

    /// DDC 写入串行合并:拖动滑杆时只保留最新目标值。
    private var ddcWriteInFlight = false
    private var ddcPendingVolume: Float?

    private func enqueueDDCVolume(_ v: Float, display: DDCDisplay, completion: ((Bool) -> Void)?) {
        ddcPendingVolume = v
        guard !ddcWriteInFlight else { completion?(true); return }
        ddcWriteInFlight = true
        flushPendingDDC(display, completion: completion ?? { _ in })
    }

    private func flushPendingDDC(_ d: DDCDisplay, completion: @escaping (Bool) -> Void) {
        guard let v = ddcPendingVolume else {
            ddcWriteInFlight = false
            completion(false)
            return
        }
        ddcPendingVolume = nil
        d.setVolumeAsync(v) { [weak self] _ in
            guard let self else { return }
            self.updateDDCSnapshot(volume: v)
            if self.ddcPendingVolume != nil, self.ddcWriteInFlight {
                self.flushPendingDDC(d, completion: completion)
            } else {
                self.ddcWriteInFlight = false
                completion(true)
            }
        }
    }

    func changeVolume(by delta: Float, completion: ((Float?) -> Void)? = nil) {
        guard let r = resolved else { completion?(nil); return }
        switch r.kind {
        case .audio(let id):
            let cur = audio.volume(of: id) ?? 0
            let next = min(max(cur + delta, 0), 1)
            if (audio.isMuted(id) ?? false) && next > 0 { audio.setMuted(false, of: id) }
            let ok = audio.setVolume(next, of: id)
            DispatchQueue.main.async { completion?(ok ? next : nil) }
        case .ddc(let d):
            d.changeVolumeAsync(by: delta) { [weak self] new in
                if let new { self?.updateDDCSnapshot(volume: new) }
                completion?(new)
            }
        }
    }

    func isMuted() -> Bool? {
        guard let r = resolved else { return nil }
        switch r.kind {
        case .audio(let id): return audio.isMuted(id)
        case .ddc(let d):
            if let m = d.isMuted() { return m }
            return (d.volume() ?? 1) == 0   // 不支持静音控制时以音量 0 视为静音
        }
    }

    private var preMuteVolume: Float?

    func setMuted(_ muted: Bool, completion: ((Bool) -> Void)? = nil) {
        guard let r = resolved else { completion?(false); return }
        switch r.kind {
        case .audio(let id):
            completion?(audio.setMuted(muted, of: id))
        case .ddc(let d):
            d.setMutedAsync(muted) { [weak self] ok in
                guard let self else { return }
                self.updateDDCSnapshot(muted: muted)
                if !ok {
                    // 显示器不支持静音 VCP:用音量 0 模拟
                    if muted {
                        let v = self.cachedVolume() ?? 0
                        if v > 0 {
                            self.preMuteVolume = v
                            d.setVolumeAsync(0) { [weak self] _ in
                                self?.updateDDCSnapshot(volume: 0)
                            }
                        }
                    } else if let v = self.preMuteVolume {
                        self.preMuteVolume = nil
                        d.setVolumeAsync(v) { [weak self] _ in
                            self?.updateDDCSnapshot(volume: v)
                        }
                    }
                }
                completion?(ok)
            }
        }
    }

    // MARK: - DDC 轮询(捕获显示器物理按键改动)

    private func startPolling() {
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.pollTick() }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 把一次 DDC 读取结果写入缓存快照;返回是否与上次不同。
    @discardableResult
    private func storeDDCSnapshot(_ vol: Float?, _ muted: Bool?) -> Bool {
        let volKey = vol.map { Int($0 * 100) } ?? -1
        let muteKey = muted.map { $0 ? 1 : 0 } ?? -1
        let changed = (volKey, muteKey) != (lastDDCSnapshot?.vol ?? -2, lastDDCSnapshot?.muted ?? -2)
        lastDDCSnapshot = (volKey, muteKey)
        return changed
    }

    /// 写入后的乐观更新(不等下次轮询,滑杆/图标立刻跟上)。
    private func updateDDCSnapshot(volume v: Float? = nil, muted m: Bool? = nil) {
        var volKey = lastDDCSnapshot?.vol ?? -1
        var muteKey = lastDDCSnapshot?.muted ?? -1
        if let v { volKey = Int(v * 100) }
        if let m { muteKey = m ? 1 : 0 }
        lastDDCSnapshot = (volKey, muteKey)
    }

    /// 菜单打开时主动刷新一次 DDC 快照(异步),结果就地更新 UI。
    func refreshVolumeSnapshot() {
        guard let r = resolved, case .ddc(let d) = r.kind else { return }
        d.snapshotAsync { [weak self] vol, muted in
            guard let self else { return }
            self.storeDDCSnapshot(vol, muted)
            self.onUpdate?(vol, muted)
        }
    }

    private func pollTick() {
        pollCount += 1
        if pollCount % 5 == 0 {
            // 慢速重新发现设备(插拔显示器)——异步,不占主线程
            refreshAndNotify()
            return
        }
        guard let r = resolved, case .ddc(let ddc) = r.kind else { return }
        ddc.snapshotAsync { [weak self] vol, muted in
            guard let self else { return }
            if self.storeDDCSnapshot(vol, muted) {
                self.onUpdate?(vol, muted)
            }
        }
    }
}
