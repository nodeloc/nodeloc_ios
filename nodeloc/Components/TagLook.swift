//
//  TagLook.swift
//  nodeloc
//
//  How a tag looks, the way the web draws it (internal/taglook, app.css
//  「标签和用户标识」): a colour (6-digit hex, grey #475569 when unset), one of
//  three styles — soft (a 12% wash of the colour behind coloured text), solid
//  (the colour behind white text), outline (a coloured border and text) — and
//  an optional line icon from the tag icon library (24×24 paths, stroked).
//  In dark mode the text colour is mixed 45% toward white and the wash is
//  24%, as the web does, so dark colours stay readable.
//
//  Looks come from `GET /api/v1/tags` (the catalog, with colour/style/icon)
//  and `GET /api/v1/nodes/{slug}/tags` (a node's own tags); the icon paths
//  from `GET /api/v1/tag-looks`. All cached for the session.
//

import SwiftUI

// MARK: - Model

nonisolated struct TagLook: Codable, Sendable, Hashable {
    var color: String?
    var style: String?
    var icon: String?

    static let plain = TagLook(color: nil, style: nil, icon: nil)

    var isStyled: Bool { (color?.isEmpty == false) || (icon?.isEmpty == false) }
}

@MainActor
@Observable
final class TagLookStore {
    static let shared = TagLookStore()

    private(set) var looks: [String: TagLook] = [:]
    private(set) var iconPaths: [String: String] = [:]

    @ObservationIgnored private var catalogLoaded = false
    @ObservationIgnored private var loading = false
    @ObservationIgnored private let client = DiscourseClient()

    private nonisolated struct TagRow: Decodable {
        let name: String
        let color: String?
        let style: String?
        let icon: String?
    }
    private nonisolated struct TagList: Decodable { let tags: [TagRow] }
    private nonisolated struct Catalog: Decodable {
        nonisolated struct Icon: Decodable { let id: String; let d: String }
        let icons: [Icon]
    }

    func look(_ name: String) -> TagLook { looks[name] ?? .plain }

    /// Loads the tag catalog and the icon library once per session.
    func loadIfNeeded() async {
        guard !catalogLoaded, !loading else { return }
        loading = true
        defer { loading = false }
        async let tagsCall: TagList? = try? client.get("api/v1/tags", query: [URLQueryItem(name: "limit", value: "500")])
        async let iconsCall: Catalog? = try? client.get("api/v1/tag-looks")
        let (tags, icons) = await (tagsCall, iconsCall)
        if let tags { merge(tags.tags) }
        if let icons {
            iconPaths = Dictionary(icons.icons.map { ($0.id, $0.d) }, uniquingKeysWith: { first, _ in first })
        }
        catalogLoaded = tags != nil && icons != nil
    }

    /// A node's own tags, with their looks, from its tags endpoint.
    func merge(nodeTags rows: [(name: String, look: TagLook)]) {
        var next = looks
        for row in rows where next[row.name] != row.look { next[row.name] = row.look }
        if next != looks { looks = next }
    }

    private func merge(_ rows: [TagRow]) {
        merge(nodeTags: rows.map { ($0.name, TagLook(color: $0.color, style: $0.style, icon: $0.icon)) })
    }
}

// MARK: - Colours

/// The web's three styles worked out for one colour scheme.
struct TagPalette {
    let fill: Color
    /// The fill when the chip is picked: the soft wash 8% stronger.
    let selectedFill: Color
    let ink: Color
    let border: Color?

    init(look: TagLook, dark: Bool) {
        let base = look.color.flatMap(Color.init(cssHex:)) ?? Color(hex: 0x475569)
        let ink = dark ? base.mixed(with: .white, by: 0.45) : base
        switch look.style {
        case "solid":
            fill = base
            selectedFill = base
            self.ink = .white
            border = nil
        case "outline":
            fill = .clear
            selectedFill = base.opacity(dark ? 0.24 : 0.12)
            self.ink = ink
            border = ink
        default:
            fill = base.opacity(dark ? 0.24 : 0.12)
            selectedFill = base.opacity(dark ? 0.32 : 0.20)
            self.ink = ink
            border = nil
        }
    }
}

private extension Color {
    /// Like CSS `color-mix(in srgb, self, other amount)`.
    func mixed(with other: Color, by amount: Double) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(amount)
        return Color(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t)
    }
}

// MARK: - Chip

/// One tag as the web draws it: colour, style and icon from the tag's look.
/// `selected` deepens the wash and adds a 1pt hairline in the tag's text
/// colour, inside the chip.
struct TagLookChip: View {
    enum Size {
        /// The node page's filter row: 28pt tall, 13pt.
        case filter
        /// On a topic row or in a topic: 24pt, 12pt.
        case row

        var height: CGFloat { self == .filter ? 28 : 24 }
        var font: CGFloat { self == .filter ? 13 : 12 }
        var icon: CGFloat { self == .filter ? 13 : 12 }
        var padding: CGFloat { self == .filter ? 10 : 9 }
    }

    let name: String
    var size: Size = .row
    var selected = false
    /// For 全部 and other chips that aren't tags: the plain grey look.
    var lookOverride: TagLook?
    /// Over scrolling content: a glass capsule under the tag's own fill.
    var onGlass = false

    @Environment(\.colorScheme) private var colorScheme
    private var store = TagLookStore.shared

    init(name: String, size: Size = .row, selected: Bool = false, lookOverride: TagLook? = nil, onGlass: Bool = false) {
        self.name = name
        self.size = size
        self.selected = selected
        self.lookOverride = lookOverride
        self.onGlass = onGlass
    }

    var body: some View {
        let look = lookOverride ?? store.look(name)
        let palette = TagPalette(look: look, dark: colorScheme == .dark)
        HStack(spacing: 4) {
            if let id = look.icon, let path = store.iconPaths[id] {
                TagIconShape(path: path)
                    .stroke(palette.ink, style: StrokeStyle(lineWidth: 2.2 * size.icon / 24, lineCap: .round, lineJoin: .round))
                    .frame(width: size.icon, height: size.icon)
            }
            Text(name)
                .font(Theme.body(size.font, weight: .bold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, size.padding)
        .frame(height: size.height)
        // Selected: a stronger wash (the web's hover step, +8%) and a hairline
        // in the tag's own text colour, drawn inside so the chip doesn't grow.
        // It was the web's 2pt ring outside a 2pt gap, which read heavy here.
        .background(selected && look.style != "solid" ? palette.selectedFill : palette.fill, in: Capsule())
        .background { if onGlass { Color.clear.glassSurface(tint: FloatingHeader.glassTint, in: .capsule) } }
        .overlay {
            if selected {
                Capsule().strokeBorder(palette.ink, lineWidth: 1)
            } else if let border = palette.border {
                Capsule().strokeBorder(border, lineWidth: 1)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Icon path

/// An SVG path (`d`) on a 24×24 canvas, scaled to the frame. Handles the
/// commands the tag icon library uses: M L H V C S A Z, absolute and relative.
struct TagIconShape: Shape {
    let path: String

    nonisolated func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let base = Self.parse(path)
        return base.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }

    nonisolated(unsafe) private static var cache: [String: Path] = [:]

    nonisolated static func parse(_ d: String) -> Path {
        if let hit = cache[d] { return hit }
        var tokens: [String] = []
        var number = ""
        func flush() { if !number.isEmpty { tokens.append(number); number = "" } }
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" {
                flush(); tokens.append(String(ch))
            } else if ch == "," || ch == " " || ch == "\n" || ch == "\t" {
                flush()
            } else if ch == "-" && !number.isEmpty && !(number.last == "e" || number.last == "E") {
                flush(); number = "-"
            } else if ch == "." && number.contains(".") {
                flush(); number = "."
            } else {
                number.append(ch)
            }
        }
        flush()

        var path = Path()
        var i = 0
        var cmd: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        func next() -> CGFloat {
            defer { i += 1 }
            return i < tokens.count ? CGFloat(Double(tokens[i]) ?? 0) : 0
        }
        func flag() -> Bool {
            // Arc flags may be packed ("011"); take one digit.
            guard i < tokens.count else { return false }
            var t = tokens[i]
            let f = t.removeFirst()
            if t.isEmpty { i += 1 } else { tokens[i] = t }
            return f == "1"
        }
        while i < tokens.count {
            if let c = tokens[i].first, tokens[i].count == 1, c.isLetter {
                cmd = c
                i += 1
                if c == "z" || c == "Z" {
                    path.closeSubpath()
                    current = start
                    lastControl = nil
                    continue
                }
            }
            let rel = cmd.isLowercase
            let o = rel ? current : .zero
            switch cmd.uppercased() {
            case "M":
                let p = CGPoint(x: o.x + next(), y: o.y + next())
                path.move(to: p); current = p; start = p
                cmd = rel ? "l" : "L"
                lastControl = nil
            case "L":
                let p = CGPoint(x: o.x + next(), y: o.y + next())
                path.addLine(to: p); current = p; lastControl = nil
            case "H":
                let p = CGPoint(x: (rel ? current.x : 0) + next(), y: current.y)
                path.addLine(to: p); current = p; lastControl = nil
            case "V":
                let p = CGPoint(x: current.x, y: (rel ? current.y : 0) + next())
                path.addLine(to: p); current = p; lastControl = nil
            case "C":
                let c1 = CGPoint(x: o.x + next(), y: o.y + next())
                let c2 = CGPoint(x: o.x + next(), y: o.y + next())
                let p = CGPoint(x: o.x + next(), y: o.y + next())
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p; lastControl = c2
            case "S":
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = CGPoint(x: o.x + next(), y: o.y + next())
                let p = CGPoint(x: o.x + next(), y: o.y + next())
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p; lastControl = c2
            case "A":
                let rx = next(), ry = next(), rotation = next()
                let large = flag(), sweep = flag()
                let p = CGPoint(x: o.x + next(), y: o.y + next())
                addArc(&path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = p; lastControl = nil
            default:
                i += 1
            }
        }
        cache[d] = path
        return path
    }

    /// SVG elliptical arc → cubic Béziers (endpoint to centre parameterisation).
    nonisolated private static func addArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy
        let y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry
        let cy1 = -coef * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + (p0.x + p1.x) / 2
        let cy = sinP * cx1 + cosP * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = Int(ceil(abs(delta) / (.pi / 2)))
        let step = delta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        var theta = theta1
        for _ in 0..<segments {
            let cos1 = cos(theta), sin1 = sin(theta)
            let cos2 = cos(theta + step), sin2 = sin(theta + step)
            func point(_ c: CGFloat, _ s: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * c * cosP - ry * s * sinP, y: cy + rx * c * sinP + ry * s * cosP)
            }
            let e1 = point(cos1 - t * sin1, sin1 + t * cos1)
            let e2 = point(cos2 + t * sin2, sin2 - t * cos2)
            let end = point(cos2, sin2)
            path.addCurve(to: end, control1: e1, control2: e2)
            theta += step
        }
    }
}
