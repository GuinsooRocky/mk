import AppKit
import ApplicationServices
import QuartzCore

/// 转写浮窗 HUD（核心原则：目标 app 永远只收到最终文本；实时体验全部发生在 MK 自己的浮窗里）。
///
/// 设计：
/// - 位置：目标窗口顶部居中，距窗顶 topOffset，并 clamp 到所在屏幕可见区（避开菜单栏/刘海）
/// - 宽度：clamp(360, 目标窗口宽 * 0.25, 640)
/// - 高度：随文字自动撑高（min 64 → max 240），超出只保留尾部（最近内容），顶部省略
/// - 样式：NSVisualEffectView dark 磨玻璃 + rgba(18,18,18,0.72) 黑底 + 1px 灰边 + 圆角 16
/// - 生命周期：热键按下 show → live 段 update → 松手 setProcessing → 最终 showFinal（停留后淡出）
@MainActor
final class TranscriptionHUD: NSObject {
    private let panel: NSPanel
    private let containerView: NSView
    private let effectView: NSVisualEffectView
    private let rippleLayer: CALayer
    private let coreDotLayer: CALayer
    private let textLabel: NSTextField
    private let retryButton: NSButton
    private let copyButton: NSButton
    private let cancelButton: NSButton

    private let cornerRadius: CGFloat = 16
    private let padH: CGFloat = 18
    private let padV: CGFloat = 14
    private let emptyWidth: CGFloat = 96
    private let emptyHeight: CGFloat = 48
    private let minHeight: CGFloat = 58
    private let maxHeight: CGFloat = 240
    private let topOffset: CGFloat = 60      // 距目标窗口顶部

    // fallback 按钮行（注入失败时显示）
    private let buttonRowHeight: CGFloat = 30
    private let buttonRowGap: CGFloat = 10
    private let buttonGap: CGFloat = 8
    private var onRetry: (() -> Void)?
    private var onCopy: (() -> Void)?
    private var onCancel: (() -> Void)?

    // 顶部锚 + 水平中心 + 宽度（show 时算好，update 复用，保证顶部固定、向下生长）
    private var anchorTopY: CGFloat = 0
    private var centerX: CGFloat = 0
    private var hudWidth: CGFloat = 360
    private var currentWidth: CGFloat = 360

    private var fadeWork: DispatchWorkItem?
    private let rippleAnimationKey = "mk.ripple.expand"
    private let corePulseAnimationKey = "mk.ripple.core"

    override init() {
        let initialRect = NSRect(x: 0, y: 0, width: 360, height: 64)
        panel = NSPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        containerView = NSView(frame: initialRect)
        effectView = NSVisualEffectView(frame: initialRect)
        rippleLayer = CALayer()
        coreDotLayer = CALayer()
        textLabel = NSTextField(wrappingLabelWithString: "")
        retryButton = NSButton()
        copyButton = NSButton()
        cancelButton = NSButton()
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true          // 点击穿透，不抢交互（fallback 时临时打开）
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        containerView.wantsLayer = true
        containerView.layer?.shadowColor = NSColor.black.cgColor
        containerView.layer?.shadowOpacity = 0.18
        containerView.layer?.shadowRadius = 18
        containerView.layer?.shadowOffset = CGSize(width: 0, height: -8)

        effectView.material = .hudWindow          // 暗色磨玻璃
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .vibrantDark)
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 1
        effectView.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        // 黑底 rgba(18,18,18,0.72) 压在磨玻璃上
        effectView.layer?.backgroundColor = NSColor(red: 12/255, green: 12/255, blue: 12/255, alpha: 0.66).cgColor

        rippleLayer.bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
        rippleLayer.cornerRadius = 13
        rippleLayer.borderWidth = 1.4
        rippleLayer.borderColor = NSColor(white: 1, alpha: 0.28).cgColor
        rippleLayer.opacity = 0

        coreDotLayer.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
        coreDotLayer.cornerRadius = 3.5
        coreDotLayer.backgroundColor = NSColor(white: 1, alpha: 0.72).cgColor

        textLabel.isEditable = false
        textLabel.isSelectable = false
        textLabel.isBezeled = false
        textLabel.drawsBackground = false
        textLabel.alignment = .left
        textLabel.textColor = NSColor(white: 1, alpha: 0.95)
        textLabel.font = .systemFont(ofSize: 15, weight: .regular)
        textLabel.maximumNumberOfLines = 0
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.cell?.wraps = true
        textLabel.cell?.isScrollable = false

        configureButton(cancelButton, title: "取消", action: #selector(cancelTapped), primary: false)
        configureButton(copyButton, title: "复制", action: #selector(copyTapped), primary: false)
        configureButton(retryButton, title: "重新粘贴", action: #selector(retryTapped), primary: true)
        for b in [cancelButton, copyButton, retryButton] {
            b.isHidden = true
            effectView.addSubview(b)
        }

        effectView.addSubview(textLabel)
        effectView.layer?.addSublayer(rippleLayer)
        effectView.layer?.addSublayer(coreDotLayer)
        containerView.addSubview(effectView)
        panel.contentView = containerView
    }

    // MARK: - 生命周期

    /// 热键按下：在目标窗口顶部居中显示「监听态」
    func show(targetPID: pid_t?) {
        fadeWork?.cancel()
        panel.ignoresMouseEvents = true
        clearFallbackHandlers()
        panel.alphaValue = 1

        let targetFrame = targetPID.flatMap { Self.focusedWindowFrame(pid: $0) }
        let area = targetFrame ?? topCenterFallbackFrame()
        let screen = screenContaining(point: CGPoint(x: area.midX, y: area.midY))
            ?? NSScreen.main ?? NSScreen.screens.first

        hudWidth = max(360, min(640, area.width * 0.25))
        centerX = area.midX
        var top = area.maxY - topOffset
        if let vf = screen?.visibleFrame {
            top = min(top, vf.maxY - 6)          // 不越过菜单栏/刘海
            top = max(top, vf.minY + minHeight + 6)
        }
        anchorTopY = top

        render(text: "", dimText: true, pulse: true, animateResize: false)
        panel.orderFrontRegardless()
    }

    /// live 段：更新实时文本（向下生长）
    func update(text: String) {
        guard !text.isEmpty else { return }
        render(text: text, dimText: false, pulse: false, animateResize: false)
    }

    /// 松手：进入「识别中…」（有实时文本就保留文本，云端很快）
    func setProcessing(currentText: String) {
        render(text: currentText, dimText: currentText.isEmpty, pulse: currentText.isEmpty, animateResize: false)
    }

    /// 最终版：显示后停留再淡出（最终文本已回填目标 app）
    func showFinal(text: String, holdSec: Double = 0.6) {
        panel.ignoresMouseEvents = true
        clearFallbackHandlers()
        render(text: text, dimText: false, pulse: false, animateResize: true)
        scheduleFade(after: holdSec)
    }

    /// 注入失败兜底：浮窗不淡出，临时可交互，文本下方出 重新粘贴/复制/取消
    func showFallback(text: String,
                      onRetry: @escaping () -> Void,
                      onCopy: @escaping () -> Void,
                      onCancel: @escaping () -> Void) {
        fadeWork?.cancel()
        panel.alphaValue = 1
        self.onRetry = onRetry
        self.onCopy = onCopy
        self.onCancel = onCancel
        panel.ignoresMouseEvents = false          // 临时收下点击（nonactivating，不抢目标 app 焦点）
        render(text: text, dimText: false, pulse: false, animateResize: true, showButtons: true)
        panel.orderFrontRegardless()
    }

    /// 立即隐藏（空/取消）
    func hide() {
        fadeWork?.cancel()
        panel.ignoresMouseEvents = true
        clearFallbackHandlers()
        panel.orderOut(nil)
        panel.alphaValue = 1
        stopPulse()
    }

    // MARK: - fallback 交互

    @objc private func retryTapped() { onRetry?() }      // 结果由调用方决定下一态（成功 showFinal / 仍失败 showFallback）
    @objc private func copyTapped() { onCopy?(); hide() }
    @objc private func cancelTapped() { onCancel?(); hide() }

    private func clearFallbackHandlers() {
        onRetry = nil
        onCopy = nil
        onCancel = nil
    }

    private func configureButton(_ b: NSButton, title: String, action: Selector, primary: Bool) {
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.target = self
        b.action = action
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.layer?.borderWidth = 1
        b.layer?.borderColor = NSColor(white: 1, alpha: primary ? 0.30 : 0.16).cgColor
        b.layer?.backgroundColor = NSColor(white: 1, alpha: primary ? 0.14 : 0.06).cgColor
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor(white: 1, alpha: primary ? 0.96 : 0.82),
            .font: NSFont.systemFont(ofSize: 12.5, weight: primary ? .medium : .regular)
        ])
    }

    // MARK: - 内部

    private func scheduleFade(after sec: Double) {
        fadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.panel.orderOut(nil)
                self?.panel.alphaValue = 1
            })
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: work)
    }

    /// 设文本 + 按文字高度自适应面板（顶部锚定向下生长；超 maxHeight 只保留尾部，顶部省略）
    private func render(text: String, dimText: Bool, pulse: Bool, animateResize: Bool, showButtons: Bool = false) {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let buttonsArea = showButtons ? (buttonRowGap + buttonRowHeight) : 0
        if pulse && !hasText {
            startPulse()
        } else {
            stopPulse()
        }

        currentWidth = (hasText || showButtons) ? hudWidth : min(emptyWidth, hudWidth)
        let innerW = currentWidth - padH * 2
        let maxTextInner = maxHeight - padV * 2 - buttonsArea
        textLabel.preferredMaxLayoutWidth = innerW

        var shown = text
        textLabel.stringValue = shown
        var textH = hasText
            ? textLabel.sizeThatFits(NSSize(width: innerW, height: .greatestFiniteMagnitude)).height
            : 0

        // 超高：二分丢弃前缀，只留能放下的尾部，前面加省略号
        if textH > maxTextInner {
            let chars = Array(text)
            var lo = 0, hi = chars.count
            while lo < hi {
                let mid = (lo + hi) / 2
                textLabel.stringValue = "…" + String(chars[mid...])
                let h = textLabel.sizeThatFits(NSSize(width: innerW, height: .greatestFiniteMagnitude)).height
                if h > maxTextInner { lo = mid + 1 } else { hi = mid }
            }
            let cut = min(lo, chars.count)
            shown = cut > 0 ? "…" + String(chars[cut...]) : text
            textLabel.stringValue = shown
            textH = textLabel.sizeThatFits(NSSize(width: innerW, height: .greatestFiniteMagnitude)).height
        }

        textLabel.textColor = NSColor(white: 1, alpha: dimText ? 0.64 : 0.95)
        textLabel.isHidden = !hasText
        rippleLayer.isHidden = hasText
        coreDotLayer.isHidden = hasText

        let contentHeight = hasText ? ceil(textH) : emptyHeight - padV * 2
        let naturalHeight = contentHeight + padV * 2 + buttonsArea
        let hudHeight = (hasText || showButtons)
            ? max(minHeight, min(maxHeight, naturalHeight))
            : emptyHeight

        let originX = centerX - currentWidth / 2
        let originY = anchorTopY - hudHeight     // 顶部固定，高度向下扩
        let frame = NSRect(x: originX, y: originY, width: currentWidth, height: hudHeight)
        panel.setFrame(frame, display: true, animate: animateResize && panel.isVisible)
        containerView.frame = NSRect(origin: .zero, size: frame.size)
        containerView.layer?.shadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: frame.size),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        effectView.frame = NSRect(origin: .zero, size: frame.size)

        rippleLayer.position = CGPoint(x: currentWidth / 2, y: hudHeight / 2)
        coreDotLayer.position = CGPoint(x: currentWidth / 2, y: hudHeight / 2)

        // 文本在上、按钮行在下（Cocoa 原点左下角，故 textY = padV + 按钮区高）
        let textY = padV + buttonsArea
        textLabel.frame = NSRect(x: padH, y: textY, width: innerW, height: hudHeight - padV - textY)

        cancelButton.isHidden = !showButtons
        copyButton.isHidden = !showButtons
        retryButton.isHidden = !showButtons
        if showButtons {
            let bw = (innerW - buttonGap * 2) / 3
            cancelButton.frame = NSRect(x: padH, y: padV, width: bw, height: buttonRowHeight)
            copyButton.frame   = NSRect(x: padH + bw + buttonGap, y: padV, width: bw, height: buttonRowHeight)
            retryButton.frame  = NSRect(x: padH + (bw + buttonGap) * 2, y: padV, width: bw, height: buttonRowHeight)
        }
    }

    private func startPulse() {
        coreDotLayer.isHidden = false
        rippleLayer.isHidden = false
        guard rippleLayer.animation(forKey: rippleAnimationKey) == nil else { return }

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.55
        scale.toValue = 1.65

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.52
        fade.toValue = 0

        let rippleGroup = CAAnimationGroup()
        rippleGroup.animations = [scale, fade]
        rippleGroup.duration = 1.18
        rippleGroup.repeatCount = .infinity
        rippleGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
        rippleLayer.add(rippleGroup, forKey: rippleAnimationKey)

        let corePulse = CABasicAnimation(keyPath: "opacity")
        corePulse.fromValue = 0.5
        corePulse.toValue = 0.95
        corePulse.duration = 0.72
        corePulse.autoreverses = true
        corePulse.repeatCount = .infinity
        corePulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        coreDotLayer.add(corePulse, forKey: corePulseAnimationKey)
    }

    private func stopPulse() {
        rippleLayer.removeAnimation(forKey: rippleAnimationKey)
        coreDotLayer.removeAnimation(forKey: corePulseAnimationKey)
    }

    private func screenContaining(point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    /// 回落位置：主屏顶部居中（无目标窗口时）
    private func topCenterFallbackFrame() -> CGRect {
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(x: vf.minX, y: vf.maxY - 120, width: vf.width, height: 120)
    }

    /// AX 取目标 app 焦点窗口 frame，转成 Cocoa 坐标（bottom-left 原点）
    private static func focusedWindowFrame(pid: pid_t) -> CGRect? {
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winRefU = winRef else { return nil }
        let winEl = winRefU as! AXUIElement

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(winEl, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(winEl, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posU = posRef, let sizeU = sizeRef else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posU as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeU as! AXValue, .cgSize, &size)
        guard size.width > 1, size.height > 1 else { return nil }

        // AX：全局 top-left 原点（y 向下，基于主屏高度）→ Cocoa：bottom-left 原点（y 向上）
        let primaryH = NSScreen.screens.first?.frame.height ?? size.height
        let cocoaY = primaryH - pos.y - size.height
        return CGRect(x: pos.x, y: cocoaY, width: size.width, height: size.height)
    }
}
