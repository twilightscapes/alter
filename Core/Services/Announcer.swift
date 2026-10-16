//
//  Announcer.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Speaks a message through VoiceOver. ALTtext isn't only for sighted posters
//  adding ALT text — a blind user can select an untagged photo and generate
//  its description, then hear it. For that to work voice-only, the result has
//  to be *announced*, not just shown in the status bar. This posts an
//  accessibility announcement that VoiceOver reads aloud (a no-op when
//  VoiceOver is off). macOS 13+ safe (AppKit, not the macOS 14 SwiftUI API).
//

import AppKit

enum Announcer {
    /// Read `message` aloud through VoiceOver, interrupting lower-priority
    /// speech when `interrupt` is true (use it for a result the user asked for).
    @MainActor
    static func announce(_ message: String, interrupt: Bool = true) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let target: Any = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp as Any
        NSAccessibility.post(
            element: target,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: (interrupt ? NSAccessibilityPriorityLevel.high
                                      : NSAccessibilityPriorityLevel.medium).rawValue,
            ])
    }
}
