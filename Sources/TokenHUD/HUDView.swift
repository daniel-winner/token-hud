import SwiftUI

/// 数字格式化
enum Fmt {
    /// 大数字：12.3K / 4.56M
    static func compact(_ v: Int) -> String {
        if v >= 1_000_000 {
            return String(format: "%.2fM", Double(v) / 1_000_000)
        }
        if v >= 1_000 {
            return String(format: "%.1fK", Double(v) / 1_000)
        }
        return "\(v)"
    }

    /// 完整数字：12,345
    static func full(_ v: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func speed(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f", v)
    }

    static func seconds(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v < 1 { return String(format: "%.0fms", v * 1000) }
        return String(format: "%.1fs", v)
    }
}

/// 暗色主题配色。
/// 显式定义而不依赖系统外观，保证任何系统主题下都是同一套夜间观感。
enum HUDTheme {
    /// 主强调色（青蓝）
    static let accent = Color(red: 0.31, green: 0.72, blue: 1.00)
    /// 输出量（暖橙）
    static let warm = Color(red: 1.00, green: 0.64, blue: 0.32)
    /// 正向指标（绿）
    static let good = Color(red: 0.36, green: 0.86, blue: 0.56)
    /// 警示（橙红）
    static let warn = Color(red: 1.00, green: 0.60, blue: 0.32)

    /// 卡片底色：深色 + 高透明度（可透出下层内容）
    static let cardFill = Color(red: 0.035, green: 0.042, blue: 0.058).opacity(0.58)
    /// 卡片描边
    static let cardStroke = Color.white.opacity(0.13)
    /// 卡片投影
    static let cardShadow = Color.black.opacity(0.42)

    /// 文本层级
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.60)
    static let textTertiary = Color.white.opacity(0.40)

    /// 指标小方块底色
    static let chipFill = Color.white.opacity(0.055)
    /// 分隔线
    static let divider = Color.white.opacity(0.09)
}

/// 浮窗布局常量（视图与 AppKit 面板共用，保证尺寸一致）
enum HUDLayout {
    static let width: CGFloat = 268
    static let expandedHeight: CGFloat = 214
    static let compactHeight: CGFloat = 38
    /// SwiftUI 命名坐标系名
    static let spaceName = "hudRoot"
}

/// 释放按钮的位置（上报给 AppKit，用于固定状态下局部可点击）
struct ReleaseZoneKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// 视图与数据源的抽象，便于离屏渲染复用
protocol HUDModelProtocol: ObservableObject {
    var snapshot: UsageSnapshot { get }
    var isCompact: Bool { get set }
    var isLive: Bool { get }
    /// 固定（鼠标穿透）状态
    var isPinned: Bool { get set }
    func startDragging()
    func quit()
    /// 上报释放按钮在 SwiftUI 根坐标系中的位置
    func reportReleaseZone(_ rect: CGRect)
}

/// 浮窗根容器：负责坐标系锚定与释放按钮位置的回收
struct HUDRoot<M: HUDModelProtocol>: View {
    @ObservedObject var model: M

    var body: some View {
        Group {
            if model.isCompact {
                CompactHUDView(model: model)
            } else {
                HUDView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: HUDLayout.spaceName)
        .onPreferenceChange(ReleaseZoneKey.self) { rect in
            model.reportReleaseZone(rect)
        }
    }
}

/// 浮窗主视图
struct HUDView<M: HUDModelProtocol>: View {
    @ObservedObject var model: M

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(HUDTheme.divider)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 10) {
                tokenSection
                speedSection
                statsSection
            }
            .padding(.horizontal, 13)
            .padding(.top, 11)
            .padding(.bottom, 11)
        }
        .frame(width: HUDLayout.width, height: HUDLayout.expandedHeight)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(HUDTheme.cardFill)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.55)
                )
                .shadow(color: HUDTheme.cardShadow, radius: 16, x: 0, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(HUDTheme.cardStroke, lineWidth: 0.5)
        )
    }

    // MARK: - 标题栏

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isLive ? HUDTheme.good : HUDTheme.warn)
                .frame(width: 7, height: 7)

            Text("Token 监控")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HUDTheme.textSecondary)

            if model.isPinned {
                Text("已固定")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(HUDTheme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(HUDTheme.accent.opacity(0.16))
                    )
            }

            Spacer(minLength: 4)

            pinButton
            releaseButton

            Button {
                model.isCompact.toggle()
            } label: {
                Image(systemName: model.isCompact ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(HUDTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help(model.isCompact ? "展开详情" : "收起详情")

            Button {
                model.quit()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(HUDTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("退出 Token 监控")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { model.startDragging() }
    }

    /// 固定按钮：开启后窗口对鼠标完全穿透
    private var pinButton: some View {
        Button {
            model.isPinned = true
        } label: {
            Image(systemName: model.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(model.isPinned ? HUDTheme.textTertiary : HUDTheme.accent)
        }
        .buttonStyle(.plain)
        .disabled(model.isPinned)
        .help("固定浮窗：鼠标点击将穿透到下层窗口")
    }

    /// 释放按钮：固定状态下唯一的可点击入口
    private var releaseButton: some View {
        Button {
            model.isPinned = false
        } label: {
            Image(systemName: "lock.open")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(model.isPinned ? HUDTheme.accent : HUDTheme.textTertiary)
                .padding(.horizontal, model.isPinned ? 6 : 0)
                .padding(.vertical, model.isPinned ? 3 : 0)
                .background(
                    Capsule()
                        .fill(HUDTheme.accent.opacity(model.isPinned ? 0.22 : 0))
                )
                .overlay(
                    Capsule()
                        .stroke(HUDTheme.accent.opacity(model.isPinned ? 0.55 : 0), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("释放浮窗：恢复鼠标交互")
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ReleaseZoneKey.self,
                    value: proxy.frame(in: .named(HUDLayout.spaceName))
                )
            }
        )
    }

    // MARK: - Token 消耗

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("今日消耗")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(HUDTheme.textSecondary)
                Spacer()
                Text(Fmt.full(model.snapshot.totalTokens))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(HUDTheme.textPrimary)
                    .contentTransition(.numericText())
            }

            // 输入 / 输出 分段条
            GeometryReader { geo in
                let total = max(model.snapshot.totalTokens, 1)
                let inRatio = Double(model.snapshot.input) / Double(total)
                HStack(spacing: 1.5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(HUDTheme.accent.opacity(0.85))
                        .frame(width: max(0, (geo.size.width - 1.5) * inRatio))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(HUDTheme.warm.opacity(0.9))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 5)

            HStack(spacing: 10) {
                legendDot(color: HUDTheme.accent, label: "输入", value: Fmt.compact(model.snapshot.input))
                legendDot(color: HUDTheme.warm, label: "输出", value: Fmt.compact(model.snapshot.output))
                Spacer(minLength: 4)
                Text("缓存 \(Int(model.snapshot.cacheHitRate * 100))%")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(HUDTheme.textTertiary)
                    .fixedSize()
            }
        }
    }

    private func legendDot(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(HUDTheme.textSecondary)
            Text(value)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(HUDTheme.textPrimary)
                .fixedSize()
        }
        .fixedSize()
    }

    // MARK: - 速度

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(model.snapshot.currentModel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(HUDTheme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if let s = model.snapshot.currentModelStat?.calls {
                    Text("\(s) 次调用")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(HUDTheme.textTertiary)
                }
            }

            HStack(spacing: 8) {
                metricBox(title: "实时", value: Fmt.speed(model.snapshot.lastSpeed), unit: "tok/s",
                          accent: model.snapshot.lastSpeed.map { $0 > 60 } ?? false)
                metricBox(title: "平均", value: Fmt.speed(model.snapshot.avgSpeed), unit: "tok/s",
                          accent: false)
                metricBox(title: "延迟", value: Fmt.seconds(model.snapshot.lastLatencySec), unit: "",
                          accent: false)
            }
        }
    }

    private func metricBox(title: String, value: String, unit: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(HUDTheme.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent ? HUDTheme.good : HUDTheme.textPrimary)
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 8.5))
                        .foregroundStyle(HUDTheme.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(HUDTheme.chipFill)
        )
    }

    // MARK: - 计数

    private var statsSection: some View {
        HStack(spacing: 0) {
            countItem("对话", model.snapshot.topLevelTurns, icon: "bubble.left")
            countItem("子任务", model.snapshot.subagentTasks, icon: "square.stack.3d.up")
            countItem("会话", model.snapshot.sessionCount, icon: "folder")
            countItem("调用", model.snapshot.llmCalls, icon: "bolt")
        }
    }

    private func countItem(_ label: String, _ value: Int, icon: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 8.5))
                Text("\(value)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(HUDTheme.textPrimary)
            Text(label)
                .font(.system(size: 8.5))
                .foregroundStyle(HUDTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 折叠态：极简一行
struct CompactHUDView<M: HUDModelProtocol>: View {
    @ObservedObject var model: M

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(model.isLive ? HUDTheme.good : HUDTheme.warn)
                .frame(width: 6, height: 6)

            Text(Fmt.compact(model.snapshot.totalTokens))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(HUDTheme.textPrimary)
                .contentTransition(.numericText())

            Text("·").foregroundStyle(HUDTheme.textTertiary)

            Text("\(Fmt.speed(model.snapshot.lastSpeed)) tok/s")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(HUDTheme.textSecondary)
                .contentTransition(.numericText())

            Text("·").foregroundStyle(HUDTheme.textTertiary)

            Text("\(model.snapshot.topLevelTurns) 对话")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(HUDTheme.textSecondary)

            Spacer(minLength: 4)

            pinButton
            releaseButton

            Button {
                model.isCompact.toggle()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(HUDTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("展开详情")

            Button {
                model.quit()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(HUDTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("退出 Token 监控")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: HUDLayout.width, height: HUDLayout.compactHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(HUDTheme.cardFill)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.55)
                )
                .shadow(color: HUDTheme.cardShadow, radius: 12, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(HUDTheme.cardStroke, lineWidth: 0.5)
        )
    }

    private var pinButton: some View {
        Button {
            model.isPinned = true
        } label: {
            Image(systemName: model.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(model.isPinned ? HUDTheme.textTertiary : HUDTheme.accent)
        }
        .buttonStyle(.plain)
        .disabled(model.isPinned)
        .help("固定浮窗：鼠标点击将穿透到下层窗口")
    }

    private var releaseButton: some View {
        Button {
            model.isPinned = false
        } label: {
            Image(systemName: "lock.open")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(model.isPinned ? HUDTheme.accent : HUDTheme.textTertiary)
                .padding(.horizontal, model.isPinned ? 5 : 0)
                .padding(.vertical, model.isPinned ? 2 : 0)
                .background(
                    Capsule()
                        .fill(HUDTheme.accent.opacity(model.isPinned ? 0.22 : 0))
                )
                .overlay(
                    Capsule()
                        .stroke(HUDTheme.accent.opacity(model.isPinned ? 0.55 : 0), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("释放浮窗：恢复鼠标交互")
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ReleaseZoneKey.self,
                    value: proxy.frame(in: .named(HUDLayout.spaceName))
                )
            }
        )
    }
}
