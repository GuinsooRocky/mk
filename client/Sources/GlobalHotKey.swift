import Cocoa
import CoreGraphics

/// 全局热键
///
/// 使用 CGEventTap 替代 NSEvent monitor，避免 macOS 26 下
/// AppKit GlobalObserverHandler 的 Swift actor runtime crash (Bus error)。
///
/// 支持两种模式：
/// 1. modifier-only（如 Right Option 单独按下）—— 监听 flagsChanged，匹配 modifier keyCode
/// 2. 组合键（如 Cmd+Shift+R）—— 监听 keyDown，匹配 keyCode + modifiers
final class GlobalHotKey: @unchecked Sendable {
    @MainActor static let shared = GlobalHotKey()

    nonisolated(unsafe) var onPress: (() -> Void)?
    nonisolated(unsafe) var onRelease: (() -> Void)?

    fileprivate nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private nonisolated(unsafe) var isPressed = false

    /// 当前生效的配置（nonisolated 是因为 callback 在非 actor 上下文读它）
    fileprivate nonisolated(unsafe) var currentConfig: HotKeyConfig = .default

    /// 缓存的前台 app bundle id，CGEventTap callback 在非 main thread 读它
    /// Why: NSWorkspace.shared.frontmostApplication 是 main-thread-only，不能在 tap callback 里直接读
    /// How to apply: 由 NSWorkspace.didActivateApplicationNotification 在 main 上更新（见 start()）
    private nonisolated(unsafe) var cachedFrontmostBundle: String?
    private nonisolated(unsafe) var frontmostObserver: Any?

    @MainActor
    func start() {
        // 启动时从 config 读
        let dict = RuntimeConfig.shared.hotKeyConfig
        currentConfig = HotKeyConfig.load(from: dict)
        Logger.log("HotKey", "Loaded hotkey: \(currentConfig.displayName) (keyCode=\(currentConfig.keyCode), modifierOnly=\(currentConfig.isModifierOnly), blocklist=\(currentConfig.appBlocklist))")

        // 监听前台 app 切换；callback 在 main 上跑，安全更新 cachedFrontmostBundle
        cachedFrontmostBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.cachedFrontmostBundle = app?.bundleIdentifier
        }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: globalHotKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Logger.log("HotKey", "Failed to create CGEventTap (check Accessibility permissions)")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Logger.log("HotKey", "Global hotkey started (CGEventTap)")
    }

    @MainActor
    func stop() {
        if let obs = frontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            frontmostObserver = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// 前台 app 在当前 blocklist 里？
    /// Why: 微信"按住说话"也吃 Option，MK 不让出去会同时录两份
    /// How to apply: press 路径调用；release 路径不调用——避免 press 已起来但 release 被吞造成 PTT 状态泄漏
    fileprivate func isFrontmostBlocked(_ blocklist: [String]) -> Bool {
        guard !blocklist.isEmpty, let bundle = cachedFrontmostBundle else { return false }
        return blocklist.contains(bundle)
    }

    /// 热更新配置（保存设置后调用）
    @MainActor
    func reload(config: HotKeyConfig) {
        currentConfig = config
        isPressed = false  // 防止跨配置切换时残留按下状态
        Logger.log("HotKey", "Hotkey reloaded: \(config.displayName) (keyCode=\(config.keyCode), modifierOnly=\(config.isModifierOnly))")
    }

    fileprivate func handleKeyDown(keyCode: Int64, flags: CGEventFlags) {
        // 仅在组合键模式下处理 keyDown
        let cfg = currentConfig
        guard !cfg.isModifierOnly else { return }
        guard Int64(cfg.keyCode) == keyCode else { return }

        // 比较 modifier 位（device-independent 部分）
        let cfgMods = cfg.deviceIndependentModifiers
        let evtMods = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
            .intersection(.deviceIndependentFlagsMask)
        guard cfgMods == evtMods else { return }

        if isFrontmostBlocked(cfg.appBlocklist) {
            Logger.log("HotKey", "\(cfg.displayName) DOWN suppressed (frontmost=\(cachedFrontmostBundle ?? "?") in blocklist)")
            return
        }

        Logger.log("HotKey", "\(cfg.displayName) DOWN")
        if let onPress {
            DispatchQueue.main.async { onPress() }
        }
        // 组合键模式下，松开通常不重要（toggle 语义只看 down），不再额外触发 onRelease
    }

    fileprivate func handleFlags(_ flags: CGEventFlags, keyCode: Int64) {
        let cfg = currentConfig
        guard cfg.isModifierOnly else { return }
        guard Int64(cfg.keyCode) == keyCode else { return }

        let modDown = isModifierDown(for: cfg.keyCode, in: flags)

        if modDown && !isPressed {
            // 拦截仅在 press 边沿；release 路径（!modDown && isPressed）不拦，
            // 保证已起来的 PTT 一定有配对 release，避免按住时切窗导致状态泄漏
            if isFrontmostBlocked(cfg.appBlocklist) {
                Logger.log("HotKey", "\(cfg.displayName) DOWN suppressed (frontmost=\(cachedFrontmostBundle ?? "?") in blocklist)")
                return
            }
            isPressed = true
            Logger.log("HotKey", "\(cfg.displayName) DOWN")
            if let onPress {
                DispatchQueue.main.async { onPress() }
            }
        } else if !modDown && isPressed {
            isPressed = false
            Logger.log("HotKey", "\(cfg.displayName) UP")
            if let onRelease {
                DispatchQueue.main.async { onRelease() }
            }
        }
    }

    /// 给定一个 modifier 键码，返回它在 CGEventFlags 里是否被按下
    private func isModifierDown(for keyCode: UInt16, in flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.maskCommand)    // Right/Left Cmd
        case 56, 60: return flags.contains(.maskShift)      // Left/Right Shift
        case 57:     return flags.contains(.maskAlphaShift) // Caps Lock
        case 58, 61: return flags.contains(.maskAlternate)  // Left/Right Option
        case 59, 62: return flags.contains(.maskControl)    // Left/Right Control
        case 63:     return flags.contains(.maskSecondaryFn) // fn
        default:     return false
        }
    }
}

/// 纯 C 回调，不经过任何 Swift concurrency 路径
private func globalHotKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let hotkey = Unmanaged<GlobalHotKey>.fromOpaque(userInfo).takeUnretainedValue()

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    if type == .flagsChanged {
        hotkey.handleFlags(event.flags, keyCode: keyCode)
    } else if type == .keyDown {
        hotkey.handleKeyDown(keyCode: keyCode, flags: event.flags)
    }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = hotkey.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    return Unmanaged.passUnretained(event)
}
