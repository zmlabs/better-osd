//
//  MediaKeyMonitor.swift
//  BetterOSD
//
//  Created by yu on 2026/1/6.
//

import AppKit
import ApplicationServices

protocol BrightnessKeyHandling: AnyObject {
    var currentState: BrightnessState { get }
    func handle(_ key: MediaKeyMonitor.MediaKey, fineStep: Bool) -> MediaKeyHandlingResult
    func handle(_ key: MediaKeyMonitor.MediaKey, fineStep: Bool, targetDisplayID: CGDirectDisplayID) -> MediaKeyHandlingResult
}

extension BrightnessKeyController: BrightnessKeyHandling {}

final class MediaKeyMonitor {
    enum MediaKey: Int {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
        // MARK: Keyboard backlight (added)
        // Routed via resolveKeyboardBacklightKey() / resolveKeyboardBacklightSystemDefined(),
        // never matched by MediaKey(rawValue:). Negative raw values guarantee no accidental
        // collision with real NX codes (all of which are ≥ 0).
        case keyboardBrightnessDown = -1
        case keyboardBrightnessUp = -2
    }

    // MARK: - Keyboard backlight key code constants (added)

    // -1 = "not configured" sentinel. The feature is opt-in: nothing is intercepted
    // until the user explicitly assigns keys via Settings.
    static let defaultKeyboardBrightnessDownCode = -1
    static let defaultKeyboardBrightnessUpCode = -1

    // Standard NX codes sent by the built-in keyboard brightness keys on Apple Silicon
    // MacBooks when no hidutil remapping is active.
    // F5 → NX_KEYTYPE_ILLUMINATION_DOWN (22), F6 → NX_KEYTYPE_ILLUMINATION_UP (21).
    static let standardKeyboardBrightnessDownCode = 22
    static let standardKeyboardBrightnessUpCode = 21

    static let shared = MediaKeyMonitor()

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var eventTapRunLoop: CFRunLoop?
    private let volumeKeyController: VolumeKeyHandling
    private let brightnessKeyController: BrightnessKeyHandling
    private let keyboardBacklightController: KeyboardBacklightKeyHandling  // added
    private let hudStore: HUDDisplayStateStore
    // Injected so unit tests can assert the classic ⌥ shortcut without
    // actually opening System Settings.
    private let openSettingsPane: (URL) -> Void
    // Resolves the ⇧+brightness target — the display under the pointer.
    private let displayUnderCursor: () -> CGDirectDisplayID?
    private var accessibilityPollTask: Task<Void, Never>?
    // Set by startRecording(); next systemDefined key consumed and its NX code forwarded (added).
    private var recordingCallback: ((Int) -> Void)?

    // Cached keyboard backlight settings (added).
    // Read on every HID event — caching avoids repeated UserDefaults I/O on hot path.
    // Refreshed via UserDefaults.didChangeNotification whenever the user changes settings.
    private var cachedBacklightEnabled: Bool = false
    private var cachedBrightnessUpCode: Int = -1
    private var cachedBrightnessDownCode: Int = -1
    private var cachedKeyMode: String = ""          // "f5f6" | "cmdF1F2" | ""
    private var defaultsObserver: NSObjectProtocol?

    private static let brightnessUpKeyCode: Int64 = 144
    private static let brightnessDownKeyCode: Int64 = 145

    convenience init(
        audioController: SystemAudioControlling = SystemAudioController.shared,
        brightnessKeyController: BrightnessKeyHandling = BrightnessKeyController(),
        hudStore: HUDDisplayStateStore = .shared
    ) {
        self.init(
            volumeKeyController: VolumeKeyController(audioController: audioController, hudStore: hudStore),
            brightnessKeyController: brightnessKeyController,
            keyboardBacklightController: KeyboardBacklightKeyController(),
            hudStore: hudStore
        )
    }

    init(
        volumeKeyController: VolumeKeyHandling,
        brightnessKeyController: BrightnessKeyHandling = BrightnessKeyController(),
        keyboardBacklightController: KeyboardBacklightKeyHandling = KeyboardBacklightKeyController(),
        hudStore: HUDDisplayStateStore = .shared,
        openSettingsPane: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        displayUnderCursor: @escaping () -> CGDirectDisplayID? = { MediaKeyMonitor.cursorDisplayID() }
    ) {
        self.volumeKeyController = volumeKeyController
        self.brightnessKeyController = brightnessKeyController
        self.keyboardBacklightController = keyboardBacklightController
        self.hudStore = hudStore
        self.openSettingsPane = openSettingsPane
        self.displayUnderCursor = displayUnderCursor
        // Keyboard backlight: prime the cache and keep it fresh (added).
        reloadBacklightCache()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadBacklightCache()
            }
        }
    }

    func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        guard !hasAccessibilityPermission() else { return }
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true as CFBoolean] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func startAccessibilityPolling(interval: TimeInterval = 1.0, maxAttempts: Int = 60) {
        guard maxAttempts > 0 else { return }

        accessibilityPollTask?.cancel()
        accessibilityPollTask = Task { [weak self] in
            guard let self else { return }

            for _ in 0 ..< maxAttempts {
                if hasAccessibilityPermission() {
                    _ = start(promptAccessibility: false)
                    break
                }

                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    @discardableResult
    func start(promptAccessibility: Bool = false) -> Bool {
        if eventTap != nil {
            return true
        }

        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: promptAccessibility as CFBoolean] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return false }

        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
                (1 << UInt64(NSEvent.EventType.systemDefined.rawValue))
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: refcon
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetMain()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        eventTapSource = source
        eventTapRunLoop = runLoop

        return true
    }

    func stop() {
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }
        accessibilityPollTask?.cancel()
        let source = eventTapSource
        let runLoop = eventTapRunLoop
        let tap = eventTap
        eventTap = nil
        eventTapSource = nil
        eventTapRunLoop = nil

        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
    }

    private func enableEventTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }

        let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            monitor.enableEventTap()
            return Unmanaged.passUnretained(event)
        }

        return monitor.handle(event)
    }

    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.type == .keyDown {
            return handleBrightnessKeyDown(event)
        }
        return handleSystemDefinedMediaKey(event)
    }

    private func handleBrightnessKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))


        // Keyboard backlight via ⌘F1 / ⌘F2 — checked first so CMD intercepts
        // before the bare F1/F2 display-brightness path below.
        if let mk = resolveKeyboardBacklightKeyDown(keyCode: keyCode, flags: event.flags) {
            return applyResult(handleMediaKey(mk, modifiers: modifiers), event: event)
        }

        // Display brightness (fixed keycodes, no modifier).
        switch keyCode {
        case Self.brightnessUpKeyCode:
            return applyResult(handleMediaKey(.brightnessUp, modifiers: modifiers), event: event)
        case Self.brightnessDownKeyCode:
            return applyResult(handleMediaKey(.brightnessDown, modifiers: modifiers), event: event)
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleSystemDefinedMediaKey(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }

        guard nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = Int((data1 & 0xFFFF_0000) >> 16)
        let flags = Int(data1 & 0x0000_FFFF)

        let keyState = (flags & 0xFF00) >> 8
        guard keyState == 0x0A else { return Unmanaged.passUnretained(event) }

        // Recording mode: capture the NX keycode, consume event, exit recording.
        if let callback = recordingCallback {
            recordingCallback = nil
            callback(keyCode)
            return nil
        }

        // ⌘F1/⌘F2 mode: CMD + display-brightness NX code → keyboard backlight.
        if let mk = resolveKeyboardBacklightSystemDefined(keyCode: keyCode, cgFlags: event.flags) {
            return applyResult(handleMediaKey(mk, modifiers: nsEvent.modifierFlags), event: event)
        }

        // Keyboard backlight keys are user-configurable — check before generic MediaKey lookup.
        if let mk = resolveKeyboardBacklightKey(for: keyCode) {
            return applyResult(handleMediaKey(mk, modifiers: nsEvent.modifierFlags), event: event)
        }

        guard let mk = MediaKey(rawValue: keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        return applyResult(handleMediaKey(mk, modifiers: nsEvent.modifierFlags), event: event)
    }

    private func reloadBacklightCache() {
        cachedBacklightEnabled = UserDefaults.standard.object(
            forKey: AppStorageKeys.keyboardBacklightEnabled) as? Bool ?? false
        cachedBrightnessUpCode = UserDefaults.standard.object(
            forKey: AppStorageKeys.keyboardBrightnessUpCode) as? Int
            ?? Self.defaultKeyboardBrightnessUpCode
        cachedBrightnessDownCode = UserDefaults.standard.object(
            forKey: AppStorageKeys.keyboardBrightnessDownCode) as? Int
            ?? Self.defaultKeyboardBrightnessDownCode
        cachedKeyMode = UserDefaults.standard.string(forKey: AppStorageKeys.keyboardBrightnessKeyMode) ?? ""
    }

    // Resolves NX systemDefined code → keyboard backlight key (f5f6 mode only).
    private func resolveKeyboardBacklightKey(for code: Int) -> MediaKey? {
        guard cachedBacklightEnabled, cachedKeyMode == "f5f6" else { return nil }
        if cachedBrightnessUpCode >= 0 && code == cachedBrightnessUpCode { return .keyboardBrightnessUp }
        if cachedBrightnessDownCode >= 0 && code == cachedBrightnessDownCode { return .keyboardBrightnessDown }
        return nil
    }

    // Resolves systemDefined + Command → keyboard backlight (cmdF1F2 mode).
    // CMD+F1 → NX code 3 (brightnessDown), CMD+F2 → NX code 2 (brightnessUp).
    private func resolveKeyboardBacklightSystemDefined(keyCode: Int, cgFlags: CGEventFlags) -> MediaKey? {
        guard cachedBacklightEnabled, cachedKeyMode == "cmdF1F2",
              cgFlags.contains(.maskCommand) else { return nil }
        switch keyCode {
        case 3: return .keyboardBrightnessDown  // ⌘F1
        case 2: return .keyboardBrightnessUp    // ⌘F2
        default: return nil
        }
    }

    // Resolves keyDown + Command → keyboard backlight key (cmdF1F2 mode only).
    // F1 key sends keyCode 145 (brightnessDownKeyCode) on MacBook keyboards;
    // F2 sends 144 (brightnessUpKeyCode). CMD intercepts before the bare press.
    // Uses CGEventFlags directly to avoid NSEvent.ModifierFlags conversion issues.
    private func resolveKeyboardBacklightKeyDown(keyCode: Int64, flags: CGEventFlags) -> MediaKey? {
        guard cachedBacklightEnabled, cachedKeyMode == "cmdF1F2",
              flags.contains(.maskCommand) else { return nil }
        switch keyCode {
        case Self.brightnessDownKeyCode: return .keyboardBrightnessDown  // ⌘F1
        case Self.brightnessUpKeyCode:   return .keyboardBrightnessUp    // ⌘F2
        default: return nil
        }
    }

    private func applyResult(_ result: MediaKeyHandlingResult, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch result {
        case .passThrough:
            Unmanaged.passUnretained(event)
        case .consumed:
            nil
        }
    }

    // MARK: - Key recording (used by settings UI to capture a new hotkey)

    func startRecording(callback: @escaping (Int) -> Void) {
        recordingCallback = callback
    }

    func stopRecording() {
        recordingCallback = nil
    }

    // MARK: - Cursor display resolution

    /// The display the pointer currently sits on — the ⇧+brightness target.
    static func cursorDisplayID() -> CGDirectDisplayID? {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSPointInRect(location, $0.frame) }
        guard let id = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return id
    }

    // MARK: - Testing

    func handleMediaKeyForTesting(_ key: MediaKey, modifiers: NSEvent.ModifierFlags) -> MediaKeyHandlingResult {
        handleMediaKey(key, modifiers: modifiers)
    }

    private func handleMediaKey(_ key: MediaKey, modifiers: NSEvent.ModifierFlags) -> MediaKeyHandlingResult {
        // Classic macOS: bare ⌥ + a media key opens the matching settings
        // pane instead of adjusting anything. ⇧⌥ keeps fine-stepping.
        if modifiers.contains(.option), !modifiers.contains(.shift), let pane = key.settingsPaneURL {
            openSettingsPane(pane)
            return .consumed(didChange: false)
        }

        let fineStep = modifiers.contains(.shift) && modifiers.contains(.option)
        // The setting-flip trick belongs to pure ⇧ only; ⇧⌥ is the fine-step
        // gesture and the pop behaves as if no modifier were held.
        let invertFeedback = modifiers.contains(.shift) && !modifiers.contains(.option)

        switch key {
        case .soundUp, .soundDown, .mute:
            return volumeKeyController.handle(key, fineStep: fineStep, invertFeedback: invertFeedback)

        case .brightnessUp, .brightnessDown:
            // ⇧+brightness adjusts only the display under the pointer — the
            // classic per-display trick. ⇧⌥ (fine step) still sweeps all.
            if modifiers.contains(.shift), !modifiers.contains(.option), let target = displayUnderCursor() {
                let result = brightnessKeyController.handle(key, fineStep: fineStep, targetDisplayID: target)
                if case .consumed = result {
                    hudStore.update(brightnessKeyController.currentState.displayState, onDisplay: target)
                }
                return result
            }
            let result = brightnessKeyController.handle(key, fineStep: fineStep)
            if case .consumed = result {
                hudStore.update(brightnessKeyController.currentState.displayState)
            }
            return result

        // Keyboard backlight (added): same consume-and-show pattern as display brightness.
        case .keyboardBrightnessUp, .keyboardBrightnessDown:
            let result = keyboardBacklightController.handle(key, fineStep: fineStep)
            if case .consumed = result {
                hudStore.update(keyboardBacklightController.currentState.displayState)
            }
            return result
        }
    }
}

extension MediaKeyMonitor.MediaKey {
    /// System Settings pane the classic bare-⌥ shortcut opens. Keyboard
    /// backlight has no classic ⌥ behavior (its binding already uses ⌘),
    /// so it returns nil and keeps adjusting.
    var settingsPaneURL: URL? {
        switch self {
        case .soundUp, .soundDown, .mute:
            // macOS 26 dropped the old "-extension" suffix form — it silently
            // falls back to the main Settings window.
            URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")
        case .brightnessUp, .brightnessDown:
            URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")
        case .keyboardBrightnessUp, .keyboardBrightnessDown:
            nil
        }
    }
}
