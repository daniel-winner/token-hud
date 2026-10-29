import AppKit
import SwiftUI

// 窗口服务器层面的穿透验证：
// CGWindowListCopyWindowInfo 反映窗口服务器实际认为"该点属于谁"。
// ignoresMouseEvents=true 的窗口会从命中列表中消失（真正让路给下层）。

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: .darkAqua)

final class Stub: ObservableObject, HUDModelProtocol {
    @Published var snapshot = UsageSnapshot()
    @Published var isCompact = false
    @Published var isLive = true
    @Published var isPinned = false
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
panel.hotspot.orderOut(nil)
RunLoop.main.run(until: Date().addingTimeInterval(1.0))

// 用窗口号标识窗口
let panelNum = panel.windowNumber
let hotspotNum = panel.hotspot.windowNumber

// 主显示器的 CG 坐标原点（top-left）与高度
let mainScreen = NSScreen.screens.first!
let cgTop = mainScreen.frame.maxY
print("主屏幕 frame =", mainScreen.frame)

var panelFrame = panel.frame
var hotFrame = panel.hotspot.frame

func ownerAt(_ p: CGPoint) -> String {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var best: (Int, Int, String) = (-1, -1, "none")
    for w in info {
        guard let b = w[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? Int, let y = b["Y"] as? Int,
              let ww = b["Width"] as? Int, let hh = b["Height"] as? Int,
              let num = w[kCGWindowNumber as String] as? Int else { continue }
        // CGWindow 坐标：X 与 AppKit 相同，Y 为 top-left 原点
        let cgY = Int(cgTop) - y - hh
        if Int(p.x) >= x && Int(p.x) < x+ww && Int(p.y) >= cgY && Int(p.y) < cgY+hh {
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            if layer > best.0 {
                // 按几何位置与尺寸识别归属（窗口号会随 orderFront 重新分配）
                let isHot = abs(x - Int(hotFrame.origin.x)) < 3 && abs(y - Int(hotFrame.origin.y)) < 3
                    && ww == Int(hotFrame.width) && hh == Int(hotFrame.height)
                let isMain = abs(x - Int(panelFrame.origin.x)) < 3 && abs(y - Int(panelFrame.origin.y)) < 3
                    && ww == Int(panelFrame.width) && hh == Int(panelFrame.height)
                let tag = isHot ? "热区窗" : (isMain ? "主浮窗" : "其他(\(num),\(ww)x\(hh))")
                best = (layer, num, tag)
            }
        }
    }
    return best.2
}

let rz = stub.reported
print("释放按钮 swift rect =", rz)
print("主浮窗 frame =", panel.frame)

// 释放按钮中心的屏幕坐标
let inWindow = host.convert(rz, to: nil)
let btnScreen = CGPoint(x: panel.frame.origin.x + inWindow.midX,
                         y: panel.frame.origin.y + inWindow.midY)
let bodyScreen = CGPoint(x: panel.frame.origin.x + 60, y: panel.frame.origin.y + 100)

panelFrame = panel.frame
print("\n[未固定] 主窗 ignoresMouseEvents =", panel.ignoresMouseEvents)
print("  释放按钮位置 ->", ownerAt(btnScreen))
print("  浮窗 body    ->", ownerAt(bodyScreen))

panel.applyPinned(true)
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
hotFrame = panel.hotspot.frame

print("\n[固定] 主窗 ignoresMouseEvents =", panel.ignoresMouseEvents)
print("  热区窗 frame =", panel.hotspot.frame)
print("  释放按钮位置 ->", ownerAt(btnScreen), "(期望：热区窗)")
print("  浮窗 body    ->", ownerAt(bodyScreen), "(期望：不是主浮窗)")

// 校验热区窗确实覆盖在释放按钮上
let covers = panel.hotspot.frame.contains(btnScreen)
print("  热区窗覆盖释放按钮 ->", covers ? "YES" : "NO")

panel.applyPinned(false)
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
print("\n[释放后] 主窗 ignoresMouseEvents =", panel.ignoresMouseEvents, " 热区可见 =", panel.hotspot.isVisible)
