import Cocoa

struct SuggestionPresentation {
    let text: String
    /// AppKit screen coordinates (bottom-left origin).
    let anchor: NSRect
}

/// Informational only: never activates, takes focus, or intercepts mouse clicks.
final class SuggestionPanel {
    private let panel: NSPanel
    private let title = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private var expiry: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.setAccessibilityTitle("CapsFlow 한글 추천")
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.masksToBounds = true
        panel.contentView = background
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        for label in [title, hint] {
            label.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(label)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 11),
            title.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -11),
            title.topAnchor.constraint(equalTo: background.topAnchor, constant: 7),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -11),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            hint.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -7)
        ])
    }

    static func placement(anchor: NSRect, size: NSSize, visible: NSRect) -> NSRect {
        let width = min(size.width, max(1, visible.width - 12))
        let height = min(size.height, max(1, visible.height - 12))
        let x = min(max(anchor.minX, visible.minX + 6), visible.maxX - width - 6)
        let preferredY = anchor.maxY + 6
        let y = preferredY + height <= visible.maxY - 6 ? preferredY : anchor.minY - height - 6
        return NSRect(x: x, y: min(max(y, visible.minY + 6), visible.maxY - height - 6), width: width, height: height)
    }

    static func fromAX(_ bounds: CGRect) -> NSRect? {
        guard let screen = NSScreen.screens.first, bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.height > 0 else { return nil }
        return NSRect(x: bounds.minX, y: screen.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    func show(_ suggestion: SuggestionPresentation, preview: Bool = false) {
        expiry?.cancel()
        title.stringValue = "추천 · " + suggestion.text
        hint.stringValue = preview ? "미리보기 · 입력은 변경하지 않습니다" : "오른쪽 ⌥ / ⌘⌥Z 적용 · Esc 닫기"
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(suggestion.anchor) }) ?? NSScreen.main else { return }
        let size = NSSize(width: min(360, max(180, max(title.intrinsicContentSize.width, hint.intrinsicContentSize.width) + 22)), height: 49)
        panel.setFrame(Self.placement(anchor: suggestion.anchor, size: size, visible: screen.visibleFrame), display: true)
        panel.orderFrontRegardless()
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        expiry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (preview ? 8 : 30), execute: item)
    }
    func hide() {
        expiry?.cancel(); expiry = nil
        if panel.isVisible { panel.orderOut(nil) }
    }
}
