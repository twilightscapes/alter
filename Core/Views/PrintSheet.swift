//
//  PrintSheet.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  File ▸ Print (⌘P), as Aperture laid it out: presets down the left, the
//  pages in the middle, the settings on the right. Print renders each
//  photo — its adjustments applied — at about 300 ppi for the size it'll
//  be, then hands the pages to the Mac's print panel (whose PDF menu
//  saves exactly what a printer would get).
//

import AppKit
import SwiftUI

struct PrintSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("print.presetID") private var presetID = PrintPreset.builtIns[0].id.uuidString
    @State private var userPresets: [PrintPreset] = PrintPresets.load()
    @State private var settings = PrintSettings()
    @State private var page = 0
    @State private var photos: [PhotoItem] = []
    @State private var previews: [Int64: NSImage] = [:]
    @State private var printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
    @State private var paperName = ""
    @State private var rendering: Double?
    @State private var namingPreset = false
    @State private var newPresetName = ""

    private var allPresets: [PrintPreset] { PrintPreset.builtIns + userPresets }
    private var preset: PrintPreset? { allPresets.first { $0.id.uuidString == presetID } }
    private var edited: Bool { preset.map { $0.settings != settings } ?? false }

    private var paper: CGSize {
        let size = printInfo.paperSize
        let short = min(size.width, size.height), long = max(size.width, size.height)
        return settings.landscape ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }
    private var layout: PrintLayout { PrintLayout(settings: settings, paper: paper, photoCount: photos.count) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                presetList
                    .frame(width: 180)
                Divider()
                previewPane
                    .frame(minWidth: 380, maxWidth: .infinity)
                Divider()
                ScrollView { controls.padding(14) }
                    .frame(width: 280)
            }
            Divider()
            footer
                .padding(12)
        }
        .frame(width: 960, height: 640)
        .onAppear(perform: load)
        .onChange(of: settings) { _ in
            page = min(page, max(0, layout.pages.count - 1))
            // Your own preset keeps what you change; a built-in stays as shipped.
            if let index = userPresets.firstIndex(where: { $0.id.uuidString == presetID }) {
                userPresets[index].settings = settings
                PrintPresets.save(userPresets)
            }
            PrintPresets.saveLast(settings)
        }
        .alert("Save Print Preset", isPresented: $namingPreset) {
            TextField("Name", text: $newPresetName)
            Button("Save") { saveAsPreset() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Presets

    private var presetList: some View {
        List(selection: Binding(get: { presetID }, set: { id in
            guard let id, let chosen = allPresets.first(where: { $0.id.uuidString == id }) else { return }
            presetID = id
            settings = chosen.settings
            page = 0
        })) {
            Section("Presets") {
                ForEach(PrintPreset.builtIns) { preset in
                    Text(preset.name).tag(preset.id.uuidString)
                }
            }
            if !userPresets.isEmpty {
                Section("My Presets") {
                    ForEach(userPresets) { preset in
                        Text(preset.name)
                            .tag(preset.id.uuidString)
                            .contextMenu {
                                Button("Delete \(preset.name)", role: .destructive) { delete(preset) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Save as Preset…") {
                    newPresetName = edited ? "\(preset?.name ?? "Print") Copy" : (preset?.name ?? "Print") + " Copy"
                    namingPreset = true
                }
                .controlSize(.small)
                Spacer()
            }
            .padding(8)
        }
    }

    // MARK: Preview

    private var previewPane: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let scale = min((geo.size.width - 30) / paper.width, (geo.size.height - 30) / paper.height)
                PrintPreview(layout: layout, settings: settings, photos: pagePhotos(previews), page: page)
                    .frame(width: paper.width * scale, height: paper.height * scale)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            HStack(spacing: 12) {
                Button { page -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(page == 0)
                    .accessibilityLabel("Previous page")
                Text("Page \(page + 1) of \(layout.pages.count)")
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                Button { page += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(page >= layout.pages.count - 1)
                    .accessibilityLabel("Next page")
            }
            .buttonStyle(.borderless)
            .padding(.bottom, 10)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: Settings

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("Paper") {
                HStack {
                    Text(paperName.isEmpty ? "Default paper" : paperName)
                        .lineLimit(1)
                    Spacer()
                    Button("Page Setup…", action: pageSetup)
                        .controlSize(.small)
                }
                Picker("Orientation", selection: $settings.landscape) {
                    Text("Portrait").tag(false)
                    Text("Landscape").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            group("Layout") {
                Picker("Layout", selection: $settings.layout) {
                    ForEach(PrintSettings.Layout.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                switch settings.layout {
                case .fitPage:
                    EmptyView()
                case .grid:
                    Stepper("Columns: \(settings.columns)", value: $settings.columns, in: 1...12)
                    Stepper("Rows: \(settings.rows)", value: $settings.rows, in: 1...15)
                case .fixedSize:
                    HStack {
                        LengthField(points: $settings.printWidth)
                        Text("×")
                        LengthField(points: $settings.printHeight)
                        Text(PrintUnits.name)
                            .foregroundColor(.secondary)
                    }
                }
                Toggle("Crop Image to Fill", isOn: $settings.cropToFill)
                Toggle("Rotate to Fit", isOn: $settings.rotateToFit)
                Stepper("Copies of each: \(settings.copies)", value: $settings.copies, in: 1...50)
            }

            group("Margins & Spacing") {
                HStack {
                    Text("Margins")
                    Spacer()
                    LengthField(points: $settings.margin)
                    Text(PrintUnits.name).foregroundColor(.secondary)
                }
                HStack {
                    Text("Spacing")
                    Spacer()
                    LengthField(points: $settings.spacing)
                    Text(PrintUnits.name).foregroundColor(.secondary)
                }
                HStack {
                    Text("Border")
                    Spacer()
                    TextField("", value: $settings.border, format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 54)
                        .multilineTextAlignment(.trailing)
                    Text("pt").foregroundColor(.secondary)
                }
            }

            group("Metadata") {
                Picker("Under each photo", selection: $settings.metadata) {
                    ForEach(PrintSettings.Metadata.allCases) { Text($0.label).tag($0) }
                }
                if settings.metadata != .none {
                    Stepper("Text size: \(Int(settings.captionSize)) pt", value: $settings.captionSize, in: 6...24)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            content()
        }
    }

    private var footer: some View {
        HStack {
            if let rendering {
                ProgressView(value: rendering)
                    .frame(width: 160)
                Text("Preparing photos…")
                    .foregroundColor(.secondary)
            } else {
                Text("\(photos.count) photo\(photos.count == 1 ? "" : "s") · \(layout.pages.count) page\(layout.pages.count == 1 ? "" : "s")"
                     + (edited ? " · \(preset?.name ?? "") (edited)" : ""))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Print…") { Task { await printNow() } }
                .keyboardShortcut(.defaultAction)
                .disabled(photos.isEmpty || rendering != nil)
        }
    }

    // MARK: Actions

    private func load() {
        photos = store.items.filter { store.selection.contains($0.id) }
        if photos.isEmpty, let id = store.viewerPhotoID, let item = store.item(id) { photos = [item] }
        settings = PrintPresets.loadLast() ?? preset?.settings ?? PrintSettings()
        paperName = printInfo.localizedPaperName ?? ""
        // Small renders for the preview, a few at a time.
        let wanted = photos
        Task {
            for item in wanted {
                let url = item.url, edits = item.edits
                let image = await Task.detached(priority: .userInitiated) {
                    ImageLoader.shared.thumbnail(for: url, edits: edits, maxPixel: 700)
                }.value
                previews[item.id] = image
            }
        }
    }

    private func pagePhotos(_ images: [Int64: NSImage]) -> [PrintPageView.Photo] {
        photos.map { item in
            PrintPageView.Photo(image: images[item.id], filename: item.filename, title: item.metadata.title,
                                caption: item.metadata.caption, rating: max(0, item.rating))
        }
    }

    private func pageSetup() {
        let panel = NSPageLayout()
        printInfo.orientation = settings.landscape ? .landscape : .portrait
        if panel.runModal(with: printInfo) == NSApplication.ModalResponse.OK.rawValue {
            settings.landscape = printInfo.orientation == .landscape
            paperName = printInfo.localizedPaperName ?? ""
            // Keep the choice for next time.
            NSPrintInfo.shared = (printInfo.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        }
    }

    private func saveAsPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let made = PrintPreset(name: name, settings: settings)
        userPresets.append(made)
        PrintPresets.save(userPresets)
        presetID = made.id.uuidString
    }

    private func delete(_ preset: PrintPreset) {
        userPresets.removeAll { $0.id == preset.id }
        PrintPresets.save(userPresets)
        if presetID == preset.id.uuidString { presetID = PrintPreset.builtIns[0].id.uuidString }
    }

    /// Render at print resolution, then the Mac's print panel.
    private func printNow() async {
        let layout = self.layout
        let longest = layout.pages.flatMap { $0 }.map { max($0.image.width, $0.image.height) }.max() ?? 500
        let maxPixel = Int(min(7200, max(600, longest * 300 / 72)))
        rendering = 0
        var images: [Int64: NSImage] = [:]
        for (index, item) in photos.enumerated() {
            let url = item.url, edits = item.edits
            images[item.id] = await Task.detached(priority: .userInitiated) {
                ImageLoader.shared.thumbnail(for: url, edits: edits, maxPixel: maxPixel)
            }.value
            rendering = Double(index + 1) / Double(max(1, photos.count))
        }
        rendering = nil

        let view = PrintPageView(layout: layout)
        view.settings = settings
        view.photos = pagePhotos(images)
        let info = (printInfo.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.orientation = settings.landscape ? .landscape : .portrait
        // Alter places everything itself; the printer's own margins aside.
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = photos.count == 1 ? photos[0].filename : "\(photos.count) photos"
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        dismiss()
        DispatchQueue.main.async {
            if let window = NSApp.mainWindow ?? NSApp.keyWindow {
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            } else {
                operation.run()
            }
        }
    }
}

// MARK: - Pieces

/// The page being looked at: the print's own drawing, scaled down.
private struct PrintPreview: NSViewRepresentable {
    let layout: PrintLayout
    let settings: PrintSettings
    let photos: [PrintPageView.Photo]
    let page: Int

    func makeNSView(context: Context) -> PrintPageView {
        let view = PrintPageView(layout: layout)
        view.autoSizes = false
        view.showsGuides = true
        return view
    }

    func updateNSView(_ view: PrintPageView, context: Context) {
        view.layout = layout
        view.settings = settings
        view.photos = photos
        // Show one page, scaled to the frame SwiftUI gave the view.
        view.bounds = CGRect(x: 0, y: layout.paper.height * Double(page),
                             width: layout.paper.width, height: layout.paper.height)
        view.needsDisplay = true
    }
}

/// Inches here, centimetres where the metric system is used.
enum PrintUnits {
    static let metric = Locale.current.measurementSystem == .metric
    static var name: String { metric ? "cm" : "in" }
    static var pointsPerUnit: Double { metric ? 72 / 2.54 : 72 }
}

private struct LengthField: View {
    @Binding var points: Double

    var body: some View {
        TextField("", value: Binding(get: { points / PrintUnits.pointsPerUnit },
                                     set: { points = max(0, $0) * PrintUnits.pointsPerUnit }),
                  format: .number.precision(.fractionLength(0...2)))
            .frame(width: 58)
            .multilineTextAlignment(.trailing)
    }
}

/// Your own presets and the last settings used, kept in preferences.
enum PrintPresets {
    private static let presetsKey = "print.userPresets", lastKey = "print.lastSettings"

    static func load() -> [PrintPreset] {
        guard let data = UserDefaults.standard.data(forKey: presetsKey),
              let presets = try? JSONDecoder().decode([PrintPreset].self, from: data) else { return [] }
        return presets
    }

    static func save(_ presets: [PrintPreset]) {
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: presetsKey) }
    }

    static func loadLast() -> PrintSettings? {
        UserDefaults.standard.data(forKey: lastKey).flatMap { try? JSONDecoder().decode(PrintSettings.self, from: $0) }
    }

    static func saveLast(_ settings: PrintSettings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: lastKey) }
    }
}
