//
//  SlideshowView.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture's basic slideshow: the photos on black, full screen, a
//  dissolve between them, optional Ken Burns drift, a few seconds each.
//  Space pauses, ← → step, Esc leaves. A small bar slides in at the bottom
//  when the pointer moves: play/pause, seconds per slide, Ken Burns, loop.
//

import SwiftUI

struct SlideshowView: View {
    @EnvironmentObject var store: LibraryStore
    let ids: [Int64]

    @State private var index = 0
    @State private var current: NSImage?
    @State private var next: NSImage?
    @State private var showingNext = false
    @State private var playing = true
    @State private var burns = false
    @State private var controlsVisible = false
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var advanceTask: Task<Void, Never>?

    @AppStorage("slideshow.seconds") private var seconds = 4.0
    @AppStorage("slideshow.kenBurns") private var kenBurns = true
    @AppStorage("slideshow.loop") private var loop = true

    private var item: PhotoItem? { ids.indices.contains(index) ? store.item(ids[index]) : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let current {
                slide(current, animate: burns)
                    .opacity(showingNext ? 0 : 1)
            }
            if let next, showingNext {
                slide(next, animate: burns)
            }

            if ids.isEmpty {
                Text("Nothing to show")
                    .foregroundColor(.secondary)
            }

            VStack {
                Spacer()
                if controlsVisible {
                    controls
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.9), value: showingNext)
        .animation(.easeOut(duration: 0.2), value: controlsVisible)
        .onContinuousHover { phase in
            if case .active = phase { revealControls() }
        }
        .onAppear {
            burns = kenBurns
            Task { await load(0) }
            schedule()
        }
        .onDisappear {
            advanceTask?.cancel()
            hideControlsTask?.cancel()
        }
        .onChange(of: playing) { _ in schedule() }
        .onChange(of: seconds) { _ in schedule() }
        .onChange(of: kenBurns) { burns = $0 }
        .background(hiddenKeys)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slideshow, \(index + 1) of \(ids.count)")
    }

    // MARK: - Slides

    @ViewBuilder
    private func slide(_ image: NSImage, animate: Bool) -> some View {
        GeometryReader { geo in
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .modifier(KenBurns(active: animate && playing, duration: seconds + 1, seed: index))
        }
        .ignoresSafeArea()
        .accessibilityLabel(item?.metadata.altText.isEmpty == false ? item!.metadata.altText : (item?.filename ?? "Photo"))
    }

    /// Decode a slide big enough for the screen; the recipe applied.
    private func render(_ id: Int64) async -> NSImage? {
        guard let item = store.item(id) else { return nil }
        let url = item.url
        let edits = item.edits
        return await Task.detached(priority: .userInitiated) {
            ImageLoader.shared.thumbnail(for: url, edits: edits, maxPixel: 2560)
        }.value
    }

    private func load(_ i: Int) async {
        guard ids.indices.contains(i) else { return }
        current = await render(ids[i])
        showingNext = false
        // Warm the one after.
        let after = i + 1 < ids.count ? i + 1 : (loop ? 0 : nil)
        if let after { next = await render(ids[after]) }
    }

    private func step(_ delta: Int) {
        guard !ids.isEmpty else { return }
        var target = index + delta
        if target >= ids.count { if loop { target = 0 } else { playing = false; return } }
        if target < 0 { target = ids.count - 1 }
        let goingForward = delta > 0
        index = target
        if goingForward, let next {
            // Dissolve into the pre-rendered slide, then make it current.
            self.showingNext = true
            Task {
                try? await Task.sleep(nanoseconds: 950_000_000)
                self.current = next
                self.showingNext = false
                let after = target + 1 < ids.count ? target + 1 : (loop ? 0 : nil)
                if let after { self.next = await render(ids[after]) } else { self.next = nil }
            }
        } else {
            Task { await load(target) }
        }
        schedule()
    }

    private func schedule() {
        advanceTask?.cancel()
        guard playing, ids.count > 1 else { return }
        advanceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            step(1)
        }
    }

    private func revealControls() {
        controlsVisible = true
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 14) {
            Button { step(-1) } label: { Image(systemName: "backward.fill") }
                .help("Previous (←)")
            Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                .help(playing ? "Pause (Space)" : "Play (Space)")
            Button { step(1) } label: { Image(systemName: "forward.fill") }
                .help("Next (→)")
            Divider().frame(height: 16)
            Text("\(index + 1) / \(ids.count)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            HStack(spacing: 6) {
                Text("Seconds").font(.caption).foregroundColor(.secondary)
                Slider(value: $seconds, in: 1...15, step: 1)
                    .frame(width: 110)
                    .accessibilityLabel("Seconds per slide")
                Text("\(Int(seconds))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 18)
            }
            Toggle("Ken Burns", isOn: $kenBurns)
                .toggleStyle(.button)
            Toggle("Loop", isOn: $loop)
                .toggleStyle(.button)
            Spacer()
            Button {
                store.stopSlideshow(window: NSApp.keyWindow ?? NSApp.mainWindow)
            } label: {
                Label("Done", systemImage: "xmark")
            }
            .help("End the slideshow (Esc)")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.75))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1) }
    }

    private var hiddenKeys: some View {
        Group {
            Button("") { playing.toggle() }
                .keyboardShortcut(.space, modifiers: [])
            Button("") { step(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { store.stopSlideshow(window: NSApp.keyWindow ?? NSApp.mainWindow) }
                .keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// A slow drift and zoom while a slide is up; which way it goes varies
/// with the slide so consecutive photos don't move in lockstep.
private struct KenBurns: ViewModifier {
    let active: Bool
    let duration: Double
    let seed: Int

    @State private var phase = false

    func body(content: Content) -> some View {
        let dx = CGFloat((seed % 3) - 1) * 18
        let dy = CGFloat(((seed / 3) % 3) - 1) * 12
        let zoomIn = seed % 2 == 0
        content
            .scaleEffect(active ? (phase ? (zoomIn ? 1.08 : 1.0) : (zoomIn ? 1.0 : 1.08)) : 1)
            .offset(x: active && phase ? dx : 0, y: active && phase ? dy : 0)
            .onAppear {
                guard active else { return }
                withAnimation(.linear(duration: duration)) { phase = true }
            }
    }
}
