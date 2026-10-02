import Foundation
import CoreAudio

struct OutputDevice: Equatable {
    let id: AudioDeviceID
    let name: String
    let manufacturer: String?
    let transport: String?
}

/// 封装 CoreAudio 输出设备的音量/静音读写与属性监听。
/// 读写的是 macOS 系统音量属性本身,与键盘音量键、控制中心操作的是同一份数据,因此天然双向同步。
final class AudioController {
    static let shared = AudioController()
    private init() {}

    private var systemTokens: [ListenerToken] = []
    private var deviceTokens: [ListenerToken] = []

    // MARK: - 设备查询

    func allOutputDevices() -> [OutputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let ids = getUIntArray(system, kAudioHardwarePropertyDevices) else { return [] }
        return ids
            .map { AudioDeviceID($0) }
            .filter { isOutputDevice($0) }
            .map {
                OutputDevice(id: $0,
                             name: deviceName($0),
                             manufacturer: manufacturerName($0),
                             transport: transportName($0))
            }
    }

    func isOutputDevice(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    func defaultOutputDeviceID() -> AudioDeviceID? {
        let id = getUInt(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0
        return id != 0 ? AudioDeviceID(id) : nil
    }

    func deviceName(_ id: AudioDeviceID) -> String {
        readCFString(id, kAudioObjectPropertyName) ?? "未知设备"
    }

    func manufacturerName(_ id: AudioDeviceID) -> String? {
        readCFString(id, kAudioObjectPropertyManufacturer)
    }

    func transportName(_ id: AudioDeviceID) -> String? {
        switch getUInt(id, kAudioDevicePropertyTransportType) ?? 0 {
        case kAudioDeviceTransportTypeBuiltIn: return "内建"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "蓝牙"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        default: return nil
        }
    }

    // MARK: - 音量 / 静音

    /// 扫描 element 0(master)与 1...15,返回带音量控制的通道。显示器音频一般是 0 或 1/2 两通道。
    private func volumeElements(_ id: AudioDeviceID) -> [UInt32] {
        elementsWithControl(id, kAudioDevicePropertyVolumeScalar)
    }

    private func elementsWithControl(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> [UInt32] {
        var result: [UInt32] = []
        for element: UInt32 in 0...15 {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
                  size >= UInt32(MemoryLayout<Float>.size) else { continue }
            result.append(element)
        }
        return result
    }

    func hasVolumeControl(_ id: AudioDeviceID) -> Bool {
        volumeElements(id).contains { element in
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            var settable = DarwinBoolean(false)
            return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
        }
    }

    /// 多通道设备取各通道平均值作为当前音量。
    func volume(of id: AudioDeviceID) -> Float? {
        let elements = volumeElements(id)
        guard !elements.isEmpty else { return nil }
        var sum: Float = 0
        var count = 0
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            var value: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr {
                sum += value
                count += 1
            }
        }
        return count > 0 ? sum / Float(count) : nil
    }

    /// 对所有可写通道统一写入。
    @discardableResult
    func setVolume(_ value: Float, of id: AudioDeviceID) -> Bool {
        let clamped = min(max(value, 0), 1)
        var ok = false
        for element in volumeElements(id) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { continue }
            var v = clamped
            if AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &v) == noErr {
                ok = true
            }
        }
        return ok
    }

    /// 任一通道静音即视为静音。
    func isMuted(_ id: AudioDeviceID) -> Bool? {
        let elements = elementsWithControl(id, kAudioDevicePropertyMute)
        guard !elements.isEmpty else { return nil }
        var muted = false
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, value != 0 {
                muted = true
            }
        }
        return muted
    }

    @discardableResult
    func setMuted(_ muted: Bool, of id: AudioDeviceID) -> Bool {
        var ok = false
        for element in elementsWithControl(id, kAudioDevicePropertyMute) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { continue }
            var value: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
                ok = true
            }
        }
        return ok
    }

    // MARK: - 属性监听

    /// 监听系统级变化:默认输出设备切换、设备列表增删。
    func observeSystem(onDefaultChange: @escaping () -> Void,
                       onDeviceListChange: @escaping () -> Void) {
        let system = AudioObjectID(kAudioObjectSystemObject)

        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let defaultBlock: AudioObjectPropertyListenerBlock = { _, _ in onDefaultChange() }
        if AudioObjectAddPropertyListenerBlock(system, &defaultAddress, .main, defaultBlock) == noErr {
            systemTokens.append(ListenerToken(objectID: system, address: defaultAddress, queue: .main, block: defaultBlock))
        }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let devicesBlock: AudioObjectPropertyListenerBlock = { _, _ in onDeviceListChange() }
        if AudioObjectAddPropertyListenerBlock(system, &devicesAddress, .main, devicesBlock) == noErr {
            systemTokens.append(ListenerToken(objectID: system, address: devicesAddress, queue: .main, block: devicesBlock))
        }
    }

    /// 监听指定设备的音量/静音变化(键盘音量键、其他 App 修改都会触发)。
    func observe(deviceID: AudioDeviceID, onChange: @escaping () -> Void) {
        deviceTokens.forEach { $0.remove() }
        deviceTokens.removeAll()
        guard deviceID != 0 else { return }

        var elements = Set<UInt32>([kAudioObjectPropertyElementMain])
        elements.formUnion(volumeElements(deviceID))
        elements.formUnion(elementsWithControl(deviceID, kAudioDevicePropertyMute))
        for element in elements.sorted() {
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: element)
                let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
                if AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block) == noErr {
                    deviceTokens.append(ListenerToken(objectID: deviceID, address: address, queue: .main, block: block))
                }
            }
        }
    }

    // MARK: - 底层读取

    private func readCFString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private func getUInt(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: UInt32 = kAudioObjectPropertyElementMain) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func getUIntArray(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                              element: UInt32 = kAudioObjectPropertyElementMain) -> [UInt32]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<UInt32>.stride
        guard count > 0 else { return nil }
        var values = [UInt32](repeating: 0, count: count)
        let status = values.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr ? values : nil
    }
}

/// 保存 CoreAudio 监听器引用,便于按需注销。
private final class ListenerToken {
    let objectID: AudioObjectID
    let address: AudioObjectPropertyAddress
    let queue: DispatchQueue
    let block: AudioObjectPropertyListenerBlock

    init(objectID: AudioObjectID, address: AudioObjectPropertyAddress,
         queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) {
        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.block = block
    }

    func remove() {
        var addr = address
        AudioObjectRemovePropertyListenerBlock(objectID, &addr, queue, block)
    }
}
