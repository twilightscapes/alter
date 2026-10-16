//
//  KeyCommands.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture's single-key commands — 1–5 rate, 0 clear, 9 reject, = and −
//  nudge, / flags, ⌃0–⌃7 label, V cycles the view, W cycles the
//  inspector, F full screen. Plain letters and digits can't be menu key
//  equivalents (they'd fire while you type a caption), so a local event
//  monitor handles them and steps aside whenever a text field has focus.
//

import AppKit
import Foundation

@MainActor
final class KeyCommands {
    private var monitor: Any?
    private weak var store: LibraryStore?

    init(store: LibraryStore) {
        self.store = store
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let store = self.store, store.isOpen else { return event }
            return self.handle(event, store: store) ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// True when the key was consumed.
    private func handle(_ event: NSEvent, store: LibraryStore) -> Bool {
        // The event's own window (keyWindow is nil when the app isn't
        // frontmost, and events still arrive). Typing wins: a field editor,
        // text view, or any sheet/panel.
        guard let window = event.window ?? NSApp.keyWindow, window.sheets.isEmpty,
              window.attachedSheet == nil,
              !(window.firstResponder is NSTextView),
              !(window.firstResponder is NSTextField) else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let chars = event.charactersIgnoringModifiers, let key = chars.first else { return false }
        let targets = store.commandTargets

        // ⌃0–⌃7: colour labels.
        if flags == [.control], let digit = key.wholeNumberValue, (0...7).contains(digit) {
            guard !targets.isEmpty else { return true }
            store.setLabel(digit, for: targets)
            return true
        }
        // ⇧H: Keywords HUD. ⇧D: keyword controls in the control bar.
        if flags == [.shift] {
            switch key {
            case "h", "H": store.isKeywordsHUDVisible.toggle(); return true
            case "d", "D": store.showKeywordControls.toggle(); return true
            default: return false
            }
        }
        guard flags.isEmpty else { return false }

        switch key {
        case "0", "1", "2", "3", "4", "5":
            guard !targets.isEmpty else { return true }
            store.setRating(key.wholeNumberValue ?? 0, for: targets)
            return true
        case "9":
            guard !targets.isEmpty else { return true }
            store.setRating(-1, for: targets)
            return true
        case "=", "+":
            guard !targets.isEmpty else { return false }
            store.adjustRating(by: 1, for: targets)
            return true
        case "-", "_":
            guard !targets.isEmpty else { return false }
            store.adjustRating(by: -1, for: targets)
            return true
        case "/":
            guard !targets.isEmpty else { return true }
            let anyUnflagged = targets.contains { !(store.item($0)?.flagged ?? true) }
            store.setFlagged(anyUnflagged, for: targets)
            return true
        case "v", "V":
            store.cycleViewMode()
            return true
        case "w", "W":
            store.cycleInspectorTab()
            return true
        case "o", "O":
            store.isLiftStampVisible.toggle()
            return true
        case "f", "F":
            store.toggleFullScreenMode(window: window)
            return true
        case "h", "H":
            guard store.isFullScreenMode else { return false }
            store.isInspectorHUDVisible.toggle()
            return true
        default:
            // Esc in full-screen browser leaves full screen (the viewer
            // handles its own Esc: tools first, then full screen).
            if event.keyCode == 53, store.isFullScreenMode, store.viewMode == .browser {
                store.exitFullScreenMode(window: window)
                return true
            }
            return false
        }
    }
}
