import Foundation
import IOKit
import Darwin

// SMC 探针:读风扇转速/模式/温度传感器,验证 AppleSMC 用户客户端通路。

// MARK: - SMC 结构体(beltex/SMCKit 同源布局,总大小 80 字节)

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes = SMCBytes(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

let selYPC: UInt8 = 2
let selRead: UInt8 = 5
let selWrite: UInt8 = 6
let selKeyFromIndex: UInt8 = 8
let selKeyInfo: UInt8 = 9

func key4(_ s: String) -> UInt32 {
    precondition(s.count == 4)
    var v: UInt32 = 0
    for b in s.utf8 { v = (v << 8) | UInt32(b) }
    return v
}

func keyString(_ v: UInt32) -> String {
    let b = [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
             UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    return String(bytes: b, encoding: .ascii) ?? "????"
}

var connection: io_connect_t = 0

func openSMC() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
    guard service != 0 else { print("[x] 未找到 AppleSMC 服务"); return false }
    let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
    IOObjectRelease(service)
    guard kr == kIOReturnSuccess else { print("[x] IOServiceOpen 失败: \(kr)"); return false }
    return true
}

func call(_ selector: UInt8, _ s: inout SMCParamStruct) -> (Bool, String) {
    s.data8 = selector
    var output = SMCParamStruct()
    var size = MemoryLayout<SMCParamStruct>.stride
    let kr = IOConnectCallStructMethod(connection, UInt32(selYPC), &s, MemoryLayout<SMCParamStruct>.stride, &output, &size)
    if kr != kIOReturnSuccess { return (false, "kIOReturn \(kr)") }
    if output.result != 0 { return (false, "SMCResult \(output.result)") }
    s = output
    return (true, "")
}

func keyInfo(_ key: String) -> (UInt32, UInt32)? {   // (type, size)
    var s = SMCParamStruct()
    s.key = key4(key)
    let (ok, _) = call(selKeyInfo, &s)
    guard ok else { return nil }
    return (s.keyInfo.dataType, s.keyInfo.dataSize)
}

func readKey(_ key: String) -> [UInt8]? {
    guard let (_, size32) = keyInfo(key), size32 > 0, size32 <= 32 else { return nil }
    let size = Int(size32)
    var s = SMCParamStruct()
    s.key = key4(key)
    s.keyInfo.dataSize = UInt32(size)
    let (ok, _) = call(selRead, &s)
    guard ok else { return nil }
    return withUnsafePointer(to: s.bytes) { ptr in
        ptr.withMemoryRebound(to: UInt8.self, capacity: 32) { p in
            Array(UnsafeBufferPointer(start: p, count: size))
        }
    }
}

func decode(_ type: UInt32, _ bytes: [UInt8]) -> Double? {
    let t = keyString(type)
    switch t {
    case "fpe2":
        guard bytes.count >= 2 else { return nil }
        return Double((Int(bytes[0]) << 8 | Int(bytes[1])) >> 2)
    case "sp78", "sp87":
        guard bytes.count >= 2 else { return nil }
        let raw = Int(Int8(bitPattern: bytes[0]))
        return Double(raw) + Double(bytes[1]) / 256.0
    case "flt ":
        guard bytes.count >= 4 else { return nil }
        var v: Float = 0
        v = Float(bitPattern: UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        return Double(v)
    case "ui8":
        guard bytes.count >= 1 else { return nil }
        return Double(bytes[0])
    case "ui16":
        guard bytes.count >= 2 else { return nil }
        return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
    case "ui32":
        guard bytes.count >= 4 else { return nil }
        return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
    default:
        return nil
    }
}

print("stride = \(MemoryLayout<SMCParamStruct>.stride)(应为 80)")
guard openSMC() else { exit(1) }
print("[✓] AppleSMC 已连接")

// MARK: 风扇

let fanCount = Int(readKey("FNum")?.first ?? 0)
print("风扇数量: \(fanCount)")
for i in 0..<max(fanCount, 0) {
    for suffix in ["Ac", "Mn", "Mx", "Md", "Tg", "Sf", "St"] {
        let key = "F\(i)\(suffix)"
        guard let (type, size) = keyInfo(key) else { print("  \(key): 无此键"); continue }
        let bytes = readKey(key) ?? []
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        var dec = "raw=\(hex)"
        if keyString(type) == "flt ", bytes.count == 4 {
            let be = Float(bitPattern: UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
            let le = Float(bitPattern: UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0]))
            dec = "BE=\(be) LE=\(le)"
        }
        print("  \(key): '\(keyString(type))' size\(size) → \(dec)")
    }
}

// MARK: 枚举全部温度键

print("\n枚举温度键(候选前缀 × 两位十六进制)…")
var temps: [(String, UInt32, Double)] = []
let prefixes = ["Tp", "Te", "Tg", "Ts", "Ta", "Tm", "Ti", "Tf", "Tb", "Th", "TC", "TG", "TM", "TW", "TR", "TX"]
var tried = 0
for prefix in prefixes {
    for i in 0..<256 {
        let name = prefix + String(format: "%02X", i)
        tried += 1
        guard let (type, size) = keyInfo(name) else { continue }
        let tn = keyString(type)
        guard ["sp78", "flt ", "sp87"].contains(tn) else { continue }
        guard let bytes = readKey(name) else { continue }
        var v: Double? = decode(type, bytes)
        if tn == "flt ", bytes.count == 4 {
            let le = Double(Float(bitPattern: UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0])))
            if v.map({ $0 < -50 || $0 > 150 }) ?? true, le > -50, le < 150 { v = le }
        }
        if let v, v > 0, v < 130 { temps.append((name, type, v)) }
    }
}
print("尝试 \(tried) 个键名,有效温度键 \(temps.count) 个,按温度降序:")
for (name, type, v) in temps.sorted(by: { $0.2 > $1.2 }) {
    print(String(format: "  %@ '%@' → %.1f°C", name, keyString(type), v))
}
