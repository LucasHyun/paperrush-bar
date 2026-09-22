import AppKit

/// The menu bar hourglass, drawn at runtime so the sand can show how much time is left.
///
/// Rendered as a template image: the system tints it for light/dark menu bars, and
/// urgency is carried by the amount of sand, not by colour.
enum HourglassIcon {
    static let size = NSSize(width: 18, height: 18)

    /// How full the upper bulb is for a given number of days left.
    ///
    /// Linear over 30 days would make D-30 and D-7 look alike. These anchors keep the
    /// last week dramatic: half the sand is gone by D-7, most of it by D-3.
    static func fill(daysRemaining days: Double) -> Double {
        let anchors: [(day: Double, fill: Double)] = [
            (0, 0.0), (1, 0.10), (3, 0.25), (7, 0.45), (14, 0.70), (30, 1.0)
        ]
        if days <= 0 { return 0 }
        if days >= anchors.last!.day { return 1 }
        for i in 1..<anchors.count where days <= anchors[i].day {
            let (a, b) = (anchors[i - 1], anchors[i])
            let t = (days - a.day) / (b.day - a.day)
            return a.fill + (b.fill - a.fill) * t
        }
        return 1
    }

    /// - Parameters:
    ///   - fill: 0 (empty top bulb) … 1 (full). `nil` draws an idle glass with no sand.
    ///   - grain: 0 … 1 position of a single falling grain along the throat-to-floor
    ///     path, or `nil` for none. Used for the brief drop animation.
    ///   - tilt: rotation in degrees about the centre, for the anxious wobble.
    ///   - sand: a colour for the sand once the deadline is close. `nil` keeps the glyph
    ///     a monochrome template that the system tints; a colour switches it to a real
    ///     image whose glass follows the label colour and whose sand carries the alarm.
    static func image(fill: Double?, grain: Double?, tilt: Double = 0, sand: NSColor? = nil) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            if tilt != 0 {
                let t = NSAffineTransform()
                t.translateX(by: size.width / 2, yBy: size.height / 2)
                t.rotate(byDegrees: CGFloat(tilt))
                t.translateX(by: -size.width / 2, yBy: -size.height / 2)
                t.concat()
            }
            draw(fill: fill, grain: grain, sand: sand)
            return true
        }
        image.isTemplate = (sand == nil)
        return image
    }

    /// Sand colour for the time left: none a week out, then yellow → orange → red.
    /// Colour is the loudest thing a menu bar item can do, so it is spent only here.
    static func sandColor(hoursLeft: Double) -> NSColor? {
        switch hoursLeft {
        case ..<0: return nil
        case ..<24: return .systemRed
        case ..<72: return .systemOrange
        case ..<168: return .systemYellow
        default: return nil
        }
    }

    // MARK: - Drawing (18×18, y grows downward)

    private static func draw(fill: Double?, grain: Double?, sand: NSColor?) {
        // Template mode paints everything black and lets the system tint it. Colour
        // mode draws the glass in the dynamic label colour so it still follows the
        // menu bar's light/dark appearance, and only the sand is coloured.
        let ink: NSColor = sand == nil ? .black : .labelColor
        let sandInk: NSColor = sand ?? .black
        ink.setFill()
        ink.setStroke()

        let cx: CGFloat = 9
        let capW: CGFloat = 10, capH: CGFloat = 1.6
        let capTopY: CGFloat = 1.6
        let capBotY: CGFloat = 18 - 1.6 - capH
        let bulbHalfW: CGFloat = 4.2
        let throatHalfW: CGFloat = 0.9
        let glassTop = capTopY + capH
        let glassBot = capBotY
        let mid = (glassTop + glassBot) / 2
        let stroke: CGFloat = 1.25

        // Caps
        for y in [capTopY, capBotY] {
            NSBezierPath(roundedRect: NSRect(x: cx - capW / 2, y: y, width: capW, height: capH),
                         xRadius: capH / 2, yRadius: capH / 2).fill()
        }

        // Bulb outlines: two trapezoids meeting at a narrow throat.
        let upper = NSBezierPath()
        upper.move(to: NSPoint(x: cx - bulbHalfW, y: glassTop))
        upper.line(to: NSPoint(x: cx + bulbHalfW, y: glassTop))
        upper.line(to: NSPoint(x: cx + throatHalfW, y: mid))
        upper.line(to: NSPoint(x: cx - throatHalfW, y: mid))
        upper.close()

        let lower = NSBezierPath()
        lower.move(to: NSPoint(x: cx - throatHalfW, y: mid))
        lower.line(to: NSPoint(x: cx + throatHalfW, y: mid))
        lower.line(to: NSPoint(x: cx + bulbHalfW, y: glassBot))
        lower.line(to: NSPoint(x: cx - bulbHalfW, y: glassBot))
        lower.close()

        for path in [upper, lower] {
            path.lineWidth = stroke
            path.lineJoinStyle = .round
            path.stroke()
        }

        guard let fill else { return }
        let f = CGFloat(min(max(fill, 0), 1))
        let inset: CGFloat = 1.1   // keep a sliver of glass visible around the sand

        // Sand left in the upper bulb: a horizontal band clipped to the bulb, its top
        // edge rising with `fill`. (The bulb narrows toward the throat, so a band of
        // constant height holds less sand lower down — which is exactly right.)
        sandInk.setFill()
        if f > 0.02 {
            let usable = (mid - glassTop) - inset * 1.4
            let top = mid - inset * 0.4 - usable * f
            NSGraphicsContext.saveGraphicsState()
            upper.addClip()
            NSRect(x: cx - bulbHalfW, y: top, width: bulbHalfW * 2, height: mid - top).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Sand already fallen: a mound on the lower floor, growing as the top empties.
        let fallen = 1 - f
        if fallen > 0.02 {
            let usable = (glassBot - mid) - inset * 1.4
            let height = max(usable * fallen, 0.9)
            let floor = glassBot - inset * 0.6
            NSGraphicsContext.saveGraphicsState()
            lower.addClip()
            // A shallow dome reads as a pile rather than a flat floor.
            let mound = NSBezierPath()
            mound.move(to: NSPoint(x: cx - bulbHalfW, y: floor))
            mound.line(to: NSPoint(x: cx + bulbHalfW, y: floor))
            mound.line(to: NSPoint(x: cx + bulbHalfW, y: floor - height * 0.55))
            mound.curve(to: NSPoint(x: cx - bulbHalfW, y: floor - height * 0.55),
                        controlPoint1: NSPoint(x: cx + bulbHalfW * 0.5, y: floor - height * 1.25),
                        controlPoint2: NSPoint(x: cx - bulbHalfW * 0.5, y: floor - height * 1.25))
            mound.close()
            mound.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // The falling grain, with a short trail. Drawn with XOR so it is dark against
        // the empty glass and punches a light hole through the mound — otherwise the
        // grain vanishes exactly when the pile it lands on is big, i.e. when it matters.
        if let grain, f > 0.02 {
            let start = mid + 0.4
            let end = glassBot - inset - 1.0
            let p = CGFloat(min(max(grain, 0), 1))
            let y = start + (end - start) * p
            NSGraphicsContext.saveGraphicsState()
            // In colour mode the grain is drawn in the glass colour, which contrasts
            // with the coloured mound on its own; XOR is only needed for monochrome.
            if sand == nil {
                NSGraphicsContext.current?.compositingOperation = .xor
            } else {
                ink.setFill()
            }
            NSBezierPath(ovalIn: NSRect(x: cx - 1.2, y: y - 1.2, width: 2.4, height: 2.4)).fill()
            if p > 0.15 {
                let trailY = y - 2.6
                NSBezierPath(ovalIn: NSRect(x: cx - 0.7, y: trailY - 0.7, width: 1.4, height: 1.4)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
