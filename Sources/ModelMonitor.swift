import Foundation
import AppKit
import IOKit
import Darwin

/// 本地大模型运行时监测与管理。
///
/// 监测:自动发现本机在跑的推理服务(Ollama / LM Studio / MLX / llama.cpp),
/// 读取各自 API 暴露的「已加载模型」列表(名称、显存占用、保活倒计时、量化),
/// 并补充进程级 CPU/内存占用与整机 GPU 利用率、统一内存压力。
///
/// 管理:Ollama 支持按模型卸载、批量卸载、续期保活;可开启对应服务或打开控制台。
///
/// 说明:所有请求都指向 127.0.0.1,显式禁用代理,避免被本机科学上网代理拦截。
final class ModelMonitor {

    static let shared = ModelMonitor()

    // MARK: - 数据模型

    enum Kind: String, CaseIterable {
        case ollama, lmstudio, mlx, llamaCpp

        var title: String {
            switch self {
            case .ollama: return "Ollama"
            case .lmstudio: return "LM Studio"
            case .mlx: return "MLX"
            case .llamaCpp: return "llama.cpp"
            }
        }

        /// 该运行时在 ps 输出里可识别的进程特征。
        var processMarkers: [String] {
            switch self {
            case .ollama: return ["/ollama", "ollama serve", "ollama.app"]
            case .lmstudio: return ["lm studio", "lmstudio", "/lms ", "lm-studio"]
            case .mlx: return ["mlx_lm.server", "mlx-lm", "mlx_lm", "omlx"]
            case .llamaCpp: return ["llama-server"]
            }
        }

        /// 本机是否装有该运行时(决定「启动服务」里是否列出)。
        var isInstalled: Bool {
            let fm = FileManager.default
            func exists(_ p: String) -> Bool { fm.fileExists(atPath: (p as NSString).expandingTildeInPath) }
            switch self {
            case .ollama:
                return exists("/Applications/Ollama.app") || exists("/usr/local/bin/ollama") || exists("/opt/homebrew/bin/ollama")
            case .lmstudio:
                return exists("~/.lmstudio/bin/lms") || exists("/Applications/LM Studio.app")
            case .mlx:
                return exists("/Applications/oMLX.app") || exists("/Applications/MTPLX.app")
                    || exists("/opt/homebrew/bin/mlx_lm.server") || Self.pathHas("mlx_lm.server")
            case .llamaCpp:
                return exists("/opt/homebrew/bin/llama-server") || Self.pathHas("llama-server")
            }
        }

        private static func pathHas(_ exe: String) -> Bool {
            let paths: [String] = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
                + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            return paths.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + exe) }
        }
    }

    struct Loaded {
        var name: String
        var sizeBytes: UInt64      // 模型文件大小
        var vramBytes: UInt64      // 驻留显存/统一内存
        var expires: Date?         // 保活到期时间(nil = 常驻或未知)
        var meta: String           // 参数量 · 量化 · 上下文
    }

    struct Runtime {
        var kind: Kind
        var port: Int
        var version: String?
        var loaded: [Loaded]
        var installed: Int         // 本地已下载的模型数量
        var controllable: Bool     // 是否支持卸载等管理动作
    }

    struct ProcStat {
        var cpu: Double            // 进程组 CPU 占用 %
        var mem: UInt64            // 进程组常驻内存
        var count: Int
        var pids: [Int]
    }

    // MARK: - 对外状态

    private(set) var runtimes: [Runtime] = []
    private(set) var procs: [Kind: ProcStat] = [:]
    private(set) var gpuUtil: Double = 0
    private(set) var memUsed: UInt64 = 0
    private(set) var memTotal: UInt64 = 0
    private(set) var memPressure = "正常"
    private(set) var lastUpdated: Date?
    var notice: String? {
        didSet {
            guard notice != oldValue, notice != nil else { return }
            noticeGeneration += 1
            let gen = noticeGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.noticeGeneration == gen else { return }
                self.notice = nil
                self.onUpdate?()
            }
        }
    }
    private var noticeGeneration = 0

    var onUpdate: (() -> Void)?

    // MARK: - 生命周期

    private var timer: Timer?
    private var polling = false

    func start(interval: TimeInterval = 5) {
        refreshNow()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
    }

    func refreshNow() {
        guard !polling else { return }
        polling = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snapshot = self.collect()
            DispatchQueue.main.async {
                self.runtimes = snapshot.runtimes
                self.procs = snapshot.procs
                self.gpuUtil = snapshot.gpuUtil
                self.memUsed = snapshot.memUsed
                self.memTotal = snapshot.memTotal
                self.memPressure = snapshot.memPressure
                self.lastUpdated = Date()
                self.polling = false
                self.onUpdate?()
            }
        }
    }

    /// 结构签名:仅在「运行时集合 / 已加载模型集合」变化时才需要重建菜单。
    /// 数值类指标(GPU、CPU、倒计时)走就地刷新,避免每 5 秒重建菜单打断交互。
    var structuralSignature: String {
        let base = runtimes.map { rt in
            "\(rt.kind.rawValue):\(rt.port):\(rt.installed):" + rt.loaded.map(\.name).joined(separator: ",")
        }.joined(separator: ";")
        // 提示语出现/消失也属于结构变化(菜单项增删),需要重建
        return base + "#" + (notice.map { String($0.count) } ?? "-")
    }

    /// 完整签名(结构 + 数值),供外部需要时判断。
    var signature: String {
        var parts: [String] = ["gpu\(Int(gpuUtil))", "mem\(memUsed / (1 << 30))", memPressure]
        for rt in runtimes {
            var s = "\(rt.kind.rawValue):\(rt.port):\(rt.installed)"
            for m in rt.loaded {
                let remain = m.expires.map { Int(max(0, $0.timeIntervalSinceNow) / 60) } ?? -1
                s += "|\(m.name)@\(remain)"
            }
            if let p = procs[rt.kind] { s += "|cpu\(Int(p.cpu / 5) * 5)" }
            parts.append(s)
        }
        return parts.joined(separator: ";")
    }

    // MARK: - 采集

    private struct Snapshot {
        var runtimes: [Runtime]
        var procs: [Kind: ProcStat]
        var gpuUtil: Double
        var memUsed: UInt64
        var memTotal: UInt64
        var memPressure: String
    }

    private func collect() -> Snapshot {
        let allProcs = sampleProcesses()
        var procs: [Kind: ProcStat] = [:]
        for kind in Kind.allCases {
            let matches = allProcs.filter { p in
                let a = p.args.lowercased()
                return kind.processMarkers.contains { a.contains($0) }
            }
            guard !matches.isEmpty else { continue }
            procs[kind] = ProcStat(cpu: matches.reduce(0) { $0 + $1.cpu },
                                   mem: UInt64(matches.reduce(0.0) { $0 + $1.rssKB } * 1024),
                                   count: matches.count,
                                   pids: matches.map(\.pid))
        }

        let mem = sampleMemory()
        return Snapshot(runtimes: probeAll(),
                        procs: procs,
                        gpuUtil: sampleGPU(),
                        memUsed: mem.used,
                        memTotal: mem.total,
                        memPressure: mem.pressure)
    }

    // MARK: - HTTP(本机,禁用代理)

    private func makeSession(_ timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]   // 显式禁用代理,避免被 127.0.0.1:7897 科学上网代理拦截
        cfg.timeoutIntervalForRequest = timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }

    private func getJSON(_ urlString: String, timeout: TimeInterval = 1.5) -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any]?
        let session = makeSession(timeout)
        session.dataTask(with: req) { data, _, _ in
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { out = obj }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        session.invalidateAndCancel()
        return out
    }

    @discardableResult
    private func postJSON(_ urlString: String, _ body: [String: Any], timeout: TimeInterval = 4) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let session = makeSession(timeout)
        session.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse { ok = (200..<300).contains(http.statusCode) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        session.invalidateAndCancel()
        return ok
    }

    // MARK: - 运行时探测

    private func probeAll() -> [Runtime] {
        var out: [Runtime] = []
        var usedPorts = Set<Int>()

        if let r = probeOllama(port: 11434) { out.append(r); usedPorts.insert(r.port) }
        if let r = probeLMStudio(port: 1234) { out.append(r); usedPorts.insert(r.port) }

        for p in [8080, 8010, 8011] where !usedPorts.contains(p) {
            if let r = probeLlamaCpp(port: p) { out.append(r); usedPorts.insert(p); break }
        }
        for p in [8088, 8080, 8000] where !usedPorts.contains(p) {
            if let r = probeMLX(port: p) { out.append(r); usedPorts.insert(p); break }
        }
        return out
    }

    private func probeOllama(port: Int) -> Runtime? {
        guard let ver = getJSON("http://127.0.0.1:\(port)/api/version") else { return nil }
        let version = ver["version"] as? String

        var loaded: [Loaded] = []
        if let ps = getJSON("http://127.0.0.1:\(port)/api/ps"),
           let models = ps["models"] as? [[String: Any]] {
            for m in models {
                var meta: [String] = []
                if let d = m["details"] as? [String: Any] {
                    if let p = d["parameter_size"] as? String, !p.isEmpty { meta.append(p) }
                    if let q = d["quantization_level"] as? String, !q.isEmpty { meta.append(q) }
                }
                if let c = (m["context_length"] as? NSNumber)?.intValue, c > 0 {
                    meta.append("ctx \(c / 1024)K")
                }
                loaded.append(Loaded(name: m["name"] as? String ?? "?",
                                     sizeBytes: (m["size"] as? NSNumber)?.uint64Value ?? 0,
                                     vramBytes: (m["size_vram"] as? NSNumber)?.uint64Value ?? 0,
                                     expires: Self.parseISO(m["expires_at"] as? String),
                                     meta: meta.joined(separator: " · ")))
            }
        }

        var installed = 0
        if let tags = getJSON("http://127.0.0.1:\(port)/api/tags"),
           let models = tags["models"] as? [[String: Any]] {
            installed = models.count
        }

        return Runtime(kind: .ollama, port: port, version: version,
                       loaded: loaded, installed: installed, controllable: true)
    }

    private func probeLMStudio(port: Int) -> Runtime? {
        if let d = getJSON("http://127.0.0.1:\(port)/api/v0/models"),
           let arr = d["data"] as? [[String: Any]] {
            var loaded: [Loaded] = []
            for m in arr {
                guard (m["state"] as? String) == "loaded" else { continue }
                var meta: [String] = []
                if let q = m["quantization"] as? String, !q.isEmpty { meta.append(q) }
                if let c = (m["max_context_length"] as? NSNumber)?.intValue, c > 0 {
                    meta.append("ctx \(c / 1024)K")
                }
                let size = (m["size_bytes"] as? NSNumber)?.uint64Value ?? 0
                loaded.append(Loaded(name: m["id"] as? String ?? "?",
                                     sizeBytes: size, vramBytes: size,
                                     expires: nil, meta: meta.joined(separator: " · ")))
            }
            return Runtime(kind: .lmstudio, port: port, version: nil,
                           loaded: loaded, installed: arr.count, controllable: true)
        }
        if let d = getJSON("http://127.0.0.1:\(port)/v1/models"),
           let arr = d["data"] as? [[String: Any]] {
            let loaded = arr.map {
                Loaded(name: $0["id"] as? String ?? "?", sizeBytes: 0, vramBytes: 0, expires: nil, meta: "")
            }
            return Runtime(kind: .lmstudio, port: port, version: nil,
                           loaded: loaded, installed: arr.count, controllable: true)
        }
        return nil
    }

    private func probeMLX(port: Int) -> Runtime? {
        guard let d = getJSON("http://127.0.0.1:\(port)/v1/models"),
              let arr = d["data"] as? [[String: Any]] else { return nil }
        let loaded = arr.map {
            Loaded(name: $0["id"] as? String ?? "?", sizeBytes: 0, vramBytes: 0, expires: nil, meta: "")
        }
        guard !loaded.isEmpty else { return nil }
        return Runtime(kind: .mlx, port: port, version: nil,
                       loaded: loaded, installed: loaded.count, controllable: false)
    }

    private func probeLlamaCpp(port: Int) -> Runtime? {
        guard let d = getJSON("http://127.0.0.1:\(port)/props") else { return nil }
        guard d["default_generation_settings"] != nil || d["model_path"] != nil || d["model_alias"] != nil else {
            return nil
        }
        var name = (d["model_alias"] as? String) ?? ""
        if name.isEmpty, let p = d["model_path"] as? String {
            name = (p as NSString).lastPathComponent
        }
        if name.isEmpty { name = "llama.cpp 模型" }
        return Runtime(kind: .llamaCpp, port: port, version: nil,
                       loaded: [Loaded(name: name, sizeBytes: 0, vramBytes: 0, expires: nil, meta: "")],
                       installed: 1, controllable: false)
    }

    // MARK: - 管理动作

    /// 触发 Ollama 加载/卸载/续期。生成模型走 /api/generate;
    /// 纯向量模型(bge 等)会拒绝 generate,回退到 /api/embed。
    /// keep_alive 传 0 表示立即卸载,传时长字符串表示续期。
    @discardableResult
    private func ollamaLifecycle(port: Int, model: String, keepAlive: Any) -> Bool {
        let base = "http://127.0.0.1:\(port)"
        // 生成/对话类模型:空 prompt 只做加载,不产生实际推理开销
        if postJSON("\(base)/api/generate", ["model": model, "keep_alive": keepAlive]) { return true }
        // 向量模型回退:带一段短输入即可完成加载/卸载
        return postJSON("\(base)/api/embed", ["model": model, "input": "ping", "keep_alive": keepAlive])
    }

    /// 卸载单个 Ollama 模型(keep_alive=0 立即释放显存)。
    @discardableResult
    func unloadOllama(_ name: String) -> Bool {
        unloadModel(kind: .ollama, name: name)
    }

    /// 卸载所有已加载的 Ollama 模型,返回成功数量。
    @discardableResult
    func unloadAllOllama() -> Int {
        guard let rt = runtimes.first(where: { $0.kind == .ollama }) else { return 0 }
        var n = 0
        for m in rt.loaded where ollamaLifecycle(port: rt.port, model: m.name, keepAlive: 0) {
            n += 1
        }
        if n > 0 { notice = "已卸载 \(n) 个模型" }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshNow() }
        return n
    }

    /// 把所有已加载的 Ollama 模型保活时间延长,避免反复冷启动。
    @discardableResult
    func keepAliveOllama(_ duration: String = "30m") -> Int {
        guard let rt = runtimes.first(where: { $0.kind == .ollama }) else { return 0 }
        var n = 0
        for m in rt.loaded where ollamaLifecycle(port: rt.port, model: m.name, keepAlive: duration) {
            n += 1
        }
        if n > 0 { notice = "保活已延长至 \(duration)" }
        refreshNow()
        return n
    }

    /// 启动运行时服务(Ollama / LM Studio / MLX 桌面端)。llama.cpp 需自行带模型启动。
    @discardableResult
    func startService(_ kind: Kind) -> Bool {
        let path: String?
        let args: [String]
        var followUp: (String, [String])?
        switch kind {
        case .ollama:
            if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
                path = "/usr/bin/open"; args = ["-a", "Ollama"]
            } else if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ollama") {
                path = "/opt/homebrew/bin/ollama"; args = ["serve"]
            } else if FileManager.default.fileExists(atPath: "/usr/local/bin/ollama") {
                path = "/usr/local/bin/ollama"; args = ["serve"]
            } else {
                path = nil; args = []
            }
        case .lmstudio:
            let lms = ("~/.lmstudio/bin/lms" as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: "/Applications/LM Studio.app") {
                // 先起 App(内建 daemon 是 lms server start 的前置),再延时拉起 HTTP 服务
                path = "/usr/bin/open"; args = ["-a", "LM Studio"]
                if FileManager.default.fileExists(atPath: lms) { followUp = (lms, ["server", "start"]) }
            } else if FileManager.default.fileExists(atPath: lms) {
                path = lms; args = ["server", "start"]
            } else {
                path = nil; args = []
            }
        case .mlx:
            // 优先本地命令行服务;否则打开已安装的 MLX 桌面端
            if let exe = Self.firstExecutable(["mlx_lm.server", "mlx-lm"]) {
                path = exe; args = ["--help"]
            } else if let app = Self.firstApp(["oMLX", "MTPLX"]) {
                path = "/usr/bin/open"; args = ["-a", app]
            } else {
                path = nil; args = []
            }
        case .llamaCpp:
            path = nil; args = []
        }
        guard let path else { return false }
        let launched = runDetached(path, args)
        if let (fp, fa) = followUp {
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak self] in
                _ = self?.runDetached(fp, fa)
                DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in self?.refreshNow() }
            }
        }
        guard launched else { return false }
        notice = "已请求启动 \(kind.title)"
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in self?.refreshNow() }
        return true
    }

    private static func firstExecutable(_ names: [String]) -> String? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for n in names { for d in dirs where FileManager.default.isExecutableFile(atPath: d + "/" + n) { return d + "/" + n } }
        return nil
    }

    private static func firstApp(_ names: [String]) -> String? {
        for n in names where FileManager.default.fileExists(atPath: "/Applications/\(n).app") { return n }
        return nil
    }

    /// 启动外部程序并立即返回(不等待退出)。
    @discardableResult
    private func runDetached(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        return true
    }

    /// 打开对应运行时的管理界面(网页控制台或 App)。
    func openConsole(_ rt: Runtime) {
        DispatchQueue.main.async {
            switch rt.kind {
            case .lmstudio:
                if FileManager.default.fileExists(atPath: "/Applications/LM Studio.app") {
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: "/Applications/LM Studio.app"),
                        configuration: NSWorkspace.OpenConfiguration())
                    return
                }
                if let u = URL(string: "http://127.0.0.1:\(rt.port)") { NSWorkspace.shared.open(u) }
            case .mlx, .llamaCpp:
                if let u = URL(string: "http://127.0.0.1:\(rt.port)") { NSWorkspace.shared.open(u) }
            case .ollama:
                if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: "/Applications/Ollama.app"),
                        configuration: NSWorkspace.OpenConfiguration())
                } else if let u = URL(string: "http://127.0.0.1:\(rt.port)") {
                    NSWorkspace.shared.open(u)
                }
            }
        }
    }

    /// 卸载指定运行时的单个模型。Ollama 走 keep_alive=0;LM Studio 走 lms CLI。
    @discardableResult
    func unloadModel(kind: Kind, name: String) -> Bool {
        switch kind {
        case .ollama:
            guard let rt = runtimes.first(where: { $0.kind == .ollama }) else { return false }
            let ok = ollamaLifecycle(port: rt.port, model: name, keepAlive: 0)
            if ok { notice = "已卸载 \(name)" }
            scheduleRefresh()
            return ok
        case .lmstudio:
            guard let lms = lmsPath else { return false }
            let ok = runDetachedSync(lms, ["unload", name], timeout: 20)
            if ok { notice = "已卸载 \(name)" }
            scheduleRefresh()
            return ok
        case .mlx, .llamaCpp:
            return false
        }
    }

    /// 结束运行时进程组(对不支持模型卸载的 MLX / llama.cpp 是唯一的管理手段)。
    @discardableResult
    func terminate(_ kind: Kind) -> Bool {
        guard let p = procs[kind], !p.pids.isEmpty else { return false }
        for pid in p.pids { kill(Int32(pid), SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            // 宽限期后仍未退出则强制结束
            if let still = self.procs[kind] {
                for pid in still.pids where kill(Int32(pid), 0) == 0 { kill(Int32(pid), SIGKILL) }
            }
            self.refreshNow()
        }
        notice = "已结束 \(kind.title) 进程"
        return true
    }

    private var lmsPath: String? {
        let p = ("~/.lmstudio/bin/lms" as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    private func scheduleRefresh() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshNow() }
    }

    /// 同步执行外部命令并等待完成(带超时保护)。
    @discardableResult
    private func runDetachedSync(_ path: String, _ args: [String], timeout: TimeInterval) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(100_000) }
        if p.isRunning { p.terminate(); return false }
        return p.terminationStatus == 0
    }

    // MARK: - 系统指标

    private struct RawProc {
        let pid: Int
        let cpu: Double
        let rssKB: Double
        let args: String
    }

    private func sampleProcesses() -> [RawProc] {
        let out = run("/bin/ps", ["-axo", "pid=,%cpu=,rss=,args="])
        var list: [RawProc] = []
        list.reserveCapacity(512)
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int(parts[0]),
                  let cpu = Double(parts[1]),
                  let rss = Double(parts[2]) else { continue }
            list.append(RawProc(pid: pid, cpu: cpu, rssKB: rss, args: String(parts[3])))
        }
        return list
    }

    /// 整机 GPU 利用率(Apple Silicon:IOAccelerator 的 Device Utilization %)。
    private func sampleGPU() -> Double {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iter) }

        var best = 0.0
        var service = IOIteratorNext(iter)
        while service != 0 {
            if let prop = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let stats = prop as? [String: Any],
               let util = stats["Device Utilization %"] as? NSNumber {
                best = max(best, util.doubleValue)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        return best
    }

    private func sampleMemory() -> (used: UInt64, total: UInt64, pressure: String) {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var used: UInt64 = 0
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
            used = pages * UInt64(pageSize)
        }

        var pressure = "正常"
        var level: Int32 = 1
        var lsize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &lsize, nil, 0) == 0 {
            switch level {
            case 2: pressure = "偏高"
            case 4: pressure = "严重"
            default: pressure = "正常"
            }
        }
        return (used, total, pressure)
    }

    // MARK: - 工具

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 解析 ISO8601(兼容 6 位小数秒这类 ISO8601DateFormatter 不接受的写法)。
    private static func parseISO(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return d }
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            var t = s
            t.replaceSubrange(r, with: "." + s[r].dropFirst().prefix(3))
            if let d = f1.date(from: t) { return d }
        }
        return nil
    }
}
