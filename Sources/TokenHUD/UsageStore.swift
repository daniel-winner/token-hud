import Foundation

struct ModelStat {
    var tokens = 0
    var calls = 0
    var generations: [(ts: Int64, ms: Int, out: Int)] = []

    /// 该模型的平均输出速度 (token/s)，按总输出 / 总生成时间加权
    var avgSpeed: Double? {
        let ms = generations.reduce(0) { $0 + $1.ms }
        let out = generations.reduce(0) { $0 + $1.out }
        guard ms > 0 else { return nil }
        return Double(out) / (Double(ms) / 1000.0)
    }

    var lastSpeed: Double? {
        guard let g = generations.last, g.ms > 0 else { return nil }
        return Double(g.out) / (Double(g.ms) / 1000.0)
    }
}

/// 单个会话文件对「今天」的贡献。
struct DayStats {
    var inputTokens = 0
    var outputTokens = 0
    var cachedTokens = 0
    var reasoningTokens = 0
    var llmCalls = 0
    var userTurns = 0
    var sessions = Set<String>()
    var models = [String: ModelStat]()

    /// 每次 LLM 生成：(时间戳, 生成耗时 ms, 输出 token 数)
    var generations: [(ts: Int64, ms: Int, out: Int)] = []

    /// 解析游标状态：上一次工具返回的时刻（生成耗时推导的起点边界）
    var lastBoundary: Int64 = 0

    mutating func reset() {
        let keepBoundary = lastBoundary
        self = DayStats()
        lastBoundary = keepBoundary
    }
}

/// 汇总视图：今日全量 + 当前模型
struct UsageSnapshot {
    var day = ""
    var input = 0
    var output = 0
    var cached = 0
    var reasoning = 0
    var llmCalls = 0
    var userTurns = 0
    var topLevelTurns = 0
    var subagentTasks = 0
    var sessionCount = 0
    var models = [String: ModelStat]()
    var generations: [(ts: Int64, ms: Int, out: Int)] = []
    var currentModel = "—"
    var updatedAt = Date()

    var totalTokens: Int { input + output }

    var cacheHitRate: Double {
        input > 0 ? Double(cached) / Double(input) : 0
    }

    /// 最近一次生成的输出速度 (token/s)
    var lastSpeed: Double? {
        guard let g = generations.last, g.ms > 0 else { return nil }
        return Double(g.out) / (Double(g.ms) / 1000.0)
    }

    /// 今日平均输出速度 (token/s)
    var avgSpeed: Double? {
        let ms = generations.reduce(0) { $0 + $1.ms }
        let out = generations.reduce(0) { $0 + $1.out }
        guard ms > 0 else { return nil }
        return Double(out) / (Double(ms) / 1000.0)
    }

    /// 最近一次 LLM 调用的响应耗时 (秒)
    var lastLatencySec: Double? {
        guard let g = generations.last else { return nil }
        return Double(g.ms) / 1000.0
    }

    var currentModelStat: ModelStat? { models[currentModel] }
}

/// 增量解析 WorkBuddy 会话日志，统计「今天」的 token 与速度。
///
/// 数据源：~/.workbuddy/projects/**\/*.jsonl
///  - token 用量：providerData.usage（inputTokens / outputTokens / cached / reasoning）
///  - 生成耗时：以「上一轮工具返回时间戳 → 本轮 usage 时间戳」推导
///    （已与 ~/.workbuddy/traces 的 generation span 交叉校验，中位误差 49ms）
final class UsageStore {

    private struct FileCursor {
        var offset: UInt64 = 0
        var dayKey = ""
        /// 上次读取末尾的残行（尚未以换行结束的半条记录）
        var pending = ""
        var stats = DayStats()
    }

    private var cursors: [String: FileCursor] = [:]
    private let projectsRoot: String
    private let calendar: Calendar

    init(projectsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/projects").path,
         calendar: Calendar = .current) {
        self.projectsRoot = projectsRoot
        self.calendar = calendar
    }

    private func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private func startOfTodayMs() -> Int64 {
        Int64(calendar.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
    }

    /// 扫描全部会话文件，返回今日汇总。
    func collect() -> UsageSnapshot {
        let today = dayKey(Date())
        let since = startOfTodayMs()
        var snapshot = UsageSnapshot()
        snapshot.day = today

        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: projectsRoot),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return snapshot }

        var seen = Set<String>()

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let path = url.path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }

            // 追加式日志：今天未改动 = 今日贡献为 0
            if dayKey(mtime) != today { continue }
            seen.insert(path)

            var cursor = cursors[path] ?? FileCursor()
            if cursor.dayKey != today {
                cursor.dayKey = today
                cursor.offset = 0
                cursor.pending = ""
                cursor.stats.reset()
            }

            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            if size < cursor.offset {
                // 文件被截断重写
                cursor.offset = 0
                cursor.pending = ""
                cursor.stats.reset()
            }

            if size > cursor.offset {
                // 首次读取时，从文件尾部回溯定位「今天」的起始偏移，
                // 避免为一个跨天的大文件全量扫描（个别会话日志可达数百 MB）。
                if cursor.offset == 0 && size > readThreshold {
                    let start = todayStartOffset(path: path, size: size, since: since)
                    cursor.offset = start
                }
                if size > cursor.offset {
                    let newBytes = readRange(path: path, from: cursor.offset, to: size)
                    cursor.offset = size
                    parse(bytes: newBytes, since: since, pending: &cursor.pending, into: &cursor.stats)
                }
            }

            cursors[path] = cursor
        }

        // 汇总
        var models = [String: ModelStat]()
        var generations: [(ts: Int64, ms: Int, out: Int)] = []
        var sessions = Set<String>()
        var turns = 0
        var subagentTasks = 0
        var topLevelTurns = 0

        for (path, cursor) in cursors where seen.contains(path) {
            let s = cursor.stats
            snapshot.input += s.inputTokens
            snapshot.output += s.outputTokens
            snapshot.cached += s.cachedTokens
            snapshot.reasoning += s.reasoningTokens
            snapshot.llmCalls += s.llmCalls
            turns += s.userTurns
            generations += s.generations
            sessions.formUnion(s.sessions)

            if path.contains("/subagents/") {
                subagentTasks += s.userTurns
            } else {
                topLevelTurns += s.userTurns
            }

            for (name, st) in s.models {
                var merged = models[name] ?? ModelStat()
                merged.tokens += st.tokens
                merged.calls += st.calls
                merged.generations += st.generations
                models[name] = merged
            }
        }

        for (name, st) in models {
            var sorted = st.generations
            sorted.sort { $0.ts < $1.ts }
            models[name]?.generations = sorted
        }
        generations.sort { $0.ts < $1.ts }

        snapshot.models = models
        snapshot.generations = generations
        snapshot.userTurns = turns
        snapshot.subagentTasks = subagentTasks
        snapshot.topLevelTurns = topLevelTurns
        snapshot.sessionCount = sessions.count
        snapshot.currentModel = models.keys.sorted { lhs, rhs in
            let l = models[lhs]!, r = models[rhs]!
            if l.calls != r.calls { return l.calls > r.calls }
            return lhs < rhs
        }.first ?? "—"
        snapshot.updatedAt = Date()
        return snapshot
    }

    /// 超过此大小才启用回溯定位（字节）
    private let readThreshold: UInt64 = 8 * 1024 * 1024

    /// 从文件尾部向前分块回溯，找到第一条「今天之前」的记录所在位置，
    /// 返回它的起始字节偏移（即今日内容的起点）。
    private func todayStartOffset(path: String, size: UInt64, since: Int64) -> UInt64 {
        let chunkSize: UInt64 = 4 * 1024 * 1024
        var cursor = size

        while cursor > 0 {
            let readLen = min(chunkSize, cursor)
            let start = cursor - readLen
            let data = readRange(path: path, from: start, to: cursor)
            guard !data.isEmpty else { break }
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.components(separatedBy: "\n")

            // 从后往前找第一条 timestamp < since 的完整行
            var offsetInChunk = text.utf8.count
            var found = false
            for line in lines.reversed() {
                guard let obj = parseJSON(line) else { continue }
                guard let ts = obj["timestamp"] as? Int64 else { continue }
                if ts < since {
                    // 这行是今日之前内容的最后一行 → 今日从它的下一行开始
                    let lineBytes = line.utf8.count + 1 // 含换行
                    offsetInChunk = max(0, offsetInChunk - lineBytes)
                    found = true
                    break
                }
                offsetInChunk = max(0, offsetInChunk - (line.utf8.count + 1))
            }

            if found {
                return start + UInt64(offsetInChunk)
            }

            if start == 0 { break }
            cursor = start
        }

        return 0
    }

    private func readRange(path: String, from: UInt64, to: UInt64) -> Data {
        guard to > from,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return Data() }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: from)
            return try handle.read(upToCount: Int(to - from)) ?? Data()
        } catch {
            return Data()
        }
    }

    /// 解析增量字节。
    ///
    /// 日志是追加写的，读到的末段可能是正在写入的残行。做法：
    ///  - 以 "\n" 切分，末段单独处理
    ///  - 末段若能解析成 JSON，说明它是完整记录 → 直接采用
    ///  - 末段解析失败 → 是残行，缓存起来等下次追加后再拼上
    ///
    /// 注意不能无条件丢弃末段 —— 日志末尾常常不以换行结尾，
    /// 无条件丢弃会漏掉最后一条完整记录。
    private func parse(bytes: Data, since: Int64, pending: inout String, into stats: inout DayStats) {
        guard !bytes.isEmpty else { return }
        let text = pending + String(decoding: bytes, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        let tail = lines.removeLast()

        for line in lines {
            guard let obj = parseJSON(line) else { continue }
            handle(obj: obj, since: since, stats: &stats)
        }

        // 末段：能解析就是完整记录，否则缓存为残行
        if let obj = parseJSON(tail) {
            handle(obj: obj, since: since, stats: &stats)
            pending = ""
        } else {
            pending = tail
        }
    }

    private func parseJSON(_ line: String) -> [String: Any]? {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private func handle(obj: [String: Any], since: Int64, stats: inout DayStats) {
        guard let ts = obj["timestamp"] as? Int64, ts >= since else { return }

        let type = obj["type"] as? String ?? ""

        if type == "function_call_result" {
            // 工具返回时刻 —— 下一次生成的起点边界
            stats.lastBoundary = ts
            return
        }

        if type == "message", let role = obj["role"] as? String, role == "user" {
            if !isInjectedUserMessage(obj) { stats.userTurns += 1 }
            return
        }

        if let sid = obj["sessionId"] as? String { stats.sessions.insert(sid) }

        let pd = obj["providerData"] as? [String: Any] ?? [:]
        guard let usage = pd["usage"] as? [String: Any] else { return }

        let input = usage["inputTokens"] as? Int ?? 0
        let output = usage["outputTokens"] as? Int ?? 0
        let total = usage["totalTokens"] as? Int ?? 0

        var cached = 0
        if let details = usage["inputTokensDetails"] as? [[String: Any]] {
            for d in details { cached += d["cached_tokens"] as? Int ?? 0 }
        }
        var reasoning = 0
        if let details = usage["outputTokensDetails"] as? [[String: Any]] {
            for d in details { reasoning += d["reasoning_tokens"] as? Int ?? 0 }
        }

        stats.inputTokens += input
        stats.outputTokens += output
        stats.cachedTokens += cached
        stats.reasoningTokens += reasoning
        stats.llmCalls += 1

        let model = (pd["requestModelName"] as? String)
            ?? (pd["requestModelId"] as? String)
            ?? (pd["model"] as? String)
            ?? "unknown"

        var mstat = stats.models[model] ?? ModelStat()
        mstat.tokens += (total > 0 ? total : input + output)
        mstat.calls += 1

        // 生成耗时 = 本轮时间戳 - 上一轮工具返回时间戳
        if stats.lastBoundary > 0, ts > stats.lastBoundary {
            let ms = Int(ts - stats.lastBoundary)
            let gen = (ts: ts, ms: ms, out: output)
            stats.generations.append(gen)
            mstat.generations.append(gen)
        }

        stats.models[model] = mstat
    }

    /// 判断是否为「真实的用户提问」。
    ///
    /// 主会话的 user 消息是复合结构：前面拼接了 <system-reminder>（环境/身份注入），
    /// 真实提问包在 <user_query> 标签里。因此不能只看整条消息的前缀，
    /// 否则会把真实提问连同注入内容一起误杀。
    private func isInjectedUserMessage(_ obj: [String: Any]) -> Bool {
        let content = obj["content"]
        var text = ""
        if let arr = content as? [[String: Any]] {
            for item in arr { text += item["text"] as? String ?? "" }
        } else if let s = content as? String {
            text = s
        }

        // 提取 <user_query> 标签内的真实提问
        if let range = text.range(of: "<user_query>"),
           let end = text.range(of: "</user_query>", range: range.upperBound..<text.endIndex) {
            let query = String(text[range.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty
        }

        // 无 <user_query>：若整条都是注入标签，则不算一次真实对话
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let injectedPrefixes = ["<system-reminder", "<identity_context", "<command-name",
                                "<local-command-stdout", "<user_memory", "<product_identity"]
        if injectedPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return true
        }

        // 子代理的任务注入消息（形如「在 xxx 中核查 …」）
        return false
    }
}
