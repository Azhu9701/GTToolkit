import AppKit
import ApplicationServices
import Darwin

protocol MediaKeyHandling: AnyObject {
    /// 处理音量键;返回 true 表示已消费(拦截系统默认行为)。
    func handleMediaKey(_ key: MediaKeyTap.Key) -> Bool
}

/// 通过 CGEventTap 接管键盘音量键(F1/F2/F3 或触控条音量键),
/// 使其对无系统音量控制的显示器喇叭(DDC)生效。需要辅助功能权限。
final class MediaKeyTap {
    enum Key {
        case up      // NX_KEYTYPE_SOUND_UP
        case down    // NX_KEYTYPE_SOUND_DOWN
        case mute    // NX_KEYTYPE_MUTE
    }

    static let shared = MediaKeyTap()
    weak var handler: MediaKeyHandling?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isEnabled: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// 尝试接管音量键。无辅助功能权限且 promptIfNeeded=true 时弹系统授权窗。
    @discardableResult
    func enable(promptIfNeeded: Bool) -> Bool {
        if isEnabled { return true }
        if tap == nil {
            // NSSystemDefined = 14(Swift 枚举未暴露该 case,直接用原始值)
            let eventMask: CGEventMask = 1 << 14
            guard let newTap = CGEvent.tapCreate(tap: .cghidEventTap,
                                                 place: .headInsertEventTap,
                                                 options: .defaultTap,
                                                 eventsOfInterest: eventMask,
                                                 callback: { _, type, cgEvent, _ -> Unmanaged<CGEvent>? in
                                                     guard let handled = MediaKeyTap.shared.process(type: type, cgEvent: cgEvent) else { return nil }
                                                     return Unmanaged.passUnretained(handled)
                                                 },
                                                 userInfo: nil) else {
                if promptIfNeeded {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                }
                return false
            }
            tap = newTap
        }
        guard let tap else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        source = src
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func disable() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
    }

    // 事件解析参考 SPMediaKeyTap:data1 高 16 位为键码,8..15 位为按下状态(0xA=按下),0 位为重复。
    private func process(type: CGEventType, cgEvent: CGEvent) -> CGEvent? {
        guard type.rawValue == 14,  // NSSystemDefined
              let nsEvent = NSEvent(cgEvent: cgEvent),
              nsEvent.subtype == NSEvent.EventSubtype(rawValue: 8) else { return cgEvent }  // 8 = auxControlButtons

        let data1 = nsEvent.data1
        let keyCode = Int16((data1 & 0xFFFF_0000) >> 16)
        let keyState = Int16((data1 & 0xFF00) >> 8)
        let keyRepeat = (data1 & 0x1) != 0

        guard keyState == 0x0A else { return cgEvent }

        let key: Key
        switch keyCode {
        case 0: key = .up
        case 1: key = .down
        case 7: key = .mute
        default: return cgEvent
        }
        if key == .mute && keyRepeat { return cgEvent }

        if let handler = handler, handler.handleMediaKey(key) {
            return nil   // 消费事件,系统不再处理
        }
        return cgEvent
    }
}
