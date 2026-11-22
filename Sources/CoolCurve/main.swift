import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let windowAutosaveName = "MmMainWindow"

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var signalSources: [DispatchSourceSignal] = []
    private let appState = AppState.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar first: no Dock icon until the window is opened.
        NSApp.setActivationPolicy(.accessory)
        applyApplicationIcon()
        routeTerminationSignals()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.image = makeMenuBarIcon()
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.length = fixedStatusItemLength(for: button)
        }
        updateTitle()

        let hosting = NSHostingController(
            rootView: MenuBarPopoverView(appState: appState) { [weak self] in
                self?.popover.performClose(nil)
                self?.showMainWindow()
            }
        )
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        // objectWillChange fires before the new values land; hop to the next run loop pass to read them.
        appState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)

        appState.$isWindowPinned
            .sink { [weak self] pinned in self?.mainWindow?.level = pinned ? .floating : .normal }
            .store(in: &cancellables)

        appState.$menuBarDensity
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let item = self.statusItem, let button = item.button else { return }
                item.length = self.fixedStatusItemLength(for: button)
                self.updateTitle()
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave fans pinned at a manual or smart speed after we quit.
        // Also restore in auto once we've written anything: a manual/curve write may still be in flight.
        if appState.fanMode != .auto || appState.fanService.hasIssuedCommands {
            _ = appState.fanService.restoreAutomaticModeNow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: - Main window

    private func showMainWindow() {
        if mainWindow == nil {
            let hosting = NSHostingController(rootView: MainWindowView(appState: appState))
            hosting.sizingOptions = .preferredContentSize

            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "CoolCurve"
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            if !window.setFrameUsingName(Self.windowAutosaveName) {
                window.center()
            }
            window.setFrameAutosaveName(Self.windowAutosaveName)
            mainWindow = window
        }

        mainWindow?.level = appState.isWindowPinned ? .floating : .normal
        NSApp.setActivationPolicy(.regular)
        applyApplicationIcon()
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to menu-bar-only once the window is gone.
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Status item

    /// Left click toggles the popover; right click opens the window.
    @objc private func statusItemClicked(_ sender: AnyObject?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(sender)
            showMainWindow()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateTitle() {
        statusItem?.button?.title = " " + appState.menuBarText
    }

    /// Explicitly sets `applicationIconImage` so the Dock tile refreshes immediately when
    /// switching from `.accessory` to `.regular` (and bypasses stale LaunchServices caches).
    private func applyApplicationIcon() {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else {
            return
        }
        NSApp.applicationIconImage = icon
        NSApp.dockTile.display()
    }

    /// Vector template icon matching the segmented dial AppIcon (`isTemplate` adapts to light/dark menu bars).
    private func makeMenuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let black = NSColor.black.cgColor
            ctx.setStrokeColor(black)
            ctx.setFillColor(black)
            ctx.setLineCap(.round)

            let center = CGPoint(x: 9, y: 9)
            let arcs: [(CGFloat, CGFloat)] = [(140, 200), (222, 282), (304, 364)]
            ctx.setLineWidth(1.6)
            for (startDeg, endDeg) in arcs {
                ctx.beginPath()
                ctx.addArc(
                    center: center,
                    radius: 6.8,
                    startAngle: startDeg * .pi / 180,
                    endAngle: endDeg * .pi / 180,
                    clockwise: false
                )
                ctx.strokePath()
            }

            ctx.addEllipse(in: CGRect(x: 7, y: 7, width: 4, height: 4))
            ctx.fillPath()

            let rad = 325.0 * CGFloat.pi / 180.0
            let tip = CGPoint(x: 9 + 4.4 * cos(rad), y: 9 + 4.4 * sin(rad))
            ctx.setLineWidth(1.5)
            ctx.beginPath()
            ctx.move(to: center)
            ctx.addLine(to: tip)
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CoolCurve"
        return image
    }

    /// Size the item for the widest possible text (100% / 100°C) so neighbouring menu bar
    /// icons never shift as the numbers change.
    private func fixedStatusItemLength(for button: NSStatusBarButton) -> CGFloat {
        let font = button.font ?? NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        let widest = AppState.widestMenuBarText(for: appState.menuBarDensity)
        let textWidth = (" " + widest as NSString).size(withAttributes: [.font: font]).width
        let imageWidth = button.image?.size.width ?? 16
        return ceil(textWidth + imageWidth + 10)
    }

    /// `kill` / `pkill` send SIGTERM, which skips applicationWillTerminate by default and would
    /// leave fans pinned. Route it through a normal terminate so fans go back to automatic.
    private func routeTerminationSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}

let app = NSApplication.shared
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
    // Developer tool: `CoolCurve --snapshot <dir> [secondsOfHistory]` renders README images and exits.
    let directory = URL(fileURLWithPath: arguments[index + 1])
    let delay = (index + 2 < arguments.count ? Double(arguments[index + 2]) : nil) ?? 0
    app.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated {
        AppState.isSnapshotMode = true
        SnapshotRenderer.run(outputDirectory: directory, delay: delay)
    }
    app.run()
} else {
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.run()
}
