import CoreText
import SwiftUI

/// The Hannya mark: the horned demon mask of Noh, drawn from the same
/// 64×64 geometry as the web UI's favicon.svg.
struct HannyaMark: View {
    var size: CGFloat = 40

    var body: some View {
        Canvas(renderer: Self.draw)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    // nonisolated: SwiftUI may render a Canvas on its background render
    // thread; a main-actor-bound renderer would crash there.
    nonisolated private static func draw(_ ctx: inout GraphicsContext, _ canvas: CGSize) {
        let s = canvas.width / 64
        let tile = CGRect(x: 0, y: 0, width: 64 * s, height: 64 * s)
        ctx.fill(Path(roundedRect: tile, cornerRadius: 14 * s), with: .color(.gwSumi))
        ctx.stroke(Path(roundedRect: tile.insetBy(dx: 0.5 * s, dy: 0.5 * s), cornerRadius: 13.5 * s),
                   with: .color(.white.opacity(0.2)), lineWidth: s)

        // The mask is scaled by 0.9 and moved down, as in the SVG:
        // translate(32 34) scale(0.9) translate(-32 -27).
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: (32 + (x - 32) * 0.9) * s, y: (34 + (y - 27) * 0.9) * s)
        }
        // Horns and head are filled one by one: the horns wind in opposite
        // directions, so filled as one path the right horn's overlap with the
        // head would cancel out and leave a notch.
        var left = Path()
        left.move(to: p(22, 21))
        left.addCurve(to: p(16, 5), control1: p(17, 17), control2: p(15, 11))
        left.addCurve(to: p(28, 16), control1: p(19, 10), control2: p(23, 13))
        left.closeSubpath()
        var right = Path()
        right.move(to: p(42, 21))
        right.addCurve(to: p(48, 5), control1: p(47, 17), control2: p(49, 11))
        right.addCurve(to: p(36, 16), control1: p(45, 10), control2: p(41, 13))
        right.closeSubpath()
        // Head, whose hem is a row of fangs
        var head = Path()
        head.move(to: p(18, 46))
        head.addLine(to: p(18, 29))
        head.addCurve(to: p(32, 15), control1: p(18, 20), control2: p(24, 15))
        head.addCurve(to: p(46, 29), control1: p(40, 15), control2: p(46, 20))
        head.addLine(to: p(46, 46))
        for (x, y) in [(41.5, 41.0), (37.0, 49.0), (32.0, 43.0), (27.0, 49.0), (22.5, 41.0)] {
            head.addLine(to: p(x, y))
        }
        head.closeSubpath()
        for shape in [left, right, head] {
            ctx.fill(shape, with: .color(.white))
        }

        var eyes = Path()
        eyes.addLines([p(20, 27), p(30, 31.5), p(28.5, 34), p(22, 32.5)])
        eyes.closeSubpath()
        eyes.addLines([p(44, 27), p(34, 31.5), p(35.5, 34), p(42, 32.5)])
        eyes.closeSubpath()
        ctx.fill(eyes, with: .color(.gwShu))
    }
}

/// The wordmark face, Shippori Mincho B1 ExtraBold (SIL OFL), bundled as a
/// subset with ASCII and katakana. It falls back to the system serif.
enum BrandFont {
    static let name = "ShipporiMinchoB1-ExtraBold"

    /// Registers the bundled font for this process; call once at launch.
    static func register() {
        guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func font(_ size: CGFloat) -> Font { .custom(name, fixedSize: size) }
}

/// Mark, wordmark and katakana reading, as in the web UI.
struct Lockup: View {
    var size: CGFloat = 36

    var body: some View {
        HStack(spacing: size * 0.3) {
            HannyaMark(size: size)
            VStack(alignment: .leading, spacing: 1) {
                Text("GHOSTWIRE")
                    .font(BrandFont.font(size * 0.47))
                    .tracking(size * 0.47 * 0.14)
                Text("ゴーストワイヤー")
                    .font(BrandFont.font(size * 0.28))
                    .tracking(size * 0.28 * 0.3)
                    .foregroundStyle(Color.gwText2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GHOSTWIRE")
    }
}
