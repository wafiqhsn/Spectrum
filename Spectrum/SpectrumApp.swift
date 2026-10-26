import SwiftUI
import AppKit

@main
struct SpectrumApp {
    @MainActor static func main() {
        let defaults = UserDefaults.standard
        // Adopt the requested normal-app behavior once; later explicit Dock choices remain respected.
        if !defaults.bool(forKey: "standardWindowBehaviorV1") {
            defaults.set(true, forKey: "showInDock")
            defaults.set(true, forKey: "standardWindowBehaviorV1")
        }
        let app = NSApplication.shared
        let delegate = SpectrumAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy((UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true) ? .regular : .accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
final class SpectrumDeckWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
@MainActor
final class SpectrumAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let model = SpectrumModel()
    private let player = SpotifyPlayer()
    private let lyrics = LyricsModel()
    private var window: SpectrumDeckWindow!
    private var statusItem: NSStatusItem!
    private var miniPanel: SpectrumMiniPanel!
    private let menuState = MenuPlayerState()
    private var aboutWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var statusMenuOpen = false
    private var wakeActivity: NSObjectProtocol?
    private var seekKeyMonitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var menuTrackingDepth = 0
    private var presentationUpdate: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var displaySleeping = false
    private var systemSleeping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.setPresentationActive(false)
        window = SpectrumDeckWindow(contentRect: NSRect(x: 0, y: 0, width: 482, height: 732), styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Spectrum"
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.isMovableByWindowBackground = true; window.isReleasedWhenClosed = false
        window.level = UserDefaults.standard.bool(forKey: "alwaysOnTop") ? .floating : .normal
        window.delegate = self
        window.contentView = NSHostingView(rootView: SpectrumWindowSurface(model: model, player: player, lyrics: lyrics))
        window.center()
        if let url = Bundle.main.url(forResource: "SpectrumIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(title: "Spectrum")
        let about = appMenu.addItem(withTitle: "About Spectrum", action: #selector(openAbout), keyEquivalent: ""); about.target = self
        appMenu.addItem(.separator())
        let mini = appMenu.addItem(withTitle: "Open Menu Bar Player", action: #selector(openMenuPlayer), keyEquivalent: "m")
        mini.keyEquivalentModifierMask = [.command, .shift]; mini.target = self
        let main = appMenu.addItem(withTitle: "Open Main Player", action: #selector(showMainWindow), keyEquivalent: "1"); main.target = self
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ","); settings.target = self
        appMenu.addItem(.separator())
        let awake = appMenu.addItem(withTitle: "Prevent Sleep", action: #selector(togglePreventSleep), keyEquivalent: ""); awake.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Spectrum", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let close = fileMenu.addItem(withTitle: "Close Window", action: #selector(closePlayerWindow), keyEquivalent: "w")
        close.target = self
        fileItem.submenu = fileMenu; menu.addItem(fileItem)
        let playbackItem = NSMenuItem(); menu.addItem(playbackItem)
        playbackItem.submenu = makePlaybackMenu()
        let visualizerItem = NSMenuItem(title: "Visualizer", action: nil, keyEquivalent: "")
        visualizerItem.submenu = makeVisualizerMenu(); menu.addItem(visualizerItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let minimize = windowMenu.addItem(withTitle: "Minimize", action: #selector(minimizeMainPlayer), keyEquivalent: "m")
        minimize.target = self
        windowItem.submenu = windowMenu; menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        let helpItem = NSMenuItem(); menu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help"); helpItem.submenu = helpMenu
        let help = helpMenu.addItem(withTitle: "Spectrum Help", action: #selector(openHelp), keyEquivalent: "?"); help.target = self
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = menu
        configureMenuBar()
        configureSeekKeys()
        configureEnergyPolicy()
        model.refresh()
        player.setArtworkEnabled(UserDefaults.standard.object(forKey: "loadArtwork") as? Bool ?? true)
        player.begin()
        if UserDefaults.standard.object(forKey: "autoCapture") as? Bool ?? true { model.start() }
        // A launch always opens the main window; a saved pin must not replace it with a popover.
        showMainWindow()
    }
    private func configureEnergyPolicy() {
        menuObservers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePresentationUpdate() }
        })
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch note.name {
                    case NSWorkspace.screensDidSleepNotification: self.displaySleeping = true
                    case NSWorkspace.screensDidWakeNotification: self.displaySleeping = false
                    case NSWorkspace.willSleepNotification: self.systemSleeping = true
                    default: self.systemSleeping = false
                    }
                    self.updatePresentation()
                }
            })
        }
        schedulePresentationUpdate()
    }
    private func schedulePresentationUpdate() {
        presentationUpdate?.cancel()
        // Avoid destroying and recreating a tap during a main/mini window handoff.
        presentationUpdate = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            self?.updatePresentation()
        }
    }
    private func updatePresentation() {
        func visible(_ candidate: NSWindow?) -> Bool {
            guard let candidate else { return false }
            return candidate.isVisible && !candidate.isMiniaturized && candidate.occlusionState.contains(.visible)
        }
        let awake = !displaySleeping && !systemSleeping && !NSApp.isHidden
        let mainVisible = awake && visible(window)
        let miniVisible = awake && visible(miniPanel)
        let defaults = UserDefaults.standard
        let showSpectrum = defaults.object(forKey: "showSpectrum") as? Bool ?? true
        let visualizerVisible = !defaults.bool(forKey: "lyricsEnabled") && (miniVisible || (mainVisible && showSpectrum))
        model.setPresentationActive(visualizerVisible)
        player.setPresentationActive(mainVisible || miniVisible)
    }
    func windowDidChangeOcclusionState(_ notification: Notification) { schedulePresentationUpdate() }
    func windowDidMiniaturize(_ notification: Notification) { schedulePresentationUpdate() }
    func windowDidDeminiaturize(_ notification: Notification) { schedulePresentationUpdate() }
    func applicationDidHide(_ notification: Notification) { schedulePresentationUpdate() }
    func applicationDidUnhide(_ notification: Notification) { schedulePresentationUpdate() }

    private func configureSeekKeys() {
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuTrackingDepth += 1 }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1) } }
            }
        ]
        seekKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.menuTrackingDepth == 0,
                      event.keyCode == 123 || event.keyCode == 124,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      let focused = NSApp.keyWindow, focused.isVisible,
                      focused === self.window || focused === self.miniPanel,
                      !(focused.firstResponder is NSTextView),
                      !(focused.firstResponder is NSTextField),
                      self.player.connected, self.player.duration > 1, !self.player.editingPosition else { return false }
                self.seekRelative(event.keyCode == 123 ? -5 : 5)
                return true
            }
            return handled ? nil : event
        }
    }
    private func seekRelative(_ seconds: Double) {
        player.position = min(player.duration, max(0, player.position + seconds))
        player.seek()
    }
    private func makeVisualizerMenu() -> NSMenu {
            let styles = NSMenu(title: "Visualizer")
            for (index, name) in ["Aurora", "Green Bars", "VU Meter", "Lyrics"].enumerated() {
                let item = styles.addItem(withTitle: name, action: #selector(selectVisualizer(_:)), keyEquivalent: "")
                item.tag = index; item.target = self
            }
        return styles
    }
    private func makePlaybackMenu() -> NSMenu {
        let playback = NSMenu(title: "Playback")
        let shortcuts: [(String, String, NSEvent.ModifierFlags, Int)] = [
            ("Play / Pause", " ", [], 1),
            ("Previous Track", "\u{f702}", [.command], 2),
            ("Next Track", "\u{f703}", [.command], 3),
            ("Seek Backward 5 Seconds", "\u{f702}", [], 4),
            ("Seek Forward 5 Seconds", "\u{f703}", [], 5),
            ("Volume Up", "\u{f700}", [.command], 6),
            ("Volume Down", "\u{f701}", [.command], 7),
            ("Toggle Shuffle", "s", [.command, .shift], 8),
            ("Toggle Repeat", "r", [.command, .shift], 9),
            ("Toggle Lyrics", "l", [.command], 10)
        ]
        for (title, key, modifiers, tag) in shortcuts {
            let item = playback.addItem(withTitle: title, action: #selector(playbackAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.tag = tag; item.target = self
        }
        return playback
    }
    func setDockVisibility(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }
    private func showInfoWindow(_ existing: inout NSWindow?, title: String, content: some View) {
        hideMenuPlayer()
        if existing == nil {
            let info = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 510), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            info.title = title; info.isReleasedWhenClosed = false
            info.contentView = NSHostingView(rootView: content)
            info.center(); existing = info
        }
        existing?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openAbout() {
        showInfoWindow(&aboutWindow, title: "About Spectrum", content: SpectrumAboutView())
    }
    @objc private func openHelp() {
        showInfoWindow(&helpWindow, title: "Spectrum Help", content: SpectrumHelpView(openSettings: { [weak self] in self?.openSettings() }))
    }
    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
                NSColor.black.setFill()
                let heights: [CGFloat] = [6, 13, 9]
                for (index, height) in heights.enumerated() {
                    NSBezierPath(roundedRect: NSRect(x: 3 + CGFloat(index) * 5, y: 2.5, width: 2, height: height), xRadius: 1, yRadius: 1).fill()
                }
                return true
            }
            icon.isTemplate = true; icon.accessibilityDescription = "Spectrum"
            button.image = icon
            button.toolTip = "Spectrum — click to open player; right-click for options"
            button.target = self; button.action = #selector(menuBarClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        miniPanel = SpectrumMiniPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 214), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        miniPanel.title = "Spectrum Menu Player"
        miniPanel.isOpaque = false; miniPanel.backgroundColor = .clear; miniPanel.hasShadow = true
        miniPanel.level = .floating; miniPanel.hidesOnDeactivate = false
        miniPanel.isReleasedWhenClosed = false; miniPanel.delegate = self
        miniPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        miniPanel.isExcludedFromWindowsMenu = true

    }
    @objc private func menuBarClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusMenuOpen = true
            defer {
                statusMenuOpen = false
                if miniPanel.isVisible { miniPanel.makeKeyAndOrderFront(nil) }
            }
            let menu = NSMenu()
            let visualizer = NSMenuItem(title: "Visualizer", action: nil, keyEquivalent: "")
            visualizer.submenu = makeVisualizerMenu(); menu.addItem(visualizer)
            menu.addItem(.separator())
            let open = menu.addItem(withTitle: "Open Main Player", action: #selector(showMainWindow), keyEquivalent: ""); open.target = self
            let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ""); settings.target = self
            let playback = NSMenuItem(title: "Playback", action: nil, keyEquivalent: "")
            playback.submenu = makePlaybackMenu(); menu.addItem(playback)
            menu.addItem(.separator())
            let awake = menu.addItem(withTitle: "Prevent Sleep", action: #selector(togglePreventSleep), keyEquivalent: ""); awake.target = self
            menu.addItem(.separator())
            let about = menu.addItem(withTitle: "About Spectrum", action: #selector(openAbout), keyEquivalent: ""); about.target = self
            let help = menu.addItem(withTitle: "Help", action: #selector(openHelp), keyEquivalent: ""); help.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Spectrum", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else if miniPanel.isVisible { hideMenuPlayer() }
        else { showMenuPlayer() }
    }
    @objc private func togglePreventSleep() {
        if let activity = wakeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            wakeActivity = nil
        } else {
            wakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                reason: "Spectrum Prevent Sleep")
        }
    }
    @objc private func selectVisualizer(_ sender: NSMenuItem) {
        if sender.tag == 3 {
            UserDefaults.standard.set(true, forKey: "lyricsEnabled")
        } else {
            let styles = ["aurora", "greenBars", "vuMeter"]
            guard styles.indices.contains(sender.tag) else { return }
            UserDefaults.standard.set(styles[sender.tag], forKey: "visualizerStyle")
            UserDefaults.standard.set(false, forKey: "lyricsEnabled")
            UserDefaults.standard.set(true, forKey: "showSpectrum")
        }
    }
    @objc private func openMenuPlayer() { showMenuPlayer() }
    private func showMenuPlayer() {
        guard let button = statusItem.button, let statusWindow = button.window else { return }
        let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = statusWindow.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let x = min(max(anchor.midX - 160, visible.minX + 8), visible.maxX - 328)
        miniPanel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - 214))
        menuState.arrowX = anchor.midX - x
        // The menu bar companion does not close or hide the main app window.
        miniPanel.contentView = NSHostingView(rootView: MenuPlayerView(model: model, player: player, lyrics: lyrics, state: menuState, close: { [weak self] in self?.hideMenuPlayer() }))
        // This nonactivating panel can receive keyboard input without replacing
        // the foreground application's menu bar. Main Player and Settings still activate normally.
        miniPanel.makeKeyAndOrderFront(nil)
        schedulePresentationUpdate()
    }
    private func hideMenuPlayer() {
        miniPanel?.orderOut(nil); miniPanel?.contentView = nil
        schedulePresentationUpdate()
    }
    @objc private func showMainWindow() {
        hideMenuPlayer()
        if window.contentView == nil { window.contentView = NSHostingView(rootView: SpectrumWindowSurface(model: model, player: player, lyrics: lyrics)) }
        window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
        schedulePresentationUpdate()
        NSApp.activate(ignoringOtherApps: true)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(closePlayerWindow) { return NSApp.keyWindow?.isVisible == true }
        if item.action == #selector(minimizeMainPlayer) { return NSApp.keyWindow === window && window.isVisible && !window.isMiniaturized }
        if item.action == #selector(togglePreventSleep) {
            item.state = wakeActivity == nil ? .off : .on
            return true
        }
        if item.action == #selector(selectVisualizer(_:)) {
            let defaults = UserDefaults.standard
            let lyrics = defaults.bool(forKey: "lyricsEnabled")
            let styles = ["aurora", "greenBars", "vuMeter"]
            let selected = item.tag == 3 ? lyrics : (!lyrics && styles.indices.contains(item.tag) && styles[item.tag] == (defaults.string(forKey: "visualizerStyle") ?? "aurora"))
            item.state = selected ? .on : .off
            return true
        }
        guard item.action == #selector(playbackAction(_:)) else { return true }
        if item.tag == 10 { return true }
        if item.tag == 6 || item.tag == 7 { return player.canAdjustVolume }
        guard player.connected else { return false }
        if NSApp.keyWindow?.firstResponder is NSTextView { return false }
        if item.tag == 4 || item.tag == 5 { return player.duration > 1 && !player.editingPosition }
        if item.tag == 8 { item.state = player.shuffle ? .on : .off; return player.shuffleAvailable }
        if item.tag == 9 { item.state = player.repeating ? .on : .off; return player.repeatAvailable }
        return true
    }
    @objc private func playbackAction(_ sender: NSMenuItem) {
        guard validateMenuItem(sender) else { return }
        switch sender.tag {
        case 1: player.playPause()
        case 2: player.previous()
        case 3: player.next()
        case 4, 5:
            seekRelative(sender.tag == 4 ? -5 : 5)
        case 6, 7:
            player.volume = min(100, max(0, player.volume + (sender.tag == 6 ? 5 : -5)))
            player.setVolume()
        case 8: player.toggleShuffle()
        case 9: player.toggleRepeat()
        case 10:
            UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "lyricsEnabled"), forKey: "lyricsEnabled")
        default: break
        }
    }
    @objc private func openSettings() { showMainWindow(); NotificationCenter.default.post(name: .init("SpectrumOpenSettings"), object: nil) }
    func closeMainPlayer() {
        window.orderOut(nil)
        window.contentView = nil
        schedulePresentationUpdate()
    }
    @objc private func closePlayerWindow() {
        guard let focused = NSApp.keyWindow else { return }
        if focused === window { closeMainPlayer() }
        else if focused === miniPanel { hideMenuPlayer() }
        else { focused.performClose(nil) }
    }
    @objc func minimizeMainPlayer() {
        // nil lets AppKit generate its native window thumbnail in the Dock.
        window.miniwindowImage = nil
        window.miniaturize(nil)
        schedulePresentationUpdate()
    }
    func windowWillClose(_ notification: Notification) { schedulePresentationUpdate() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window { closeMainPlayer(); return false }
        return true
    }
    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === miniPanel, !menuState.pinned, !statusMenuOpen { hideMenuPlayer() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        presentationUpdate?.cancel()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let seekKeyMonitor { NSEvent.removeMonitor(seekKeyMonitor) }
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        if let activity = wakeActivity { ProcessInfo.processInfo.endActivity(activity); wakeActivity = nil }
        model.stop(); player.end()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(); return true
    }
}

struct SpectrumWindowSurface: View {
    let model: SpectrumModel
    let player: SpotifyPlayer
    let lyrics: LyricsModel
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22).fill(Color(white: 0.75))
                .frame(width: 394, height: 644)
                .shadow(color: .black.opacity(0.46), radius: 18, x: 0, y: 12)
                .shadow(color: .black.opacity(0.22), radius: 4, x: 0, y: 3)
            SpectrumView(model: model, player: player, lyrics: lyrics)
        }.padding(44)
    }
}

struct DeckScreenShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 22, y: 8))
        p.addLine(to: CGPoint(x: 372, y: 8))
        p.addQuadCurve(to: CGPoint(x: 386, y: 22), control: CGPoint(x: 386, y: 8))
        p.addLine(to: CGPoint(x: 386, y: 362))
        p.addQuadCurve(to: CGPoint(x: 372, y: 376), control: CGPoint(x: 386, y: 376))
        p.addLine(to: CGPoint(x: 296, y: 376))
        p.addCurve(to: CGPoint(x: 197, y: 322), control1: CGPoint(x: 272, y: 340), control2: CGPoint(x: 240, y: 322))
        p.addCurve(to: CGPoint(x: 98, y: 376), control1: CGPoint(x: 154, y: 322), control2: CGPoint(x: 122, y: 340))
        p.addLine(to: CGPoint(x: 22, y: 376))
        p.addQuadCurve(to: CGPoint(x: 8, y: 362), control: CGPoint(x: 8, y: 376))
        p.addLine(to: CGPoint(x: 8, y: 22))
        p.addQuadCurve(to: CGPoint(x: 22, y: 8), control: CGPoint(x: 8, y: 8))
        p.closeSubpath()
        return p
    }
}

struct VolumeDotRing: View {
    let volume: Double
    var body: some View {
        Canvas { context, size in
            for index in 0..<27 {
                let angle = (150.0 + Double(index) * 240.0 / 26.0) * Double.pi / 180.0
                let x = Double(size.width) / 2 + 84.0 * cos(angle)
                let y = Double(size.height) / 2 + 84.0 * sin(angle)
                let dot = Path(ellipseIn: CGRect(x: x - 1.75, y: y - 1.75, width: 3.5, height: 3.5))
                context.fill(dot, with: .color(Double(index) / 26.0 < volume / 100.0 ? Color(white: 0.88) : .black))
                context.stroke(dot, with: .color(.black.opacity(0.65)), lineWidth: 0.45)
            }
        }.accessibilityHidden(true)
    }
}

private enum MainDeckLayout {
    static let width: CGFloat = 394
    static let contentWidth: CGFloat = 356
    static let contentInset = (width - contentWidth) / 2
    static let transportSize: CGFloat = 56
    static let transportInset: CGFloat = 29
    static let transportY: CGFloat = 398
}

struct SpectrumView: View {
    let model: SpectrumModel
    @ObservedObject var player: SpotifyPlayer
    @State private var settingsOpen = false
    @State private var knobHovered = false
    @State private var knobDragging = false
    @ObservedObject var lyrics: LyricsModel
    @AppStorage("lyricsEnabled") private var lyricsEnabled = false
    @AppStorage("showSpectrum") private var showSpectrum = true
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    private var lyricsTrack: LyricsTrack? {
        guard player.connected, !player.artist.isEmpty else { return nil }
        return LyricsTrack(title: player.title, artist: player.artist, album: player.album, duration: Int(player.duration.rounded()))
    }
    private var lyricsTaskID: String { "\(lyricsEnabled)|\(String(describing: lyricsTrack))" }
    private func retryLyrics() { Task { await lyrics.load(lyricsTrack, enabled: lyricsEnabled, force: true) } }
    private func clock(_ value: Double) -> String {
        let seconds = max(0, Int(value.isFinite ? value : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.88), Color(white: 0.73)], startPoint: .top, endPoint: .bottom)
            DeckScreenShape().fill(Color(red: 0.065, green: 0.057, blue: 0.077))
            trackHeader.frame(width: MainDeckLayout.contentWidth, height: 90, alignment: .topLeading).offset(x: MainDeckLayout.contentInset, y: 18)
            Group {
                if lyricsEnabled {
                    LyricsPanel(lyrics: lyrics, position: player.position, retry: retryLyrics, height: 150)
                } else if showSpectrum {
                    SpectrumVisualizer(model: model).padding(.horizontal, -11)
                } else { Color.clear }
            }.frame(width: MainDeckLayout.contentWidth, height: 150).modifier(VisualizerContextMenu()).offset(x: MainDeckLayout.contentInset, y: 112)
            timeline.frame(width: MainDeckLayout.contentWidth, height: 51).offset(x: MainDeckLayout.contentInset, y: 270)
            Text(player.volumeLabel)
                .font(.system(size: 8)).foregroundStyle(.white.opacity(0.64)).offset(x: 26, y: 351)
                .help("Drag the knob up or down to adjust the selected volume target")
            SpectrumDemoBadge(model: model).offset(x: 319, y: 351)
            dial.frame(width: 190, height: 190).offset(x: 102, y: 331)
            DeckRoundButton(symbol: "backward.end.fill", label: "Previous track") { player.previous() }
                .disabled(!player.connected).offset(x: MainDeckLayout.transportInset, y: MainDeckLayout.transportY)
            DeckRoundButton(symbol: "forward.end.fill", label: "Next track") { player.next() }
                .disabled(!player.connected).offset(x: MainDeckLayout.width - MainDeckLayout.transportInset - MainDeckLayout.transportSize, y: MainDeckLayout.transportY)
            speakerGrille.offset(x: 26, y: 510)
            VStack(spacing: 2) {
                PikoDeveloperLogo().fill(.white.opacity(0.8), style: FillStyle(eoFill: true)).frame(width: 45, height: 9).accessibilityLabel("PIKO")
                Text("MUSIC VISUALIZER").font(.system(size: 6)).foregroundStyle(.black.opacity(0.75))
            }.frame(width: 150).offset(x: 122, y: 524)
            modeSwitch.offset(x: 125, y: 560)
            transportModes.offset(x: 314, y: 522)
        }
        .frame(width: 394, height: 644)
        .onChange(of: alwaysOnTop) { _, value in
            NSApp.windows.first { $0.title == "Spectrum" }?.level = value ? .floating : .normal
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .preferredColorScheme(.dark)
        .task(id: lyricsTaskID) { await lyrics.load(lyricsTrack, enabled: lyricsEnabled) }
        .onReceive(NotificationCenter.default.publisher(for: .init("SpectrumOpenSettings"))) { _ in settingsOpen = true }
    }
    private var trackHeader: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let image = player.artwork { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                else { ZStack { Color(white: 0.1); Image(systemName: "opticaldisc").font(.system(size: 26, weight: .ultraLight)).foregroundStyle(.white.opacity(0.4)) } }
            }.frame(width: 74, height: 74).clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.18), lineWidth: 1.5)).offset(x: 7, y: 8)
            VStack(alignment: .leading, spacing: 5) {
                Text(player.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.92)).lineLimit(1).help(player.title)
                Text(player.artist).font(.system(size: 10)).foregroundStyle(.white.opacity(0.47)).lineLimit(1)
                Text(player.album).font(.system(size: 8)).foregroundStyle(.white.opacity(0.28)).lineLimit(1)
            }.frame(width: 170, alignment: .leading).offset(x: 96, y: 20)
            HStack(spacing: 4) {
                DeckGlyph(symbol: "gearshape", label: "Settings") { settingsOpen.toggle() }
                    .keyboardShortcut(",", modifiers: .command)
                    .popover(isPresented: $settingsOpen, arrowEdge: .bottom) { DeckSettingsView(model: model, player: player).frame(width: 350) }
                DeckGlyph(symbol: "minus", label: "Minimize") { (NSApp.delegate as? SpectrumAppDelegate)?.minimizeMainPlayer() }
                DeckGlyph(symbol: "xmark", label: "Close") { (NSApp.delegate as? SpectrumAppDelegate)?.closeMainPlayer() }
            }.offset(x: 269, y: 8)
        }
    }
    private var timeline: some View {
        VStack(spacing: 1) {
            Slider(value: $player.position, in: 0...max(1, player.duration), onEditingChanged: { editing in
                player.editingPosition = editing
                if !editing { player.seek() }
            }).controlSize(.small).tint(Color(white: 0.58)).disabled(!player.connected || player.duration <= 1).accessibilityLabel("Track position")
            HStack { Text(clock(player.position)); Spacer(); Text(clock(player.duration)) }
                .font(.system(size: 7, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
            HStack {
                Text(lyricsEnabled && lyrics.lines.isEmpty ? "LYRICS" : "SYNCED LYRICS")
                Spacer()
                Link("LRCLIB ↗", destination: URL(string: "https://lrclib.net")!)
            }.font(.system(size: 6, design: .monospaced)).foregroundStyle(.white.opacity(0.35))
        }.padding(.horizontal, 7).padding(.vertical, 5)
    }
    private var dial: some View {
        ZStack {
            VolumeDotRing(volume: player.volume).frame(width: 190, height: 190)
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(white: 0.40), .black], startPoint: .top, endPoint: .bottom))
                    .frame(width: 138, height: 138)
                Circle().fill(LinearGradient(colors: [Color(white: 0.105), Color(white: 0.20)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 129, height: 129)
                Circle().fill(.white.opacity(0.95)).frame(width: 4.5, height: 4.5).offset(y: -49)
                    .rotationEffect(.degrees(-135 + player.volume * 2.7))
                    .opacity(knobHovered || knobDragging ? 1 : 0)
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 38, weight: .medium)).foregroundStyle(.white).offset(x: player.playing ? 0 : 3)
            }.frame(width: 138, height: 138)
                .overlay(Circle().stroke(.white.opacity(player.connected && knobHovered && !knobDragging ? 0.20 : 0), lineWidth: 1))
                .brightness(player.connected ? (knobDragging ? -0.035 : (knobHovered ? 0.065 : 0)) : 0)
                .scaleEffect(knobDragging ? 0.97 : (player.connected && knobHovered ? 1.015 : 1))
                .shadow(color: .black.opacity(0.6), radius: knobDragging ? 6 : 14, x: 0, y: knobDragging ? 4 : 14)
                .animation(.easeOut(duration: 0.09), value: knobDragging)
                .animation(.easeOut(duration: 0.14), value: knobHovered)
        }.frame(width: 190, height: 190)
        .overlay(PlayerKnobInput(player: player, hovered: $knobHovered, dragging: $knobDragging).frame(width: 138, height: 138))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(player.playing ? "Pause Spotify" : "Play Spotify")
        .accessibilityValue("\(player.volumeTargetTitle) volume \(Int(player.volume.rounded())) percent")
        .accessibilityAddTraits(.isButton).accessibilityAction { player.playPause() }
        .accessibilityAdjustableAction { direction in
            guard player.canAdjustVolume else { return }
            player.volume = max(0, min(100, player.volume + (direction == .increment ? 5 : -5))); player.setVolume()
        }
        .help("Click to play/pause. Drag to adjust the selected volume target.")
    }
    private var speakerGrille: some View {
        Canvas { context, size in
            let diameter = 4.9
            let pitchX = (Double(size.width) - diameter) / 8
            let pitchY = (Double(size.height) - diameter) / 15
            for row in 0..<16 { for column in 0..<9 {
                context.fill(Path(ellipseIn: CGRect(x: Double(column) * pitchX, y: Double(row) * pitchY, width: diameter, height: diameter)), with: .color(.black))
            }}
        }.frame(width: 60, height: 108).accessibilityHidden(true)
    }
    private var modeSwitch: some View {
        Button { lyricsEnabled.toggle() } label: {
            HStack(spacing: 0) {
                modeTile(symbol: "chart.bar.fill", selected: !lyricsEnabled)
                modeTile(symbol: "quote.bubble.fill", selected: lyricsEnabled)
            }
            .frame(width: 144, height: 40)
            .background(LinearGradient(colors: [Color(white: 0.12), Color(white: 0.20)], startPoint: .top, endPoint: .bottom), in: Capsule())
            .overlay(Capsule().stroke(.black.opacity(0.8), lineWidth: 1))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }.buttonStyle(.plain)
            .accessibilityLabel("Lyrics / EQ")
            .accessibilityValue(lyricsEnabled ? "Lyrics" : "EQ")
            .help("Click anywhere to switch between EQ and lyrics")
    }
    private func modeTile(symbol: String, selected: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [Color(red: 0.04, green: 0.92, blue: 0.49), Color(red: 0, green: 0.72, blue: 0.32)], startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().stroke(Color(red: 0.015, green: 0.22, blue: 0.11), lineWidth: 1.5))
                .padding(3).opacity(selected ? 1 : 0)
            Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
                .foregroundStyle(selected ? Color(red: 0.01, green: 0.35, blue: 0.16) : .white)
        }.frame(width: 72, height: 40).allowsHitTesting(false)
    }
    private var transportModes: some View {
        VStack(spacing: 0) {
            Button { player.toggleRepeat() } label: { Image(systemName: "repeat").font(.system(size: 18, weight: .semibold)).foregroundStyle(player.repeating ? .green : .white).frame(width: 54, height: 48) }
                .disabled(!player.connected || !player.repeatAvailable).accessibilityLabel("Repeat").accessibilityValue(player.repeating ? "On" : "Off")
            Button { player.toggleShuffle() } label: { Image(systemName: "shuffle").font(.system(size: 18, weight: .semibold)).foregroundStyle(player.shuffle ? .green : .white).frame(width: 54, height: 48) }
                .disabled(!player.connected || !player.shuffleAvailable).accessibilityLabel("Shuffle").accessibilityValue(player.shuffle ? "On" : "Off")
        }.buttonStyle(.plain).background(Color(white: 0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct DeckSettingsView: View {
    @AppStorage("showInDock") private var showInDock = true
    @ObservedObject var model: SpectrumModel
    @ObservedObject var player: SpotifyPlayer
    @AppStorage("visualizerStyle") private var visualizerStyle = "aurora"
    @AppStorage("autoCapture") private var autoCapture = true
    @AppStorage("loadArtwork") private var loadArtwork = true
    @AppStorage("showSpectrum") private var showSpectrum = true
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.system(size: 20, weight: .semibold)).padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("GENERAL") {
                        Toggle("Show in Dock", isOn: $showInDock)
                            .onChange(of: showInDock) { _, value in
                                (NSApp.delegate as? SpectrumAppDelegate)?.setDockVisibility(value)
                            }
                        Text("Spectrum opens its main window on launch. Closing a window keeps the app and menu bar icon running; Quit exits. Turn this off only for menu bar only mode.").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    section("SPOTIFY CONNECTION") {
                        Label(player.connected ? "Connected to Spotify" : "Not connected", systemImage: player.connected ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(player.connected ? .green : .orange)
                        Text("Playback controls require Automation permission, separate from audio capture permission.").font(.caption).foregroundStyle(.secondary)
                        if !player.error.isEmpty { Text(player.error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                        Picker("Volume control", selection: $player.volumeTarget) {
                            Text("Spotify").tag("spotify")
                            Text("Device").tag("device")
                        }
                        Text(player.volumeTarget == "device" ? "Controls the current macOS output device." : "Controls Spotify's app volume.").font(.caption).foregroundStyle(.secondary)
                        if !player.volumeError.isEmpty { Text(player.volumeError).font(.caption).foregroundStyle(.orange) }
                        Slider(value: Binding(get: { player.volume }, set: { player.volume = $0; player.setVolume() }), in: 0...100, onEditingChanged: { editing in
                            player.editingVolume = editing; if !editing { player.setVolume() }
                        }).disabled(!player.canAdjustVolume).accessibilityLabel("\(player.volumeTargetTitle) volume")
                        HStack { Button("Open Spotify") { player.openSpotify() }; Button("Reconnect") { player.retryConnection() } }
                        Button("Automation permissions…") { player.openAutomationSettings() }
                    }
                    Divider()
                    section("AUDIO SPECTRUM") {
                        Picker("Visualizer style", selection: $visualizerStyle) {
                            Text("Aurora").tag("aurora")
                            Text("Green Bars").tag("greenBars")
                            Text("VU Meter").tag("vuMeter")
                        }

                        Toggle("Enable visualizer", isOn: Binding(get: { model.enabled }, set: { $0 ? model.start() : model.stop() }))
                        Toggle("Demo signal (not Spotify)", isOn: $model.demo).disabled(model.enabled)
                        Picker("Source", selection: $model.selected) {
                            Text("All Spotify processes (\(model.processes.count))").tag(UInt32(0))
                            ForEach(model.processes) { process in Text(process.title).tag(process.id) }
                        }.disabled(model.enabled || model.demo)
                        HStack { Button("Refresh processes") { model.refresh() }.disabled(model.enabled); Button("Audio permissions…") { model.privacySettings() } }
                        Text(model.status).font(.caption).fontWeight(.medium)
                        Text(model.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(String(format: "%.1f kHz · FFT 4096 · CH 1 · 64 bands", model.sampleRate / 1000)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        Text("Capture pauses when the visualizer is hidden, minimized, covered, or showing lyrics, and resumes when visible.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Start visualizer on launch", isOn: $autoCapture)
                    }
                    Divider()
                    section("APPEARANCE") {
                        Toggle("Show visualizer", isOn: $showSpectrum)
                        Toggle("Always on top", isOn: $alwaysOnTop)
                        Toggle("Load album artwork", isOn: $loadArtwork)
                            .onChange(of: loadArtwork) { _, value in player.setArtworkEnabled(value) }
                        Text("Click the knob to play/pause; drag to adjust the selected volume target. Use the slider below the spectrum to seek.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20)
            }
        }.frame(height: 535).preferredColorScheme(.dark)
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
            content()
        }
    }
}

struct PlayerKnobInput: NSViewRepresentable {
    @ObservedObject var player: SpotifyPlayer
    @Binding var hovered: Bool
    @Binding var dragging: Bool
    func makeNSView(context: Context) -> PlayerKnobMouseView {
        let view = PlayerKnobMouseView(); view.player = player
        view.hoverChanged = { value in if hovered != value { hovered = value } }
        view.dragChanged = { value in if dragging != value { dragging = value } }
        return view
    }
    func updateNSView(_ view: PlayerKnobMouseView, context: Context) {
        view.player = player
        view.hoverChanged = { value in if hovered != value { hovered = value } }
        view.dragChanged = { value in if dragging != value { dragging = value } }
    }
}
final class PlayerKnobMouseView: NSView {
    weak var player: SpotifyPlayer?
    var hoverChanged: ((Bool) -> Void)?
    var dragChanged: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var hoverTimer: Timer?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hoverTimer?.invalidate(); hoverTimer = nil
        if window != nil {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                guard let self, let window = self.window else { return }
                let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                self.hoverChanged?(window.isKeyWindow && self.bounds.contains(point))
            }
        }
    }
    deinit { hoverTimer?.invalidate() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag]
        if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { options.insert(.assumeInside) }
        let area = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }
    private var origin: Double = 0
    private var start = NSPoint.zero
    private var moved = false
    private var rotating = false
    private var lastAngle: Double = 0
    private var rotation: Double = 0
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let player, player.connected || player.canAdjustVolume else { return }
        hoverChanged?(true); dragChanged?(true)
        start = convert(event.locationInWindow, from: nil); origin = player.volume
        moved = false; player.editingVolume = true
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        rotating = hypot(start.x - center.x, start.y - center.y) > 38
        lastAngle = atan2(Double(start.y - center.y), Double(start.x - center.x)); rotation = 0
    }
    override func mouseDragged(with event: NSEvent) {
        guard let player else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 3 || moved else { return }
        moved = true
        guard player.canAdjustVolume else { return }
        if rotating {
            let angle = atan2(Double(point.y - bounds.midY), Double(point.x - bounds.midX))
            var delta = angle - lastAngle
            if delta > .pi { delta -= 2 * .pi }
            if delta < -.pi { delta += 2 * .pi }
            rotation += delta; lastAngle = angle
            player.volume = min(100, max(0, origin + rotation / (1.5 * .pi) * 100))
        } else {
            player.volume = min(100, max(0, origin - Double(point.y - start.y) * 0.65))
        }
        player.setVolume()
    }
    override func mouseUp(with event: NSEvent) {
        defer { player?.editingVolume = false; moved = false; dragChanged?(false) }
        guard let player else { return }
        if moved { player.setVolume() } else if player.connected { player.playPause() }
    }
}

struct DeckGlyph: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5)).frame(width: 24, height: 24)
                .background(LinearGradient(colors: [Color(white: 0.15), Color(white: 0.075)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.06)))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}
struct DeckRoundButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .frame(width: 56, height: 56)
        }.buttonStyle(DeckRoundButtonStyle()).help(label).accessibilityLabel(label)
    }
}

private struct DeckRoundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration)
    }
    private struct Feedback: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false
        private var pressed: Bool { isEnabled && configuration.isPressed }
        private var highlighted: Bool { isEnabled && hovered }
        var body: some View {
            configuration.label.foregroundStyle(.white.opacity(isEnabled ? 0.95 : 0.40))
                .background(LinearGradient(colors: [Color(white: pressed ? 0.11 : (highlighted ? 0.29 : 0.20)), Color(white: pressed ? 0.055 : (highlighted ? 0.08 : 0.035))], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                .overlay(Circle().stroke(.white.opacity(pressed ? 0.06 : (highlighted ? 0.23 : 0.09)), lineWidth: 1))
                .contentShape(Circle())
                .scaleEffect(pressed ? 0.94 : (highlighted ? 1.035 : 1))
                .shadow(color: .black.opacity(0.45), radius: pressed ? 3 : 7, x: 0, y: pressed ? 2 : 7)
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.09), value: pressed)
                .animation(.easeOut(duration: 0.14), value: highlighted)
        }
    }
}

struct AuroraSpectrum: View {
    @ObservedObject var model: SpectrumModel
    private let colors: [Color] = [Color(red: 0.19, green: 0.62, blue: 0.46), Color(red: 0.37, green: 0.97, blue: 0.84), Color(red: 0.45, green: 0.92, blue: 1), Color(red: 0.99, green: 0.90, blue: 0.55), Color(red: 1, green: 0.40, blue: 0.76), Color(red: 0.61, green: 0.25, blue: 0.70)]
    var body: some View {
        Canvas { context, size in
            let inset = 24.0
            let width = Double(size.width)
            let baseY = Double(size.height) - 27
            let plotWidth = width - 2 * inset
            // Budget for the tallest envelope plus its blur, rather than clipping loud peaks.
            let maximumCoreHeight = max(0, (baseY - 34) / 1.48)
            var points: [CGPoint] = []
            for index in 0..<64 {
                var total: Float = 0; var weight: Float = 0
                for j in max(0, index - 7)...min(63, index + 7) {
                    let distance = Float(index - j); let w = exp(-distance * distance / 22)
                    total += model.bands[j] * w; weight += w
                }
                let edge = pow(sin(Double(index) / 63 * .pi), 0.65)
                let level = min(0.96, Double(total / max(weight, 0.001)) * 1.35)
                let h = max(0, level * maximumCoreHeight * edge)
                points.append(CGPoint(x: inset + Double(index) * plotWidth / 63, y: baseY - h))
            }
            // The colored envelope rises with each band's height, around a smaller white core.
            // Every envelope returns to the same baseline so quiet audio stays flat.
            func contour(_ scale: Double, topMargin: Double) -> Path {
                let outline = points.map { point in
                    CGPoint(x: point.x, y: baseY - min(max(0, baseY - topMargin), (baseY - point.y) * scale))
                }
                var path = Path(); path.move(to: outline[0])
                for point in outline.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
                return path
            }
            let outerFlame = contour(1.48, topMargin: 15)
            let colorBody = contour(1.22, topMargin: 21)
            let whiteCore = contour(0.88, topMargin: 27)
            let tint = GraphicsContext.Shading.linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: inset, y: 0), endPoint: CGPoint(x: width - inset, y: 0))
            let opacity = model.running ? 1.0 : 0.05
            // Preserve the soft upper glow while fading its blur before the lower edge.
            context.drawLayer { glow in
                var haze = glow; haze.opacity = opacity * 0.80
                haze.addFilter(.blur(radius: 12)); haze.fill(outerFlame, with: tint)
                var color = glow; color.opacity = opacity * 0.88
                color.addFilter(.blur(radius: 5)); color.fill(colorBody, with: tint)
                var whiteBody = glow; whiteBody.opacity = opacity
                whiteBody.addFilter(.blur(radius: 6)); whiteBody.fill(whiteCore, with: .color(.white))
                glow.blendMode = .destinationIn
                glow.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                    Gradient(colors: [.white, .clear]),
                    startPoint: CGPoint(x: 0, y: baseY - 3),
                    endPoint: CGPoint(x: 0, y: baseY + 0.5)))
            }
            // A fine idle line fades away as the filled spectrum appears: no second base layer.
            let idle = 1 - min(1, Double(model.bands.max() ?? 0) * 18)
            var base = context; base.opacity = opacity * idle * 0.65
            base.addFilter(.blur(radius: 1))
            var baseline = Path(); baseline.move(to: CGPoint(x: inset, y: baseY - 0.5)); baseline.addLine(to: CGPoint(x: width - inset, y: baseY - 0.5))
            base.stroke(baseline, with: .linearGradient(Gradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.15), .init(color: .white, location: 0.85), .init(color: .clear, location: 1)]), startPoint: CGPoint(x: inset, y: 0), endPoint: CGPoint(x: width - inset, y: 0)), lineWidth: 1.5)
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.07), .init(color: .white, location: 0.93), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.16), .init(color: .white, location: 0.88), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .accessibilityLabel("Soft iridescent audio glow")
    }
}


@MainActor
final class MenuPlayerState: ObservableObject {
    @Published var pinned = UserDefaults.standard.bool(forKey: "menuPlayerPinned") {
        didSet { UserDefaults.standard.set(pinned, forKey: "menuPlayerPinned") }
    }
    @Published var arrowX: CGFloat = 205
}
final class SpectrumMiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
struct MenuPlayerArrow: Shape {
    var x: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: x - 11, y: 12))
        p.addLine(to: CGPoint(x: x, y: 1)); p.addLine(to: CGPoint(x: x + 11, y: 12)); p.closeSubpath(); return p
    }
}
struct MenuPlayerView: View {
    let model: SpectrumModel
    @ObservedObject var player: SpotifyPlayer
    @ObservedObject var lyrics: LyricsModel
    @AppStorage("lyricsEnabled") private var lyricsEnabled = false
    @ObservedObject var state: MenuPlayerState
    let close: () -> Void
    private let panelColor = Color(red: 0.06, green: 0.055, blue: 0.07)
    private var lyricsTrack: LyricsTrack? {
        guard player.connected, !player.artist.isEmpty else { return nil }
        return LyricsTrack(title: player.title, artist: player.artist, album: player.album, duration: Int(player.duration.rounded()))
    }
    private var lyricsTaskID: String { "\(lyricsEnabled)|\(String(describing: lyricsTrack))" }
    private func retryLyrics() { Task { await lyrics.load(lyricsTrack, enabled: lyricsEnabled, force: true) } }
    var body: some View {
        ZStack(alignment: .topLeading) {
            MenuPlayerArrow(x: state.arrowX).fill(panelColor)
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    VStack(spacing: 2) {
                        Text(player.title).font(.system(size: 18, weight: .bold)).foregroundStyle(.white).lineLimit(1).help(player.title)
                        Text(player.artist).font(.system(size: 10)).foregroundStyle(.white.opacity(0.38)).lineLimit(1)
                    }.frame(width: 238).frame(maxWidth: .infinity)
                    HStack {
                        Button { state.pinned.toggle() } label: {
                            Image(systemName: state.pinned ? "pin.fill" : "pin")
                                .foregroundStyle(state.pinned ? Color.green : Color.white.opacity(0.5))
                                .font(.system(size: 11)).frame(width: 24, height: 24).contentShape(Rectangle())
                        }.accessibilityLabel("Keep player visible").accessibilityValue(state.pinned ? "Pinned" : "Unpinned")
                            .help(state.pinned ? "Unpin: close when clicking outside" : "Pin: stay visible above other windows")
                        Spacer()
                        Button(action: close) {
                            Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                                .frame(width: 24, height: 24).contentShape(Rectangle())
                        }.accessibilityLabel("Close menu player").help("Hide player; reopen from the menu bar")
                    }.padding(.horizontal, 5)
                }.frame(height: 50, alignment: .top).padding(.top, 10)
                ZStack(alignment: .topTrailing) {
                    if lyricsEnabled {
                        LyricsPanel(lyrics: lyrics, position: player.position, retry: retryLyrics, height: 114)
                    } else {
                        SpectrumVisualizer(model: model)
                        SpectrumDemoBadge(model: model)
                    }
                }.frame(height: 114).modifier(VisualizerContextMenu()).padding(.horizontal, 10)
                HStack(spacing: 3) {
                    Button(action: player.previous) { Image(systemName: "backward.end.fill").frame(width: 17, height: 20).contentShape(Rectangle()) }.accessibilityLabel("Previous track")
                    Button(action: player.playPause) { Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 17, height: 20).contentShape(Rectangle()) }.accessibilityLabel(player.playing ? "Pause Spotify" : "Play Spotify")
                    Button(action: player.next) { Image(systemName: "forward.end.fill").frame(width: 17, height: 20).contentShape(Rectangle()) }.accessibilityLabel("Next track")
                    MinimalSeekBar(player: player).padding(.leading, 4)
                }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).disabled(!player.connected)
                    .padding(.horizontal, 14).frame(height: 20).padding(.bottom, 10)
            }.background(panelColor, in: RoundedRectangle(cornerRadius: 9)).padding(.top, 10)
        }.frame(width: 320, height: 214, alignment: .top).buttonStyle(.plain).preferredColorScheme(.dark)
            .task(id: lyricsTaskID) { await lyrics.load(lyricsTrack, enabled: lyricsEnabled) }
    }
}

struct MinimalSeekBar: View {
    @ObservedObject var player: SpotifyPlayer
    private var progress: Double { player.duration > 0 ? min(1, max(0, player.position / player.duration)) : 0 }
    private func move(to x: CGFloat, width: CGFloat) {
        guard player.connected, player.duration > 1, width > 0 else { return }
        player.position = min(1, max(0, Double(x / width))) * player.duration
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10))
                Capsule().fill(.white.opacity(0.24)).frame(width: geometry.size.width * progress)
            }.frame(height: 3).frame(height: 20).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard player.connected, player.duration > 1 else { return }
                        player.editingPosition = true
                        move(to: value.location.x, width: geometry.size.width)
                    }
                    .onEnded { value in
                        move(to: value.location.x, width: geometry.size.width)
                        player.editingPosition = false
                        if player.connected, player.duration > 1 { player.seek() }
                    })
        }.frame(height: 20)
            .accessibilityElement(children: .ignore).accessibilityLabel("Track position")
            .accessibilityValue("\(Int(progress * 100)) percent")
            .accessibilityAdjustableAction { direction in
                guard player.connected, player.duration > 1 else { return }
                player.position = min(player.duration, max(0, player.position + (direction == .increment ? 5 : -5)))
                player.seek()
            }
            .onDisappear { player.editingPosition = false }
    }
}


struct SpectrumVisualizer: View {
    let model: SpectrumModel
    @AppStorage("visualizerStyle") private var style = "aurora"
    var body: some View {
        if style == "vuMeter" { StereoVUMeter(model: model) }
        else if style == "greenBars" { GreenBarSpectrum(model: model) }
        else { AuroraSpectrum(model: model) }
    }
}

struct GreenBarSpectrum: View {
    @ObservedObject var model: SpectrumModel
    private let centers: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    private let labels = ["31", "62", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
    private func level(at frequency: Double) -> Double {
        let high = min(20000, model.sampleRate / 2)
        guard high > 20 else { return 0 }
        let lowEdge = frequency / sqrt(2), highEdge = frequency * sqrt(2)
        let values = model.bands.enumerated().compactMap { index, value -> Double? in
            let center = 20 * pow(high / 20, (Double(index) + 0.5) / Double(SpectrumFFT.bandCount))
            return center >= lowEdge && center < highEdge ? Double(value) : nil
        }
        guard !values.isEmpty else { return 0 }
        // Combine existing FFT bands into octave columns; these are relative levels, not a calibrated meter.
        let rms = sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(values.count))
        return min(1, max(0, rms * 1.12))
    }
    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 20
            let plotWidth = max(1, size.width - left * 2)
            let pitch = plotWidth / 10
            let barWidth = min(18, pitch * 0.62)
            let base = size.height - 22
            let top: CGFloat = 14
            let rows = 18
            let rowPitch = max(1, (base - top) / CGFloat(rows))
            let rowHeight = max(0.7, rowPitch * 0.62)
            var unlit = Path(), lit = Path(), tips = Path()
            for column in 0..<10 {
                let count = model.running ? Int((level(at: centers[column]) * Double(rows)).rounded(.down)) : 0
                let x = left + CGFloat(column) * pitch + (pitch - barWidth) / 2
                for row in 0..<rows {
                    let rect = CGRect(x: x, y: base - CGFloat(row + 1) * rowPitch, width: barWidth, height: rowHeight)
                    let segment = Path(roundedRect: rect, cornerRadius: 0.5)
                    unlit.addPath(segment)
                    if row < count { lit.addPath(segment) }
                    if row == count - 1 { tips.addPath(segment) }
                }
                context.draw(Text(labels[column]).font(.system(size: 7, weight: .medium, design: .monospaced)).foregroundColor(Color(red: 0.55, green: 0.95, blue: 0.67).opacity(0.65)), at: CGPoint(x: x + barWidth / 2, y: base + 9))
            }
            context.fill(unlit, with: .color(Color(red: 0.04, green: 0.7, blue: 0.25).opacity(0.065)))
            let green = Color(red: 0.02, green: 1, blue: 0.32)
            var halo = context; halo.opacity = 0.64
            halo.addFilter(.blur(radius: 4)); halo.fill(lit, with: .color(green))
            context.fill(lit, with: .linearGradient(Gradient(stops: [
                .init(color: green, location: 0),
                .init(color: Color(red: 0.2, green: 1, blue: 0.45), location: 0.5),
                .init(color: Color(red: 0.76, green: 1, blue: 0.81), location: 1)
            ]), startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: base)))
            context.fill(tips, with: .color(Color(red: 0.48, green: 1, blue: 0.63)))
        }.accessibilityLabel("Green segmented audio spectrum")
    }
}


struct StereoVUMeter: View {
    @ObservedObject var model: SpectrumModel
    var body: some View {
        HStack(spacing: 10) {
            AnalogVUDial(level: model.vuLevels[0], channel: "L")
            AnalogVUDial(level: model.vuLevels[1], channel: "R")
        }.padding(.horizontal, 12).padding(.top, 4)
            .help("Stereo RMS level · 0 VU = −12 dBFS RMS · approximate analog response")
            .accessibilityElement(children: .ignore).accessibilityLabel("Stereo VU meter")
            .accessibilityValue("Left \(Int(model.vuLevels[0] * 100)) percent, right \(Int(model.vuLevels[1] * 100)) percent")
    }
}

struct AnalogVUDial: View {
    let level: Double
    let channel: String
    private let red = Color(red: 0.93, green: 0.20, blue: 0.18)
    private func angle(_ fraction: Double) -> Double { (-140 + fraction * 100) * .pi / 180 }
    var body: some View {
        Canvas { context, size in
            let radius = max(1, min((Double(size.width) / 2 - 17) / cos(40 * .pi / 180), Double(size.height) * 0.79))
            let center = CGPoint(x: size.width / 2, y: size.height - 8)
            func point(_ fraction: Double, _ distance: Double) -> CGPoint {
                CGPoint(x: center.x + cos(angle(fraction)) * distance, y: center.y + sin(angle(fraction)) * distance)
            }
            func arc(_ from: Double, _ to: Double, _ distance: Double) -> Path {
                var p = Path(); p.move(to: point(from, distance))
                for step in 1...60 { p.addLine(to: point(from + (to - from) * Double(step) / 60, distance)) }
                return p
            }
            let orange = Color(red: 1, green: 0.32, blue: 0.09)
            let amber = Color(red: 1, green: 0.65, blue: 0.32)
            let warmth = 0.10 + min(1, max(0, level)) * 0.19
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                Gradient(stops: [.init(color: orange.opacity(warmth), location: 0),
                                 .init(color: orange.opacity(warmth * 0.35), location: 0.5),
                                 .init(color: .clear, location: 1)]),
                center: CGPoint(x: center.x, y: center.y - radius * 0.27), startRadius: 0, endRadius: radius * 0.75))
            var arcGlow = context; arcGlow.addFilter(.blur(radius: 3)); arcGlow.opacity = 0.28
            arcGlow.stroke(arc(0, 1, radius), with: .color(orange), lineWidth: 2)
            let zero = pow(10, -3.0 / 20)
            context.stroke(arc(0, zero, radius), with: .color(.white.opacity(0.85)), lineWidth: 3)
            context.stroke(arc(zero + 0.035, 1, radius), with: .color(red), lineWidth: 3)
            let markings: [(Double, String)] = [(-20,"20"),(-10,"10"),(-7,"7"),(-5,"5"),(-3,"3"),(-1,"1"),(0,"0"),(3,"3")]
            for (db, label) in markings {
                let fraction = pow(10, (db - 3) / 20)
                let color = db >= 0 ? red : Color.white.opacity(0.8)
                var tick = Path(); tick.move(to: point(fraction, radius + 1)); tick.addLine(to: point(fraction, radius + 9))
                context.stroke(tick, with: .color(color), lineWidth: 1.2)
                context.draw(Text(label).font(.system(size: 8, weight: .medium)).foregroundColor(color), at: point(fraction, radius + 17))
            }
            for index in 0...28 {
                let fraction = Double(index) / 28
                var tick = Path(); tick.move(to: point(fraction, radius - 9)); tick.addLine(to: point(fraction, radius - 14))
                context.stroke(tick, with: .color(fraction >= zero ? red.opacity(0.8) : .white.opacity(0.55)), lineWidth: 0.7)
            }
            context.draw(Text("VU").font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.5)), at: CGPoint(x: center.x, y: center.y - radius * 0.49))
            context.draw(Text(channel).font(.system(size: 7, weight: .medium, design: .monospaced)).foregroundColor(.white.opacity(0.34)), at: CGPoint(x: center.x - 12, y: center.y - 4))
            let position = min(1, max(0, level))
            var needle = Path(); needle.move(to: center); needle.addLine(to: point(position, radius - 5))
            var bloom = context; bloom.addFilter(.blur(radius: 6)); bloom.opacity = 0.65
            bloom.stroke(needle, with: .color(orange), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            var glow = context; glow.addFilter(.blur(radius: 2)); glow.opacity = 0.9
            glow.stroke(needle, with: .color(orange), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            context.stroke(needle, with: .color(amber), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            context.stroke(needle, with: .color(Color(red: 1, green: 0.93, blue: 0.77)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)), with: .color(amber.opacity(0.8)))
        }
    }
}


struct SpectrumAboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Version \(info["CFBundleShortVersionString"] as? String ?? "1.0") (\(info["CFBundleVersion"] as? String ?? ""))"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    if let url = Bundle.main.url(forResource: "SpectrumIcon", withExtension: "png"), let icon = NSImage(contentsOf: url) {
                        Image(nsImage: icon).resizable().frame(width: 58, height: 58)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Spectrum").font(.title2.bold())
                        Text(version).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("A native music visualizer, lyrics display, and companion player for Spotify.").font(.callout)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Developed by").font(.caption).foregroundStyle(.secondary)
                    PikoDeveloperLogo().fill(.white, style: FillStyle(eoFill: true))
                        .frame(width: 90, height: 18).accessibilityLabel("PIKO, developer")
                }
                Divider()
                Text("Credits & Licenses").font(.headline)
                Text("Lyrics provided by LRCLIB").font(.callout.weight(.medium))
                Text("LRCLIB is accessed as an online service. Its server software uses the MIT License. Song lyrics remain subject to their respective rights; the server license does not license lyric content.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("LRCLIB", destination: URL(string: "https://lrclib.net")!)
                    Link("Server license", destination: URL(string: "https://github.com/tranxuanthang/lrclib/blob/main/LICENSE")!)
                }.font(.caption)
                Text("Built with SwiftUI, Core Audio, and Accelerate. System icons use Apple's SF Symbols. No third-party library source code is bundled in this build.").font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Spotify and music content belong to their respective owners. This is an independent app, not affiliated with or endorsed by Spotify, Apple, or LRCLIB.").font(.caption).foregroundStyle(.secondary)
                Link("Spotify branding guidelines", destination: URL(string: "https://developer.spotify.com/documentation/design")!).font(.caption)
            }.padding(24).textSelection(.enabled)
        }.frame(width: 420, height: 510).preferredColorScheme(.dark)
    }
}

struct SpectrumHelpView: View {
    let openSettings: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Spectrum Help").font(.title2.bold())
                help("Menu bar player", "Click the spectrum icon to show or hide the compact player. Right-click it for Settings, Playback, About, Help, and Quit. Opening the compact panel preserves the current app's menu bar.")
                help("Dock icon", "Turn off Show in Dock in Settings → General for menu bar only mode. Restore it from the same setting. Closing a player window keeps Spectrum running; use Quit to exit.")
                help("Prevent Sleep", "Right-click the menu bar icon and enable Prevent Sleep to keep the Mac and display awake while Spectrum runs. Disable it to restore automatic sleep. It resets when you quit and does not override manual sleep or closing the lid.")
                help("Keep player visible", "Pin the compact player to keep it above other windows. Unpin it to dismiss when clicking outside.")
                help("Music & shortcuts", "Open Spotify and play a track. Playback controls need Automation permission. The Playback menu lists keyboard shortcuts; they are not global shortcuts.")
                help("Visualizer & lyrics", "Choose Aurora, Green Bars, or VU Meter in Settings. Toggle Lyrics / EQ in the main player, or use Command + L, to change both players together. Lyrics use LRCLIB and may not exist for every track.")
                help("Audio capture", "Allow System Audio Recording when requested. If capture is silent, check Spotify playback, then disable the visualizer, refresh processes, and re-enable it. Demo uses synthetic audio and is labeled DEMO.")
                help("Privacy", "Audio is processed locally and is not saved or uploaded. When lyrics are enabled, the track title, artist, album, and duration are sent to LRCLIB. Album artwork is downloaded when enabled.")
                Button("Open Settings…", action: openSettings)
            }.padding(24)
        }.frame(width: 420, height: 510).preferredColorScheme(.dark)
    }
    private func help(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}


struct VisualizerContextMenu: ViewModifier {
    @AppStorage("visualizerStyle") private var style = "aurora"
    @AppStorage("lyricsEnabled") private var lyricsEnabled = false
    @AppStorage("showSpectrum") private var showSpectrum = true
    private let choices = [("aurora", "Aurora"), ("greenBars", "Green Bars"), ("vuMeter", "VU Meter"), ("lyrics", "Lyrics")]
    private var selected: String { lyricsEnabled ? "lyrics" : style }
    private func select(_ value: String) {
        if value == "lyrics" { lyricsEnabled = true }
        else { style = value; lyricsEnabled = false; showSpectrum = true }
    }
    func body(content: Content) -> some View {
        content.contentShape(Rectangle()).contextMenu {
            ForEach(choices, id: \.0) { value, title in
                Toggle(title, isOn: Binding(get: { selected == value }, set: { _ in select(value) }))
            }
        }
    }
}

// Vector geometry from the developer-provided piko.svg (1000 × 200).
struct PikoDeveloperLogo: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func polygon(_ points: [CGPoint]) {
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
        polygon([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 200), CGPoint(x: 66.6669, y: 200), CGPoint(x: 66.6669, y: 133.333), CGPoint(x: 200.001, y: 133.333), CGPoint(x: 200.001, y: 0)])
        polygon([CGPoint(x: 266.667, y: 0), CGPoint(x: 266.667, y: 66.6666), CGPoint(x: 333.334, y: 66.6666), CGPoint(x: 333.334, y: 133.333), CGPoint(x: 266.667, y: 133.333), CGPoint(x: 266.667, y: 200), CGPoint(x: 466.666, y: 200), CGPoint(x: 466.666, y: 133.333), CGPoint(x: 400, y: 133.333), CGPoint(x: 400, y: 66.6666), CGPoint(x: 466.666, y: 66.6666), CGPoint(x: 466.666, y: 0)])
        polygon([CGPoint(x: 600, y: 0), CGPoint(x: 533.333, y: 0), CGPoint(x: 533.333, y: 200), CGPoint(x: 600, y: 200), CGPoint(x: 600, y: 133.333), CGPoint(x: 666.667, y: 133.333), CGPoint(x: 666.667, y: 66.6666), CGPoint(x: 600, y: 66.6666)])
        path.addRect(CGRect(x: 666.667, y: 0, width: 66.667, height: 66.6666))
        path.addRect(CGRect(x: 666.667, y: 133.333, width: 66.667, height: 66.667))
        path.addRect(CGRect(x: 799.999, y: 0, width: 200.001, height: 200))
        path.addRect(CGRect(x: 866.666, y: 66.6666, width: 66.667, height: 66.6664))
        return path.applying(CGAffineTransform(scaleX: rect.width / 1000, y: rect.height / 200).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

// Subscribe only to the setting this label displays, not the audio frame stream.
struct SpectrumDemoBadge: View {
    let model: SpectrumModel
    @State private var demo = false
    var body: some View {
        Group {
            if demo { Text("DEMO").font(.system(size: 7, weight: .semibold, design: .monospaced)).foregroundStyle(.orange) }
        }.onReceive(model.$demo.removeDuplicates()) { demo = $0 }
    }
}
