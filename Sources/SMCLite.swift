import Foundation
import IOKit
import Darwin

// MARK: - SMC 底层访问(App 与特权助手共用)
// 结构体布局与 beltex/SMCKit 一致,总大小必须为 80 字节;
// Apple Silicon 上 'flt ' 键为小端浮点,风扇转速/温度均走该类型。

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
    var bytes = SMCBytes(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

enum SMCLite {
    static let selYPC: UInt8 = 2           // 用户客户端固定走 YPC 事件
    static let selRead: UInt8 = 5
    static let selWrite: UInt8 = 6
    static let selKeyFromIndex: UInt8 = 8
    static let selKeyInfo: UInt8 = 9

    static func key4(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for b in s.utf8 { v = (v << 8) | UInt32(b) }
        return v
    }

    static func keyString(_ v: UInt32) -> String {
        let b = [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
                 UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
        return String(bytes: b, encoding: .ascii) ?? "????"
    }

    static func decodeTemp(_ typeName: String, _ bytes: [UInt8]) -> Double? {
        switch typeName {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let le = Double(Float(bitPattern: UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0])))
            let be = Double(Float(bitPattern: UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])))
            if le > -50, le < 150 { return le }
            if be > -50, be < 150 { return be }
            return nil
        case "sp78", "sp87":
            guard bytes.count >= 2 else { return nil }
            return Double(Int8(bitPattern: bytes[0])) + Double(bytes[1]) / 256.0
        default:
            return nil
        }
    }

    final class Connection {
        private var connection: io_connect_t = 0
        private(set) var isOpen = false

        func openSMC() -> Bool {
            guard connection == 0 else { return true }
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
            guard service != 0 else { return false }
            let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
            IOObjectRelease(service)
            isOpen = kr == kIOReturnSuccess && connection != 0
            return isOpen
        }

        func closeSMC() {
            guard connection != 0 else { return }
            IOServiceClose(connection)
            connection = 0
            isOpen = false
        }

        private func call(_ selector: UInt8, _ s: inout SMCParamStruct) -> Bool {
            guard isOpen else { return false }
            s.data8 = selector
            var output = SMCParamStruct()
            var size = MemoryLayout<SMCParamStruct>.stride
            assert(size == 80, "SMCParamStruct 布局异常")
            guard IOConnectCallStructMethod(connection, UInt32(selYPC), &s, MemoryLayout<SMCParamStruct>.stride, &output, &size) == kIOReturnSuccess,
                  output.result == 0 else { return false }
            s = output
            return true
        }

        func keyInfo(_ key: String) -> (type: UInt32, size: UInt32)? {
            var s = SMCParamStruct()
            s.key = SMCLite.key4(key)
            guard call(selKeyInfo, &s) else { return nil }
            return (s.keyInfo.dataType, s.keyInfo.dataSize)
        }

        func read(_ key: String) -> [UInt8]? {
            guard let info = keyInfo(key), info.size > 0, info.size <= 32 else { return nil }
            var s = SMCParamStruct()
            s.key = SMCLite.key4(key)
            s.keyInfo.dataSize = info.size
            guard call(selRead, &s) else { return nil }
            return withUnsafePointer(to: s.bytes) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: 32) { p in
                    Array(UnsafeBufferPointer(start: p, count: Int(info.size)))
                }
            }
        }

        @discardableResult
        func write(_ key: String, _ bytes: [UInt8]) -> Bool {
            guard let info = keyInfo(key), info.size == UInt32(bytes.count) else { return false }
            var s = SMCParamStruct()
            s.key = SMCLite.key4(key)
            s.keyInfo.dataSize = info.size
            s.keyInfo.dataType = info.type
            withUnsafeMutablePointer(to: &s.bytes) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: 32) { p in
                    for (i, b) in bytes.enumerated() { p[i] = b }
                }
            }
            return call(selWrite, &s)
        }

        // MARK: 高层键操作

        func readRPM(_ key: String) -> Double? {
            guard let b = read(key), b.count == 4 else { return nil }
            return Double(Float(bitPattern: UInt32(b[3]) << 24 | UInt32(b[2]) << 16 | UInt32(b[1]) << 8 | UInt32(b[0])))
        }

        func readUInt8(_ key: String) -> UInt8? {
            read(key)?.first
        }

        @discardableResult
        func writeRPM(_ key: String, _ rpm: Double) -> Bool {
            let bits = Float(rpm).bitPattern.littleEndian
            let bytes = withUnsafeBytes(of: bits) { Array($0) }
            return write(key, bytes)
        }

        @discardableResult
        func writeUInt8(_ key: String, _ v: UInt8) -> Bool {
            write(key, [v])
        }

        /// 一次性发现温度键(约 1-2 秒,数百次 SMC 查询)。
        func discoverTemperatureKeys() -> [(key: String, type: String)] {
            var found: [(String, String)] = []
            let prefixes = ["Tp", "Te", "Tg", "Ts", "Ta", "Tm", "Ti", "Tf", "Tb", "Th", "TC", "TG", "TM", "TW", "TR", "TX"]
            for prefix in prefixes {
                for i in 0..<256 {
                    let name = prefix + String(format: "%02X", i)
                    guard let info = keyInfo(name) else { continue }
                    let typeName = SMCLite.keyString(info.type)
                    guard ["sp78", "flt ", "sp87"].contains(typeName) else { continue }
                    if let b = read(name), let v = SMCLite.decodeTemp(typeName, b), v > 0, v < 130 {
                        found.append((name, typeName))
                    }
                }
            }
            return found
        }
    }
}
