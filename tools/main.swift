import Foundation
import CoreAudio

/// CLI 自检:列出输出设备与 DDC 显示器,验证音量读写通路(原值回写,不改变当前音量)。

let audio = AudioController.shared
let devices = audio.allOutputDevices()
let defaultID = audio.defaultOutputDeviceID()

print("默认输出设备:\(defaultID.map { audio.deviceName($0) } ?? "无")\n")
print("输出设备(CoreAudio):")
for device in devices {
    let volume = audio.volume(of: device.id)
    let percent = volume.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"
    let mark = device.id == defaultID ? "  [系统默认]" : ""
    let ctrl = audio.hasVolumeControl(device.id) ? "" : "  [无音量控制]"
    var parts: [String] = []
    if let maker = device.manufacturer, !maker.isEmpty { parts.append(maker) }
    if let transport = device.transport { parts.append(transport) }
    let suffix = parts.isEmpty ? "" : " (\(parts.joined(separator: " · ")))"
    print("  \(device.name)\(suffix)\(mark)\(ctrl) — 音量 \(percent)")
}

print("\n显示器喇叭(DDC/CI):")
let ddcDisplays = DDCDisplay.discover()
if ddcDisplays.isEmpty {
    print("  未发现可控制的显示器")
}
for ddc in ddcDisplays {
    let volume = ddc.volume()
    let percent = volume.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"
    let mute = ddc.isMuted().map { $0 ? "静音" : "未静音" } ?? "不支持静音"
    print("  \(ddc.productName) (\(ddc.manufacturer ?? "?")) [displayID \(ddc.displayID)] — 音量 \(percent), \(mute)")
    if let v = volume {
        let ok = ddc.setVolume(v)
        print("    写入测试(原值回写): \(ok ? "成功" : "失败")")
    }
}

if let id = defaultID, audio.hasVolumeControl(id), let v = audio.volume(of: id) {
    let ok = audio.setVolume(v, of: id)
    print("\nCoreAudio 写入测试(对默认设备原值回写): \(ok ? "成功" : "失败")")
}
