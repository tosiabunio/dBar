import AppKit
import SwiftUI

/// Owns the menu bar icon and the meter popover. Audio is only captured while the popover is
/// open, so the app costs nothing (and shows no recording indicator) the rest of the time.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model = LevelMeterModel()
    private let launchAtLogin = LaunchAtLogin()

    override init() {
        super.init()

        if let button = statusItem.button {
            button.image = MenuBarIcon.make()
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        let hostingController = NSHostingController(rootView: MeterView(model: model, launchAtLogin: launchAtLogin))
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.delegate = self
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    func popoverWillShow(_ notification: Notification) {
        launchAtLogin.refresh()
        model.start()
    }

    func popoverDidClose(_ notification: Notification) {
        model.stop()
    }
}
