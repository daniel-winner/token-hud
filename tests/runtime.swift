import AppKit
import SwiftUI

// 完整运行时链路验证：
// 1) SwiftUI 上报释放按钮位置 -> 热区窗定位
// 2) 热区窗位置是否精确覆盖按钮（换算回 SwiftUI 坐标比对）
// 3) 固定/释放切换时 ignoresMouseEvents 与热区可见性是否同步

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: .darkAqua)

final class Stub: ObservableObject, HUDModelProtocol {
    @Published var snapshot = UsageSnapshot()
    @Published var isCompact = false
    @Published var isLive = true
    @Published var isPinned: Bool = false { didSet { panel?.applyPinned(isPinned) } }
    var reported: CGRect = .zero
    weak var panel: HUDPanel?
    func startDragging() {}
    func quit() {}
    func reportReleaseZone(_ r: CGRect) { reported = r; panel?.hostView?.updateReleaseZone(r) }
}

let stub = Stub()
let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: HUDLayout.width, height: HUDLayout.expandedHeight),
                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
let host = HUDHostingView(rootView: AnyView(HUDRoot(model: stub)))
host.frame = NSRect(x: 0, y: 0, width: HUDLayout.width, height: HUDLayout.expandedHeight)
panel.install(hostView: host)
stub.panel = panel
panel.setFrameOrigin(NSPoint(x: 200, y: 300))
panel.orderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(1.0))

var pass = 0, fail = 0
func check(_ label: String, _ cond: Bool) {
    if cond { pass += 1; print("  PASS  \(label)") }
    else { fail += 1; print("  FAIL  \(label)") }
}

print("[1] 释放按钮位置上报")
check("SwiftUI 已上报释放按钮矩形", !stub.reported.isEmpty)
print("      swift rect =", stub.reported)

print("\n[2] 固定：主窗让路 + 热区就位")
stub.isPinned = true
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
check("主窗 ignoresMouseEvents = true", panel.ignoresMouseEvents)
check("热区窗可见", panel.hotspot.isVisible)
check("热区层级 >= 主窗", panel.hotspot.level.rawValue >= panel.level.rawValue)

// 关键：把热区窗位置换算回 SwiftUI 坐标，应与上报的按钮矩形一致
let hotFrame = panel.hotspot.frame
let hotInWindow = CGRect(x: hotFrame.origin.x - panel.frame.origin.x,
                         y: hotFrame.origin.y - panel.frame.origin.y,
                         width: hotFrame.width, height: hotFrame.height)
// 窗口基坐标 -> SwiftUI 坐标（flipped 反转）
let hotInSwift = CGRect(x: hotInWindow.origin.x,
                         y: panel.contentView!.bounds.height - hotInWindow.origin.y - hotInWindow.height,
                         width: hotInWindow.width, height: hotInWindow.height)
print("      热区换算回 SwiftUI 坐标 =", hotInSwift)
let btn = stub.reported
check("热区中心与按钮中心一致",
      abs(hotInSwift.midX - btn.midX) < 2 && abs(hotInSwift.midY - btn.midY) < 2)

print("\n[3] 释放：恢复交互")
stub.isPinned = false
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
check("主窗 ignoresMouseEvents = false", !panel.ignoresMouseEvents)
check("热区窗已隐藏", !panel.hotspot.isVisible)

print("\n[4] 折叠态下按钮位置也正确")
stub.isCompact = true
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
check("折叠态已上报新位置", !stub.reported.isEmpty && stub.reported.width < 30)
stub.isPinned = true
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
let hf2 = panel.hotspot.frame
let hw2 = CGRect(x: hf2.origin.x - panel.frame.origin.x,
                 y: hf2.origin.y - panel.frame.origin.y,
                 width: hf2.width, height: hf2.height)
let hs2 = CGRect(x: hw2.origin.x,
                 y: panel.contentView!.bounds.height - hw2.origin.y - hw2.height,
                 width: hw2.width, height: hw2.height)
check("折叠态热区仍对准按钮",
      abs(hs2.midX - stub.reported.midX) < 2 && abs(hs2.midY - stub.reported.midY) < 2)

print("\n结果: PASS=\(pass) FAIL=\(fail)")
