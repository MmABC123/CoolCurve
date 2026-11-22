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
            button.font = MenuBarFormat.font
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

    /// Text and fixed width of the status item; called after every state change.
    private func updateTitle() {
        guard let item = statusItem, let button = item.button else { return }
        let text = appState.menuBarItems.isEmpty ? "" : " " + appState.menuBarText
        if button.title != text { button.title = text }
        if button.image == nil { button.image = MenuBarFormat.gaugeIcon }
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
        let width = appState.menuBarWidth
        if item.length != width { item.length = width }
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
