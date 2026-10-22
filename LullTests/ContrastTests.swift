import BedJetKit
import SwiftUI
import XCTest
@testable import Lull

/// Every pairing of text colour and background the screens use reads at 4.5:1 or better, the WCAG AA level for
/// body text. Checked from the colours themselves, so it holds wherever the text sits or scrolls.
final class ContrastTests: XCTestCase {
    private let backgrounds: [(String, Color)] = [("background", Theme.background), ("surface", Theme.surface), ("raised", Theme.raised)]

    func testLabelsOnEveryBackground() {
        for (text, color) in [("primary", Color.white), ("secondary", Theme.secondary), ("tertiary", Theme.tertiary)] {
            for (name, background) in backgrounds {
                assertReadable(color, on: background, "\(text) text on \(name)")
            }
        }
    }

    func testModeButtons() {
        for mode in Mode.allCases {
            // Unselected: the mode's colour on a raised button. Selected: black on the mode's colour.
            assertReadable(mode.tint, on: Theme.raised, "\(mode.title) on a mode button")
            assertReadable(.black, on: mode.tint, "a selected \(mode.title) button")
            // The running phase is written in its mode's colour on a card.
            assertReadable(mode.tint, on: Theme.surface, "\(mode.title) on a card")
        }
    }

    func testPrimaryButtons() {
        assertReadable(.black, on: .white, "a prominent button")
        assertReadable(.white, on: Theme.raised, "a plain button")
    }

    /// The faintest grey before it was raised, which this check is there to catch.
    func testCatchesTheOldFaintGrey() {
        XCTAssertLessThan(contrast(.white.opacity(0.32), on: Theme.surface), 4.5)
    }

    // MARK: WCAG contrast

    private func assertReadable(_ text: Color, on background: Color, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let ratio = contrast(text, on: background)
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(what) is \(String(format: "%.2f", ratio)):1", file: file, line: line)
    }

    private func contrast(_ text: Color, on background: Color) -> Double {
        let back = rgba(background)
        let front = rgba(text)
        // Translucent text shows the background through it.
        let blended = (0..<3).map { front[$0] * front[3] + back[$0] * (1 - front[3]) }
        let lighter = max(luminance(blended), luminance(back)), darker = min(luminance(blended), luminance(back))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func rgba(_ color: Color) -> [Double] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha].map(Double.init)
    }

    private func luminance(_ rgb: [Double]) -> Double {
        let linear = rgb.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
