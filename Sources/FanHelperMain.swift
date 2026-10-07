import Foundation
import IOKit
import Darwin
import CoreAudio
import CoreGraphics
import AudioToolbox

// gt-fanctl:GT 工具箱的特权助手(root)。
//
// 三种模式:
//   daemon <socket> <uid>   常驻守护(launchd 拉起):白名单风扇命令 + 唤醒后音频假死自动探测修复
//   install <uid>           安装为 LaunchDaemon(自拷贝到 /Library/PrivilegedHelperTools)
//   uninstall               停止并移除守护
//
// 安全:socket 0600 属主为用户;命令全部白名单;转速钳制在 SMC 上报区间;
//      风扇强制状态只在"本连接真的动过风扇"时才在断开时恢复系统自动。

@main
struct GTFanHelper {
    static var smc = SMCLite.Connection()
    static var fanCount = 0
    static var fanMin: [Double] = []
    static var fanMax: [Double] = []
    static var forcedInConnection = false
    static var repairCount = 0
    static var lastProbeTime: TimeInterval = 0

    static let helperInstallPath = "/Library/PrivilegedHelperTools/com.sounds.gtfanctl"
    static let plistInstallPath = "/Library/LaunchDaemons/com.sounds.gtfanctl.plist"
    static let serviceLabel = "com.sounds.gtfanctl"

    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else { usage(); exit(2) }
        switch args[1] {
        case "daemon":
            guard args.count >= 4 else { usage(); exit(2) }
            daemonRun(socketPath: args[2], uidArg: args[3])
        case "install":
            install(uidArg: args.count > 2 ? args[2] : "", sourceArg: args.count > 3 ? args[3] : nil)
        case "uninstall":
            uninstall()
        default:
            usage(); exit(2)
        }
    }

    static func usage() {
        fputs("usage: gt-fanctl daemon <socket-path> <uid> | install <uid> | uninstall\n", stderr)
    }

    // MARK: - 安装 / 卸载(root)

    static func logLine(_ s: String) {
        let line = "(\(Date())) \(s)\n"
        let p = "/tmp/gt-fanctl-install.log"
        if let fh = FileHandle(forWritingAtPath: p) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            fh.closeFile()
        } else {
            try? line.write(toFile: p, atomically: true, encoding: .utf8)
        }
    }

    static func install(uidArg: String, sourceArg: String?) {
        logLine("install 开始 uid=\(uidArg) source=\(sourceArg ?? "nil") getuid=\(getuid())")
        guard getuid() == 0 else { logLine("install 失败:非 root"); fputs("install 需要 root\n", stderr); exit(1) }
        let uid = uidArg.isEmpty ? String(getuid()) : uidArg
        let fm = FileManager.default
        let selfPath = CommandLine.arguments[0]
        let source = (sourceArg?.isEmpty == false) ? sourceArg! : selfPath
        let socketPath = "/tmp/gt-fanctl-\(uid).sock"

        do {
            logLine("创建目录 /Library/PrivilegedHelperTools")
            try fm.createDirectory(atPath: (helperInstallPath as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            logLine("拷贝助手 \(source) → \(helperInstallPath)")
            if fm.fileExists(atPath: helperInstallPath) { try fm.removeItem(atPath: helperInstallPath) }
            try fm.copyItem(atPath: source, toPath: helperInstallPath)
            chmod(helperInstallPath, 0o755)
            chown(helperInstallPath, 0, 0)

            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(serviceLabel)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(helperInstallPath)</string>
                    <string>daemon</string>
                    <string>\(socketPath)</string>
                    <string>\(uid)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
                <key>ProcessType</key>
                <string>Background</string>
            </dict>
            </plist>
            """
            try plist.write(toFile: plistInstallPath, atomically: true, encoding: .utf8)
            chmod(plistInstallPath, 0o644)
            chown(plistInstallPath, 0, 0)
        } catch {
            fputs("安装失败: \(error)\n", stderr)
            exit(1)
        }

        logLine("bootout + bootstrap \(serviceLabel)")
        _ = runCmd("/bin/launchctl", ["bootout", "system/\(serviceLabel)"])
        if runCmd("/bin/launchctl", ["bootstrap", "system", plistInstallPath]) != 0 {
            logLine("bootstrap 失败,回退 load -w")
            _ = runCmd("/bin/launchctl", ["load", "-w", plistInstallPath])
        }
        logLine("安装完成")
        print("已安装并启动: \(serviceLabel)")
    }

    static func uninstall() {
        guard getuid() == 0 else { fputs("uninstall 需要 root\n", stderr); exit(1) }
        if smc.openSMC() { restoreAuto() }
        _ = runCmd("/bin/launchctl", ["bootout", "system/\(serviceLabel)"])
        try? FileManager.default.removeItem(atPath: plistInstallPath)
        try? FileManager.default.removeItem(atPath: helperInstallPath)
        print("已卸载")
    }

    static func runCmd(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: - 常驻守护

    static func daemonRun(socketPath: String, uidArg: String) {
        let uid = uid_t(uidArg) ?? 0
        signal(SIGHUP, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, { _ in
            GTFanHelper.restoreAuto()
            GTFanHelper.forceExit()
        })

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
        restoreAuto()   // 清理残留强制状态

        // 显示器重配置(睡眠/唤醒都会触发)后自动探测音频假死;探测内部会跳过睡眠状态
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in
            let now = Date().timeIntervalSince1970
            guard now - GTFanHelper.lastProbeTime > 45 else { return }
            GTFanHelper.lastProbeTime = now
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                GTFanHelper.probeAndRepair()
            }
        }, nil)

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

        // 启动后先探测一次
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { probeAndRepair() }

        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { break }
            forcedInConnection = false
            handle(client)
            close(client)
            if forcedInConnection {
                restoreAuto()   // 本连接动过风扇 → 断开恢复系统自动(安全兜底)
            }
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
            var fields = ["OK", "REP=\(repairCount)"]
            for i in 0..<fanCount {
                fields.append("F\(i)Ac=\(Int(smc.readRPM("F\(i)Ac") ?? -1))")
                fields.append("F\(i)Md=\(smc.readUInt8("F\(i)Md") ?? 255)")
            }
            return fields.joined(separator: " ")
        case "ALLAUTO":
            restoreAuto()
            return "OK"
        case "MODE":
            guard parts.count == 3, let i = Int(parts[1]), i < fanCount,
                  let m = UInt8(parts[2]), m <= 1 else { return "ERR args" }
            let ok = smc.writeUInt8("F\(i)Md", m)
            if ok, m == 1 { forcedInConnection = true }
            return ok ? "OK" : "ERR write"
        case "RPM":
            guard parts.count == 3, let i = Int(parts[1]), i < fanCount,
                  let rpm = Double(parts[2]) else { return "ERR args" }
            let clamped = min(max(rpm, fanMin[i]), fanMax[i])
            return smc.writeRPM("F\(i)Tg", clamped) ? "OK" : "ERR write"
        case "AUDIO-RESET":
            // 重启系统音频服务,修复 DP 音频假死(播放报 AudioQueueStart failed)。
            // 必须异步:coreaudiod 重启可能耗时很长甚至卡住,若在命令循环里同步执行,
            // 守护会停止读取 socket,把客户端的阻塞式 send 一起拖死。
            DispatchQueue.global().async { _ = audioReset() }
            return "OK"
        default:
            return "ERR unknown"
        }
    }

    // MARK: - 音频假死探测与自动修复

    /// 在默认输出上静默启动一个探测流;假死设备会启动失败。无默认输出视为健康。
    static func audioHealthy() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return true }

        var format = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0)
        var queue: AudioQueueRef?
        let newResult = AudioQueueNewOutput(&format, { _, _, _ in }, nil, nil, nil, 0, &queue)
        guard newResult == noErr, let queue else { return false }
        defer { AudioQueueDispose(queue, true) }

        var buffer: AudioQueueBufferRef?
        guard AudioQueueAllocateBuffer(queue, 8192, &buffer) == noErr, let buf = buffer else { return false }
        buf.pointee.mAudioDataByteSize = UInt32(8192)
        memset(buf.pointee.mAudioData, 0, 8192)
        guard AudioQueueEnqueueBuffer(queue, buf, 0, nil) == noErr else { return false }

        let startResult = AudioQueueStart(queue, nil)
        if startResult == noErr {
            usleep(30_000)
            AudioQueueStop(queue, true)
        }
        return startResult == noErr
    }

    /// 探测失败 → 重启 coreaudiod → 复测,最多 3 次。显示器睡眠中不做探测(等唤醒事件)。
    static func probeAndRepair() {
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return }
        guard !audioHealthy() else { return }
        for _ in 0..<3 {
            repairCount += 1
            _ = audioReset()
            usleep(3_000_000)
            if audioHealthy() { return }
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

    // MARK: - 风扇

    static func restoreAuto() {
        let count = min(Int(smc.readUInt8("FNum") ?? 0), 8)
        for i in 0..<count {
            _ = smc.writeUInt8("F\(i)Md", 0)
        }
    }

    static func forceExit() {
        exit(0)
    }
}
