import Foundation
import CoreAudio

// 探针:dump 音频设备的音量相关属性,确认 DP 显示器到底暴露了哪些控制。

func hex4(_ v: UInt32) -> String {
    let bytes = [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]
    let chars = bytes.map { b in Character(UnicodeScalar(UInt8(truncatingIfNeeded: b))) }
    return "'\(String(chars))'"
}

let selectors: [(UInt32, String)] = [
    (kAudioDevicePropertyVolumeScalar, "VolumeScalar"),
    (kAudioDevicePropertyVolumeDecibels, "VolumeDecibels"),
    (kAudioDevicePropertyVolumeRangeDecibels, "VolumeRangeDecibels"),
    (kAudioDevicePropertyMute, "Mute"),
    (kAudioDevicePropertyStereoPan, "StereoPan"),
    (kAudioDevicePropertyDataSource, "DataSource"),
    (kAudioDevicePropertyJackIsConnected, "JackIsConnected"),
]

let scopes: [(AudioObjectPropertyScope, String)] = [
    (kAudioObjectPropertyScopeOutput, "output"),
    (kAudioObjectPropertyScopeGlobal, "global"),
]

let system = AudioObjectID(kAudioObjectSystemObject)
var addr0 = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
var sz0: UInt32 = 0
AudioObjectGetPropertyDataSize(system, &addr0, 0, nil, &sz0)
var ids = [AudioDeviceID](repeating: 0, count: Int(sz0) / MemoryLayout<AudioDeviceID>.stride)
AudioObjectGetPropertyData(system, &addr0, 0, nil, &sz0, &ids)

for id in ids {
    // 只看输出设备
    var sAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: 0)
    var sSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 else { continue }

    var nAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var nameRef: Unmanaged<CFString>?
    var nSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(id, &nAddr, 0, nil, &nSize, &nameRef)
    let name = nameRef?.takeRetainedValue() as String? ?? "?"

    print("===== \(name) [\(id)] =====")

    for (scope, scopeName) in scopes {
        for (sel, label) in selectors {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            let st = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
            guard st == noErr, size > 0 else { continue }
            var raw = [UInt32](repeating: 0, count: Int(size) / 4)
            let st2 = raw.withUnsafeMutableBufferPointer { buf -> OSStatus in
                AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf.baseAddress!)
            }
            guard st2 == noErr else { continue }
            if size == 4 {
                let f = Float(bitPattern: raw[0])
                print("  \(label)@\(scopeName) main: size=\(size) u32=\(raw[0])(\(hex4(raw[0]))) float=\(f)")
            } else {
                print("  \(label)@\(scopeName) main: size=\(size) 列表=\(raw.map { String($0) }.joined(separator: ","))")
            }
        }
    }

    print("  --- 逐元素 settable / value(output scope) ---")
    for element: UInt32 in 0...2 {
        for (sel, label) in [(kAudioDevicePropertyVolumeScalar, "VolumeScalar"), (kAudioDevicePropertyMute, "Mute")] {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
            var size: UInt32 = 0
            let st = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
            var settable = DarwinBoolean(false)
            let st2 = AudioObjectIsPropertySettable(id, &addr, &settable)
            var value: Float = -1
            if st == noErr && size >= 4 {
                var vsize = UInt32(4)
                if AudioObjectGetPropertyData(id, &addr, 0, nil, &vsize, &value) != noErr { value = -2 }
            }
            let ok = settable.boolValue
            print("    elem\(element) \(label): sizeStatus=\(st) size=\(size) settable=\(st2 == noErr ? String(ok) : "err\(st2)") value=\(value)")
        }
    }
}

print("\n--- osascript 系统音量 ---")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
p.arguments = ["-e", "get volume settings"]
let pipe = Pipe()
p.standardOutput = pipe
try? p.run()
p.waitUntilExit()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
print(String(data: data, encoding: .utf8) ?? "")
