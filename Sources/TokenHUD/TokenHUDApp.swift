import AppKit
import SwiftUI
import Combine

/// 浮窗的数据模型 + 定时刷新
final class HUDModel: ObservableObject, HUDModelProtocol {
    @Published var snapshot = UsageSnapshot()
    @Published var isCompact = false
    @Published var isLive = true

    /// 固定状态：开启后窗口对鼠标完全穿透，仅"释放"按钮可点
    @Published var isPinned: Bool = false {
        didSet { panel?.applyPinned(isPinned) }
    }

    private let store = UsageStore()
    private var timer: Timer?
    private var refreshQueue: DispatchQueue?
    private weak var panel: HUDPanel?

    init() {
        refresh()
        startTimer()
    }

    func attach(panel: HUDPanel) {
        self.panel = panel
        panel.applyPinned(isPinned)
    }

    private func startTimer() {
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        // 采集放到后台，避免阻塞主线程（首轮要扫较多文件）
        if refreshQueue == nil {
            refreshQueue = DispatchQueue(label: "hud.usage.collect", qos: .utility)
        }
        let store = self.store
        refreshQueue?.async {
            let snap = store.collect()
            DispatchQueue.main.async {
                self.snapshot = snap
                self.isLive = true
            }
        }
    }

    func startDragging() {
        // 面板已设置 isMovableByWindowBackground = true，
        // 按住标题栏区域拖动即可移动，这里无需额外处理。
        NSApp.activate(ignoringOtherApps: false)
    }

    /// SwiftUI 上报"释放"按钮位置（SwiftUI 根坐标系，top-left 原点）
    func reportReleaseZone(_ rect: CGRect) {
        panel?.hostView?.updateReleaseZone(rect)
    }

    func quit() {
        NSApp.terminate(nil)
    }
}

@main
struct TokenHUDApp {
    static func main() {
        // 离屏渲染模式：TokenHUD --render <输出路径> [--compact]
        let args = CommandLine.arguments
        if args.contains("--render"), let outIdx = args.firstIndex(of: "--render"), outIdx + 1 < args.count {
            let path = args[outIdx + 1]
            let compact = args.contains("--compact")
            let pinned = args.contains("--pinned")
            let snap = UsageStore().collect()
            Renderer.render(to: path, compact: compact, pinned: pinned, snapshot: snap)
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // 强制暗色外观：无论系统是亮是暗，浮窗都保持夜间观感
        app.appearance = NSAppearance(named: .darkAqua)

        let model = HUDModel()
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: HUDLayout.width, height: HUDLayout.expandedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        panel.isFloatingPanel = true
        panel.level = .floating          // 浮在普通窗口之上
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .utilityWindow
        panel.appearance = NSAppearance(named: .darkAqua)

        // 恢复上次位置；没有记录则放在主屏右上角。
        // 位置可能来自"屏幕已被拔出/分辨率变更"的旧记录，需要做可见性校正，
        // 否则浮窗会停在屏幕外，用户再也点不到。
        let defaults = UserDefaults.standard
        var origin: NSPoint?
        if let savedX = defaults.object(forKey: "panelX") as? Double,
           let savedY = defaults.object(forKey: "panelY") as? Double {
            origin = NSPoint(x: savedX, y: savedY)
        }
        if origin == nil, let screen = NSScreen.main {
            origin = NSPoint(
                x: screen.visibleFrame.maxX - HUDLayout.width - 18,
                y: screen.visibleFrame.maxY - HUDLayout.expandedHeight - 18
            )
        }
        if let o = origin {
            panel.setFrameOrigin(Self.clampToVisibleScreen(o, panel.frame.size))
        }

        let host = HUDHostingView(rootView: AnyView(
            HUDRoot(model: model)
        ))
        host.frame = NSRect(x: 0, y: 0, width: HUDLayout.width, height: HUDLayout.expandedHeight)
        panel.install(hostView: host)
        model.attach(panel: panel)

        // 固定状态下叠在"释放"按钮上的透明热区窗：主窗让路时，它是唯一可点入口
        panel.hotspot.hotspotView.onClick = { [weak model] in
            model?.isPinned = false
        }
        panel.orderFront(nil)
        panel.hotspot.orderOut(nil)
        panel.setContentSize(NSSize(width: HUDLayout.width, height: HUDLayout.expandedHeight))

        // 位置记忆：窗口移动后写回偏好设置
        let savePos = { [weak panel] in
            guard let p = panel else { return }
            // 拖到屏幕外时不记录该位置，否则下次启动会停在看不见的地方
            let f = TokenHUDApp.clampToVisibleScreen(p.frame.origin, p.frame.size)
            defaults.set(Double(f.x), forKey: "panelX")
            defaults.set(Double(f.y), forKey: "panelY")
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { _ in
            savePos()
            // 主窗移动后，热区窗要跟着走
            panel.repositionHotspot()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in savePos() }

        // 折叠/展开时同步窗口高度
        model.$isCompact
            .receive(on: RunLoop.main)
            .sink { compact in
                let h = compact ? HUDLayout.compactHeight : HUDLayout.expandedHeight
                panel.setContentSize(NSSize(width: HUDLayout.width, height: h))
            }
            .store(in: &cancellables)

        // 菜单栏
        MainMenuManager.shared.configure(model: model, panel: panel)

        app.run()
    }

    private static var cancellables = Set<AnyCancellable>()

    /// 确保浮窗至少有一部分落在某个屏幕的可见区域内。
    /// 完全跑出屏幕时，拉回到主屏右上角。
    static func clampToVisibleScreen(_ origin: NSPoint, _ size: NSSize) -> NSPoint {
        let margin: CGFloat = 40
        for screen in NSScreen.screens {
            let vf = screen.visibleFrame
            let overlapsX = origin.x + size.width > vf.minX + margin && origin.x < vf.maxX - margin
            let overlapsY = origin.y + size.height > vf.minY + margin && origin.y < vf.maxY - margin
            if overlapsX && overlapsY {
                return origin
            }
        }
        // 完全不可见 -> 拉回主屏右上角
        guard let main = NSScreen.main else { return origin }
        return NSPoint(
            x: main.visibleFrame.maxX - size.width - 18,
            y: main.visibleFrame.maxY - size.height - 18
        )
    }
}

/// 菜单栏图标 + 控制菜单
final class MainMenuManager {
    static let shared = MainMenuManager()
    private var statusItem: NSStatusItem?
    private weak var model: HUDModel?
    private weak var panel: NSPanel?

    private init() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
            accessibilityDescription: "Token 监控"
        )
        item.button?.image?.isTemplate = true
        item.menu = NSMenu()
        statusItem = item
    }

    func configure(model: HUDModel, panel: NSPanel) {
        self.model = model
        self.panel = panel

        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: "显示 / 隐藏浮窗", action: #selector(togglePanel), keyEquivalent: "h")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let compactItem = NSMenuItem(title: "折叠为一行", action: #selector(toggleCompact), keyEquivalent: "c")
        compactItem.target = self
        menu.addItem(compactItem)

        let pinItem = NSMenuItem(title: "固定（鼠标穿透）", action: #selector(togglePin), keyEquivalent: "p")
        pinItem.target = self
        menu.addItem(pinItem)

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let topItem = NSMenuItem(title: "始终置顶", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        topItem.target = self
        topItem.state = .on
        menu.addItem(topItem)

        let loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 Token 监控", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFront(nil) }
    }

    @objc private func toggleCompact() {
        model?.isCompact.toggle()
    }

    @objc private func togglePin() {
        model?.isPinned.toggle()
    }

    @objc private func refresh() {
        model?.refresh()
    }

    @objc private func toggleAlwaysOnTop() {
        guard let panel else { return }
        let newLevel: NSWindow.Level = (panel.level == .floating) ? .normal : .floating
        panel.level = newLevel
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// 开机自启（通过 LaunchAgent plist）
enum LaunchAtLogin {
    private static let label = "cn.workbuddy.tokenhud"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        let url = plistURL
        if enabled {
            let appPath = Bundle.main.bundlePath
            let dict: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", appPath],
                "RunAtLoad": true,
                "KeepAlive": false,
            ]
            let data = try? PropertyListSerialization.data(
                fromPropertyList: dict, format: .xml, options: 0)
            try? data?.write(to: url)
            runLaunchctl(["load", "-w", url.path])
        } else {
            runLaunchctl(["unload", "-w", url.path])
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func runLaunchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            // launchctl 不可用时静默降级
        }
    }
}
