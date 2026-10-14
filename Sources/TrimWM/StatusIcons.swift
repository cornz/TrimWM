import AppKit

/// The layout a workspace shows in the menu bar.
enum StatusGlyph: Equatable, Sendable {
    case autotile, niri, tabsTop, tabsBottom, tabsLeft, tabsRight, fullscreen
}

struct StatusWorkspace: Equatable, Sendable {
    let number: Int
    let glyph: StatusGlyph
    let isVisible: Bool
}

/// Draws the menu-bar status: each occupied workspace's number and layout
/// glyph, with the visible workspace knocked out of a filled pill. The image is
/// a template, so the menu bar tints it for light and dark appearances.
enum StatusIcons {
    static let height: CGFloat = 18
    static let glyphSize = CGSize(width: 16, height: 12)
    private static let pillHeight: CGFloat = 16
    private static let padding: CGFloat = 4
    private static let spacing: CGFloat = 3
    private static let itemSpacing: CGFloat = 2
    private static var font: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .semibold) }

    static func image(for workspaces: [StatusWorkspace]) -> NSImage {
        let widths = workspaces.map(itemWidth)
        let width = widths.reduce(0, +) + itemSpacing * CGFloat(max(0, workspaces.count - 1))
        let image = NSImage(size: CGSize(width: max(1, ceil(width)), height: height), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            var x: CGFloat = 0
            for (workspace, itemWidth) in zip(workspaces, widths) {
                draw(workspace, in: CGRect(x: x, y: 0, width: itemWidth, height: height), context: context)
                x += itemWidth + itemSpacing
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = workspaces.map(description).joined(separator: ", ")
        return image
    }

    /// One glyph alone, as a template image.
    static func image(for glyph: StatusGlyph) -> NSImage {
        let image = NSImage(size: glyphSize, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            drawGlyph(glyph, in: rect, context: context)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func itemWidth(_ workspace: StatusWorkspace) -> CGFloat {
        ceil(label(workspace.number).size().width) + spacing + glyphSize.width + padding * 2
    }

    private static func label(_ number: Int) -> NSAttributedString {
        NSAttributedString(string: "\(number)", attributes: [.font: font, .foregroundColor: NSColor.black])
    }

    private static func draw(_ workspace: StatusWorkspace, in rect: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if workspace.isVisible {
            let pill = CGRect(x: rect.minX, y: (rect.height - pillHeight) / 2, width: rect.width, height: pillHeight)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(CGPath(roundedRect: pill, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.fillPath()
            context.setBlendMode(.destinationOut)
        } else {
            context.setAlpha(0.8)
        }
        let text = label(workspace.number)
        let textSize = text.size()
        text.draw(at: CGPoint(x: rect.minX + padding, y: (rect.height - textSize.height) / 2))
        let glyph = CGRect(
            x: rect.minX + padding + ceil(textSize.width) + spacing,
            y: (rect.height - glyphSize.height) / 2,
            width: glyphSize.width,
            height: glyphSize.height
        )
        drawGlyph(workspace.glyph, in: glyph, context: context)
    }

    /// Draws in a flipped 16 × 12 point box: y grows downwards.
    static func drawGlyph(_ glyph: StatusGlyph, in rect: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setFillColor(NSColor.black.cgColor)
        context.setLineWidth(1)
        let frame = CGRect(x: 0.5, y: 0.5, width: 15, height: 11)
        func outline(_ rect: CGRect, radius: CGFloat = 2) {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
        }
        func fill(_ rect: CGRect, radius: CGFloat = 1, alpha: CGFloat = 1) {
            context.saveGState()
            context.setAlpha(alpha)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
            context.restoreGState()
        }
        func line(_ from: CGPoint, _ to: CGPoint) {
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
        }

        switch glyph {
        case .tabsBottom:
            // The top glyph upside down.
            context.translateBy(x: 0, y: glyphSize.height)
            context.scaleBy(x: 1, y: -1)
            drawGlyph(.tabsTop, in: CGRect(origin: .zero, size: glyphSize), context: context)
            return
        case .tabsRight:
            // The left glyph mirrored.
            context.translateBy(x: glyphSize.width, y: 0)
            context.scaleBy(x: -1, y: 1)
            drawGlyph(.tabsLeft, in: CGRect(origin: .zero, size: glyphSize), context: context)
            return
        case .autotile:
            // One window on the left, two stacked on the right.
            outline(frame)
            line(CGPoint(x: 8, y: 0.5), CGPoint(x: 8, y: 11.5))
            line(CGPoint(x: 8, y: 6), CGPoint(x: 15.5, y: 6))
        case .niri:
            // Two columns in view, more scrolled off on either side.
            fill(CGRect(x: 0, y: 2, width: 2, height: 8), alpha: 0.45)
            outline(CGRect(x: 3.5, y: 0.5, width: 4, height: 11), radius: 1.5)
            outline(CGRect(x: 8.5, y: 0.5, width: 4, height: 11), radius: 1.5)
            fill(CGRect(x: 14, y: 2, width: 2, height: 8), alpha: 0.45)
        case .tabsTop:
            // A tab strip with the first tab active.
            outline(frame)
            line(CGPoint(x: 0.5, y: 4), CGPoint(x: 15.5, y: 4))
            fill(CGRect(x: 1, y: 1, width: 6, height: 3), radius: 0.5)
            line(CGPoint(x: 10, y: 1), CGPoint(x: 10, y: 4))
        case .tabsLeft:
            // A sidebar of tabs with the first one active.
            outline(frame)
            line(CGPoint(x: 5, y: 0.5), CGPoint(x: 5, y: 11.5))
            fill(CGRect(x: 1.5, y: 2, width: 3, height: 2), radius: 0.5)
            fill(CGRect(x: 1.5, y: 5, width: 3, height: 2), radius: 0.5, alpha: 0.45)
            fill(CGRect(x: 1.5, y: 8, width: 3, height: 2), radius: 0.5, alpha: 0.45)
        case .fullscreen:
            // One window filling the screen.
            outline(frame)
            fill(CGRect(x: 2, y: 2, width: 12, height: 8))
        }
    }

    private static func description(_ workspace: StatusWorkspace) -> String {
        let layout = switch workspace.glyph {
        case .autotile: "tiling"
        case .niri: "scrolling"
        case .tabsTop, .tabsBottom, .tabsLeft, .tabsRight: "tabs"
        case .fullscreen: "fullscreen"
        }
        return "Workspace \(workspace.number), \(layout)\(workspace.isVisible ? ", visible" : "")"
    }
}
