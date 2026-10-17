//
//  SidebarSection.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import SwiftUI

/// A sidebar section that folds away — Library, Projects, Albums and the
/// rest — and remembers whether it was open. macOS 14 and later use the
/// system's own sidebar disclosure; macOS 13 gets a chevron in the header.
struct SidebarSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let accessory: () -> Accessory
    @AppStorage private var expanded: Bool

    /// `id` keys the remembered state ("sidebar.section.<id>").
    init(_ title: String, id: String,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.content = content
        self.accessory = accessory
        _expanded = AppStorage(wrappedValue: true, "sidebar.section." + id)
    }

    var body: some View {
        if #available(macOS 14.0, *) {
            Section(isExpanded: $expanded) {
                content()
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    accessory()
                }
            }
        } else {
            Section {
                if expanded { content() }
            } header: {
                HStack(spacing: 4) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                            Text(title)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Collapse \(title)" : "Expand \(title)")
                    Spacer()
                    accessory()
                }
            }
        }
    }
}

extension SidebarSection where Accessory == EmptyView {
    init(_ title: String, id: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, id: id, content: content, accessory: { EmptyView() })
    }
}
