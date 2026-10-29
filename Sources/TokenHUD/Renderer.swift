import AppKit
import SwiftUI

/// 离屏渲染浮窗内容为 PNG（用于预览 / 版式自检）。
/// 用法：TokenHUD --render <输出路径> [--compact] [--pinned]
enum Renderer {
    static func render(to path: String, compact: Bool, pinned: Bool, snapshot: UsageSnapshot) {
        let model = PreviewModel(snapshot: snapshot, isCompact: compact, isPinned: pinned)
        let view = AnyView(
            Group {
                if compact {
                    CompactHUDView(model: model)
                } else {
                    HUDView(model: model)
                }
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: HUDLayout.width,
                               height: compact ? HUDLayout.compactHeight : HUDLayout.expandedHeight)
        hosting.layoutSubtreeIfNeeded()

        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        // 用 cacheDisplay 走 AppKit 正常的绘制路径，避免 layer.render 造成的上下翻转
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let data = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                print("已渲染: \(path) (\(Int(size.width))x\(Int(size.height)))")
            } else {
                print("渲染失败")
            }
        } else {
            print("渲染失败: 无法创建位图")
        }
    }
}

/// 预览用的静态数据源
final class PreviewModel: ObservableObject, HUDModelProtocol {
    @Published var snapshot: UsageSnapshot
    @Published var isCompact: Bool
    @Published var isLive = true
    @Published var isPinned: Bool

    init(snapshot: UsageSnapshot, isCompact: Bool, isPinned: Bool = false) {
        self.snapshot = snapshot
        self.isCompact = isCompact
        self.isPinned = isPinned
    }

    func startDragging() {}
    func quit() {}
    func reportReleaseZone(_ rect: CGRect) {}
}
