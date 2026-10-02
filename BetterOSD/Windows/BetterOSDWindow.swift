//
//  BetterOSDWindow.swift
//  BetterOSD
//
//  Created by yu on 2025/9/23.
//

import AppKit
import SwiftUI

class BetterOSDWindow: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    private let hostingView: NSHostingView<BetterOSDFactoryView>

    private static let windowWidth: CGFloat = HUDLayout.windowSize.width
    private static let windowHeight: CGFloat = HUDLayout.windowSize.height

    @objc(_hasActiveAppearance) dynamic func _hasActiveAppearance() -> Bool {
        true
    }

    @objc(_hasActiveAppearanceIgnoringKeyFocus) dynamic func _hasActiveAppearanceIgnoringKeyFocus() -> Bool {
        true
    }

    @objc(_hasActiveControls) dynamic func _hasActiveControls() -> Bool {
        true
    }

    @objc(_hasKeyAppearance) dynamic func _hasKeyAppearance() -> Bool {
        true
    }

    @objc(_hasMainAppearance) dynamic func _hasMainAppearance() -> Bool {
        true
    }

    init() {
        let contentView = BetterOSDFactoryView()
        hostingView = NSHostingView(rootView: contentView)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        setupWindow()
        setupContent()
    }

    private func setupWindow() {
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
    }

    func updatePosition(on displayID: CGDirectDisplayID? = nil) {
        let screen = displayID.flatMap(Self.screen(for:)) ?? NSScreen.main
        guard let screen else { return }

        let screenFrame = screen.frame
        let bottomOffset = (UserDefaults.standard.object(forKey: AppStorageKeys.bottomOffset) as? Double) ?? 120

        let x = screenFrame.minX + (screenFrame.width - Self.windowWidth) / 2
        let y = screenFrame.minY + bottomOffset

        setFrame(NSRect(x: x, y: y, width: Self.windowWidth, height: Self.windowHeight), display: false)
    }

    /// Maps a CGDirectDisplayID (the ⇧+brightness target) to its NSScreen.
    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }

    private func setupContent() {
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight)
        hostingView.autoresizingMask = [.width, .height]

        contentView = hostingView
    }

    func showWithAnimation(on displayID: CGDirectDisplayID? = nil) {
        updatePosition(on: displayID)

        alphaValue = 0.0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
    }

    func hideWithAnimation() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.orderOut(nil)
            }
        }
    }
}
