//
//  ViewerView.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Full-size view of one photo or video in the center pane. The controls
//  live in a solid tray UNDER the media (Aperture's control strip) — never
//  floating at the window edge where full screen or AVKit's own video
//  controls can swallow them. Esc returns to the grid; arrows step.
//

import AVKit
import SwiftUI
#if canImport(ImagePlayground)
import ImagePlayground
#endif

struct ViewerView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.undoManager) private var undoManager
    @State private var image: NSImage?
    /// A GIF with more than one frame — shown through an animating NSImageView
    /// so it actually plays, instead of the still-frame-0 render every other
    /// still uses. Set on the same task that loads `image`.
    @State private var isAnimatedGIF = false
    /// Which file `image` belongs to. Stepping to another photo drops the
    /// stale frame and shows the spinner — a slow decode (a 45-megapixel
    /// RAW) must LOOK like loading, not like the click did nothing.
    @State private var imagePath: String?
    @State private var loadFailed = false
    @State private var retouchMode = false
    @State private var retouchRadius = 0.02 // fraction of image width
    // Aperture's Retouch HUD.
    @State private var retouchClone = false
    @State private var retouchSoftness = 0.45
    @State private var retouchOpacity = 1.0
    /// Clone mode: the source point (normalized), set with ⌥-click.
    @State private var cloneSource: CGPoint?
    // Red Eye (E).
    @State private var redEyeMode = false
    @State private var redEyeRadius = 0.012
    @State private var showPlayground = false
    @State private var player: AVPlayer?

    // The Loupe: Aperture's magnifier — a circle that floats with the
    // cursor showing the photo's FULL-RESOLUTION pixels (edits applied),
    // for judging focus and detail without leaving the fitted view.
    @State private var loupeMode = false
    @State private var loupeFullImage: CGImage?
    /// Which file + recipe the full-res render belongs to.
    @State private var loupeRenderKey = ""
    @State private var loupeHover: CGPoint?
    /// Loupe preferences, kept across launches like Aperture kept its
    /// loupe how you left it: diameter (points), zoom (1 = 100%), Focus on
    /// Cursor (the glass trails the pointer on a tether) or Focus on Loupe
    /// (the glass is a thing you drag; it magnifies what's under its own
    /// centre), colour values, pixel grid.
    @AppStorage("viewer.loupeDiameter") private var loupeDiameter = 300.0
    @AppStorage("viewer.loupeZoom") private var loupeZoom = 1.0
    @AppStorage("viewer.loupeFocusCursor") private var loupeFocusCursor = true
    @AppStorage("viewer.loupeColorValues") private var loupeColorValues = false
    @AppStorage("viewer.loupePixelGrid") private var loupePixelGrid = true
    /// Focus-on-Loupe: where the glass sits (viewer coordinates).
    @State private var loupePosition: CGPoint?
    @State private var loupeDrag: LoupeDrag?
    @State private var loupeScrollMonitor: Any?

    private enum LoupeDrag {
        case move(offset: CGSize)
        case resize
    }

    // Zoom: Aperture's Z — actual pixels (or any zoom), panned by drag or
    // scroll, with a navigator thumbnail showing where you are. nil = fit.
    @State private var viewerZoom: CGFloat?
    /// Offset of the zoomed image's centre from the container's centre.
    @State private var viewerPan: CGSize = .zero
    @State private var panDragStart: CGSize?
    /// Pointer position over the photo, kept for zoom-to-point.
    @State private var lastHover: CGPoint?
    /// Zoom-to-point waiting for the full-res render: keep this image
    /// point under this screen point once the geometry is known.
    @State private var zoomAnchor: (screen: CGPoint, nx: CGFloat, ny: CGFloat)?
    @State private var containerSize: CGSize = .zero
    /// Hot & cold areas, computed from the displayed render.
    @State private var hotColdOverlay: NSImage?
    /// M: the master in place of the version — the file as it is, no
    /// recipe at all (Aperture's Show Master).
    @State private var showMaster = false
    /// Aperture's viewer background brightness preference (0 = black).
    @AppStorage("viewer.background") private var viewerBackground = 0.08

    static let zoomLevels: [CGFloat] = [0.25, 0.5, 1, 2, 4]
    private var isZoomed: Bool { viewerZoom != nil }
    private var backingScale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }

    // Brush mode: paint an adjustment in (Aperture's brushes). Strokes go
    // to the ACTIVE brush layer; the Adjust panel's sliders shape that
    // layer's recipe while the mode is up.
    @State private var brushMode = false
    @State private var brushRadius = 0.045      // fraction of image width
    @State private var brushSoftness = 0.5
    @State private var brushErasing = false
    /// Aperture's brush Strength: how much of the look one dab applies.
    @State private var brushStrength = 1.0
    /// Aperture's brush overlay: see the mask while you paint.
    @State private var brushOverlay: BrushOverlay = .none
    @State private var brushMaskImage: NSImage?
    @State private var brushHover: CGPoint?

    enum BrushOverlay: String, CaseIterable, Identifiable {
        case none = "None", color = "Color Overlay", strokes = "Brush Strokes",
             onBlack = "On Black", onWhite = "On White"
        var id: String { rawValue }
    }
    /// Last dab in normalized coords — spacing throttle for smooth strokes.
    @State private var lastDab: CGPoint?

    /// White-balance eyedropper: next click on the photo neutralizes it.
    /// An eyedropper is armed (store.pickRequest) — clicks sample the photo.
    private var wbPicking: Bool { store.pickRequest != nil }

    /// Compare: original beside the edited render — the recipe's receipts.
    @State private var compareMode = false
    @State private var originalImage: NSImage?
    /// Compare against Aperture's own render instead of the untouched
    /// original — available for photos opened from an Aperture library.
    @AppStorage("viewer.compareReference") private var compareReference = false
    /// Stacked (original above) or side-by-side — panoramas want one,
    /// portraits the other. Remembered like the loupe settings.
    @AppStorage("viewer.compareVertical") private var compareVertical = false

    // Crop mode: the viewer shows the *uncropped* (but rotated/straightened)
    // frame with the crop as an adjustable overlay, so you can grow a crop
    // back out as well as tighten it.
    @State private var cropMode = false
    @State private var cropAspect: CropAspect = .freeform
    @AppStorage("crop.showGuides") private var showCropGuides = true
    @AppStorage("crop.customW") private var cropCustomW = 4.0
    @AppStorage("crop.customH") private var cropCustomH = 5.0
    /// The file's pixel size (unrotated), for the Crop HUD's readout.
    @State private var imagePixelSize: CGSize?
    // Straighten tool (G): drag on the photo to level it, under a grid.
    @State private var straightenMode = false
    @State private var straightenStart: (angle: Double, value: Double)?
    @State private var cropDragRect: CGRect?       // view-space, during a drag
    @State private var cropDragKind: CropDragKind?

    private var item: PhotoItem? { store.viewerItem }

    /// Play the GIF when nothing needs a still: not while framing a crop or
    /// placing heal spots, and not once an adjustment is baked in (those all
    /// need the rendered frame-0 with its overlays).
    private var showAnimatedGIF: Bool {
        isAnimatedGIF && !cropMode && !retouchMode && (item?.edits.isNeutral ?? true)
    }

    /// What the viewer actually renders: in crop mode, the recipe minus its
    /// crop — geometry context stays (rotation, straighten), the frame shows
    /// everything the crop could reclaim.
    private func displayEdits(_ edits: PhotoEdits) -> PhotoEdits {
        if showMaster { return PhotoEdits() }
        guard cropMode else { return edits }
        var e = edits
        e.crop = nil
        return e
    }

    private var renderKey: String {
        guard let item else { return "" }
        return "\(item.url.path)#\(item.fileDate)#\(displayEdits(item.edits).cacheKey)#\(cropMode ? "cropping" : "")"
    }

    private var mediaAccessibilityLabel: String {
        guard let item else { return "Photo" }
        let alt = item.metadata.altText.trimmingCharacters(in: .whitespacesAndNewlines)
        if alt.isEmpty {
            return "\(item.filename). No ALT text yet — press Command G to generate a description."
        }
        return "\(item.filename). \(alt)"
    }

    var body: some View {
        // The tray rides as a bottom safe-area inset, NOT a VStack row. In
        // full-size mode the pane touches the window's bottom safe-area
        // (the status bar): a plain VStack laid the tray into that hidden
        // strip, which is why Crop/Retouch "disappeared" without the
        // filmstrip. safeAreaInset composes with the window's own inset in
        // every mode, so the tray always sits visibly above the status bar.
        mediaArea
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    controlTray
                }
            }
        .background(hiddenShortcuts)
        .modifier(PlaygroundSheet(
            isPresented: $showPlayground,
            sourceImage: image,
            onResult: handlePlaygroundResult))
        .onChange(of: store.viewerPhotoID) { _ in
            retouchMode = false
            cropMode = false
            cropDragRect = nil
            brushMode = false
            store.pickRequest = nil
            store.activeBrushLayerID = nil
            lastDab = nil
            // Compare survives stepping — flipping through a shoot two-up
            // is exactly what it's for. The original reloads per photo.
            originalImage = nil
            // Loupe MODE survives stepping (Aperture's did); the render is
            // per-photo, so drop it and let the task rebuild.
            loupeFullImage = nil
            loupeRenderKey = ""
        }
        .onChange(of: loupeMode) { on in
            if on || isZoomed { installLoupeScrollMonitor() } else { removeLoupeScrollMonitor() }
        }
        .onChange(of: store.activeBrushLayerID) { id in
            // The Adjust panel's "Brush X In/Away" and Quick Brushes land
            // here: a layer became active → paint it; cleared → stop.
            if let id, !brushMode, item?.edits.brushLayers.contains(where: { $0.id == id }) == true {
                loupeMode = false
                store.pickRequest = nil
                compareMode = false
                cropMode = false
                retouchMode = false
                brushErasing = false
                brushMode = true
                lastDab = nil
            } else if id == nil, brushMode {
                brushMode = false
                brushHover = nil
                brushMaskImage = nil
            }
        }
        .task(id: "\(brushMode)#\(brushOverlay.rawValue)#\(activeBrushLayer?.id.uuidString ?? "")#\(activeBrushLayer?.strokes.count ?? 0)#\(imagePath ?? "")") {
            guard brushMode, brushOverlay != .none, let layer = activeBrushLayer, let image,
                  layer.maskPath == nil else {
                brushMaskImage = nil
                return
            }
            let strokes = layer.strokes
            let size = image.size
            let mode = brushOverlay
            brushMaskImage = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let cg = BrushOverlayRenderer.render(strokes: strokes, size: size, mode: mode) else { return nil }
                return NSImage(cgImage: cg, size: size)
            }.value
        }
        .onChange(of: isZoomed) { on in
            if on || loupeMode { installLoupeScrollMonitor() } else { removeLoupeScrollMonitor() }
            if !on { viewerPan = .zero; zoomAnchor = nil }
        }
        .onDisappear { removeLoupeScrollMonitor() }
        .task(id: "\(compareMode)#\(compareReference)#\(imagePath ?? "")") {
            guard compareMode, let item, !item.isVideo else {
                originalImage = nil
                return
            }
            let url = item.url
            let reference = compareReference && !item.referencePath.isEmpty
                ? URL(fileURLWithPath: item.referencePath) : nil
            originalImage = await Task.detached(priority: .userInitiated) {
                if let reference {
                    // Aperture's JPEG, adjustments already baked in.
                    return ImageLoader.shared.thumbnail(for: reference, edits: PhotoEdits(), maxPixel: 1600)
                }
                return ImageLoader.shared.thumbnail(for: url, edits: PhotoEdits(), maxPixel: 1600)
            }.value
        }
        .task(id: "\(store.showHotCold)#\(renderKey)#\(image == nil)") {
            guard store.showHotCold, let image,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                hotColdOverlay = nil
                return
            }
            let overlay = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let out = ClippingOverlay.make(from: cg) else { return nil }
                return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
            }.value
            hotColdOverlay = overlay
        }
        .task(id: "\(loupeMode || isZoomed)#\(renderKey)") {
            if loupeMode || isZoomed {
                await renderLoupeImage()
            } else if loupeFullImage != nil {
                // Full-res pixels are the biggest thing we hold — let go
                // the moment the loupe is down.
                loupeFullImage = nil
                loupeRenderKey = ""
            }
        }
        .task(id: renderKey) {
            guard let item else { return }
            let url = item.url
            try? await FileLocality.ensureLocal(url)
            if item.isVideo {
                player?.pause()
                removeViewerObserver()
                let newPlayer = AVPlayer(url: url)
                player = newPlayer
                viewerTime = 0
                viewerPlaying = false
                viewerDuration = CMTimeGetSeconds(
                    (try? await AVURLAsset(url: url).load(.duration)) ?? .zero)
                viewerTimeObserver = newPlayer.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                    queue: .main
                ) { time in
                    Task { @MainActor in
                        viewerTime = CMTimeGetSeconds(time)
                        viewerPlaying = newPlayer.timeControlStatus == .playing
                    }
                }
                image = nil
                return
            }
            player?.pause()
            removeViewerObserver()
            player = nil
            isAnimatedGIF = ImageLoader.shared.isAnimatedGIF(url)
            // Different photo: spinner, not the previous photo's pixels.
            // Same photo re-rendering (slider drag): keep the frame, no flash.
            if imagePath != url.path {
                image = nil
                imagePath = url.path
            }
            loadFailed = false
            let edits = displayEdits(item.edits)
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageLoader.shared.thumbnail(for: url, edits: edits, maxPixel: 1600)
            }.value
            if imagePixelSize == nil || imagePath != url.path {
                imagePixelSize = await Task.detached(priority: .utility) { () -> CGSize? in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let w = props[kCGImagePropertyPixelWidth] as? Double,
                          let h = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
                    // Honour EXIF orientation so the readout matches what's shown.
                    let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
                    return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
                }.value
            }
            // A stale task racing a photo switch must not clobber the state.
            guard imagePath == url.path else { return }
            image = loaded
            loadFailed = loaded == nil
        }
    }

    // MARK: - Video transport (no shroud over the pixels)

    @State private var viewerTime: Double = 0
    @State private var viewerDuration: Double = 0
    @State private var viewerPlaying = false
    @State private var viewerTimeObserver: Any?

    private func removeViewerObserver() {
        if let viewerTimeObserver, let player {
            player.removeTimeObserver(viewerTimeObserver)
        }
        viewerTimeObserver = nil
    }

    private func toggleViewerPlayback(_ player: AVPlayer) {
        if player.timeControlStatus == .playing {
            player.pause()
            viewerPlaying = false
        } else {
            if viewerDuration > 0, viewerTime >= viewerDuration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
            viewerPlaying = true
        }
    }

    private func viewerTransport(_ player: AVPlayer) -> some View {
        HStack(spacing: 8) {
            Button {
                toggleViewerPlayback(player)
            } label: {
                Image(systemName: viewerPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(viewerPlaying ? "Pause" : "Play — or click the video")
            Slider(value: Binding(
                get: { viewerTime },
                set: { t in
                    viewerTime = t
                    player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                                toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
                                toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600))
                }
            ), in: 0...max(viewerDuration, 0.1))
            .controlSize(.small)
            Text(viewerTimecodeText)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var viewerTimecodeText: String {
        func format(_ seconds: Double) -> String {
            let total = Int(max(0, seconds).rounded(.down))
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        return format(viewerTime) + " / " + format(viewerDuration)
    }

    // MARK: - Media

    private var mediaArea: some View {
        ZStack {
            Color(white: viewerBackground)

            if let player, item?.isVideo == true {
                // Chrome-free playback: AVKit's hover controls shroud the
                // frame in a dark overlay, which ruins color judgment. The
                // bare player layer shows honest pixels; the transport
                // lives below the frame, never over it.
                VStack(spacing: 0) {
                    PlayerLayerView(player: player)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleViewerPlayback(player) }
                    viewerTransport(player)
                }
                .onDisappear {
                    player.pause()
                    removeViewerObserver()
                }
            } else if let item, showAnimatedGIF {
                // Let it play. Crop/retouch or any baked adjustment flips this
                // off (the conditions below go false), so the still-frame
                // render takes over with its overlays and edits intact.
                AnimatedImageView(url: item.url)
                    .accessibilityLabel(mediaAccessibilityLabel)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { store.exitViewer() }
                    .padding(6)
            } else if compareMode, let image {
                // Original | edited, both fitted — slider changes land on
                // the edited pane live while the original never lies.
                let layout = compareVertical
                    ? AnyLayout(VStackLayout(spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    Group {
                        if let originalImage {
                            Image(nsImage: originalImage)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomLeading) {
                        if let item, !item.referencePath.isEmpty {
                            // Opened from Aperture: flip the left pane between
                            // the untouched original and what Aperture showed.
                            Button {
                                compareReference.toggle()
                            } label: {
                                compareBadge(compareReference ? "APERTURE ⇄" : "ORIGINAL ⇄")
                            }
                            .buttonStyle(.plain)
                            .help(compareReference
                                  ? "Showing Aperture's own render. Click for the untouched original."
                                  : "Showing the untouched original. Click for Aperture's own render.")
                            .accessibilityLabel(compareReference ? "Aperture's render" : "Original")
                            .accessibilityHint("Switches the comparison between the original and Aperture's render")
                        } else {
                            compareBadge("ORIGINAL")
                        }
                    }
                    .accessibilityLabel(compareReference && !(item?.referencePath.isEmpty ?? true)
                                        ? "Aperture's render of this photo" : "Original, before adjustments")
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottomLeading) { compareBadge("EDITED") }
                        .accessibilityLabel(mediaAccessibilityLabel)
                }
                .padding(10)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { compareMode = false }
            } else if let image {
                GeometryReader { geo in
                    let fit = displayRect(image: image, container: geo.size)
                    ZStack(alignment: .topLeading) {
                        Group {
                            if isZoomed, let full = loupeFullImage {
                                // Actual pixels: the full-res render, placed
                                // at the zoom with the pan applied.
                                Image(nsImage: NSImage(cgImage: full, size: fit.size))
                                    .resizable()
                                    .interpolation((viewerZoom ?? 1) >= 2 ? .none : .high)
                            } else {
                                Image(nsImage: image)
                                    .resizable()
                            }
                        }
                        .frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        // Read the photo's own description aloud when it's
                        // on screen — a blind user opening a photo hears
                        // its ALT text, or that it hasn't got one yet.
                        .accessibilityLabel(mediaAccessibilityLabel)
                        if brushMode, brushOverlay != .none, let brushMaskImage {
                            Image(nsImage: brushMaskImage)
                                .resizable()
                                .frame(width: fit.width, height: fit.height)
                                .position(x: fit.midX, y: fit.midY)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .opacity(brushOverlay == .color || brushOverlay == .strokes ? 0.55 : 1)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        if store.showHotCold, let hotColdOverlay {
                            Image(nsImage: hotColdOverlay)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: fit.width, height: fit.height)
                                .position(x: fit.midX, y: fit.midY)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        Color.clear
                            .onAppear { containerSize = geo.size }
                            .onChange(of: geo.size) { containerSize = $0 }
                        if retouchMode, let item {
                            retouchMarkers(for: item, fit: fit)
                            if retouchClone, let source = cloneSource {
                                let d = max(6, retouchRadius * fit.width * 2)
                                Circle()
                                    .strokeBorder(Color.green.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                                    .frame(width: d, height: d)
                                    .offset(x: fit.minX + source.x * fit.width - d / 2,
                                            y: fit.minY + source.y * fit.height - d / 2)
                                    .allowsHitTesting(false)
                            }
                        }
                        if redEyeMode, let item {
                            redEyeMarkers(for: item, fit: fit)
                        }
                        if cropMode, let item {
                            cropOverlay(for: item, fit: fit)
                        }
                        if straightenMode {
                            straightenGrid(fit: fit)
                        }
                        if loupeMode {
                            loupeOverlay(fit: fit, container: geo.size)
                        }
                        if brushMode {
                            brushCursor(fit: fit)
                        }
                    }
                    .coordinateSpace(name: "viewer")
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let point):
                            lastHover = point
                            if loupeMode { loupeHover = point }
                            if brushMode { brushHover = point }
                        case .ended:
                            lastHover = nil
                            loupeHover = nil
                            brushHover = nil
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard !retouchMode && !cropMode && !redEyeMode else { return }
                        // Zoomed: double-click goes back to fit (Aperture's
                        // viewer); fitted: back to the grid as before.
                        if isZoomed { viewerZoom = nil } else { store.exitViewer() }
                    }
                    .onTapGesture(count: 1, coordinateSpace: .local) { location in
                        if retouchMode { addSpot(at: location, fit: fit) }
                        if redEyeMode { addRedEye(at: location, fit: fit) }
                        if let kind = store.pickRequest { performPick(kind, at: location, fit: fit) }
                    }
                    .gesture(cropMode ? cropGesture(fit: fit) : nil)
                    .gesture(straightenMode ? straightenGesture(fit: fit) : nil)
                    .gesture(brushMode ? brushGesture(fit: fit) : nil)
                    .gesture(isZoomed && !cropMode && !brushMode && !retouchMode && !wbPicking
                             && (loupeFocusCursor || !loupeMode) ? panGesture(fit: fit, container: geo.size) : nil)
                    .overlay(alignment: .bottomTrailing) {
                        if isZoomed, loupeFullImage != nil,
                           fit.width > geo.size.width || fit.height > geo.size.height {
                            navigator(image: image, rect: fit, container: geo.size)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if item?.isVideo != true { zoomChip }
                    }
                    .overlay(alignment: .topLeading) {
                        if showMaster {
                            compareBadge("MASTER")
                                .padding(4)
                                .help("Showing the master, no adjustments (M)")
                        }
                    }
                }
                .padding(6)
            } else if let item, loadFailed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30))
                    Text("Couldn't read \(item.filename)")
                        .font(.headline)
                    Text(FileManager.default.fileExists(atPath: item.url.path)
                         ? "The file exists but didn't decode as an image."
                         : "The file isn't at its cataloged location — relink its folder from the sidebar.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .foregroundColor(.secondary)
            } else if let item {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                    // Big originals (RAW especially) take a beat — say so.
                    Text("Loading \(item.filename)…")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            } else {
                Text(store.items.isEmpty ? "No photos in this view" : "Select a photo")
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .leading) {
            stepButton(systemImage: "chevron.left", delta: -1)
        }
        .overlay(alignment: .trailing) {
            stepButton(systemImage: "chevron.right", delta: 1)
        }
        .overlay(alignment: .top) {
            if loupeMode {
                loupePill
            } else if compareMode {
                comparePill
            } else if let kind = store.pickRequest {
                HStack(spacing: 8) {
                    Image(systemName: "eyedropper")
                    Text(kind.hint)
                    Button("Cancel") { store.pickRequest = nil }
                        .controlSize(.small)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                .padding(.top, 10)
            }
        }
    }

    /// One floating control for compare: flip the split.
    private var comparePill: some View {
        Button {
            compareVertical.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: compareVertical
                      ? "square.split.2x1" : "square.split.1x2")
                Text(compareVertical ? "Side by Side" : "Stacked")
                    .font(.caption)
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        .padding(.top, 10)
        .help("Flip the comparison between side-by-side and stacked")
        .accessibilityLabel(compareVertical
            ? "Switch comparison to side by side" : "Switch comparison to stacked")
    }

    /// The loupe's settings, floating over the photo in a pill — the same
    /// choices Aperture put in the loupe's own popup, reachable even when
    /// the glass is trailing the pointer.
    private var loupePill: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass.circle")
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Menu {
                ForEach(Self.loupeZoomLevels, id: \.self) { zoom in
                    Button {
                        loupeZoom = zoom
                    } label: {
                        if abs(loupeZoom - zoom) < 0.01 {
                            Label("\(Int(zoom * 100))%", systemImage: "checkmark")
                        } else {
                            Text("\(Int(zoom * 100))%")
                        }
                    }
                }
            } label: {
                Text("\(Int((loupeZoom * 100).rounded()))%")
                    .monospacedDigit()
            }
            .fixedSize()
            .help("Loupe zoom (⇧⌘+ / ⇧⌘− or scroll over the photo)")
            .accessibilityLabel("Loupe zoom")
            HStack(spacing: 5) {
                Image(systemName: "circle")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                Slider(value: $loupeDiameter, in: 160...600)
                    .frame(width: 90)
                    .accessibilityLabel("Loupe size")
                Image(systemName: "circle")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .help("Loupe size — or drag the rim of the glass")
            Picker("", selection: $loupeFocusCursor) {
                Text("Cursor").tag(true)
                Text("Loupe").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .labelsHidden()
            .help("Focus on Cursor: the glass trails the pointer. Focus on Loupe: drag the glass where you want it.")
            .accessibilityLabel("Loupe focus")
            Toggle(isOn: $loupeColorValues) {
                Image(systemName: "eyedropper")
            }
            .toggleStyle(.button)
            .help("Show the colour values under the loupe's centre")
            .accessibilityLabel("Colour values")
            Toggle(isOn: $loupePixelGrid) {
                Image(systemName: "grid")
            }
            .toggleStyle(.button)
            .help("Pixel grid at 800% and above")
            .accessibilityLabel("Pixel grid")
            Divider().frame(height: 14)
            Button {
                loupeMode = false
                loupeHover = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Close the Loupe (` or Esc)")
            .accessibilityLabel("Close the Loupe")
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        .padding(.top, 10)
    }

    // MARK: - Control tray

    private var controlTray: some View {
        HStack(spacing: 12) {
            if retouchMode {
                retouchControls
            } else if cropMode {
                cropControls
            } else if redEyeMode {
                redEyeControls
            } else if straightenMode {
                straightenControls
            } else if brushMode {
                brushControls
            } else {
              // Two rows, as Aperture had them: the control bar (navigate,
              // rotate, rate, flag, label) and the tool strip.
              VStack(spacing: 6) {
               HStack(spacing: 12) {
                Button {
                    store.exitViewer()
                } label: {
                    Label("Grid", systemImage: "square.grid.2x2")
                }
                .help("Back to the grid (Esc)")

                HStack(spacing: 4) {
                    Button { store.viewerStep(-1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous photo")
                    Button { store.viewerStep(1) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Next photo")
                }

                // Aperture's control bar: rotate, rating, flag, label.
                if let item, !item.isVideo {
                    HStack(spacing: 4) {
                        Button { store.rotate(-1, for: [item.id]) } label: {
                            Image(systemName: "rotate.left")
                        }
                        .help("Rotate counterclockwise (⌘[)")
                        .accessibilityLabel("Rotate counterclockwise")
                        Button { store.rotate(1, for: [item.id]) } label: {
                            Image(systemName: "rotate.right")
                        }
                        .help("Rotate clockwise (⌘])")
                        .accessibilityLabel("Rotate clockwise")
                    }
                    Spacer()
                    RatingControl(rating: item.rating) { store.setRating($0, for: [item.id]) }
                        .help("Rating: 1–5, 0 clears, 9 rejects, = and − nudge")
                    Button {
                        store.setFlagged(!item.flagged, for: [item.id])
                    } label: {
                        Image(systemName: item.flagged ? "flag.fill" : "flag")
                            .foregroundColor(item.flagged ? .orange : .primary)
                    }
                    .help(item.flagged ? "Unflag (/)" : "Flag (/)")
                    .accessibilityLabel(item.flagged ? "Unflag" : "Flag")
                    LabelDots(selected: item.label) { store.setLabel($0, for: [item.id]) }
                        .help("Colour label (⌃0–⌃7)")
                }

                Spacer()

                if let item {
                    HStack(spacing: 8) {
                        if item.dirty {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                        Text(item.filename)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let index = store.items.firstIndex(where: { $0.id == item.id }) {
                            Text("\(index + 1) of \(store.items.count)")
                                .foregroundColor(.secondary)
                        }
                        if !item.edits.isNeutral {
                            Image(systemName: "dial.medium.fill")
                                .foregroundColor(.accentColor)
                                .help("Has adjustments")
                                .accessibilityLabel("Has adjustments")
                        }
                    }
                    .font(.callout)
                }
               }
               if store.showKeywordControls {
                   KeywordControlsBar()
               }
               HStack(spacing: 12) {
                Spacer()
                if playgroundAvailable {
                    Button {
                        showPlayground = true
                    } label: {
                        Label("Playground", systemImage: "apple.image.playground")
                    }
                    .help("Send this photo to Image Playground — the result imports beside the original")
                }
                if let item, let tools = AlterExtensions.shared.viewerTools {
                    tools(item, store)
                }
                if item?.isVideo == false {
                    Button {
                        if compareMode { compareMode = false } else { enterCompareMode() }
                    } label: {
                        Label("Compare", systemImage: "square.split.2x1")
                    }
                    .background(compareMode
                        ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.3))
                        : nil)
                    .help("Original beside the edited photo — the recipe's before and after (⌥M). M alone shows the master in place.")
                    Button {
                        loupeMode.toggle()
                        if !loupeMode { loupeHover = nil }
                    } label: {
                        Label("Loupe", systemImage: "magnifyingglass.circle")
                    }
                    .background(loupeMode
                        ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.3))
                        : nil)
                    .help("The Loupe — full-resolution pixels under the cursor, for focus and detail (`)")
                    Button {
                        straightenMode = true
                        loupeMode = false
                        compareMode = false
                    } label: {
                        Label("Straighten", systemImage: "level")
                    }
                    .help("Straighten — drag on the photo to level it (G)")
                    Button {
                        cropMode = true
                        loupeMode = false
                        compareMode = false
                    } label: {
                        Label("Crop", systemImage: "crop")
                    }
                    .help("Crop, straighten, rotate, flip — stored in the recipe, original untouched (C)")
                    Button {
                        retouchMode = true
                        loupeMode = false
                        compareMode = false
                    } label: {
                        Label("Retouch", systemImage: "bandage")
                    }
                    .help("Repair or clone — stored in the recipe, original untouched (X)")
                    Button {
                        redEyeMode = true
                        loupeMode = false
                        compareMode = false
                    } label: {
                        Label("Red Eye", systemImage: "eye")
                    }
                    .help("Click each red pupil (E)")
                    Menu {
                        ForEach(QuickBrush.allCases) { quick in
                            Button(quick.name) {
                                if let item { store.beginQuickBrush(quick, photoID: item.id) }
                            }
                        }
                        Divider()
                        Button("Free-form Brush") { enterBrushMode() }
                    } label: {
                        Label("Brush", systemImage: "paintbrush.pointed")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .help("Quick Brushes — paint a look in. Bricks brush in from their gear menu in Adjust.")
                    Button {
                        store.pickRequest = store.pickRequest == nil ? .neutral : nil
                        loupeMode = false
                    } label: {
                        Label("Neutral", systemImage: "eyedropper.halffull")
                    }
                    .background(wbPicking
                        ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.3))
                        : nil)
                    .help("White-balance eyedropper: click something that should be neutral gray")
                }
                Spacer()
               }
              }
              .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var brushControls: some View {
        HStack(spacing: 10) {
            Image(systemName: "paintbrush.pointed")
                .foregroundColor(.accentColor)
            if let layer = activeBrushLayer {
                Text(layer.name ?? "Brush")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                // In / Away: paint where it applies, or where it doesn't.
                Picker("", selection: Binding(
                    get: { layer.inverted == true },
                    set: { away in
                        mutateActiveLayer { layers in
                            if let i = layers.firstIndex(where: { $0.id == layer.id }) {
                                layers[i].inverted = away ? true : nil
                            }
                        }
                    })) {
                    Text("In").tag(false)
                    Text("Away").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
                .help("Brush In: applies where you paint. Brush Away: applies everywhere except where you paint.")
                .accessibilityLabel("Brush direction")
            }
            Picker("", selection: $brushErasing) {
                Text("Brush").tag(false)
                Text("Erase").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .accessibilityLabel("Brush action")
            HStack(spacing: 4) {
                Text("Size").font(.caption).foregroundColor(.secondary)
                Slider(value: $brushRadius, in: 0.01...0.15)
                    .frame(width: 70)
                    .accessibilityLabel("Brush size")
            }
            HStack(spacing: 4) {
                Text("Softness").font(.caption).foregroundColor(.secondary)
                Slider(value: $brushSoftness, in: 0...1)
                    .frame(width: 60)
                    .accessibilityLabel("Brush softness")
            }
            HStack(spacing: 4) {
                Text("Strength").font(.caption).foregroundColor(.secondary)
                Slider(value: $brushStrength, in: 0.1...1)
                    .frame(width: 60)
                    .accessibilityLabel("Brush strength")
            }
            Picker("Overlay", selection: $brushOverlay) {
                ForEach(BrushOverlay.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 150)
            .help("See the brushed area while you paint")
            Button("Clear") {
                mutateActiveLayer { layers in
                    if let i = layers.firstIndex(where: { $0.id == store.activeBrushLayerID }) {
                        layers[i].strokes.removeAll()
                    }
                }
            }
            .help("Remove every stroke of this brush")
            Button("Undo Stroke") {
                mutateActiveLayer { layers in
                    if let i = layers.firstIndex(where: { $0.id == store.activeBrushLayerID }) {
                        _ = layers[i].strokes.popLast()
                    }
                }
            }
            .disabled(activeBrushLayer?.strokes.isEmpty ?? true)
            Spacer()
            Button("Done") { exitBrushMode() }
                .keyboardShortcut(.defaultAction)
                .help("Leave Brush mode (Esc)")
        }
    }

    /// Aperture's Retouch HUD: Repair (source chosen for you) or Clone
    /// (⌥-click a source, then click), radius, softness, opacity.
    private var retouchControls: some View {
        HStack(spacing: 10) {
            Image(systemName: "bandage")
                .foregroundColor(.accentColor)
            Picker("", selection: $retouchClone) {
                Text("Repair").tag(false)
                Text("Clone").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .help("Repair picks a source beside the spot. Clone copies from a source you ⌥-click.")
            .accessibilityLabel("Retouch mode")
            Text(retouchClone
                 ? (cloneSource == nil ? "⌥-click a source, then click to clone" : "Click to clone from the source")
                 : "Click a spot to heal it")
                .font(.callout)
                .foregroundColor(.secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text("Radius").font(.caption).foregroundColor(.secondary)
                Slider(value: $retouchRadius, in: 0.005...0.08)
                    .frame(width: 80)
                    .accessibilityLabel("Retouch radius")
            }
            HStack(spacing: 4) {
                Text("Softness").font(.caption).foregroundColor(.secondary)
                Slider(value: $retouchSoftness, in: 0...1)
                    .frame(width: 70)
                    .accessibilityLabel("Retouch softness")
            }
            HStack(spacing: 4) {
                Text("Opacity").font(.caption).foregroundColor(.secondary)
                Slider(value: $retouchOpacity, in: 0.1...1)
                    .frame(width: 70)
                    .accessibilityLabel("Retouch opacity")
            }
            Button("Undo") { removeLastSpot() }
                .disabled((item?.edits.retouchSpots.isEmpty) ?? true)
            Button("Clear All") { clearSpots() }
                .disabled((item?.edits.retouchSpots.isEmpty) ?? true)
            Spacer()
            Button("Done") { retouchMode = false; cloneSource = nil }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Red Eye (E)

    private var redEyeControls: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye")
                .foregroundColor(.accentColor)
            Text("Click each red pupil")
                .font(.callout)
                .foregroundColor(.secondary)
            HStack(spacing: 4) {
                Text("Radius").font(.caption).foregroundColor(.secondary)
                Slider(value: $redEyeRadius, in: 0.004...0.05)
                    .frame(width: 110)
                    .accessibilityLabel("Red eye radius")
            }
            Button("Undo") {
                mutateRedEyes { if !$0.isEmpty { $0.removeLast() } }
            }
            .disabled(item?.edits.redEyeSpots.isEmpty ?? true)
            Button("Clear All") { mutateRedEyes { $0.removeAll() } }
                .disabled(item?.edits.redEyeSpots.isEmpty ?? true)
            Spacer()
            Button("Done") { redEyeMode = false }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func mutateRedEyes(_ mutate: (inout [RedEyeSpot]) -> Void) {
        guard let item else { return }
        let binding = store.editsBinding(for: item.id)
        var edits = binding.wrappedValue
        var spots = edits.redEyeSpots
        mutate(&spots)
        edits.redEyes = spots.isEmpty ? nil : spots
        binding.wrappedValue = edits
    }

    private func addRedEye(at location: CGPoint, fit: CGRect) {
        guard fit.width > 0 else { return }
        let nx = (location.x - fit.minX) / fit.width
        let ny = (location.y - fit.minY) / fit.height
        guard (0...1).contains(nx), (0...1).contains(ny) else { return }
        mutateRedEyes { $0.append(RedEyeSpot(x: nx, y: ny, radius: redEyeRadius)) }
    }

    @ViewBuilder
    private func redEyeMarkers(for item: PhotoItem, fit: CGRect) -> some View {
        ForEach(Array(item.edits.redEyeSpots.enumerated()), id: \.element) { _, spot in
            let diameter = max(6, spot.radius * fit.width * 2)
            Circle()
                .strokeBorder(Color.red.opacity(0.85), lineWidth: 1.5)
                .frame(width: diameter, height: diameter)
                .offset(x: fit.minX + spot.x * fit.width - diameter / 2,
                        y: fit.minY + spot.y * fit.height - diameter / 2)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Compare

    private func compareBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .kerning(1)
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .padding(8)
            .accessibilityHidden(true)
    }

    private func enterCompareMode() {
        guard item?.isVideo != true else { return }
        loupeMode = false
        store.pickRequest = nil
        compareMode = true
    }

    // MARK: - Zoom (Z)

    /// Where the photo sits in the container: fitted, or at the zoom with
    /// the pan applied. Zoom geometry needs the full-res render (its size
    /// is the edited size); until it lands the fitted frame stays.
    private func displayRect(image: NSImage, container: CGSize) -> CGRect {
        guard let zoom = viewerZoom, let full = loupeFullImage else {
            return fitRect(imageSize: image.size, in: container)
        }
        let w = CGFloat(full.width) * zoom / backingScale
        let h = CGFloat(full.height) * zoom / backingScale
        let pan = clampedPan(viewerPan, w: w, h: h, container: container)
        return CGRect(x: (container.width - w) / 2 + pan.width,
                      y: (container.height - h) / 2 + pan.height,
                      width: w, height: h)
    }

    /// A zoomed image never shows a gap on an edge it could cover, and a
    /// smaller-than-container image stays centred.
    private func clampedPan(_ pan: CGSize, w: CGFloat, h: CGFloat, container: CGSize) -> CGSize {
        var p = pan
        let maxX = max(0, (w - container.width) / 2)
        let maxY = max(0, (h - container.height) / 2)
        p.width = min(max(p.width, -maxX), maxX)
        p.height = min(max(p.height, -maxY), maxY)
        return p
    }

    /// Z: fit ↔ actual size, keeping whatever's under the pointer put.
    private func toggleZoom() {
        setZoom(isZoomed ? nil : 1)
    }

    private func setZoom(_ zoom: CGFloat?) {
        guard item?.isVideo != true else { return }
        if let zoom {
            // Remember the image point under the pointer (or the centre).
            if let image, containerSize != .zero {
                let fit = displayRect(image: image, container: containerSize)
                let screen = lastHover.flatMap { fit.contains($0) ? $0 : nil }
                    ?? CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
                zoomAnchor = (screen,
                              (screen.x - fit.minX) / max(fit.width, 1),
                              (screen.y - fit.minY) / max(fit.height, 1))
            }
            viewerZoom = min(max(zoom, 0.1), 8)
            resolveZoomAnchor()
        } else {
            viewerZoom = nil
        }
    }

    private func stepZoom(_ direction: Int) {
        let current = viewerZoom ?? fittedZoom
        let levels = Self.zoomLevels
        let next: CGFloat?
        if direction > 0 {
            next = levels.first { $0 > current + 0.001 }
        } else {
            next = levels.last { $0 < current - 0.001 }
        }
        guard let next else { return }
        // Stepping down past the fitted size lands on fit.
        if direction < 0, next <= fittedZoom { setZoom(nil) } else { setZoom(next) }
    }

    /// The zoom at which the full-res render exactly fits the container.
    private var fittedZoom: CGFloat {
        guard let full = loupeFullImage, containerSize != .zero else { return 0.25 }
        return min(containerSize.width / CGFloat(full.width),
                   containerSize.height / CGFloat(full.height)) * backingScale
    }

    /// Once the zoom geometry is known, pan so the anchored image point
    /// sits under the screen point it was picked at.
    private func resolveZoomAnchor() {
        guard let anchor = zoomAnchor, let zoom = viewerZoom, let full = loupeFullImage,
              containerSize != .zero else { return }
        let w = CGFloat(full.width) * zoom / backingScale
        let h = CGFloat(full.height) * zoom / backingScale
        let pan = CGSize(width: anchor.screen.x - anchor.nx * w - (containerSize.width - w) / 2,
                         height: anchor.screen.y - anchor.ny * h - (containerSize.height - h) / 2)
        viewerPan = clampedPan(pan, w: w, h: h, container: containerSize)
        zoomAnchor = nil
    }

    private func panGesture(fit: CGRect, container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { drag in
                if panDragStart == nil { panDragStart = viewerPan }
                guard let start = panDragStart else { return }
                viewerPan = clampedPan(
                    CGSize(width: start.width + drag.translation.width,
                           height: start.height + drag.translation.height),
                    w: fit.width, h: fit.height, container: container)
            }
            .onEnded { _ in panDragStart = nil }
    }

    /// Aperture's navigator: the whole photo small, a frame on the part
    /// you're looking at; drag the frame to pan.
    private func navigator(image: NSImage, rect: CGRect, container: CGSize) -> some View {
        let w: CGFloat = 150
        let h = max(1, w * rect.height / rect.width)
        let visible = CGRect(x: -rect.minX / rect.width * w,
                             y: -rect.minY / rect.height * h,
                             width: container.width / rect.width * w,
                             height: container.height / rect.height * h)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        return ZStack(alignment: .topLeading) {
            Image(nsImage: image)
                .resizable()
                .frame(width: w, height: h)
            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .background(Rectangle().fill(Color.white.opacity(0.12)))
                .frame(width: max(4, visible.width), height: max(4, visible.height))
                .offset(x: visible.minX, y: visible.minY)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 8, y: 3)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    // Centre the view on the dragged point.
                    let nx = min(max(drag.location.x / w, 0), 1)
                    let ny = min(max(drag.location.y / h, 0), 1)
                    let pan = CGSize(width: container.width / 2 - nx * rect.width - (container.width - rect.width) / 2,
                                     height: container.height / 2 - ny * rect.height - (container.height - rect.height) / 2)
                    viewerPan = clampedPan(pan, w: rect.width, h: rect.height, container: container)
                }
        )
        .padding(12)
        .accessibilityLabel("Navigator")
        .accessibilityHint("Drag to move around the zoomed photo")
    }

    /// "Fit" / "100%" in the corner — click to toggle, like pressing Z.
    private var zoomChip: some View {
        Button {
            toggleZoom()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                Text(viewerZoom.map { "\(Int(($0 * 100).rounded()))%" } ?? "Fit")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
            }
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .padding(10)
        .help(isZoomed ? "Back to fit (Z)" : "Actual size (Z) — ⌘+ / ⌘− for other zooms; drag or scroll to pan")
        .accessibilityLabel(isZoomed ? "Zoom to fit" : "Zoom to actual size")
    }

    // MARK: - Loupe

    /// Aperture's zoom stops.
    static let loupeZoomLevels: [Double] = [0.5, 1, 2, 4, 8, 16]

    private func stepLoupeZoom(_ direction: Int) {
        let levels = Self.loupeZoomLevels
        let index = levels.indices.min { abs(levels[$0] - loupeZoom) < abs(levels[$1] - loupeZoom) } ?? 1
        loupeZoom = levels[min(max(index + direction, 0), levels.count - 1)]
    }

    /// Focus on Cursor: the glass floats up-and-right of the examined
    /// point on a tether, flipped when an edge is close so it never slides
    /// off screen.
    private func loupeCenter(for point: CGPoint, in container: CGSize) -> CGPoint {
        let d = CGFloat(loupeDiameter)
        let reach = d / 2 + 30
        let dx: CGFloat = point.x + reach + d / 2 - 8 > container.width ? -reach : reach
        let dy: CGFloat = point.y - reach - d / 2 + 8 < 0 ? reach : -reach
        return CGPoint(x: point.x + dx * 0.8, y: point.y + dy * 0.8)
    }

    /// Focus on Loupe: where the glass is, kept on screen.
    private func clampedLoupePosition(fit: CGRect, container: CGSize) -> CGPoint {
        let p = loupePosition ?? CGPoint(x: fit.midX, y: fit.midY)
        let margin = CGFloat(loupeDiameter) / 2 - 20
        return CGPoint(x: min(max(p.x, margin), container.width - margin),
                       y: min(max(p.y, margin), container.height - margin))
    }

    /// The magnifier. Focus on Cursor: trails the pointer and can't be
    /// clicked (it would run away). Focus on Loupe: a draggable glass —
    /// drag the inside to move it, the rim to resize it — with its zoom
    /// popup live in the rim.
    @ViewBuilder
    private func loupeOverlay(fit: CGRect, container: CGSize) -> some View {
        if loupeFocusCursor {
            if let hover = loupeHover, fit.contains(hover) {
                loupeGlass(examining: hover, center: loupeCenter(for: hover, in: container),
                           fit: fit, tethered: true)
                    .allowsHitTesting(false)
            }
        } else {
            let position = clampedLoupePosition(fit: fit, container: container)
            loupeGlass(examining: position, center: position, fit: fit, tethered: false)
                .gesture(loupeDragGesture(center: position))
        }
    }

    private func loupeDragGesture(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("viewer"))
            .onChanged { drag in
                let d = CGFloat(loupeDiameter)
                if loupeDrag == nil {
                    let fromCenter = hypot(drag.startLocation.x - center.x, drag.startLocation.y - center.y)
                    loupeDrag = fromCenter > d / 2 - 18
                        ? .resize
                        : .move(offset: CGSize(width: center.x - drag.startLocation.x,
                                               height: center.y - drag.startLocation.y))
                }
                switch loupeDrag {
                case .move(let offset):
                    loupePosition = CGPoint(x: drag.location.x + offset.width,
                                            y: drag.location.y + offset.height)
                case .resize:
                    let radius = hypot(drag.location.x - center.x, drag.location.y - center.y)
                    loupeDiameter = Double(min(max(radius * 2, 160), 600))
                case nil:
                    break
                }
            }
            .onEnded { _ in loupeDrag = nil }
    }

    @ViewBuilder
    private func loupeGlass(examining point: CGPoint, center: CGPoint, fit: CGRect,
                            tethered: Bool) -> some View {
        let d = CGFloat(loupeDiameter)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let inside = fit.contains(point)
        let nx = (point.x - fit.minX) / fit.width
        let ny = (point.y - fit.minY) / fit.height
        // Region of the full-res render shown in the glass: d points at
        // `zoom` image pixels per screen pixel.
        let regionPx = d * scale / max(CGFloat(loupeZoom), 0.05)
        let crop: CGImage? = {
            guard inside, let full = loupeFullImage else { return nil }
            let cx = min(max(CGFloat(full.width) * nx - regionPx / 2, 0),
                         max(CGFloat(full.width) - regionPx, 0))
            let cy = min(max(CGFloat(full.height) * ny - regionPx / 2, 0),
                         max(CGFloat(full.height) - regionPx, 0))
            return full.cropping(to: CGRect(x: cx, y: cy,
                                            width: min(regionPx, CGFloat(full.width)),
                                            height: min(regionPx, CGFloat(full.height))))
        }()
        let rgb: (Int, Int, Int)? = (loupeColorValues && inside)
            ? loupeFullImage.flatMap { loupePixelColor($0, nx: nx, ny: ny) } : nil
        let pixelPoints = CGFloat(loupeZoom) / scale

        ZStack {
            if tethered {
                // The tether and the ring on the examined point.
                Path { p in
                    p.move(to: point)
                    p.addLine(to: center)
                }
                .stroke(Color.black.opacity(0.55), lineWidth: 4)
                Path { p in
                    p.move(to: point)
                    p.addLine(to: center)
                }
                .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                Circle()
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
                    .background(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 3.5))
                    .frame(width: 13, height: 13)
                    .position(point)
            }
            ZStack {
                if let crop {
                    Image(nsImage: NSImage(cgImage: crop, size: NSSize(width: d, height: d)))
                        .resizable()
                        .interpolation(loupeZoom >= 4 ? .none : .high)
                        .frame(width: d, height: d)
                } else {
                    Circle().fill(Color.black.opacity(0.7))
                    if inside && loupeFullImage == nil {
                        ProgressView().controlSize(.small)
                    }
                }
                if loupePixelGrid, pixelPoints >= 4, crop != nil {
                    Canvas { context, size in
                        var grid = Path()
                        var x = (size.width / 2).truncatingRemainder(dividingBy: pixelPoints)
                        while x < size.width { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)); x += pixelPoints }
                        var y = (size.height / 2).truncatingRemainder(dividingBy: pixelPoints)
                        while y < size.height { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)); y += pixelPoints }
                        context.stroke(grid, with: .color(.black.opacity(0.35)), lineWidth: 0.5)
                    }
                    .frame(width: d, height: d)
                }
                if loupeColorValues {
                    // A hairline cross on the sampled pixel.
                    Path { p in
                        p.move(to: CGPoint(x: d / 2 - 8, y: d / 2)); p.addLine(to: CGPoint(x: d / 2 + 8, y: d / 2))
                        p.move(to: CGPoint(x: d / 2, y: d / 2 - 8)); p.addLine(to: CGPoint(x: d / 2, y: d / 2 + 8))
                    }
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
                    .shadow(color: .black, radius: 1)
                    .frame(width: d, height: d)
                }
            }
            .frame(width: d, height: d)
            .clipShape(Circle())
            .overlay(
                // Aperture's rim: dark band, light hairline inside.
                Circle().strokeBorder(Color(white: 0.12).opacity(0.92), lineWidth: 7)
            )
            .overlay(
                Circle().inset(by: 7).strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
            )
            .overlay(alignment: .top) {
                if let rgb {
                    Text("R \(rgb.0)  G \(rgb.1)  B \(rgb.2)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .padding(.top, 14)
                }
            }
            .overlay(alignment: .bottom) {
                loupeZoomChip(interactive: !tethered)
                    .offset(y: 8)
            }
            .shadow(color: .black.opacity(0.6), radius: 14, y: 6)
            .contentShape(Circle())
            .position(center)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loupe at \(Int((loupeZoom * 100).rounded())) percent")
    }

    /// "100% ▾" sitting on the rim. Live in Focus-on-Loupe mode; a plain
    /// readout when the glass is trailing the pointer.
    @ViewBuilder
    private func loupeZoomChip(interactive: Bool) -> some View {
        let label = Text("\(Int((loupeZoom * 100).rounded()))%")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundColor(.white)
        if interactive {
            Menu {
                ForEach(Self.loupeZoomLevels, id: \.self) { zoom in
                    Button {
                        loupeZoom = zoom
                    } label: {
                        if abs(loupeZoom - zoom) < 0.01 {
                            Label("\(Int(zoom * 100))%", systemImage: "checkmark")
                        } else {
                            Text("\(Int(zoom * 100))%")
                        }
                    }
                }
                Divider()
                Button("Focus on Cursor") { loupeFocusCursor = true }
                Toggle("Color Values", isOn: $loupeColorValues)
                Toggle("Pixel Grid", isOn: $loupePixelGrid)
            } label: {
                HStack(spacing: 3) {
                    label
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(white: 0.12).opacity(0.95)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
            }
            .menuStyle(.button)
                .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Loupe zoom and options")
        } else {
            label
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(white: 0.12).opacity(0.95)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        }
    }

    /// The 8-bit sRGB value of one pixel of the full-res render.
    private func loupePixelColor(_ image: CGImage, nx: CGFloat, ny: CGFloat) -> (Int, Int, Int)? {
        let px = min(max(Int(CGFloat(image.width) * nx), 0), image.width - 1)
        let py = min(max(Int(CGFloat(image.height) * ny), 0), image.height - 1)
        guard let one = image.cropping(to: CGRect(x: px, y: py, width: 1, height: 1)) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
    }

    /// Scroll over the photo while the loupe is up = zoom the loupe,
    /// Aperture-style. Installed only for the mode's lifetime.
    private func installLoupeScrollMonitor() {
        guard loupeScrollMonitor == nil else { return }
        loupeScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard lastHover != nil else { return event }
            if loupeMode, loupeHover != nil || !loupeFocusCursor {
                let delta = event.scrollingDeltaY
                guard abs(delta) > 0.001 else { return event }
                loupeZoom = min(16, max(0.5, loupeZoom * (1 + delta / 100)))
                return nil
            }
            if isZoomed, let image, let full = loupeFullImage, containerSize != .zero {
                let zoom = viewerZoom ?? 1
                let w = CGFloat(full.width) * zoom / backingScale
                let h = CGFloat(full.height) * zoom / backingScale
                _ = image
                viewerPan = clampedPan(
                    CGSize(width: viewerPan.width + event.scrollingDeltaX,
                           height: viewerPan.height + event.scrollingDeltaY),
                    w: w, h: h, container: containerSize)
                return nil
            }
            return event
        }
    }

    private func removeLoupeScrollMonitor() {
        if let loupeScrollMonitor { NSEvent.removeMonitor(loupeScrollMonitor) }
        loupeScrollMonitor = nil
    }

    /// Decode the original at full resolution and run the recipe over it —
    /// once per photo+recipe while the loupe is up. Bounded to ~64MP so a
    /// pathological scan can't eat the machine.
    private func renderLoupeImage() async {
        guard loupeMode || isZoomed, let item, !item.isVideo else { return }
        let key = renderKey
        guard loupeRenderKey != key else { return }
        loupeRenderKey = key
        let url = item.url
        let edits = displayEdits(item.edits)
        let rendered = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Double ?? 0
            let h = props?[kCGImagePropertyPixelHeight] as? Double ?? 0
            let upright = edits.appliesFileOrientation
            let options: [CFString: Any] = w * h > 64_000_000
                ? [kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: upright,
                   kCGImageSourceThumbnailMaxPixelSize: 8000]
                : [kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: upright,
                   kCGImageSourceThumbnailMaxPixelSize: max(w, h)]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return EditRenderer.apply(edits, to: cg)
        }.value
        // Stale guard: the photo or recipe may have moved on mid-render.
        guard loupeMode || isZoomed, renderKey == key else { return }
        loupeFullImage = rendered
        resolveZoomAnchor()
    }

    // MARK: - Brush

    private var activeBrushLayer: BrushLayer? {
        guard let item, let id = store.activeBrushLayerID else { return nil }
        return item.edits.brushLayers.first { $0.id == id }
    }

    /// Enter Brush mode on the photo's last layer, creating one if needed.
    private func enterBrushMode() {
        guard let item else { return }
        loupeMode = false
        store.pickRequest = nil
        compareMode = false
        var edits = store.editsBinding(for: item.id).wrappedValue
        if edits.brushLayers.isEmpty {
            let layer = BrushLayer()
            edits.brushes = [layer]
            store.editsBinding(for: item.id).wrappedValue = edits
        }
        store.activeBrushLayerID = edits.brushLayers.last?.id
        brushMode = true
        store.inspectorTab = .adjust
    }

    private func exitBrushMode() {
        brushMode = false
        brushHover = nil
        store.activeBrushLayerID = nil
        // An untouched empty layer left behind is just recipe lint.
        guard let item else { return }
        var edits = store.editsBinding(for: item.id).wrappedValue
        let cleaned = edits.brushLayers.filter { !$0.isEmpty }
        edits.brushes = cleaned.isEmpty ? nil : cleaned
        store.editsBinding(for: item.id).wrappedValue = edits
    }

    /// Paint: dabs along the drag, spaced so strokes stay smooth without
    /// flooding the recipe.
    private func brushGesture(fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard fit.width > 0 else { return }
                let nx = (value.location.x - fit.minX) / fit.width
                let ny = (value.location.y - fit.minY) / fit.height
                guard (0...1).contains(nx), (0...1).contains(ny) else { return }
                brushHover = value.location
                let point = CGPoint(x: nx, y: ny)
                if let last = lastDab {
                    let spacing = max(brushRadius * 0.35, 0.004)
                    guard hypot(point.x - last.x, point.y - last.y) > spacing else { return }
                }
                lastDab = point
                addDab(at: point)
            }
            .onEnded { _ in lastDab = nil }
    }

    private func addDab(at point: CGPoint) {
        guard let item, let layerID = store.activeBrushLayerID else { return }
        let binding = store.editsBinding(for: item.id)
        var edits = binding.wrappedValue
        var layers = edits.brushLayers
        guard let index = layers.firstIndex(where: { $0.id == layerID }) else { return }
        layers[index].strokes.append(BrushStroke(
            x: point.x, y: point.y, radius: brushRadius,
            softness: brushSoftness, erase: brushErasing ? true : nil,
            strength: brushStrength < 0.995 ? brushStrength : nil))
        edits.brushes = layers
        binding.wrappedValue = edits
    }

    private func mutateActiveLayer(_ mutate: (inout [BrushLayer]) -> Void) {
        guard let item else { return }
        let binding = store.editsBinding(for: item.id)
        var edits = binding.wrappedValue
        var layers = edits.brushLayers
        mutate(&layers)
        edits.brushes = layers.isEmpty ? nil : layers
        binding.wrappedValue = edits
    }

    /// The brush's footprint at the cursor: outer ring is the reach, inner
    /// ring where it's full strength. Orange while erasing.
    @ViewBuilder
    private func brushCursor(fit: CGRect) -> some View {
        if let hover = brushHover, fit.contains(hover) {
            let radius = brushRadius * fit.width
            let color: Color = brushErasing ? .orange : .white
            ZStack {
                Circle()
                    .strokeBorder(color.opacity(0.9), lineWidth: 1.5)
                    .frame(width: radius * 2, height: radius * 2)
                Circle()
                    .strokeBorder(color.opacity(0.45),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: radius * 2 * (1 - brushSoftness),
                           height: radius * 2 * (1 - brushSoftness))
            }
            .position(hover)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: - White balance eyedropper

    /// Sample a small patch under the click and set warmth/tint so it
    /// reads neutral — solved against the real filter. The sample comes
    /// from the CURRENT render, so the solve composes with whatever
    /// white balance is already dialed.
    /// Average sRGB (0…1) of a 5×5 patch under the click, in the displayed render.
    private func sampleColor(at location: CGPoint, fit: CGRect) -> (r: Double, g: Double, b: Double)? {
        guard let image, fit.width > 0 else { return nil }
        let nx = (location.x - fit.minX) / fit.width
        let ny = (location.y - fit.minY) / fit.height
        guard (0...1).contains(nx), (0...1).contains(ny),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let px = Int(nx * Double(cg.width)), py = Int(ny * Double(cg.height))
        let region = CGRect(x: max(0, px - 2), y: max(0, py - 2), width: 5, height: 5)
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let crop = cg.cropping(to: region) else { return nil }
        let w = crop.width, h = crop.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: data.count, by: 4) {
            r += Double(data[i]); g += Double(data[i + 1]); b += Double(data[i + 2])
        }
        let n = Double(w * h) * 255
        return (r / n, g / n, b / n)
    }

    /// The armed eyedropper takes the click: white balance (neutral or
    /// skin), or a black / grey / white point for Levels and Curves.
    private func performPick(_ kind: ColorPick, at location: CGPoint, fit: CGRect) {
        guard let item, let sample = sampleColor(at: location, fit: fit) else { return }
        let binding = store.editsBinding(for: item.id)
        let luminance = min(1, max(0, 0.2126 * sample.r + 0.7152 * sample.g + 0.0722 * sample.b))
        switch kind {
        case .neutral:
            pickWhiteBalance(sample: sample)
            return
        case .skinTone:
            // Make the sampled skin land on a healthy reference tone.
            let ref = (r: 0.86, g: 0.64, b: 0.55)
            pickWhiteBalance(sample: (sample.r / ref.r, sample.g / ref.g, sample.b / ref.b))
            return
        case .levelsBlack, .levelsWhite:
            var edits = binding.wrappedValue
            var levels = edits.levels ?? Levels()
            if kind == .levelsBlack {
                levels.rgb.blackSrc = min(luminance, levels.rgb.whiteSrc - 0.05)
            } else {
                levels.rgb.whiteSrc = max(luminance, levels.rgb.blackSrc + 0.05)
            }
            levels.rgb.shadowSrc = (levels.rgb.blackSrc + levels.rgb.midSrc) / 2
            levels.rgb.highlightSrc = (levels.rgb.midSrc + levels.rgb.whiteSrc) / 2
            edits.levels = levels
            binding.wrappedValue = edits
        case .curvesBlack, .curvesGray, .curvesWhite:
            var edits = binding.wrappedValue
            var curves = edits.curves ?? ToneCurves()
            let target: Double = kind == .curvesBlack ? 0 : (kind == .curvesWhite ? 1 : 0.5)
            let x = min(max(luminance, 0.01), 0.99)
            var points = curves.rgb.filter { abs($0.x - x) > 0.04 }
            points.append(CurvePoint(x: x, y: target))
            curves.rgb = points.sorted { $0.x < $1.x }
            edits.curves = curves
            binding.wrappedValue = edits
        }
        store.pickRequest = nil
    }

    private func pickWhiteBalance(sample: (r: Double, g: Double, b: Double)) {
        guard let item else { return }
        let delta = EditRenderer.neutralizeWhiteBalance(r: sample.r, g: sample.g, b: sample.b)
        let current = store.editsBinding(for: item.id).wrappedValue
        Self.setWhiteBalance(
            store: store, undoManager: undoManager, id: item.id,
            temperature: min(max(current.temperature + delta.temperature, -100), 100),
            tint: min(max(current.tint + delta.tint, -100), 100))
        store.pickRequest = nil
    }

    /// Apply a white balance and register its inverse — ⌘Z after a
    /// regretted eyedropper pick puts the old warmth/tint back (and ⌘⇧Z
    /// re-applies; the registration re-arms itself on every swap).
    private static func setWhiteBalance(store: LibraryStore, undoManager: UndoManager?,
                                        id: Int64, temperature: Double, tint: Double) {
        let binding = store.editsBinding(for: id)
        var edits = binding.wrappedValue
        let previous = (edits.temperature, edits.tint)
        edits.temperature = temperature
        edits.tint = tint
        binding.wrappedValue = edits
        undoManager?.registerUndo(withTarget: store) { target in
            setWhiteBalance(store: target, undoManager: undoManager, id: id,
                            temperature: previous.0, tint: previous.1)
        }
        undoManager?.setActionName("Neutral White Balance")
    }

    // MARK: - Retouch

    /// Ring markers over the healed spots while retouching.
    private func retouchMarkers(for item: PhotoItem, fit: CGRect) -> some View {
        ForEach(Array(item.edits.retouchSpots.enumerated()), id: \.element) { _, spot in
            let diameter = max(6, spot.radius * fit.width * 2)
            Circle()
                .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5)
                .frame(width: diameter, height: diameter)
                .offset(x: fit.minX + spot.x * fit.width - diameter / 2,
                        y: fit.minY + spot.y * fit.height - diameter / 2)
                .allowsHitTesting(false)
        }
    }

    /// The image's letterboxed rect inside the container (scaledToFit).
    private func fitRect(imageSize: NSSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func addSpot(at location: CGPoint, fit: CGRect) {
        guard let item, fit.width > 0 else { return }
        let nx = (location.x - fit.minX) / fit.width
        let ny = (location.y - fit.minY) / fit.height
        guard (0...1).contains(nx), (0...1).contains(ny) else { return }

        // ⌥-click in Clone mode sets the source instead of painting.
        if retouchClone, NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            cloneSource = CGPoint(x: nx, y: ny)
            return
        }
        var dx: Double
        var dy = 0.0
        if retouchClone, let source = cloneSource {
            dx = source.x - nx
            dy = source.y - ny
        } else {
            // Repair: clone from beside the spot — away from the nearer edge
            // so the source stays inside the frame.
            let offset = retouchRadius * 2.4
            dx = nx < 0.5 ? offset : -offset
            if nx + dx < retouchRadius || nx + dx > 1 - retouchRadius { dx = -dx }
        }

        let spot = RetouchSpot(x: nx, y: ny, radius: retouchRadius, dx: dx, dy: dy,
                               softness: abs(retouchSoftness - 0.45) < 0.01 ? nil : retouchSoftness,
                               opacity: retouchOpacity > 0.995 ? nil : retouchOpacity,
                               clone: retouchClone ? true : nil)
        let binding = store.editsBinding(for: item.id)
        var edits = binding.wrappedValue
        edits.retouches = edits.retouchSpots + [spot]
        binding.wrappedValue = edits
    }

    private func removeLastSpot() {
        guard let item else { return }
        let binding = store.editsBinding(for: item.id)
        var edits = binding.wrappedValue
        var spots = edits.retouchSpots
        guard !spots.isEmpty else { return }
        spots.removeLast()
        edits.retouches = spots.isEmpty ? nil : spots
        binding.wrappedValue = edits
    }

    private func clearSpots() {
        guard let item else { return }
        let binding = store.editsBinding(for: item.id)
        var edits = binding.wrappedValue
        edits.retouches = nil
        binding.wrappedValue = edits
    }

    // MARK: - Crop / straighten / rotate

    private var cropCustomRatio: Double { cropCustomW / max(cropCustomH, 0.01) }

    /// Aperture's Crop HUD: aspect (with Custom W:H), guides, the crop's
    /// pixel size, straighten, rotate, flip.
    private var cropControls: some View {
        HStack(spacing: 10) {
            Image(systemName: "crop")
                .foregroundColor(.accentColor)

            Picker("Aspect", selection: $cropAspect) {
                ForEach(CropAspect.allCases) { aspect in
                    Text(aspect.rawValue).tag(aspect)
                }
            }
            .frame(width: 160)
            .help("Constrain the crop to a ratio")
            .accessibilityLabel("Crop aspect ratio")
            .onChange(of: cropAspect) { _ in applyAspect() }
            if cropAspect == .custom {
                HStack(spacing: 3) {
                    TextField("W", value: $cropCustomW, format: .number)
                        .frame(width: 40)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Custom aspect width")
                    Text(":").foregroundColor(.secondary)
                    TextField("H", value: $cropCustomH, format: .number)
                        .frame(width: 40)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Custom aspect height")
                }
                .onChange(of: cropCustomW) { _ in applyAspect() }
                .onChange(of: cropCustomH) { _ in applyAspect() }
            }

            Toggle(isOn: $showCropGuides) {
                Image(systemName: "grid")
            }
            .toggleStyle(.button)
            .help("Show guides (thirds)")
            .accessibilityLabel("Show crop guides")

            if let px = cropPixelReadout {
                Text(px)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .help("The crop's size in pixels")
            }

            HStack(spacing: 6) {
                Text("Straighten")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Slider(value: straightenBinding, in: -15...15)
                    .frame(width: 110)
                    .help("Straighten — the frame scales to cover, no blank corners (or drag with the Straighten tool, G)")
                    .accessibilityLabel("Straighten")
                    .accessibilityValue(String(format: "%.1f degrees", item?.edits.straightenDegrees ?? 0))
                ScrubValue(value: item?.edits.straightenDegrees ?? 0, range: -15...15, perPoint: 0.05,
                           format: { signedReadout($0, decimals: 1, suffix: "°") }, defaultValue: 0,
                           onChange: { straightenBinding.wrappedValue = $0 })
            }

            HStack(spacing: 4) {
                Button { rotateQuarter(clockwise: false) } label: {
                    Image(systemName: "rotate.left")
                }
                .help("Rotate 90° counterclockwise (⌘[)")
                .accessibilityLabel("Rotate left")
                Button { rotateQuarter(clockwise: true) } label: {
                    Image(systemName: "rotate.right")
                }
                .help("Rotate 90° clockwise (⌘])")
                .accessibilityLabel("Rotate right")
                Button {
                    if let item { store.flip(horizontal: true, for: [item.id]) }
                } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Flip horizontal")
                .accessibilityLabel("Flip horizontal")
                Button {
                    if let item { store.flip(horizontal: false, for: [item.id]) }
                } label: {
                    Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
                .help("Flip vertical")
                .accessibilityLabel("Flip vertical")
            }

            Button("Reset") { resetGeometry() }
                .disabled(!(item?.edits.hasGeometry ?? false))
                .help("Clear crop, straighten, rotation and flips")

            Spacer()

            Button("Done") { cropMode = false }
                .keyboardShortcut(.defaultAction)
                .help("Keep the crop (Return)")
        }
    }

    /// "4512 × 3008 px" for the crop, from the file's real pixel size.
    private var cropPixelReadout: String? {
        guard let item, let px = imagePixelSize, px.width > 0 else { return nil }
        let rotated = item.edits.rotationQuarters % 2 == 1
        let w = rotated ? px.height : px.width
        let h = rotated ? px.width : px.height
        let c = (item.edits.crop ?? .full).clamped()
        return "\(Int((c.w * w).rounded())) × \(Int((c.h * h).rounded())) px"
    }

    // MARK: - Straighten tool (G)

    private var straightenControls: some View {
        HStack(spacing: 12) {
            Image(systemName: "level")
                .foregroundColor(.accentColor)
            Text("Drag on the photo to level it")
                .font(.callout)
                .foregroundColor(.secondary)
            Slider(value: straightenBinding, in: -15...15)
                .frame(width: 160)
                .accessibilityLabel("Straighten")
                .accessibilityValue(String(format: "%.1f degrees", item?.edits.straightenDegrees ?? 0))
            ScrubValue(value: item?.edits.straightenDegrees ?? 0, range: -15...15, perPoint: 0.05,
                       format: { signedReadout($0, decimals: 1, suffix: "°") }, defaultValue: 0,
                       onChange: { straightenBinding.wrappedValue = $0 })
            Button("Reset") { straightenBinding.wrappedValue = 0 }
                .disabled((item?.edits.straightenDegrees ?? 0) == 0)
            Spacer()
            Button("Done") { straightenMode = false }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Aperture's straighten grid: lines every eighth, a bolder centre.
    private func straightenGrid(fit: CGRect) -> some View {
        Path { p in
            for i in 1..<8 {
                let x = fit.minX + fit.width * CGFloat(i) / 8
                p.move(to: CGPoint(x: x, y: fit.minY)); p.addLine(to: CGPoint(x: x, y: fit.maxY))
                let y = fit.minY + fit.height * CGFloat(i) / 8
                p.move(to: CGPoint(x: fit.minX, y: y)); p.addLine(to: CGPoint(x: fit.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        .overlay(
            Path { p in
                p.move(to: CGPoint(x: fit.midX, y: fit.minY)); p.addLine(to: CGPoint(x: fit.midX, y: fit.maxY))
                p.move(to: CGPoint(x: fit.minX, y: fit.midY)); p.addLine(to: CGPoint(x: fit.maxX, y: fit.midY))
            }
            .stroke(Color.yellow.opacity(0.8), lineWidth: 1)
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Drag around the photo's centre: the angle swept is the angle added.
    private func straightenGesture(fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                let center = CGPoint(x: fit.midX, y: fit.midY)
                func angle(_ p: CGPoint) -> Double {
                    atan2(Double(p.y - center.y), Double(p.x - center.x)) * 180 / .pi
                }
                if straightenStart == nil {
                    straightenStart = (angle(value.startLocation), item?.edits.straightenDegrees ?? 0)
                }
                guard let start = straightenStart else { return }
                var delta = angle(value.location) - start.angle
                if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                straightenBinding.wrappedValue = min(15, max(-15, (start.value + delta * 10).rounded() / 10))
            }
            .onEnded { _ in straightenStart = nil }
    }

    private var straightenBinding: Binding<Double> {
        Binding(
            get: { item?.edits.straightenDegrees ?? 0 },
            set: { value in
                guard let item else { return }
                let binding = store.editsBinding(for: item.id)
                var edits = binding.wrappedValue
                edits.straighten = value == 0 ? nil : value
                binding.wrappedValue = edits
            }
        )
    }

    /// The committed crop, in view space for the current fit rect.
    private func cropViewRect(for item: PhotoItem, fit: CGRect) -> CGRect {
        let c = (item.edits.crop ?? .full).clamped()
        return CGRect(x: fit.minX + c.x * fit.width,
                      y: fit.minY + c.y * fit.height,
                      width: c.w * fit.width,
                      height: c.h * fit.height)
    }

    private func commitCrop(_ viewRect: CGRect, fit: CGRect) {
        guard let item, fit.width > 0, fit.height > 0 else { return }
        let c = CropRect(x: (viewRect.minX - fit.minX) / fit.width,
                         y: (viewRect.minY - fit.minY) / fit.height,
                         w: viewRect.width / fit.width,
                         h: viewRect.height / fit.height).clamped()
        let binding = store.editsBinding(for: item.id)
        var edits = binding.wrappedValue
        // A full-frame crop is no crop at all — store nil, stay neutral.
        edits.crop = c == .full ? nil : c
        binding.wrappedValue = edits
    }

    /// Dim outside the crop, thirds grid inside, handles on the frame.
    private func cropOverlay(for item: PhotoItem, fit: CGRect) -> some View {
        let rect = cropDragRect ?? cropViewRect(for: item, fit: fit)
        return ZStack(alignment: .topLeading) {
            // Even-odd fill: everything but the crop, dimmed.
            Path { p in
                p.addRect(fit)
                p.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

            // Thirds grid — visible while framing, like every cutting mat.
            if showCropGuides {
                Path { p in
                    for i in 1...2 {
                        let x = rect.minX + rect.width * Double(i) / 3
                        p.move(to: CGPoint(x: x, y: rect.minY))
                        p.addLine(to: CGPoint(x: x, y: rect.maxY))
                        let y = rect.minY + rect.height * Double(i) / 3
                        p.move(to: CGPoint(x: rect.minX, y: y))
                        p.addLine(to: CGPoint(x: rect.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
            }

            Rectangle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)

            // Corner handles.
            ForEach(CropCorner.allCases, id: \.self) { corner in
                let point = corner.point(in: rect)
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .shadow(radius: 1.5)
                    .offset(x: point.x - 5, y: point.y - 5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Crop frame")
        .accessibilityValue(cropAccessibilityValue(rect: rect, fit: fit))
    }

    private func cropAccessibilityValue(rect: CGRect, fit: CGRect) -> String {
        guard fit.width > 0, fit.height > 0 else { return "" }
        let w = Int((rect.width / fit.width * 100).rounded())
        let h = Int((rect.height / fit.height * 100).rounded())
        return "\(w) percent wide, \(h) percent tall"
    }

    /// One drag gesture, dispatched by where it started: on a corner handle
    /// (resize), inside the crop (move), or outside it (draw a new crop).
    private func cropGesture(fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                guard let item else { return }
                if cropDragKind == nil {
                    // Classify once, at drag start, against the committed
                    // rect — and carry that rect in the kind so anchors and
                    // offsets never compound as the drag mutates the preview.
                    cropDragKind = CropDragKind.begin(
                        at: value.startLocation,
                        rect: cropViewRect(for: item, fit: fit))
                }
                guard let kind = cropDragKind else { return }
                let ratio = cropAspect.ratio(imageSize: image?.size, custom: cropCustomRatio)

                switch kind {
                case .move(let origin):
                    var r = origin
                    r.origin.x = min(max(fit.minX, origin.minX + value.translation.width), fit.maxX - origin.width)
                    r.origin.y = min(max(fit.minY, origin.minY + value.translation.height), fit.maxY - origin.height)
                    cropDragRect = r
                case .corner(let corner, let origin):
                    cropDragRect = Self.resize(origin, corner: corner,
                                               to: value.location, within: fit,
                                               ratio: ratio, minSide: 40)
                case .draw:
                    let anchor = value.startLocation
                    let corner: CropCorner = value.location.x >= anchor.x
                        ? (value.location.y >= anchor.y ? .bottomRight : .topRight)
                        : (value.location.y >= anchor.y ? .bottomLeft : .topLeft)
                    let seed = CGRect(x: anchor.x, y: anchor.y, width: 0, height: 0)
                    cropDragRect = Self.resize(seed, corner: corner,
                                               to: value.location, within: fit,
                                               ratio: ratio, minSide: 12)
                }
            }
            .onEnded { _ in
                if let rect = cropDragRect { commitCrop(rect, fit: fit) }
                cropDragRect = nil
                cropDragKind = nil
            }
    }

    /// Resize `rect` by dragging `corner` to `point`, anchored on the
    /// opposite corner, clamped to `bounds`, optionally ratio-locked.
    private static func resize(_ rect: CGRect, corner: CropCorner, to point: CGPoint,
                               within bounds: CGRect, ratio: Double?, minSide: Double) -> CGRect {
        let anchor = corner.opposite.point(in: rect)
        let p = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                        y: min(max(point.y, bounds.minY), bounds.maxY))
        var w = abs(p.x - anchor.x)
        var h = abs(p.y - anchor.y)
        if let ratio {
            // The dominant axis wins; the other follows the lock.
            if w / ratio >= h { h = w / ratio } else { w = h * ratio }
        }
        w = max(w, minSide)
        h = max(h, ratio.map { minSide / min($0, 1) } ?? minSide)
        // Grow toward the pointer, but never past the image bounds.
        let signX: Double = p.x >= anchor.x ? 1 : -1
        let signY: Double = p.y >= anchor.y ? 1 : -1
        let maxW = signX > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let maxH = signY > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        if let ratio {
            let scale = min(1, maxW / w, maxH / h)
            w *= scale
            h = w / ratio
        } else {
            w = min(w, maxW)
            h = min(h, maxH)
        }
        return CGRect(x: signX > 0 ? anchor.x : anchor.x - w,
                      y: signY > 0 ? anchor.y : anchor.y - h,
                      width: w, height: h)
    }

    /// Snap the existing crop to the chosen ratio, preserving its center.
    private func applyAspect() {
        guard let item, let image, cropAspect != .freeform,
              let ratio = cropAspect.ratio(imageSize: image.size, custom: cropCustomRatio) else { return }
        let c = (item.edits.crop ?? .full).clamped()
        // Work in pixel space — normalized units aren't square.
        let W = image.size.width, H = image.size.height
        var w = c.w * W
        var h = c.h * H
        if w / h > ratio { w = h * ratio } else { h = w / ratio }
        let cx = (c.x + c.w / 2) * W
        let cy = (c.y + c.h / 2) * H
        let rect = CropRect(x: (cx - w / 2) / W, y: (cy - h / 2) / H,
                            w: w / W, h: h / H).clamped()
        let binding = store.editsBinding(for: item.id)
        var edits = binding.wrappedValue
        edits.crop = rect == .full ? nil : rect
        binding.wrappedValue = edits
    }

    /// Quarter-turn the image — and carry the crop along with the pixels.
    private func rotateQuarter(clockwise: Bool) {
        guard let item else { return }
        let binding = store.editsBinding(for: item.id)
        var edits = binding.wrappedValue
        edits.rotation = (edits.rotationQuarters + (clockwise ? 1 : 3)) % 4
        if edits.rotation == 0 { edits.rotation = nil }
        if let c = edits.crop {
            edits.crop = clockwise
                ? CropRect(x: 1 - c.y - c.h, y: c.x, w: c.h, h: c.w)
                : CropRect(x: c.y, y: 1 - c.x - c.w, w: c.h, h: c.w)
        }
        binding.wrappedValue = edits
    }

    private func resetGeometry() {
        guard let item else { return }
        let binding = store.editsBinding(for: item.id)
        var edits = binding.wrappedValue
        edits.rotation = nil
        edits.straighten = nil
        edits.crop = nil
        edits.flipHorizontal = nil
        edits.flipVertical = nil
        binding.wrappedValue = edits
        cropAspect = .freeform
    }

    // MARK: - Image Playground

    private var playgroundAvailable: Bool {
        #if canImport(ImagePlayground)
        if #available(macOS 15.1, *) {
            return item != nil && item?.isVideo != true && ImagePlaygroundViewController.isAvailable
        }
        #endif
        return false
    }

    /// The generated image lands beside the original and joins the library.
    private func handlePlaygroundResult(_ url: URL) {
        guard let item else { return }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let base = item.url.deletingPathExtension().lastPathComponent + " Playground"
        let directory = item.url.deletingLastPathComponent()
        var dest = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            counter += 1
            dest = directory.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
        }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            Task { await store.importAndReveal(dest, keyword: LibraryStore.playgroundKeyword) }
        } catch {
            store.alertMessage = "Couldn't save the Playground image: \(error.localizedDescription)"
        }
    }

    private func stepButton(systemImage: String, delta: Int) -> some View {
        Button {
            store.viewerStep(delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .padding(10)
        }
        .buttonStyle(.plain)
        .foregroundColor(.white.opacity(0.7))
        .padding(6)
        .accessibilityLabel(delta < 0 ? "Previous photo" : "Next photo")
    }

    /// Invisible buttons that give the viewer its keyboard: Esc, ← →, Space.
    private var hiddenShortcuts: some View {
        Group {
            Button("") {
                if retouchMode {
                    retouchMode = false
                    cloneSource = nil
                } else if redEyeMode {
                    redEyeMode = false
                } else if cropMode {
                    cropMode = false
                } else if straightenMode {
                    straightenMode = false
                } else if brushMode {
                    exitBrushMode()
                } else if wbPicking {
                    store.pickRequest = nil
                } else if compareMode {
                    compareMode = false
                } else if loupeMode {
                    loupeMode = false
                    loupeHover = nil
                } else if isZoomed {
                    viewerZoom = nil
                } else if store.isFullScreenMode {
                    store.exitFullScreenMode(window: NSApp.keyWindow ?? NSApp.mainWindow)
                } else {
                    store.exitViewer()
                }
            }
            .keyboardShortcut(.cancelAction)
            Button("") {
                guard item?.isVideo != true else { return }
                loupeMode.toggle()
                if !loupeMode { loupeHover = nil }
            }
            .keyboardShortcut("`", modifiers: [])   // Aperture's key
            Button("") {
                guard item?.isVideo != true else { return }
                loupeMode.toggle()
                if !loupeMode { loupeHover = nil }
            }
            .keyboardShortcut("l", modifiers: [])
            Button("") { toggleZoom() }
                .keyboardShortcut("z", modifiers: [])
            // Aperture's tool keys.
            Button("") {
                guard item?.isVideo != true else { return }
                cropMode.toggle()
                if cropMode { straightenMode = false; retouchMode = false; loupeMode = false; compareMode = false }
            }
            .keyboardShortcut("c", modifiers: [])
            Button("") {
                guard item?.isVideo != true else { return }
                straightenMode.toggle()
                if straightenMode { cropMode = false; retouchMode = false; loupeMode = false; compareMode = false }
            }
            .keyboardShortcut("g", modifiers: [])
            Button("") {
                guard item?.isVideo != true else { return }
                retouchMode.toggle()
                if retouchMode { cropMode = false; straightenMode = false; loupeMode = false; compareMode = false }
            }
            .keyboardShortcut("x", modifiers: [])
            Button("") {
                guard item?.isVideo != true else { return }
                redEyeMode.toggle()
                if redEyeMode { cropMode = false; straightenMode = false; retouchMode = false; loupeMode = false; compareMode = false }
            }
            .keyboardShortcut("e", modifiers: [])
            Button("") { store.showHotCold.toggle() }
                .keyboardShortcut("h", modifiers: [.option, .shift])
            Button("") { store.primaryOnly.toggle() }
                .keyboardShortcut("u", modifiers: .option)
            Button("") { stepZoom(1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("") { stepZoom(-1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { if loupeMode { stepLoupeZoom(1) } }
                .keyboardShortcut("=", modifiers: [.command, .shift])
            Button("") { if loupeMode { stepLoupeZoom(-1) } }
                .keyboardShortcut("-", modifiers: [.command, .shift])
            Button("") {
                guard item?.isVideo != true else { return }
                showMaster.toggle()
            }
            .keyboardShortcut("m", modifiers: [])
            Button("") {
                if compareMode { compareMode = false } else { enterCompareMode() }
            }
            .keyboardShortcut("m", modifiers: .option)
            Button("") { store.viewerStep(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { store.viewerStep(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("") {
                guard let player else { return }
                player.timeControlStatus == .playing ? player.pause() : player.play()
            }
            .keyboardShortcut(.space, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}

/// Plays an animated GIF. SwiftUI's `Image` only ever shows frame 0, but
/// AppKit's NSImageView animates a multi-frame GIF for free once `animates`
/// is on — so the viewer wraps one to make GIFs move.
private struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.animates = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        context.coordinator.load(url, into: view)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.load(url, into: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var url: URL?

        /// Decode off the main thread — a big GIF's frames shouldn't hitch the
        /// UI — then hand the whole animating image back on main.
        func load(_ url: URL, into view: NSImageView) {
            self.url = url
            DispatchQueue.global(qos: .userInitiated).async {
                let image = NSImage(contentsOf: url)
                DispatchQueue.main.async {
                    // A fast photo-step could have moved on already.
                    guard self.url == url else { return }
                    view.image = image
                    view.animates = true
                }
            }
        }
    }
}

// MARK: - Crop support types

private enum CropAspect: String, CaseIterable, Identifiable {
    case freeform = "Freeform"
    case master = "Master Aspect Ratio"
    case square = "Square"
    case r2x3 = "2 : 3"
    case r3x2 = "3 : 2"
    case r3x4 = "3 : 4"
    case r4x3 = "4 : 3"
    case r4x5 = "4 : 5"
    case r5x4 = "5 : 4"
    case r9x16 = "9 : 16"
    case r16x9 = "16 : 9"
    case custom = "Custom…"

    var id: String { rawValue }

    /// Width/height, in pixel space. `imageSize` feeds "Master".
    func ratio(imageSize: NSSize?, custom: Double) -> Double? {
        switch self {
        case .freeform: return nil
        case .master:
            guard let s = imageSize, s.height > 0 else { return nil }
            return s.width / s.height
        case .square: return 1
        case .r2x3: return 2.0 / 3.0
        case .r3x2: return 3.0 / 2.0
        case .r3x4: return 3.0 / 4.0
        case .r4x3: return 4.0 / 3.0
        case .r4x5: return 4.0 / 5.0
        case .r5x4: return 5.0 / 4.0
        case .r9x16: return 9.0 / 16.0
        case .r16x9: return 16.0 / 9.0
        case .custom: return custom > 0 ? custom : nil
        }
    }
}

private enum CropCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var opposite: CropCorner {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}

/// What a crop drag is doing, decided where it started. Each case carries the
/// rect as it stood at drag start so nothing compounds tick to tick.
private enum CropDragKind {
    case move(origin: CGRect)
    case corner(CropCorner, origin: CGRect)
    case draw

    static func begin(at point: CGPoint, rect: CGRect) -> CropDragKind {
        let grab: Double = 14
        for corner in CropCorner.allCases {
            let p = corner.point(in: rect)
            if abs(p.x - point.x) <= grab && abs(p.y - point.y) <= grab {
                return .corner(corner, origin: rect)
            }
        }
        if rect.insetBy(dx: 4, dy: 4).contains(point) {
            return .move(origin: rect)
        }
        return .draw
    }
}

/// Round-trip into Apple's Image Playground where the OS supports it;
/// otherwise this modifier is inert. Passes the rendered image (adjustments
/// baked in) — handing a file URL made Playground fall back to its blank
/// concept picker instead of loading the photo.
private struct PlaygroundSheet: ViewModifier {
    @Binding var isPresented: Bool
    let sourceImage: NSImage?
    let onResult: (URL) -> Void

    func body(content: Content) -> some View {
        #if canImport(ImagePlayground)
        if #available(macOS 15.1, *), let sourceImage {
            content.imagePlaygroundSheet(
                isPresented: $isPresented,
                concepts: [],
                sourceImage: Image(nsImage: sourceImage)
            ) { result in
                onResult(result)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
