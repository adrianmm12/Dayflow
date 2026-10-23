import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let menu = NSMenu()
  private var cancellable: AnyCancellable?
  private var flowCancellable: AnyCancellable?

  override init() {
    super.init()
    menu.delegate = self
    statusItem.menu = menu

    if let button = statusItem.button {
      button.imageScaling = .scaleProportionallyDown
      button.imagePosition = .imageOnly

      let isRecording = AppState.shared.isRecording
      button.image = menuBarIcon(isRecording: isRecording)
    }

    // Observe recording state changes and update icon
    cancellable = AppState.shared.$isRecording
      .removeDuplicates()
      .sink { [weak self] isRecording in
        self?.updateIcon(isRecording: isRecording)
      }

    // Keep the icon in sync when a Flow session ends.
    flowCancellable = FlowSessionMirror.shared.$snapshot
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.flowSessionChanged()
      }
  }

  private func updateIcon(isRecording: Bool) {
    guard !FlowSessionMirror.shared.isSessionOn else { return }
    statusItem.button?.image = menuBarIcon(isRecording: isRecording)
  }

  // MARK: - Flow session

  // The Flow countdown pill (FlowMenuBarPill) and the session hero at the top
  // of the open menu (FlowMenuSessionHero) were removed with the Menu layer;
  // the plain recording icon stays up while a session is on.

  private func flowSessionChanged() {
    if !FlowSessionMirror.shared.isSessionOn {
      statusItem.length = NSStatusItem.squareLength
      statusItem.button?.image = menuBarIcon(isRecording: AppState.shared.isRecording)
    }
  }

  private func menuBarIcon(isRecording: Bool) -> NSImage? {
    let name = isRecording ? "MenuBarOnIcon" : "MenuBarOffIcon"
    guard let image = NSImage(named: name)?.copy() as? NSImage else { return nil }
    image.size = NSSize(width: 22, height: 18)
    return image
  }

  // MARK: - Menu

  // Rebuilt every time the menu opens, so it always reflects the current recording state.
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    switch RecordingControl.currentMode() {
    case .active:
      break
    case .pausedTimed(let endTime):
      let time = endTime.formatted(date: .omitted, time: .shortened)
      menu.addItem(infoItem(String(localized: "Paused until \(time)")))
      menu.addItem(resumeItem())
    case .pausedIndefinite, .stopped:
      menu.addItem(resumeItem())
    }

    menu.addItem(.separator())
    menu.addItem(
      actionItem(String(localized: "Open Dayflow"), #selector(openDayflow), symbol: "macwindow"))
    menu.addItem(actionItem(String(localized: "Open Recordings"), #selector(openRecordingsFolder)))
    menu.addItem(actionItem(String(localized: "Check for Updates"), #selector(checkForUpdates)))
    menu.addItem(.separator())
    menu.addItem(
      actionItem(
        String(localized: "Quit Completely"), #selector(quitDayflow), keyEquivalent: "q",
        symbol: "power", tint: .systemRed))
  }

  private func resumeItem() -> NSMenuItem {
    actionItem(
      String(localized: "Resume Dayflow"), #selector(resumeRecording), symbol: "play.circle",
      tint: .systemBlue)
  }

  /// A plain menu item. Items without a symbol get a blank one, so every title
  /// lines up after the icon column the way the design lays them out.
  private func actionItem(
    _ title: String, _ action: Selector, keyEquivalent: String = "", symbol: String? = nil,
    tint: NSColor? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = self
    if let symbol {
      let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      item.image =
        tint.flatMap { image?.withSymbolConfiguration(.init(paletteColors: [$0])) } ?? image
    } else {
      item.image = NSImage(size: NSSize(width: 15, height: 13))
    }
    // macOS 27 hides menu item images unless an item asks for them.
    #if compiler(>=6.4)
      if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
    #endif
    return item
  }

  // No action, so the menu shows it greyed out as a status line.
  private func infoItem(_ title: String) -> NSMenuItem {
    NSMenuItem(title: title, action: nil, keyEquivalent: "")
  }

  // MARK: - Actions

  @objc private func resumeRecording() {
    if PauseManager.shared.isPaused {
      PauseManager.shared.resume(source: .userClickedMenuBar)
    } else {
      RecordingControl.start(reason: "user_menu_bar")
    }
  }

  @objc private func openDayflow() {
    let showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
    if showDockIcon {
      NSApp.setActivationPolicy(.regular)
    }

    NSApp.unhide(nil)
    MainWindowController.shared.showMainWindow()
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func openRecordingsFolder() {
    NSWorkspace.shared.open(StorageManager.shared.recordingsRoot)
  }

  @objc private func checkForUpdates() {
    UpdaterManager.shared.checkForUpdates(showUI: true)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func quitDayflow() {
    AppDelegate.permitTermination(reason: "menu_bar_quit")
    NSApp.terminate(nil)
  }
}
