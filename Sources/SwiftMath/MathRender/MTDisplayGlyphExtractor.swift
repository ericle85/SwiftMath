//
//  MTDisplayGlyphExtractor.swift
//  SwiftMath
//
//  Extracts per-glyph bounding rectangles from the MTDisplay tree.
//  Coordinates are in the same space as MTDisplay.draw() — CoreText
//  coordinates (origin at baseline, y-up).
//

import Foundation
import CoreText
import QuartzCore

/// A single glyph's character string and bounding rect in display coordinates.
public struct GlyphRect {
    public let character: String
    public let rect: CGRect

    public init(character: String, rect: CGRect) {
        self.character = character
        self.rect = rect
    }
}

/// Recursively extracts per-glyph bounding rects from an MTDisplay tree.
/// The returned rects are in the same coordinate system as `MTDisplay.draw()` —
/// CoreText coordinates with y-up. To convert to UIKit (y-down) for rendering
/// into a UIImage, flip: `y_uikit = totalHeight - rect.maxY`.
public func extractGlyphRects(from display: MTDisplay, offset: CGPoint = .zero) -> [GlyphRect] {
    let pos = CGPoint(x: offset.x + display.position.x,
                      y: offset.y + display.position.y)

    switch display {
    case let listDisplay as MTMathListDisplay:
        return listDisplay.subDisplays.flatMap { extractGlyphRects(from: $0, offset: pos) }

    case let ctLine as MTCTLineDisplay:
        return extractFromCTLine(ctLine, offset: pos)

    case let glyph as MTGlyphDisplay:
        return extractFromGlyph(glyph, offset: pos)

    case let construction as MTGlyphConstructionDisplay:
        // Constructed glyphs (e.g. large delimiters built from pieces)
        // Treat as a single rect
        let rect = CGRect(x: pos.x, y: pos.y - display.descent,
                          width: display.width, height: display.ascent + display.descent)
        return [GlyphRect(character: "⎸", rect: rect)]

    case let fraction as MTFractionDisplay:
        var rects = [GlyphRect]()
        if let num = fraction.numerator {
            rects.append(contentsOf: extractGlyphRects(from: num, offset: .zero))
        }
        if let den = fraction.denominator {
            rects.append(contentsOf: extractGlyphRects(from: den, offset: .zero))
        }
        // Add the fraction line itself as a rect
        let lineY = pos.y + fraction.linePosition
        let lineRect = CGRect(x: pos.x, y: lineY - fraction.lineThickness / 2,
                              width: fraction.width, height: fraction.lineThickness)
        if fraction.lineThickness > 0 {
            rects.append(GlyphRect(character: "—", rect: lineRect))
        }
        return rects

    case let radical as MTRadicalDisplay:
        var rects = [GlyphRect]()
        if let radicand = radical.radicand {
            rects.append(contentsOf: extractGlyphRects(from: radicand, offset: .zero))
        }
        if let degree = radical.degree {
            rects.append(contentsOf: extractGlyphRects(from: degree, offset: .zero))
        }
        return rects

    case let limits as MTLargeOpLimitsDisplay:
        var rects = [GlyphRect]()
        if let nucleus = limits.nucleus {
            rects.append(contentsOf: extractGlyphRects(from: nucleus, offset: pos))
        }
        if let upper = limits.upperLimit {
            rects.append(contentsOf: extractGlyphRects(from: upper, offset: .zero))
        }
        if let lower = limits.lowerLimit {
            rects.append(contentsOf: extractGlyphRects(from: lower, offset: .zero))
        }
        return rects

    case let accent as MTAccentDisplay:
        var rects = [GlyphRect]()
        if let accentee = accent.accentee {
            rects.append(contentsOf: extractGlyphRects(from: accentee, offset: .zero))
        }
        if let accentGlyph = accent.accent {
            rects.append(contentsOf: extractGlyphRects(from: accentGlyph, offset: pos))
        }
        return rects

    case let lineDisplay as MTLineDisplay:
        var rects = [GlyphRect]()
        if let inner = lineDisplay.inner {
            rects.append(contentsOf: extractGlyphRects(from: inner, offset: .zero))
        }
        return rects

    default:
        // Unknown display type — return bounding box
        let rect = CGRect(x: pos.x, y: pos.y - display.descent,
                          width: display.width, height: display.ascent + display.descent)
        return [GlyphRect(character: "?", rect: rect)]
    }
}

// MARK: - CTLine glyph extraction

private func extractFromCTLine(_ display: MTCTLineDisplay, offset: CGPoint) -> [GlyphRect] {
    guard let line = display.line else { return [] }
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    var rects = [GlyphRect]()

    for run in runs {
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { continue }

        var positions = [CGPoint](repeating: .zero, count: count)
        var advances = [CGSize](repeating: .zero, count: count)
        var glyphs = [CGGlyph](repeating: 0, count: count)

        CTRunGetPositions(run, CFRangeMake(0, count), &positions)
        CTRunGetAdvances(run, CFRangeMake(0, count), &advances)
        CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)

        // Get the font for this run to compute glyph bounding boxes
        let attrs = CTRunGetAttributes(run) as! [String: Any]
        let ctFont = attrs[kCTFontAttributeName as String] as! CTFont

        // Get per-glyph bounding rects from the font
        var boundingRects = [CGRect](repeating: .zero, count: count)
        CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, glyphs, &boundingRects, count)

        // Get string indices to extract the actual characters
        let status = CTRunGetStatus(run)
        var indices = [CFIndex](repeating: 0, count: count)
        CTRunGetStringIndices(run, CFRangeMake(0, count), &indices)

        let attrStr = display.attributedString

        for i in 0..<count {
            let glyphPos = positions[i]
            let glyphBounds = boundingRects[i]

            // The glyph rect in the CTLine's local coordinate space
            // glyphBounds.origin is the offset from the glyph origin to the bbox corner
            let x = offset.x + glyphPos.x + glyphBounds.origin.x
            let y = offset.y + glyphPos.y + glyphBounds.origin.y
            let rect = CGRect(x: x, y: y,
                              width: glyphBounds.width, height: glyphBounds.height)

            // Extract the character string
            var character = "?"
            if let attrStr = attrStr {
                let str = attrStr.string as NSString
                let strIdx = indices[i]
                if strIdx < str.length {
                    // Handle surrogate pairs
                    let range = str.rangeOfComposedCharacterSequence(at: strIdx)
                    character = str.substring(with: range)
                }
            }

            // Skip zero-width or invisible glyphs
            if glyphBounds.width > 0.1 && glyphBounds.height > 0.1 {
                rects.append(GlyphRect(character: character, rect: rect))
            }
        }
    }

    return rects
}

// MARK: - Single glyph extraction

private func extractFromGlyph(_ display: MTGlyphDisplay, offset: CGPoint) -> [GlyphRect] {
    guard let font = display.font, let glyph = display.glyph else { return [] }

    var glyphVal = glyph
    var boundingRect = CGRect.zero
    CTFontGetBoundingRectsForGlyphs(font.ctFont, .horizontal, &glyphVal, &boundingRect, 1)

    let x = offset.x + boundingRect.origin.x
    let y = offset.y + boundingRect.origin.y
    let rect = CGRect(x: x, y: y, width: boundingRect.width, height: boundingRect.height)

    // Try to get the character name from the glyph
    var character = "?"
    if let name = CTFontCopyNameForGlyph(font.ctFont, glyph) as String? {
        character = name
    } else {
        // Fallback: use CGGlyph to unicode mapping
        var unichars = [UniChar](repeating: 0, count: 1)
        var glyphs = [glyph]
        if CTFontGetGlyphsForCharacters(font.ctFont, &unichars, &glyphs, 1) {
            character = String(utf16CodeUnits: unichars, count: 1)
        }
    }

    if boundingRect.width > 0.1 && boundingRect.height > 0.1 {
        return [GlyphRect(character: character, rect: rect)]
    }
    return []
}
