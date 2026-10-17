//
//  LibraryStore+Menus.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  The commands Aperture's menus had that Alter's didn't: the rest of the
//  Stacks menu, Show in Finder, Deselect All, Remove All Keywords, and the
//  way a menu reaches the viewer's tools.
//

import AppKit

extension LibraryStore {
    // MARK: Stacks

    /// The stack the selection is in, if it's all one stack.
    var selectedStackID: Int64? {
        let stacks = Set(selection.compactMap { item($0)?.stackID })
        return stacks.count == 1 ? stacks.first : nil
    }

    /// Open (show every member) or close (pick only) the selection's stack.
    func setStackOpen(_ open: Bool) {
        guard let catalog, let stackID = selectedStackID else { return }
        try? catalog.setStackCollapsed(stackID: stackID, collapsed: !open)
        reloadSidebar()
        reloadItems()
    }

    func setAllStacksOpen(_ open: Bool) {
        guard let catalog else { return }
        for stackID in stackInfo.keys {
            try? catalog.setStackCollapsed(stackID: stackID, collapsed: !open)
        }
        reloadSidebar()
        reloadItems()
    }

    /// Aperture's Extract Item: the selected photos leave their stack. A
    /// stack left with one photo isn't a stack any more; one that lost its
    /// pick gets its first remaining member.
    func extractFromStack() {
        guard let catalog else { return }
        let ids = selection.filter { item($0)?.stackID != nil }
        let touched = Set(ids.compactMap { item($0)?.stackID })
        for id in ids { try? catalog.removeFromStack(photoID: id) }
        reloadItems()
        tidyStacks(touched)
        statusMessage = "Took \(ids.count) photo\(ids.count == 1 ? "" : "s") out of the stack."
    }

    /// Aperture's Split Stack: the stack splits at the selected photo —
    /// it and everything after it become a stack of their own, with it as
    /// the pick. The stack has to be open (its order is what's shown).
    func splitStack() {
        guard let catalog, selection.count == 1, let at = selection.first,
              let stackID = item(at)?.stackID else { return }
        let members = items.filter { $0.stackID == stackID && !$0.isVersion }
        guard let index = members.firstIndex(where: { $0.id == at }), index > 0 else { return }
        let tail = members[index...].map(\.id)
        _ = try? catalog.createStack(photoIDs: tail, pick: at)
        reloadItems()
        tidyStacks([stackID])
        statusMessage = "Split the stack in two."
    }

    /// Every member in order, the ones on show as they're shown and any a
    /// search or filter hides after them — for writing a stack's order.
    func fullStackOrder(_ stackID: Int64) -> [Int64] {
        let shown = stackMembers(stackID)
        let all = (try? catalog?.stackMemberIDs(stackID: stackID)) ?? []
        return shown + all.filter { !shown.contains($0) }
    }

    /// A stack's members in order: the pick, then by position, then as sorted.
    func stackMembers(_ stackID: Int64) -> [Int64] {
        let pick = stackInfo[stackID]?.pick
        let shown = items.filter { $0.stackID == stackID && !$0.isVersion }
        let order = Dictionary(uniqueKeysWithValues: shown.enumerated().map { ($1.id, $0) })
        return shown.map(\.id).sorted { a, b in
            if a == pick { return true }
            if b == pick { return false }
            let pa = stackPositions[a] ?? 0, pb = stackPositions[b] ?? 0
            return pa != pb ? pa < pb : (order[a] ?? 0) < (order[b] ?? 0)
        }
    }

    /// Stack members together, in stack order, where the first of them falls.
    func orderStacks() {
        guard items.contains(where: { $0.stackID != nil }) else { return }
        var placed = Set<Int64>()
        var out: [PhotoItem] = []
        out.reserveCapacity(items.count)
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for item in items {
            guard let stackID = item.stackID, !item.isVersion else { out.append(item); continue }
            guard placed.insert(stackID).inserted else { continue }
            out += stackMembers(stackID).compactMap { byID[$0] }
        }
        items = out
    }

    /// Aperture's Promote (⌘[) / Demote (⌘]): one place earlier or later in
    /// its stack. Promoted to the front, it's the pick.
    func moveInStack(_ id: Int64, by delta: Int) {
        guard let catalog, let stackID = item(id)?.stackID else { return }
        var members = fullStackOrder(stackID)
        guard let index = members.firstIndex(of: id) else { return }
        let target = index + delta
        guard members.indices.contains(target) else { return }
        members.swapAt(index, target)
        try? catalog.setStackOrder(stackID: stackID, photoIDs: members)
        reloadSidebar()
        reloadItems()
        selection = [id]
    }

    /// After members leave: dissolve stacks of one, re-pick orphaned picks.
    private func tidyStacks(_ stackIDs: Set<Int64>) {
        guard let catalog else { return }
        for stackID in stackIDs {
            let members = items.filter { $0.stackID == stackID && !$0.isVersion }
            if members.count < 2 {
                try? catalog.unstack(stackID: stackID)
            } else if let pick = stackInfo[stackID]?.pick, !members.contains(where: { $0.id == pick }) {
                try? catalog.setStackPick(stackID: stackID, photoID: members[0].id)
            }
        }
        reloadSidebar()
        reloadItems()
    }

    // MARK: Selection, files, keywords

    func deselectAll() {
        selection = []
    }

    /// File ▸ Show in Finder: the originals, selected in Finder.
    func showInFinder(_ ids: [Int64]) {
        let urls = ids.compactMap { item($0)?.url }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Metadata ▸ Remove Keyword ▸ Remove All Keywords.
    func removeAllKeywords(from ids: [Int64]) {
        for id in ids {
            guard let keywords = item(id)?.metadata.keywords else { continue }
            for keyword in keywords { removeKeyword(keyword, from: [id]) }
        }
    }

    // MARK: Viewer tools from the menus

    /// Pick up a viewer tool from a menu: into the viewer first if the
    /// browser is showing (the selected photo), then the viewer obliges.
    func requestViewerTool(_ tool: String) {
        if viewerPhotoID == nil {
            guard let id = selection.first ?? items.first?.id else { return }
            enterViewer(id)
        }
        viewerToolRequest = tool
    }

    /// Whether a menu can offer the viewer's tools right now.
    var canUseViewerTools: Bool {
        guard isOpen else { return false }
        if let id = viewerPhotoID { return item(id)?.isVideo != true }
        return selection.count == 1 && selection.first.flatMap { item($0)?.isVideo } == false
    }
}
