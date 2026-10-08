import Foundation
import AppKit
import IOKit
import Darwin

/// 本地与局域网大模型运行时监测与管理。
///
/// 监测:自动发现本机在跑的推理服务(Ollama / LM Studio / MLX / llama.cpp),
/// 读取各自 API 暴露的「已加载模型」列表(名称、显存占用、保活倒计时、量化),
/// 并补充进程级 CPU/内存占用与整机 GPU 利用率、统一内存压力。
/// 另支持添加局域网内的远程主机(Windows 上跑的 Ollama / LM Studio / llama.cpp /
/// vLLM 等),手动添加 IP:端口或一键扫描 /24 网段自动发现。
///
/// 管理:Ollama(本机与远程)支持按模型卸载、批量卸载、续期保活;可开启对应服务或打开控制台。
///
/// 说明:所有请求都显式禁用代理,避免被本机科学上网代理拦截。
final class ModelMonitor {

    static let shared = ModelMonitor()

    // MARK: - 数据模型

    enum Kind: String, CaseIterable {
        case ollama, lmstudio, mlx, llamaCpp, openai, comfyui

        var title: String {
            switch self {
            case .ollama: return "Ollama"
            case .lmstudio: return "LM Studio"
            case .mlx: return "MLX"
            case .llamaCpp: return "llama.cpp"
            case .openai: return "OpenAI 兼容"
            case .comfyui: return "ComfyUI"
            }
        }

        /// 该运行时在 ps 输出里可识别的进程特征。
        var processMarkers: [String] {
            switch self {
            case .ollama: return ["/ollama", "ollama serve", "ollama.app"]
            case .lmstudio: return ["lm studio", "lmstudio", "/lms ", "lm-studio"]
            case .mlx: return ["mlx_lm.server", "mlx-lm", "mlx_lm", "omlx"]
            case .llamaCpp: return ["llama-server"]
            // ComfyUI 是 python 进程,按名字匹配会误伤其他脚本;
            // 它的显存占用来自自身 API,进程 RSS 反而看不出问题(见 probeComfyUI)。
            case .openai, .comfyui: return []
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
            case .comfyui:
                return exists("/Applications/Comfy Desktop.app") || exists("~/ComfyUI-Installs") || exists("~/ComfyUI")
            case .openai:
                return false
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
        var host: String = "127.0.0.1"
        var port: Int
        var version: String?
        var loaded: [Loaded]
        var installed: Int         // 已下载/可见的模型数量
        var controllable: Bool     // 是否支持卸载等管理动作
        var remote: Bool = false   // 局域网内的其他机器(如 Windows 上的 Ollama)

        // ComfyUI 专有:模型常驻显存且不暴露「已加载列表」,这两组数才看得出占用情况
        var vramFree: UInt64 = 0
        var vramTotal: UInt64 = 0
        var queueRunning: Int = 0
        var queuePending: Int = 0

        /// 端点标识 "host:port";IPv6 字面量带方括号。
        var endpoint: String { Self.endpointKey(host: host, port: port) }

        static func endpointKey(host: String, port: Int) -> String {
            host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        }

        static func httpBase(host: String, port: Int) -> String {
            host.contains(":") ? "http://[\(host)]:\(port)" : "http://\(host):\(port)"
        }

        /// 解析 "host[:port]",端口缺省 11434;接受 http:// 前缀、IPv6 字面量与尾部路径。
        static func parseEndpoint(_ spec: String) -> (host: String, port: Int)? {
            var s = spec.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("http://") { s.removeFirst(7) }
            else if s.hasPrefix("https://") { s.removeFirst(8) }
            s = s.split(separator: "/", maxSplits: 1).first.map(String.init) ?? s
            guard !s.isEmpty else { return nil }

            var host = s
            var port = 11434
            if s.hasPrefix("[") {                                  // [::1]:11434
                guard let close = s.firstIndex(of: "]") else { return nil }
                host = String(s[s.index(after: s.startIndex)..<close])
                let rest = s[s.index(after: close)...]
                if rest.hasPrefix(":"), let p = Int(rest.dropFirst()) { port = p }
            } else if s.contains(":") {
                let parts = s.split(separator: ":", omittingEmptySubsequences: false)
                if parts.count == 2, let p = Int(parts[1]), !parts[1].isEmpty {
                    host = String(parts[0])
                    port = p
                } else if parts.count > 2 {
                    // 多段冒号:裸 IPv6,端口保持默认
                } else {
                    return nil   // "host:"、"host:abc" 这类非法写法
                }
            }
            guard !host.isEmpty, (1...65535).contains(port) else { return nil }
            return (host, port)
        }
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

    // MARK: - 远程主机(局域网内的 Windows / Linux 推理机)

    private static let remoteKey = "remoteModelEndpoints"

    /// 已保存的远程端点("host:port"),持久化在 UserDefaults。
    private(set) var remoteEndpoints: [String] = []
    /// 本次探测中无响应的端点。
    private(set) var offlineEndpoints: [String] = []

    var remoteRuntimes: [Runtime] { runtimes.filter(\.remote) }
    var localRuntimes: [Runtime] { runtimes.filter { !$0.remote } }

    /// endpoint -> 探测结果(nil = 离线)。
    private var remoteCache: [String: Runtime?] = [:]
    private var lastRemoteProbe = Date.distantPast
    private var remoteDirty = true

    private func loadRemoteEndpoints() {
        remoteEndpoints = UserDefaults.standard.stringArray(forKey: Self.remoteKey) ?? []
    }

    @discardableResult
    func addRemoteEndpoint(_ spec: String) -> Bool {
        guard let (host, port) = Runtime.parseEndpoint(spec) else { return false }
        let key = Runtime.endpointKey(host: host, port: port)
        if remoteEndpoints.contains(key) {
            notice = "\(key) 已在列表中"
            return true
        }
        remoteEndpoints.append(key)
        UserDefaults.standard.set(remoteEndpoints, forKey: Self.remoteKey)
        remoteDirty = true
        notice = "已添加远程主机 \(key),正在探测…"
        return true
    }

    func removeRemoteEndpoint(_ endpoint: String) {
        remoteEndpoints.removeAll { $0 == endpoint }
        UserDefaults.standard.set(remoteEndpoints, forKey: Self.remoteKey)
        remoteCache[endpoint] = nil
        remoteDirty = true
        scheduleRefresh()
    }

    // MARK: - 生命周期

    private var timer: Timer?
    private var polling = false

    func start(interval: TimeInterval = 5) {
        loadRemoteEndpoints()
        remoteDirty = true
        refreshNow()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
    }

    /// forceRemote:立即重探远程主机(菜单打开 / 管理动作后),不受节流窗口约束。
    func refreshNow(forceRemote: Bool = false) {
        guard !polling else {
            if forceRemote { remoteDirty = true }
            return
        }
        polling = true
        if forceRemote { remoteDirty = true }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snapshot = self.collect()
            DispatchQueue.main.async {
                self.runtimes = snapshot.runtimes
                self.offlineEndpoints = snapshot.offlineEndpoints
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

    /// 结构签名:仅在「运行时集合 / 已加载模型集合 / 扫描状态」变化时才需要重建菜单。
    /// 数值类指标(GPU、CPU、倒计时)走就地刷新,避免每 5 秒重建菜单打断交互。
    var structuralSignature: String {
        let base = runtimes.map { rt -> String in
            let id = rt.remote ? "\(rt.host):\(rt.port)" : "local:\(rt.port)"
            return "\(id)|\(rt.kind.rawValue):\(rt.installed):" + rt.loaded.map(\.name).joined(separator: ",")
        }.joined(separator: ";")
        let offline = offlineEndpoints.sorted().joined(separator: ",")
        let scan = (scanning ? "S1" : "S0") + scanCandidates.map { $0.endpoint + $0.kindTitle }.joined(separator: ",")
        // 提示语出现/消失也属于结构变化(菜单项增删),需要重建
        return base + "#" + offline + "#" + scan + "#" + (notice.map { String($0.count) } ?? "-")
    }

    /// 完整签名(结构 + 数值),供外部需要时判断。
    var signature: String {
        var parts: [String] = ["gpu\(Int(gpuUtil))", "mem\(memUsed / (1 << 30))", memPressure]
        for rt in runtimes {
            var s = "\(rt.kind.rawValue):\(rt.host):\(rt.port):\(rt.installed)"
            for m in rt.loaded {
                let remain = m.expires.map { Int(max(0, $0.timeIntervalSinceNow) / 60) } ?? -1
                s += "|\(m.name)@\(remain)"
            }
            if let p = procs[rt.kind] { s += "|cpu\(Int(p.cpu / 5) * 5)" }
            if rt.kind == .comfyui { s += "|vram\(rt.vramFree / (1 << 30))|q\(rt.queueRunning)/\(rt.queuePending)" }
            parts.append(s)
        }
        return parts.joined(separator: ";")
    }

    // MARK: - 采集

    private struct Snapshot {
        var runtimes: [Runtime]
        var offlineEndpoints: [String]
        var procs: [Kind: ProcStat]
        var gpuUtil: Double
        var memUsed: UInt64
        var memTotal: UInt64
        var memPressure: String
    }

    private func collect() -> Snapshot {
        let allProcs = sampleProcesses()
        var procs: [Kind: ProcStat] = [:]
        for kind in Kind.allCases where !kind.processMarkers.isEmpty {
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

        // 远程主机探测:动作(add/卸载)后置 dirty 立即重探,平时 12 秒节流
        if !remoteEndpoints.isEmpty {
            if remoteDirty || Date().timeIntervalSince(lastRemoteProbe) >= 12 {
                lastRemoteProbe = Date()
                remoteDirty = false
                remoteCache = probeRemotesConcurrently()
            }
        }

        var remoteRTs: [Runtime] = []
        var offline: [String] = []
        for ep in remoteEndpoints {
            if let rt = remoteCache[ep] ?? nil {
                remoteRTs.append(rt)
            } else {
                offline.append(ep)
            }
        }

        let mem = sampleMemory()
        return Snapshot(runtimes: probeAll() + remoteRTs,
                        offlineEndpoints: offline,
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

    /// 与 getJSON 相同,但用于返回顶层数组的接口(如 ComfyUI 的 /models/*)。
    private func getJSONArray(_ urlString: String, timeout: TimeInterval = 1.5) -> [Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        let sem = DispatchSemaphore(value: 0)
        var out: [Any]?
        let session = makeSession(timeout)
        session.dataTask(with: req) { data, _, _ in
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [Any] { out = obj }
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
        for p in [8200, 8188] where !usedPorts.contains(p) {   // 8200 = Comfy Desktop,8188 = ComfyUI 默认
            if let r = probeComfyUI(port: p) { out.append(r); usedPorts.insert(p); break }
        }
        return out
    }

    private func probeOllama(host: String = "127.0.0.1", port: Int) -> Runtime? {
        let base = Runtime.httpBase(host: host, port: port)
        guard let ver = getJSON("\(base)/api/version") else { return nil }
        let version = ver["version"] as? String

        var loaded: [Loaded] = []
        if let ps = getJSON("\(base)/api/ps"),
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
        if let tags = getJSON("\(base)/api/tags"),
           let models = tags["models"] as? [[String: Any]] {
            installed = models.count
        }

        return Runtime(kind: .ollama, host: host, port: port, version: version,
                       loaded: loaded, installed: installed, controllable: true)
    }

    private func probeLMStudio(host: String = "127.0.0.1", port: Int) -> Runtime? {
        if let rt = probeLMStudioV0(host: host, port: port) { return rt }
        // 本机兜底:LM Studio 关闭 v0 API 时退回 OpenAI 兼容端点
        if var rt = probeOpenAICompatible(host: host, port: port) {
            rt.kind = .lmstudio
            return rt
        }
        return nil
    }

    /// LM Studio 的 v0 API,带加载状态与量化信息。
    private func probeLMStudioV0(host: String, port: Int) -> Runtime? {
        let base = Runtime.httpBase(host: host, port: port)
        guard let d = getJSON("\(base)/api/v0/models"),
              let arr = d["data"] as? [[String: Any]] else { return nil }
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
        return Runtime(kind: .lmstudio, host: host, port: port, version: nil,
                       loaded: loaded, installed: arr.count, controllable: true)
    }

    /// 通用 OpenAI 兼容服务(vLLM、KoboldCpp、text-generation-webui 等)。
    private func probeOpenAICompatible(host: String, port: Int) -> Runtime? {
        let base = Runtime.httpBase(host: host, port: port)
        guard let d = getJSON("\(base)/v1/models", timeout: 2.0),
              let arr = d["data"] as? [[String: Any]], !arr.isEmpty else { return nil }
        let loaded = arr.map {
            Loaded(name: $0["id"] as? String ?? "?", sizeBytes: 0, vramBytes: 0, expires: nil, meta: "")
        }
        return Runtime(kind: .openai, host: host, port: port, version: nil,
                       loaded: loaded, installed: arr.count, controllable: false)
    }

    /// ComfyUI(含 Comfy Desktop)。它不暴露「已加载模型列表」,但 /system_stats 给出
    /// 显存可用量——这正是排查「画完图后 20GB 显存一直被占着」最需要的数字。
    private func probeComfyUI(host: String = "127.0.0.1", port: Int) -> Runtime? {
        let base = Runtime.httpBase(host: host, port: port)
        guard let d = getJSON("\(base)/system_stats", timeout: 2.0),
              let sys = d["system"] as? [String: Any],
              let version = sys["comfyui_version"] as? String else { return nil }

        var rt = Runtime(kind: .comfyui, host: host, port: port, version: version,
                         loaded: [], installed: 0, controllable: true)
        if let devices = d["devices"] as? [[String: Any]], let dev = devices.first {
            rt.vramFree = (dev["vram_free"] as? NSNumber)?.uint64Value ?? 0
            rt.vramTotal = (dev["vram_total"] as? NSNumber)?.uint64Value ?? 0
        }
        if let q = getJSON("\(base)/queue") {
            rt.queueRunning = (q["queue_running"] as? [Any])?.count ?? 0
            rt.queuePending = (q["queue_pending"] as? [Any])?.count ?? 0
        }
        rt.installed = getJSONArray("\(base)/models/checkpoints")?.count ?? 0
        return rt
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

    private func probeLlamaCpp(host: String = "127.0.0.1", port: Int) -> Runtime? {
        let base = Runtime.httpBase(host: host, port: port)
        guard let d = getJSON("\(base)/props") else { return nil }
        guard d["default_generation_settings"] != nil || d["model_path"] != nil || d["model_alias"] != nil else {
            return nil
        }
        var name = (d["model_alias"] as? String) ?? ""
        if name.isEmpty, let p = d["model_path"] as? String {
            name = (p as NSString).lastPathComponent
        }
        if name.isEmpty { name = "llama.cpp 模型" }
        return Runtime(kind: .llamaCpp, host: host, port: port, version: nil,
                       loaded: [Loaded(name: name, sizeBytes: 0, vramBytes: 0, expires: nil, meta: "")],
                       installed: 1, controllable: false)
    }

    // MARK: - 远程端点探测

    /// 识别一个远程端点上跑的推理服务。llama.cpp 的 /props 优先于通用 /v1/models,
    /// 避免 vLLM 等被误判为 LM Studio。
    func probeRemoteEndpoint(_ endpoint: String) -> Runtime? {
        guard let (host, port) = Runtime.parseEndpoint(endpoint) else { return nil }
        // 先快速 TCP 探测:离线主机直接返回,避免逐个 API 等超时
        guard Self.tcpOpen(host: host, port: port, timeoutMs: 800) else { return nil }

        if let rt = probeOllama(host: host, port: port) {
            var r = rt
            r.remote = true
            return r
        }
        if var r = probeComfyUI(host: host, port: port) {
            r.remote = true   // /free 走 HTTP,远程照样能释放显存
            return r
        }
        if let rt = probeLlamaCpp(host: host, port: port) {
            var r = rt
            r.remote = true
            return r
        }
        if var r = probeLMStudioV0(host: host, port: port) {
            r.remote = true
            r.controllable = false   // lms CLI 只能管本机,远程没有 HTTP 卸载接口
            return r
        }
        if var r = probeOpenAICompatible(host: host, port: port) {
            r.remote = true
            return r
        }
        return nil
    }

    private func probeRemotesConcurrently() -> [String: Runtime?] {
        var out: [String: Runtime?] = [:]
        let group = DispatchGroup()
        let lock = NSLock()
        for ep in remoteEndpoints {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { group.leave(); return }
                let rt = self.probeRemoteEndpoint(ep)
                lock.lock()
                out[ep] = rt
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        return out
    }

    // MARK: - 管理动作

    /// 触发 Ollama 加载/卸载/续期。生成模型走 /api/generate;
    /// 纯向量模型(bge 等)会拒绝 generate,回退到 /api/embed。
    /// keep_alive 传 0 表示立即卸载,传时长字符串表示续期。
    @discardableResult
    private func ollamaLifecycle(host: String = "127.0.0.1", port: Int, model: String, keepAlive: Any) -> Bool {
        let base = Runtime.httpBase(host: host, port: port)
        // 生成/对话类模型:空 prompt 只做加载,不产生实际推理开销
        if postJSON("\(base)/api/generate", ["model": model, "keep_alive": keepAlive]) { return true }
        // 向量模型回退:带一段短输入即可完成加载/卸载
        return postJSON("\(base)/api/embed", ["model": model, "input": "ping", "keep_alive": keepAlive])
    }

    /// 参与管理的 Ollama 运行时:给定端点则只取该端点,否则只取本机。
    private func ollamaTargets(endpoint: String?) -> [Runtime] {
        runtimes.filter { rt in
            guard rt.kind == .ollama else { return false }
            if let endpoint { return rt.endpoint == endpoint }
            return !rt.remote
        }
    }

    /// 卸载所有已加载的 Ollama 模型(可指定远程端点),返回成功数量。
    @discardableResult
    func unloadAllOllama(endpoint: String? = nil) -> Int {
        var n = 0
        for rt in ollamaTargets(endpoint: endpoint) {
            for m in rt.loaded where ollamaLifecycle(host: rt.host, port: rt.port, model: m.name, keepAlive: 0) {
                n += 1
            }
        }
        if n > 0 {
            notice = endpoint == nil ? "已卸载 \(n) 个模型" : "已卸载 \(endpoint!) 上的 \(n) 个模型"
        }
        remoteDirty = true
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshNow() }
        return n
    }

    /// 把已加载的 Ollama 模型保活时间延长,避免反复冷启动(可指定远程端点)。
    @discardableResult
    func keepAliveOllama(_ duration: String = "30m", endpoint: String? = nil) -> Int {
        var n = 0
        for rt in ollamaTargets(endpoint: endpoint) {
            for m in rt.loaded where ollamaLifecycle(host: rt.host, port: rt.port, model: m.name, keepAlive: duration) {
                n += 1
            }
        }
        if n > 0 {
            notice = endpoint == nil ? "保活已延长至 \(duration)" : "\(endpoint!) 保活已延长至 \(duration)"
        }
        remoteDirty = true
        refreshNow()
        return n
    }

    /// 让 ComfyUI 卸载已加载的模型并释放显存(等价于面板上的「释放显存」)。
    /// 下次生成会自动重新加载,代价只是第一次稍慢。
    @discardableResult
    func freeComfyUIMemory(endpoint: String? = nil) -> Bool {
        let target = runtimes.first {
            $0.kind == .comfyui && (endpoint == nil ? !$0.remote : $0.endpoint == endpoint)
        }
        guard let rt = target else { return false }
        let ok = postJSON("\(Runtime.httpBase(host: rt.host, port: rt.port))/free",
                          ["unload_models": true, "free_memory": true], timeout: 10)
        notice = ok
            ? (rt.remote ? "已请求 \(rt.endpoint) 释放显存" : "已请求 ComfyUI 释放显存")
            : "释放失败:ComfyUI 未响应"
        remoteDirty = true
        scheduleRefresh()
        return ok
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
        case .comfyui:
            if FileManager.default.fileExists(atPath: "/Applications/Comfy Desktop.app") {
                path = "/usr/bin/open"; args = ["-a", "Comfy Desktop"]
            } else {
                path = nil; args = []
            }
        case .openai:
            return false   // 通用 OpenAI 兼容服务没有本机可启动的固定入口
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
                if !rt.remote, FileManager.default.fileExists(atPath: "/Applications/LM Studio.app") {
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: "/Applications/LM Studio.app"),
                        configuration: NSWorkspace.OpenConfiguration())
                    return
                }
                if let u = URL(string: Runtime.httpBase(host: rt.host, port: rt.port)) { NSWorkspace.shared.open(u) }
            case .mlx, .llamaCpp, .openai, .comfyui:
                if let u = URL(string: Runtime.httpBase(host: rt.host, port: rt.port)) { NSWorkspace.shared.open(u) }
            case .ollama:
                if !rt.remote, FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: "/Applications/Ollama.app"),
                        configuration: NSWorkspace.OpenConfiguration())
                } else if let u = URL(string: Runtime.httpBase(host: rt.host, port: rt.port)) {
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
            guard let rt = runtimes.first(where: { $0.kind == .ollama && !$0.remote }) else { return false }
            let ok = ollamaLifecycle(host: rt.host, port: rt.port, model: name, keepAlive: 0)
            if ok { notice = "已卸载 \(name)" }
            scheduleRefresh()
            return ok
        case .lmstudio:
            guard let lms = lmsPath else { return false }
            let ok = runDetachedSync(lms, ["unload", name], timeout: 20)
            if ok { notice = "已卸载 \(name)" }
            scheduleRefresh()
            return ok
        case .mlx, .llamaCpp, .openai, .comfyui:
            return false   // ComfyUI 无按模型卸载接口,用 freeComfyUIMemory 一次性释放
        }
    }

    /// 卸载远程主机(如 Windows 上的 Ollama)上的单个模型。
    @discardableResult
    func unloadRemoteModel(_ endpoint: String, name: String) -> Bool {
        guard let (host, port) = Runtime.parseEndpoint(endpoint) else { return false }
        let ok = ollamaLifecycle(host: host, port: port, model: name, keepAlive: 0)
        notice = ok ? "已卸载远程 \(name)" : "卸载失败:\(endpoint) 未响应"
        remoteDirty = true
        scheduleRefresh()
        return ok
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

    // MARK: - 局域网扫描

    struct ScanCandidate {
        let endpoint: String
        let kindTitle: String
    }

    /// 扫描的常见推理端口:Ollama / LM Studio / llama.cpp / KoboldCpp / vLLM / text-generation-webui / ComfyUI
    static let scanPorts = [11434, 1234, 8080, 5001, 8000, 5000, 8188, 8200]

    private(set) var scanning = false
    private(set) var scanCandidates: [ScanCandidate] = []

    /// 手动触发局域网扫描(主网卡所在 /24 网段,跳过本机)。
    /// 结果存入 scanCandidates,菜单里一键添加;约 3~10 秒。
    @discardableResult
    func startScan() -> Bool {
        guard !scanning else { return false }
        scanning = true
        notice = "正在扫描局域网…"
        onUpdate?()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let found = self.scanLAN()
            DispatchQueue.main.async {
                self.scanning = false
                self.scanCandidates = found.filter { !self.remoteEndpoints.contains($0.endpoint) }
                self.notice = found.isEmpty
                    ? "扫描完成:未发现模型服务"
                    : "扫描完成:发现 \(found.count) 个服务,在「扫描局域网」下方点击添加"
                self.onUpdate?()
            }
        }
        return true
    }

    func clearScanCandidates() {
        scanCandidates = []
    }

    /// 扫描指定网段前缀(如 "192.168.3")的 /24;nil 时用主网卡网段。
    /// 供 startScan 调用,前缀参数留作测试缝。
    func scanLAN(prefix: String? = nil) -> [ScanCandidate] {
        var scanPrefix = prefix
        if scanPrefix == nil, let ip = Self.primaryIPv4() {
            let octets = ip.split(separator: ".")
            if octets.count == 4 { scanPrefix = octets.dropLast().joined(separator: ".") }
        }
        guard let scanPrefix else { return [] }
        let ownIPs = Set(Self.localIPv4s().map(\.ip))

        var targets: [(ip: String, port: Int)] = []
        for i in 1...254 {
            let host = "\(scanPrefix).\(i)"
            if ownIPs.contains(host) { continue }
            for p in Self.scanPorts { targets.append((host, p)) }
        }

        var out: [ScanCandidate] = []
        for (host, port) in Self.probeTCPPorts(targets) {
            let ep = Runtime.endpointKey(host: host, port: port)
            guard let rt = probeRemoteEndpoint(ep) else { continue }
            out.append(ScanCandidate(endpoint: ep, kindTitle: rt.kind.title))
        }
        return out.sorted { $0.endpoint < $1.endpoint }
    }

    /// 非阻塞 TCP 连接探测,timeoutMs 内可连上视为端口开放。
    static func tcpOpen(host: String, port: Int, timeoutMs: Int32 = 400) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else { return false }
        defer { freeaddrinfo(info) }

        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc = connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen)
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMs) > 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    /// 并发探测一批 (ip, port),返回可连通的。128 并发下全 /24 × 6 端口约 3~5 秒。
    static func probeTCPPorts(_ targets: [(ip: String, port: Int)],
                              concurrency: Int = 128, timeoutMs: Int32 = 400) -> [(ip: String, port: Int)] {
        let queue = DispatchQueue(label: "gt.tcp-scan", attributes: .concurrent)
        let sem = DispatchSemaphore(value: concurrency)
        let group = DispatchGroup()
        let lock = NSLock()
        var open: [(ip: String, port: Int)] = []
        for t in targets {
            sem.wait()
            group.enter()
            queue.async {
                defer { group.leave(); sem.signal() }
                if tcpOpen(host: t.ip, port: t.port, timeoutMs: timeoutMs) {
                    lock.lock()
                    open.append(t)
                    lock.unlock()
                }
            }
        }
        group.wait()
        return open
    }

    private struct IPv4Addr {
        let name: String
        let ip: String
    }

    /// 所有已启用、非环回接口的 IPv4。
    private static func localIPv4s() -> [IPv4Addr] {
        var out: [IPv4Addr] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            ptr = p.pointee.ifa_next
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0,
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }

            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            out.append(IPv4Addr(name: String(cString: ifa.ifa_name), ip: String(cString: buf)))
        }
        return out
    }

    /// 主网卡(优先 en*):扫描用它的 /24 网段。
    static func primaryIPv4() -> String? {
        let all = localIPv4s()
        return all.first(where: { $0.name.hasPrefix("en") })?.ip ?? all.first?.ip
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
