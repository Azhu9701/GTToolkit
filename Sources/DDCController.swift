import Foundation
import CoreGraphics
import IOKit
import Darwin

// MARK: - 私有 IOAVService API(Apple Silicon DDC 通路,与 m1ddc / MonitorControl 同源)
// 这些符号分别随 IOKit / CoreDisplay 框架动态链接(CoreDisplay 在 SDK 中有 tbd 存根,
// 运行时由 dyld 共享缓存解析)。

@_silgen_name("IOAVServiceCreateWithService")
private func _IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<AnyObject>?

@_silgen_name("IOAVServiceReadI2C")
private func _IOAVServiceReadI2C(_ service: AnyObject, _ chipAddress: UInt32, _ offset: UInt32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
private func _IOAVServiceWriteI2C(_ service: AnyObject, _ chipAddress: UInt32, _ dataAddress: UInt32, _ data: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

@_silgen_name("CoreDisplay_DisplayCreateInfoDictionary")
private func _CoreDisplay_DisplayCreateInfoDictionary(_ displayID: CGDirectDisplayID) -> Unmanaged<CFDictionary>?

// 用自定义绑定控制返回值的 retain 语义(IORegistryEntrySearchCFProperty 返回 +1 的 CF 对象)
@_silgen_name("IORegistryEntrySearchCFProperty")
private func _IORegistryEntrySearchCFProperty(_ entry: io_registry_entry_t, _ plane: UnsafePointer<CChar>, _ key: CFString, _ allocator: CFAllocator?, _ options: IOOptionBits) -> Unmanaged<CFTypeRef>?

@_silgen_name("IORegistryEntryGetName")
@discardableResult
private func _IORegistryEntryGetName(_ entry: io_registry_entry_t, _ name: UnsafeMutablePointer<CChar>) -> IOReturn

private let ddcChipDefault: UInt32 = 0x37
private let ddcChipMCDP29XX: UInt32 = 0xB7
private let ddcInputAddress: UInt32 = 0x51
private let ddcInputAddressByte: UInt8 = 0x51
private let ddcWaitUS: useconds_t = 10_000
private let vcpVolume: UInt8 = 0x62   // VCP: Audio speaker volume
private let vcpMute: UInt8 = 0x8D     // VCP: Audio mute(1=静音, 2=取消)

/// 一台支持 DDC/CI 的显示器,可直控其喇叭音量(与显示器物理按钮等效)。
final class DDCDisplay {
    let displayID: CGDirectDisplayID
    let productName: String
    let manufacturer: String?
    private let service: AnyObject            // IOAVServiceRef(retained)
    private let chipAddress: UInt32
    private let ioQueue = DispatchQueue(label: "gt-volume.ddc-io")   // 串行化 I2C 访问

    init(displayID: CGDirectDisplayID, productName: String, manufacturer: String?,
         service: AnyObject, chipAddress: UInt32) {
        self.displayID = displayID
        self.productName = productName
        self.manufacturer = manufacturer
        self.service = service
        self.chipAddress = chipAddress
    }

    struct VCPValue: Equatable {
        let current: Int
        let max: Int
    }

    // MARK: - 公共接口

    /// 音量 0...1;读不到返回 nil。
    func volume() -> Float? {
        ioQueue.sync { _volume() }
    }

    @discardableResult
    func setVolume(_ v: Float) -> Bool {
        ioQueue.sync { _setVolume(v) }
    }

    /// true = 静音(VCP 0x8D 值 1);显示器不支持静音控制时返回 nil。
    func isMuted() -> Bool? {
        ioQueue.sync { _isMuted() }
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        ioQueue.sync { _setMuted(muted) }
    }

    func volumeAsync(_ completion: @escaping (Float?) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let v = self._volume()
            DispatchQueue.main.async { completion(v) }
        }
    }

    func setVolumeAsync(_ v: Float, completion: ((Bool) -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let ok = self._setVolume(v)
            if let completion { DispatchQueue.main.async { completion(ok) } }
        }
    }

    func setMutedAsync(_ muted: Bool, completion: ((Bool) -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let ok = self._setMuted(muted)
            if let completion { DispatchQueue.main.async { completion(ok) } }
        }
    }

    /// 读当前音量 + 静音状态(用于轮询显示器物理按键的改动)。
    func snapshotAsync(_ completion: @escaping (Float?, Bool?) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let vol = self._volume()
            let muted = self._isMuted()
            DispatchQueue.main.async { completion(vol, muted) }
        }
    }

    func changeVolumeAsync(by delta: Float, completion: ((Float?) -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard let cur = self._volume() else {
                DispatchQueue.main.async { completion?(nil) }
                return
            }
            let next = min(max(cur + delta, 0), 1)
            let ok = self._setVolume(next)
            DispatchQueue.main.async { completion?(ok ? next : nil) }
        }
    }

    // MARK: - 内部实现(必须在 ioQueue 上调用)

    private func _volume() -> Float? {
        guard let v = _getVCP(vcpVolume) else { return nil }
        return Float(v.current) / Float(max(v.max, 1))
    }

    private func _setVolume(_ v: Float) -> Bool {
        guard let m = _getVCP(vcpVolume)?.max else { return false }
        let target = Int((min(max(v, 0), 1) * Float(m)).rounded())
        return _setVCP(vcpVolume, target)
    }

    private func _isMuted() -> Bool? {
        guard let v = _getVCP(vcpMute) else { return nil }
        return v.current == 1
    }

    private func _setMuted(_ muted: Bool) -> Bool {
        _setVCP(vcpMute, muted ? 1 : 2)
    }

    /// DDC/CI Get VCP:先写请求 [0x82,0x01,code,校验],再读 12 字节回复;
    /// 回复的 [6..7] 为最大值、[8..9] 为当前值(大端)。
    private func _getVCP(_ code: UInt8, attempts: Int = 8) -> VCPValue? {
        for _ in 0..<attempts {
            usleep(ddcWaitUS)
            var req = [UInt8](repeating: 0, count: 8)
            req[0] = 0x82
            req[1] = 0x01
            req[2] = code
            req[3] = 0x6E ^ req[0] ^ req[1] ^ req[2]
            let wr = req.withUnsafeMutableBufferPointer { buf -> IOReturn in
                _IOAVServiceWriteI2C(service, chipAddress, ddcInputAddress, buf.baseAddress!, 4)
            }
            guard wr == KERN_SUCCESS else { continue }

            usleep(ddcWaitUS)
            var reply = [UInt8](repeating: 0, count: 12)
            let rd = reply.withUnsafeMutableBufferPointer { buf -> IOReturn in
                _IOAVServiceReadI2C(service, chipAddress, ddcInputAddress, buf.baseAddress!, 12)
            }
            guard rd == KERN_SUCCESS else { continue }

            let maxV = (Int(reply[6]) << 8) | Int(reply[7])
            let curV = (Int(reply[8]) << 8) | Int(reply[9])
            if maxV > 0 && curV <= maxV {
                return VCPValue(current: curV, max: maxV)
            }
        }
        return nil
    }

    /// DDC/CI Set VCP:写 [0x84,0x03,code,hi,lo,校验]。
    private func _setVCP(_ code: UInt8, _ value: Int, attempts: Int = 3) -> Bool {
        let clamped = max(0, min(value, 0xFFFF))
        for _ in 0..<attempts {
            usleep(ddcWaitUS)
            var req = [UInt8](repeating: 0, count: 8)
            req[0] = 0x84
            req[1] = 0x03
            req[2] = code
            req[3] = UInt8((clamped >> 8) & 0xFF)
            req[4] = UInt8(clamped & 0xFF)
            req[5] = 0x6E ^ ddcInputAddressByte ^ req[0] ^ req[1] ^ req[2] ^ req[3] ^ req[4]
            let wr = req.withUnsafeMutableBufferPointer { buf -> IOReturn in
                _IOAVServiceWriteI2C(service, chipAddress, ddcInputAddress, buf.baseAddress!, 6)
            }
            if wr == KERN_SUCCESS { return true }
        }
        return false
    }

    // MARK: - 显示器发现

    /// 枚举所有可通过 DCP DDC 控制的外接显示器。
    static func discover() -> [DDCDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }

        var result: [DDCDisplay] = []
        for i in 0..<Int(count) {
            guard let (adapter, name, manufacturer) = displayAttributes(ids[i]) else { continue }
            defer { IOObjectRelease(adapter) }
            guard let (service, chip) = ddcTransport(adapter: adapter) else { continue }
            result.append(DDCDisplay(displayID: ids[i], productName: name, manufacturer: manufacturer,
                                     service: service, chipAddress: chip))
        }
        return result
    }

    /// CGDisplayID → IORegistry adapter(含 EDID 产品名/厂商)。
    private static func displayAttributes(_ displayID: CGDirectDisplayID) -> (io_registry_entry_t, String, String?)? {
        guard let dict = _CoreDisplay_DisplayCreateInfoDictionary(displayID)?.takeRetainedValue() as? [String: Any],
              let ioLocation = dict["IODisplayLocation"] as? String,
              dict["kCGDisplayUUID"] != nil else { return nil }

        let adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, ioLocation as CFString)
        guard adapter != 0 else { return nil }

        var name = "未知显示器"
        var manufacturer: String?
        if let attrsRef = _IORegistryEntrySearchCFProperty(adapter, kIOServicePlane, "DisplayAttributes" as CFString,
                                                           kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) {
            let attrs = attrsRef.takeRetainedValue() as? [String: Any]
            if let product = attrs?["ProductAttributes"] as? [String: Any] {
                name = product["ProductName"] as? String ?? name
                manufacturer = product["ManufacturerID"] as? String
            }
        }
        return (adapter, name, manufacturer)
    }

    /// adapter → 同注册表 ID 的 IOMobileFramebuffer → DCPAVServiceProxy(External)→ IOAVService
    private static func ddcTransport(adapter: io_registry_entry_t) -> (AnyObject, UInt32)? {
        var adapterID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(adapter, &adapterID) == KERN_SUCCESS else { return nil }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }

        var iter: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var framebufferMatches = false
        while true {
            let service = IOIteratorNext(iter)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            if IOObjectConformsTo(service, "IOMobileFramebuffer") != 0 {
                var id: UInt64 = 0
                framebufferMatches = IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS && id == adapterID
                continue
            }

            var nameBuf = [CChar](repeating: 0, count: 128)
            _IORegistryEntryGetName(service, &nameBuf)
            guard framebufferMatches, String(cString: nameBuf) == "DCPAVServiceProxy" else { continue }

            guard let avRef = _IOAVServiceCreateWithService(kCFAllocatorDefault, service)?.takeRetainedValue() else { continue }

            let locationRef = _IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Location" as CFString,
                                                               kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively))
            let location = locationRef?.takeRetainedValue() as? String
            guard location == "External" else { continue }

            var chip = ddcChipDefault
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
                defer { IOObjectRelease(parent) }
                if let providerRef = _IORegistryEntrySearchCFProperty(parent, kIOServicePlane, "EPICProviderClass" as CFString,
                                                                      kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) {
                    let provider = providerRef.takeRetainedValue() as? String
                    if provider == "AppleDCPMCDP29XX" { chip = ddcChipMCDP29XX }
                }
            }
            return (avRef, chip)
        }
        return nil
    }
}
