import Foundation
import IOKit
import Darwin

// gt-fanctl:GT 音量助手的特权风扇控制助手(root)。
// 由 App 通过管理员授权拉起,通过本地 UNIX socket 接收白名单命令;
// 连接断开时自动把所有风扇恢复为系统自动模式,启动时同样清理残留强制状态。

@main
struct GTFanHelper {
    static var smc = SMCLite.Connection()
    static var fanCount = 0
    static var fanMin: [Double] = []
    static var fanMax: [Double] = []

    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 4, args[1] == "daemon" else {
            fputs("usage: gt-fanctl daemon <socket-path> <uid>\n", stderr)
            exit(2)
        }
        signal(SIGHUP, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let socketPath = args[2]
        let uid = uid_t(args[3]) ?? 0

        guard smc.openSMC() else {
            fputs("打开 AppleSMC 失败\n", stderr)
            exit(1)
        }

        fanCount = min(Int(smc.readUInt8("FNum") ?? 0), 8)
        for i in 0..<fanCount {
            fanMin.append(smc.readRPM("F\(i)Mn") ?? 0)
            fanMax.append(smc.readRPM("F\(i)Mx") ?? 0)
        }
        guard fanCount > 0 else {
            fputs("未发现风扇\n", stderr)
            exit(1)
        }
        restoreAuto()   // 清理上次异常退出残留的强制状态

        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { exit(1) }
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < 104 else { exit(1) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: UInt8.self, capacity: 104) { p in
                for (i, b) in pathBytes.enumerated() { p[i] = b }
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            fputs("bind \(socketPath) 失败\n", stderr)
            exit(1)
        }
        chmod(socketPath, 0o600)
        chown(socketPath, uid, gid_t(0xFFFFFFFF))
        listen(fd, 1)

        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { break }
            handle(client)
            close(client)
            restoreAuto()   // 连接断开 → 恢复系统自动(安全兜底)
        }
        restoreAuto()
    }

    static func handle(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 1024)
        var pending: [UInt8] = []
        while true {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { return }
            pending.append(contentsOf: buf[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(bytes: pending[0..<nl], encoding: .utf8) ?? ""
                pending.removeSubrange(0...nl)
                let reply = dispatch(line)
                var out = Array((reply + "\n").utf8)
                var offset = 0
                while offset < out.count {
                    let w = out.withUnsafeBufferPointer { p in
                        write(fd, p.baseAddress! + offset, out.count - offset)
                    }
                    guard w > 0 else { return }
                    offset += w
                }
            }
        }
    }

    static func dispatch(_ line: String) -> String {
        let parts = line.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return "ERR empty" }
        switch parts[0] {
        case "PING":
            return "OK"
        case "STATE":
            var fields = ["OK"]
            for i in 0..<fanCount {
                fields.append("F\(i)Ac=\(Int(smc.readRPM("F\(i)Ac") ?? -1))")
                fields.append("F\(i)Md=\(smc.readUInt8("F\(i)Md") ?? 255)")
            }
            return fields.joined(separator: " ")
        case "ALLAUTO":
            restoreAuto()
            return "OK"
        case "AUDIO-RESET":
            // 重启系统音频服务,修复 DP 音频假死(播放报 AudioQueueStart failed)
            return audioReset() ? "OK" : "ERR reset"
        case "MODE":
            guard parts.count == 3, let i = Int(parts[1]), i < fanCount,
                  let m = UInt8(parts[2]), m <= 1 else { return "ERR args" }
            return smc.writeUInt8("F\(i)Md", m) ? "OK" : "ERR write"
        case "RPM":
            guard parts.count == 3, let i = Int(parts[1]), i < fanCount,
                  let rpm = Double(parts[2]) else { return "ERR args" }
            let clamped = min(max(rpm, fanMin[i]), fanMax[i])
            return smc.writeRPM("F\(i)Tg", clamped) ? "OK" : "ERR write"
        default:
            return "ERR unknown"
        }
    }

    static func restoreAuto() {
        let count = min(Int(smc.readUInt8("FNum") ?? 0), 8)
        for i in 0..<count {
            _ = smc.writeUInt8("F\(i)Md", 0)
        }
    }

    static func audioReset() -> Bool {
        // 首选 launchctl 平滑重启;失败则直接 killall(launchd 会自动拉起 coreaudiod)
        let kick = Process()
        kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        kick.arguments = ["kickstart", "-k", "system/com.apple.audio.coreaudiod"]
        kick.standardOutput = FileHandle.nullDevice
        kick.standardError = FileHandle.nullDevice
        if (try? kick.run()) != nil {
            kick.waitUntilExit()
            if kick.terminationStatus == 0 { return true }
        }
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["coreaudiod"]
        kill.standardOutput = FileHandle.nullDevice
        kill.standardError = FileHandle.nullDevice
        return ((try? kill.run()) != nil) && { kill.waitUntilExit(); return kill.terminationStatus == 0 }()
    }
}
