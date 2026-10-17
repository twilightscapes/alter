import AppKit
import SwiftUI

/// The Retouch tool's state, shared by the overlay on the photo and the
/// controls in the tray. Pick it up (X) and the cursor becomes the brush:
/// click to heal a spot, drag to heal along a line. Every spot stays
/// editable — select it, drag it, drag its edge to resize, drag its source,
/// delete it.
@MainActor
final class RetouchTool: ObservableObject {
    /// The brush, as a fraction of the image width.
    @Published var radius = 0.02
    @Published var softness = 0.45
    @Published var opacity = 1.0
    enum Mode: Hashable { case repair, remove, clone }
    /// Repair heals from a matching patch; Remove rebuilds the spot from
    /// its surroundings (for things across an edge); Clone copies straight
    /// from a source you ⌥-click.
    @Published var mode = Mode.repair
    var clone: Bool { mode == .clone }
    /// Clone mode's source (normalized), set with ⌥-click.
    @Published var cloneSource: CGPoint?
    /// Index into the recipe's spots.
    @Published var selection: Int?
    /// H: see the result without any marks.
    @Published var hideMarks = false

    /// The photo the spots heal from — decoded without its recipe — and
    /// search canvases built from it, keyed by the spots before them.
    private var base: CGImage?
    private var baseKey = ""
    private var canvases: [String: HealSourceFinder.Canvas] = [:]

    func reset() {
        selection = nil
        cloneSource = nil
        hideMarks = false
        canvases = [:]
    }

    func loadBase(url: URL, edits: PhotoEdits) async {
        let key = "\(url.path)#\(edits.appliesFileOrientation)"
        guard key != baseKey else { return }
        let upright = edits.appliesFileOrientation
        let decoded = await Task.detached(priority: .userInitiated) {
            ImageLoader.shared.decodedBase(for: url, appliesOrientation: upright, maxPixel: 1600)
        }.value
        base = decoded
        baseKey = key
        canvases = [:]
    }

    /// Where a spot at `index` should borrow from: the best match on the
    /// image as it stands under it (geometry and the spots before it).
    func findSource(for spot: RetouchSpot, at index: Int, in edits: PhotoEdits,
                    avoiding: (Double, Double)? = nil) -> (dx: Double, dy: Double)? {
        guard let base else { return nil }
        var key = "\(index)#\(edits.rotationQuarters)#\(edits.straightenDegrees)#\(String(describing: edits.crop))"
        for s in edits.retouchSpots.prefix(index) { key += "|\(s.hashValue)" }
        let canvas: HealSourceFinder.Canvas
        if let cached = canvases[key] {
            canvas = cached
        } else {
            guard let stage = EditRenderer.retouchStage(edits, spots: index, to: base),
                  let built = HealSourceFinder.Canvas(stage) else { return nil }
            if canvases.count > 12 { canvases = [:] }
            canvases[key] = built
            canvas = built
        }
        return HealSourceFinder.search(for: spot, in: canvas, avoiding: avoiding).map { ($0.dx, $0.dy) }
    }

    // MARK: Recipe edits (undoable)

    func spots(_ edits: Binding<PhotoEdits>) -> [RetouchSpot] { edits.wrappedValue.retouchSpots }

    /// Write without an undo step — the live frames of a drag.
    func setLive(_ spots: [RetouchSpot], _ edits: Binding<PhotoEdits>) {
        var e = edits.wrappedValue
        e.retouches = spots.isEmpty ? nil : spots
        edits.wrappedValue = e
    }

    /// Write as one undoable step.
    func commit(_ spots: [RetouchSpot], previous: [RetouchSpot], name: String,
                _ edits: Binding<PhotoEdits>, undo: UndoManager?) {
        setLive(spots, edits)
        if let selection, selection >= spots.count { self.selection = spots.isEmpty ? nil : spots.count - 1 }
        guard spots != previous, let undo else { return }
        undo.registerUndo(withTarget: self) { tool in
            tool.commit(previous, previous: spots, name: name, edits, undo: undo)
        }
        undo.setActionName(name)
    }

    func deleteSelected(_ edits: Binding<PhotoEdits>, undo: UndoManager?) {
        let before = spots(edits)
        guard let index = selection, before.indices.contains(index) else { return }
        var after = before
        after.remove(at: index)
        selection = nil
        commit(after, previous: before, name: "Delete Retouch Spot", edits, undo: undo)
    }

    func clearAll(_ edits: Binding<PhotoEdits>, undo: UndoManager?) {
        let before = spots(edits)
        selection = nil
        commit([], previous: before, name: "Clear Retouch", edits, undo: undo)
    }

    /// "/" — try another: Repair borrows from the next-best source,
    /// Remove rebuilds a different way.
    func newSource(_ edits: Binding<PhotoEdits>, undo: UndoManager?) {
        let before = spots(edits)
        guard let index = selection, before.indices.contains(index) else { return }
        var after = before
        if before[index].isFill {
            after[index].variant = (before[index].variant ?? 0) + 1
        } else {
            guard let found = findSource(for: before[index], at: index, in: edits.wrappedValue,
                                         avoiding: (before[index].dx, before[index].dy)) else { return }
            after[index].dx = found.dx
            after[index].dy = found.dy
        }
        commit(after, previous: before, name: "Try Another Retouch", edits, undo: undo)
    }

    /// Retype the selected spot (the tray's mode picker).
    func setMode(_ mode: Mode, _ edits: Binding<PhotoEdits>, undo: UndoManager?) {
        self.mode = mode
        let before = spots(edits)
        guard let index = selection, before.indices.contains(index) else { return }
        var spot = before[index]
        spot.clone = mode == .clone ? true : nil
        spot.fill = mode == .remove ? true : nil
        if mode != .remove, abs(spot.dx) < 1e-6, abs(spot.dy) < 1e-6,
           let found = findSource(for: spot, at: index, in: edits.wrappedValue) {
            spot.dx = found.dx
            spot.dy = found.dy
        }
        var after = before
        after[index] = spot
        commit(after, previous: before, name: mode == .clone ? "Clone" : mode == .remove ? "Remove" : "Repair",
               edits, undo: undo)
    }

    /// The tray's sliders edit the selected spot when there is one, the
    /// brush otherwise.
    func binding(_ key: WritableKeyPath<RetouchTool, Double>, spotValue: @escaping (RetouchSpot) -> Double,
                 set: @escaping (inout RetouchSpot, Double) -> Void,
                 _ edits: Binding<PhotoEdits>) -> Binding<Double> {
        Binding(
            get: { [unowned self] in
                if let i = self.selection, let spot = edits.wrappedValue.retouchSpots[safe: i] { return spotValue(spot) }
                return self[keyPath: key]
            },
            set: { [unowned self] value in
                var tool = self
                tool[keyPath: key] = value
                guard let i = self.selection else { return }
                var spots = edits.wrappedValue.retouchSpots
                guard spots.indices.contains(i) else { return }
                set(&spots[i], value)
                self.setLive(spots, edits)
            })
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - On the photo

/// Marks, brush cursor and every mouse interaction of the Retouch tool,
/// laid over the photo's displayed rect (`fit`, view points).
struct RetouchOverlay: View {
    @ObservedObject var tool: RetouchTool
    let fit: CGRect
    let edits: Binding<PhotoEdits>
    let undo: UndoManager?

    private enum Drag { case paint, move, resize, source }
    @State private var drag: Drag?
    @State private var dragStart: CGPoint = .zero
    @State private var startSpots: [RetouchSpot] = []
    @State private var stroke: [CGPoint] = []
    @State private var keyMonitor: Any?
    /// Pointer over the photo (view points), nil when it's elsewhere. Kept
    /// here, not on the tool, so a mouse move redraws only the marks.
    @State private var hover: CGPoint?

    private var spots: [RetouchSpot] { edits.wrappedValue.retouchSpots }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                draw(in: &context)
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged(dragChanged)
            .onEnded(dragEnded))
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                hover = fit.contains(point) ? point : nil
                cursor(at: point).set()
            case .ended:
                hover = nil
                NSCursor.arrow.set()
            }
        }
        .onAppear(perform: installKeys)
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            KeyCommands.bracketsClaimed = false
            NSCursor.arrow.set()
        }
        .accessibilityElement()
        .accessibilityLabel("Retouch. \(spots.count) spot\(spots.count == 1 ? "" : "s"). Click to heal, drag to heal along a line.")
    }

    // MARK: Geometry

    private func viewPoint(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: fit.minX + x * fit.width, y: fit.minY + y * fit.height)
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - fit.minX) / max(fit.width, 1), y: (p.y - fit.minY) / max(fit.height, 1))
    }

    private func viewRadius(_ r: Double) -> CGFloat { max(3, r * fit.width) }

    /// The spot's centre line (target, or its source shifted by dx/dy):
    /// one point for a click, the path for a stroke.
    private func centreLine(_ spot: RetouchSpot, source: Bool = false) -> [CGPoint] {
        spot.dabs.map { viewPoint($0.x + (source ? spot.dx : 0), $0.y + (source ? spot.dy : 0)) }
    }

    /// Outline a round-capped stroke of radius `r` along `points` — one
    /// clean shape, no seams where the dabs overlap: paint it fat, then cut
    /// the inside back out.
    private func outline(_ points: [CGPoint], r: CGFloat, color: Color, width: CGFloat,
                         dash: [CGFloat] = [], in context: inout GraphicsContext) {
        guard !points.isEmpty else { return }
        if points.count == 1 || !dash.isEmpty {
            // A circle (or a dashed source, where seams don't show) strokes directly.
            let path: Path
            if points.count == 1 {
                path = Path(ellipseIn: CGRect(x: points[0].x - r, y: points[0].y - r, width: 2 * r, height: 2 * r))
            } else {
                var line = Path()
                line.addLines(points)
                path = line.strokedPath(StrokeStyle(lineWidth: 2 * r, lineCap: .round, lineJoin: .round))
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, dash: dash))
            return
        }
        var line = Path()
        line.addLines(points)
        context.drawLayer { layer in
            layer.stroke(line, with: .color(color),
                         style: StrokeStyle(lineWidth: 2 * r + width, lineCap: .round, lineJoin: .round))
            layer.blendMode = .destinationOut
            layer.stroke(line, with: .color(.black),
                         style: StrokeStyle(lineWidth: max(1, 2 * r - width), lineCap: .round, lineJoin: .round))
        }
    }

    /// Distance from `p` to the spot's nearest dab, in view points.
    private func distance(_ p: CGPoint, to spot: RetouchSpot, source: Bool = false) -> CGFloat {
        spot.dabs.map { hypot(p.x - viewPoint($0.x + (source ? spot.dx : 0), $0.y + (source ? spot.dy : 0)).x,
                              p.y - viewPoint($0.x + (source ? spot.dx : 0), $0.y + (source ? spot.dy : 0)).y) }
            .min() ?? .greatestFiniteMagnitude
    }

    /// A selection-shaped Remove's bounds in view points.
    private func boxRect(_ spot: RetouchSpot) -> CGRect? {
        guard let box = spot.maskBox else { return nil }
        return CGRect(x: fit.minX + box.x * fit.width, y: fit.minY + box.y * fit.height,
                      width: box.w * fit.width, height: box.h * fit.height)
    }

    private func hit(_ p: CGPoint) -> (Drag, Int)? {
        // Selection-shaped Removes (from the Select tool) select by their
        // bounds; they can be deleted or retried, not reshaped here.
        for (i, spot) in spots.enumerated().reversed() {
            if let rect = boxRect(spot), rect.contains(p) { return (.move, i) }
        }
        if let i = tool.selection, let spot = spots[safe: i], spot.maskBox == nil {
            let r = viewRadius(spot.radius)
            let d = distance(p, to: spot)
            if abs(d - r) < 6 { return (.resize, i) }
            if !spot.isFill, distance(p, to: spot, source: true) < r { return (.source, i) }
        }
        for (i, spot) in spots.enumerated().reversed()
        where spot.maskBox == nil && distance(p, to: spot) < viewRadius(spot.radius) {
            return (.move, i)
        }
        return nil
    }

    private func cursor(at p: CGPoint) -> NSCursor {
        guard fit.contains(p) else { return .arrow }
        switch hit(p)?.0 {
        case .resize: return .resizeLeftRight
        case .move, .source: return .openHand
        default: return .crosshair
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext) {
        let shadow = Color.black.opacity(0.55)
        if !tool.hideMarks {
            for (i, spot) in spots.enumerated() {
                let target = centreLine(spot)
                let r = viewRadius(spot.radius)
                if let rect = boxRect(spot) {
                    guard i == tool.selection || hover != nil || drag != nil else { continue }
                    let path = Path(roundedRect: rect, cornerRadius: 4)
                    let selected = i == tool.selection
                    context.stroke(path, with: .color(shadow), style: StrokeStyle(lineWidth: selected ? 3.5 : 2, dash: [5, 4]))
                    context.stroke(path, with: .color(.white.opacity(selected ? 1 : 0.55)),
                                   style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: [5, 4]))
                    continue
                }
                if i == tool.selection, spot.isFill {
                    outline(target, r: r, color: shadow, width: 3.5, in: &context)
                    outline(target, r: r, color: .white, width: 2, in: &context)
                } else if i == tool.selection {
                    let source = centreLine(spot, source: true)
                    // Joined by a line from the source to the spot.
                    var link = Path()
                    let a = viewPoint(spot.x + spot.dx, spot.y + spot.dy), b = viewPoint(spot.x, spot.y)
                    let len = max(hypot(b.x - a.x, b.y - a.y), 1)
                    if len > 2 * r {
                        let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
                        link.move(to: CGPoint(x: a.x + ux * r, y: a.y + uy * r))
                        link.addLine(to: CGPoint(x: b.x - ux * r, y: b.y - uy * r))
                    }
                    // The source: thinner and dimmer than the spot it feeds.
                    outline(source, r: r, color: shadow.opacity(0.7), width: 2.5, in: &context)
                    outline(source, r: r, color: .white.opacity(0.75), width: 1, in: &context)
                    context.stroke(link, with: .color(shadow), style: StrokeStyle(lineWidth: 3, dash: [2, 3]))
                    context.stroke(link, with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                    outline(target, r: r, color: shadow, width: 3.5, in: &context)
                    outline(target, r: r, color: .white, width: 2, in: &context)
                } else if hover != nil || drag != nil {
                    // The others stay quiet: a faint ring while the pointer
                    // is over the photo, nothing when it leaves.
                    outline(target, r: r, color: shadow.opacity(0.5), width: 2, in: &context)
                    outline(target, r: r, color: .white.opacity(0.55), width: 1, in: &context)
                }
            }
            if tool.clone, let source = tool.cloneSource {
                let p = viewPoint(source.x, source.y)
                var cross = Path()
                cross.move(to: CGPoint(x: p.x - 6, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 6, y: p.y))
                cross.move(to: CGPoint(x: p.x, y: p.y - 6)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 6))
                context.stroke(cross, with: .color(shadow), lineWidth: 3)
                context.stroke(cross, with: .color(.green), lineWidth: 1.5)
            }
        }
        // The stroke being painted.
        if drag == .paint, stroke.count > 1 {
            var line = Path()
            line.addLines(stroke)
            let painted = line.strokedPath(StrokeStyle(lineWidth: 2 * viewRadius(tool.radius), lineCap: .round, lineJoin: .round))
            context.fill(painted, with: .color(.white.opacity(0.18)))
            context.stroke(painted, with: .color(.white.opacity(0.8)), lineWidth: 1)
        }
        // The brush itself, where the pointer is, unless it's over a spot
        // (then the cursor says move or resize).
        if let p = hover, drag == nil, hit(p) == nil {
            let r = viewRadius(tool.radius)
            let ring = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            context.stroke(ring, with: .color(shadow), lineWidth: 3)
            context.stroke(ring, with: .color(tool.clone ? .green : .white), lineWidth: 1.5)
        }
    }

    // MARK: Mouse

    private func dragChanged(_ value: DragGesture.Value) {
        if drag == nil {
            dragStart = value.startLocation
            startSpots = spots
            if tool.clone, NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                guard fit.contains(value.startLocation) else { return }
                tool.cloneSource = normalized(value.startLocation)
                drag = .source // swallow the rest of this click
                startSpots = []
                return
            }
            if let (kind, index) = hit(value.startLocation) {
                tool.selection = index
                drag = kind
                (kind == .move || kind == .source ? NSCursor.closedHand : NSCursor.resizeLeftRight).set()
            } else {
                guard fit.contains(value.startLocation) else { return }
                tool.selection = nil
                drag = .paint
                stroke = [value.startLocation]
            }
        }
        let delta = normalized(value.location)
        let origin = normalized(dragStart)
        let dx = delta.x - origin.x, dy = delta.y - origin.y
        switch drag {
        case .paint:
            let spacing = max(4, viewRadius(tool.radius) * 0.4)
            if let last = stroke.last, hypot(value.location.x - last.x, value.location.y - last.y) >= spacing {
                stroke.append(clamped(value.location))
            }
        case .move:
            guard let i = tool.selection, startSpots.indices.contains(i), startSpots[i].maskBox == nil else { return }
            var updated = startSpots
            // The target moves; its source stays where it was.
            updated[i] = startSpots[i].moved(by: dx, dy)
            updated[i].dx = startSpots[i].dx - dx
            updated[i].dy = startSpots[i].dy - dy
            tool.setLive(updated, edits)
        case .source:
            guard let i = tool.selection, startSpots.indices.contains(i) else { return }
            var updated = startSpots
            updated[i].dx = startSpots[i].dx + dx
            updated[i].dy = startSpots[i].dy + dy
            tool.setLive(updated, edits)
        case .resize:
            guard let i = tool.selection, startSpots.indices.contains(i) else { return }
            var updated = startSpots
            let d = distance(value.location, to: startSpots[i])
            updated[i].radius = min(0.2, max(0.002, d / max(fit.width, 1)))
            tool.setLive(updated, edits)
        case nil:
            break
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        defer {
            drag = nil
            stroke = []
            if let hover = hover { cursor(at: hover).set() }
        }
        switch drag {
        case .paint:
            addSpot(along: stroke.count > 1 ? stroke : [clamped(value.startLocation)])
        case .move:
            tool.commit(spots, previous: startSpots, name: "Move Retouch Spot", edits, undo: undo)
        case .source:
            guard !startSpots.isEmpty else { return }
            tool.commit(spots, previous: startSpots, name: "Move Retouch Source", edits, undo: undo)
        case .resize:
            tool.commit(spots, previous: startSpots, name: "Resize Retouch Spot", edits, undo: undo)
        case nil:
            break
        }
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, fit.minX), fit.maxX), y: min(max(p.y, fit.minY), fit.maxY))
    }

    private func addSpot(along points: [CGPoint]) {
        let path = points.map(normalized)
        guard let first = path.first else { return }
        var spot = RetouchSpot(
            x: first.x, y: first.y, radius: tool.radius, dx: 0, dy: 0,
            softness: abs(tool.softness - 0.45) < 0.01 ? nil : tool.softness,
            opacity: tool.opacity > 0.995 ? nil : tool.opacity,
            clone: tool.clone ? true : nil,
            fill: tool.mode == .remove ? true : nil)
        if path.count > 1 { spot.trail = path.dropFirst().map { RetouchPoint(x: $0.x, y: $0.y) } }
        let before = spots
        if tool.mode == .remove {
            // Rebuilt from its surroundings — no source.
        } else if tool.clone, let source = tool.cloneSource {
            spot.dx = source.x - first.x
            spot.dy = source.y - first.y
        } else if let found = tool.findSource(for: spot, at: before.count, in: edits.wrappedValue) {
            spot.dx = found.dx
            spot.dy = found.dy
        } else {
            // No clean source anywhere (a tiny or edge-filling photo):
            // fall back to beside the spot, away from the nearer edge.
            spot.dx = first.x < 0.5 ? tool.radius * 2.4 : -tool.radius * 2.4
        }
        tool.selection = before.count
        tool.commit(before + [spot], previous: before, name: "Retouch", edits, undo: undo)
    }

    // MARK: Keys

    private func installKeys() {
        guard keyMonitor == nil else { return }
        KeyCommands.bracketsClaimed = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [tool] event in
            // Typing in a field (ALT text, keywords) is never a tool key.
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            switch event.keyCode {
            case 51, 117: // delete, forward delete
                guard tool.selection != nil else { return event }
                tool.deleteSelected(edits, undo: undo)
                return nil
            default:
                break
            }
            switch event.charactersIgnoringModifiers {
            case "[":
                tool.radius = max(0.003, tool.radius / 1.15)
                return nil
            case "]":
                tool.radius = min(0.15, tool.radius * 1.15)
                return nil
            case "/":
                tool.newSource(edits, undo: undo)
                return nil
            case "h", "H":
                tool.hideMarks.toggle()
                return nil
            default:
                return event
            }
        }
    }
}

// MARK: - In the tray

struct RetouchControls: View {
    @ObservedObject var tool: RetouchTool
    let edits: Binding<PhotoEdits>
    let undo: UndoManager?
    let done: () -> Void

    private var spots: [RetouchSpot] { edits.wrappedValue.retouchSpots }
    private var selected: RetouchSpot? { tool.selection.flatMap { spots[safe: $0] } }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bandage")
                .foregroundColor(.accentColor)
            Picker("", selection: modeBinding) {
                Text("Repair").tag(RetouchTool.Mode.repair)
                Text("Remove").tag(RetouchTool.Mode.remove)
                Text("Clone").tag(RetouchTool.Mode.clone)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .help("Repair heals dust and blemishes from a matching patch. Remove rebuilds the spot from its surroundings — for wires and branches that cross an edge. Clone copies straight from a source you ⌥-click.")
            .accessibilityLabel("Retouch mode")
            Text(hint)
                .font(.callout)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                // Fixed width: the buttons after it must not move when the
                // hint changes.
                .frame(width: 250, alignment: .leading)
                .help(hint)
            slider("Size", tool.binding(\.radius, spotValue: { $0.radius }, set: { $0.radius = $1 }, edits),
                   0.003...0.15, help: "Brush size, or the selected spot's ([ and ])")
            slider("Softness", tool.binding(\.softness, spotValue: { $0.softness ?? 0.45 }, set: { $0.softness = $1 }, edits),
                   0...1, help: "How gradually the edge blends in")
            slider("Opacity", tool.binding(\.opacity, spotValue: { $0.opacity ?? 1 }, set: { $0.opacity = $1 }, edits),
                   0.1...1, help: "How much of the fix shows")
            Button {
                tool.newSource(edits, undo: undo)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .disabled(selected == nil)
            .help("Try another: a different source, or a different rebuild (/)")
            .accessibilityLabel("Try another")
            Button {
                tool.deleteSelected(edits, undo: undo)
            } label: {
                Image(systemName: "trash")
            }
            .disabled(selected == nil)
            .help("Delete the selected spot (⌫)")
            .accessibilityLabel("Delete spot")
            Toggle(isOn: $tool.hideMarks) {
                Image(systemName: tool.hideMarks ? "eye.slash" : "eye")
            }
            .toggleStyle(.button)
            .help("Hide the marks to judge the result (H)")
            .accessibilityLabel("Hide marks")
            Button("Clear All") { tool.clearAll(edits, undo: undo) }
                .disabled(spots.isEmpty)
            Spacer(minLength: 0)
            Button("Done", action: done)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Switching mode retypes the selected spot too.
    private var modeBinding: Binding<RetouchTool.Mode> {
        Binding(
            get: {
                guard let spot = selected else { return tool.mode }
                return spot.clone == true ? .clone : spot.isFill ? .remove : .repair
            },
            set: { tool.setMode($0, edits, undo: undo) })
    }

    private var hint: String {
        if let selected {
            return selected.isFill ? "Drag to move · edge to resize · / for another try"
                : "Drag to move · edge to resize · drag the faint circle to change the source"
        }
        switch tool.mode {
        case .clone: return tool.cloneSource == nil ? "⌥-click where to copy from, then paint" : "Click or drag to clone"
        case .remove: return "Paint over what should go"
        case .repair: return "Click a spot or drag along a line to heal it"
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, help: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Slider(value: value, in: range)
                .frame(width: 70)
                .accessibilityLabel("Retouch \(label.lowercased())")
        }
        .help(help)
    }
}
