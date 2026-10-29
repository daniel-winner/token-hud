import AppKit
import SwiftUI

/// 固定状态下的"释放"热区视图。
///
/// 主浮窗在固定时设置 ignoresMouseEvents = true，整个窗口对鼠标让路；
/// 这个透明小窗叠在"释放"按钮正上方，是固定状态下唯一的可点入口。
final class HUDHotspotView: NSView {
    var onClick: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea {
            removeTrackingArea(t)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// 热区小窗：无边框、透明、层级略高于主浮窗
final class HUDHotspotPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    let hotspotView = HUDHotspotView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = hotspotView
    }
}

/// 承载 SwiftUI 内容的宿主视图
final class HUDHostingView: NSHostingView<AnyView> {
    /// 调试日志开关：TOKENHUD_DEBUG=1
    private let debug = ProcessInfo.processInfo.environment["TOKENHUD_DEBUG"] == "1"

    /// 上报"释放"按钮在 SwiftUI 根坐标系中的位置
    var onReleaseZoneChange: ((CGRect) -> Void)?

    func updateReleaseZone(_ swiftRect: CGRect) {
        guard !swiftRect.isEmpty else { return }
        if debug {
            FileHandle.standardError.write(Data("[HUD] releaseZone(swift)=\(swiftRect)\n".utf8))
        }
        onReleaseZoneChange?(swiftRect)
    }
}

/// 无标题栏、可拖动的置顶浮窗
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private(set) var hostView: HUDHostingView?
    /// 固定状态下的释放热区窗
    let hotspot = HUDHotspotPanel()

    /// 最近一次上报的释放按钮位置（SwiftUI 根坐标系）
    private var lastSwiftZone: CGRect = .zero
    /// 当前是否处于固定状态
    private(set) var isPinned = false

    func install(hostView: HUDHostingView) {
        self.hostView = hostView
        contentView = hostView
        hostView.onReleaseZoneChange = { [weak self] rect in
            self?.lastSwiftZone = rect
            self?.repositionHotspot()
        }
    }

    /// 切换固定状态
    func applyPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned

        if pinned {
            // 主窗整体让路：鼠标事件直接穿透到下层应用
            ignoresMouseEvents = true
            repositionHotspot()
        } else {
            ignoresMouseEvents = false
            hotspot.orderOut(nil)
        }
    }

    /// 热区位置跟随主窗（主窗移动或按钮布局变化时重算）
    func repositionHotspot() {
        guard isPinned, !lastSwiftZone.isEmpty, let host = hostView else { return }

        // SwiftUI 根坐标(top-left) == host 自身坐标(flipped, top-left)
        // -> 窗口基坐标 -> 屏幕坐标（窗口基坐标原点 = 窗口左下角）
        let inWindow = host.convert(lastSwiftZone, to: nil)
        let origin = NSPoint(
            x: frame.origin.x + inWindow.origin.x,
            y: frame.origin.y + inWindow.origin.y
        )
        let padded = CGRect(
            x: origin.x - 8,
            y: origin.y - 8,
            width: inWindow.width + 16,
            height: inWindow.height + 16
        )
        hotspot.setFrame(padded, display: false)
        // 热区层级必须不低于主窗，否则会被主窗盖住点不到
        hotspot.level = NSWindow.Level(rawValue: max(level.rawValue + 1, NSWindow.Level.floating.rawValue + 1))
        hotspot.orderFront(nil)
    }

    /// 主窗不可见时热区也要隐藏，否则会留下一个"悬空的可点区域"
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        hotspot.orderOut(sender)
    }

    /// 主窗移动时同步热区
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        if isPinned {
            repositionHotspot()
        }
    }

    override var level: NSWindow.Level {
        didSet {
            if isPinned {
                hotspot.level = NSWindow.Level(rawValue: max(level.rawValue + 1, NSWindow.Level.floating.rawValue + 1))
            }
        }
    }
}
