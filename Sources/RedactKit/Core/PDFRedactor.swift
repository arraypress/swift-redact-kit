//
//  PDFRedactor.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  PDF redaction that is actually redaction. The classic failure is a
//  black rectangle drawn over live text — the text is still in the file
//  and copies right out. The only honest guarantee PDFKit affords is to
//  RASTERIZE the affected page: find the matches, paint them out, and
//  replace the page with its own picture. Pages with no findings keep
//  their text layer untouched; pages with findings lose selectable text,
//  which is the price of the guarantee and is stated, not hidden.
//

import AppKit
import Foundation
import PDFKit

/// Text redaction on PDFs.
public enum PDFRedactor {

    /// How a PDF redaction behaves.
    public struct Options: Sendable {
        /// Which kinds of value to destroy.
        public var types: Set<RedactionType>
        /// Caller-supplied regular expressions.
        public var customPatterns: [String]
        /// Rasterization scale for affected pages; 2 keeps text legible.
        public var scale: CGFloat

        public init(types: Set<RedactionType> = RedactionType.defaults,
                    customPatterns: [String] = [],
                    scale: CGFloat = 2) {
            self.types = types
            self.customPatterns = customPatterns
            self.scale = scale
        }
    }

    /// Redacts one PDF to `output` (or only reports, when `dryRun`).
    ///
    /// Document attributes (author, title, producer, dates) are stripped
    /// from the copy as well — a redacted report that still names its
    /// author in metadata is half a redaction.
    public static func redact(
        pdfAt url: URL, options: Options, to output: URL, dryRun: Bool
    ) throws -> RedactionOutcome {
        guard let document = PDFDocument(url: url) else {
            throw RedactError.unreadable("\(url.lastPathComponent) is not a readable PDF")
        }

        var allFindings: [TextFinding] = []
        var affected: [(index: Int, rects: [CGRect], fullPage: Bool)] = []

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let text = page.string ?? ""
            guard !text.isEmpty else { continue }
            let findings = try PatternRules.findings(
                in: text, types: options.types, customPatterns: options.customPatterns)
            guard !findings.isEmpty else { continue }
            allFindings.append(contentsOf: findings)

            if page.rotation != 0 {
                // A rotated page's selection bounds and draw transform
                // disagree; covering the whole page is the conservative
                // guarantee rather than a maybe-misplaced box.
                affected.append((index, [], true))
                continue
            }
            var rects: [CGRect] = []
            for finding in findings {
                if let bounds = page.selection(for: finding.range)?
                    .bounds(for: page).insetBy(dx: -2, dy: -2), !bounds.isEmpty {
                    rects.append(bounds)
                } else {
                    // A finding whose bounds cannot be located still MUST
                    // be destroyed; the whole page is the fallback.
                    affected.append((index, [], true))
                    rects = []
                    break
                }
            }
            if !rects.isEmpty { affected.append((index, rects, false)) }
        }

        let grouped = RedactionOutcome.grouped(allFindings)
        if dryRun {
            return RedactionOutcome(
                input: url.path, status: allFindings.isEmpty ? .skipped : .wouldRedact,
                findings: grouped,
                detail: allFindings.isEmpty ? "no findings"
                    : "\(affected.count) page(s) would be rasterized")
        }
        guard !allFindings.isEmpty else {
            return RedactionOutcome(input: url.path, status: .skipped,
                                    detail: "no findings")
        }

        for entry in affected {
            guard let page = document.page(at: entry.index) else { continue }
            let replacement = try rasterize(
                page, covering: entry.rects, fullPage: entry.fullPage, scale: options.scale)
            document.removePage(at: entry.index)
            document.insert(replacement, at: entry.index)
        }
        document.documentAttributes = [:]

        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard document.write(to: output) else {
            throw RedactError.unwritable("could not write \(output.lastPathComponent)")
        }
        let fullPages = affected.filter(\.fullPage).count
        var detail = "\(affected.count) page(s) rasterized; selectable text lost on those pages"
        if fullPages > 0 { detail += "; \(fullPages) covered whole (rotated or unlocatable bounds)" }
        return RedactionOutcome(input: url.path, output: output.path,
                                status: .redacted, findings: grouped, detail: detail)
    }

    /// The page as a picture with its findings painted out.
    private static func rasterize(
        _ page: PDFPage, covering rects: [CGRect], fullPage: Bool, scale: CGFloat
    ) throws -> PDFPage {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RedactError.unwritable("could not create a page context") }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        if fullPage {
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            for rect in rects {
                context.fill(CGRect(
                    x: (rect.minX - bounds.minX) * scale,
                    y: (rect.minY - bounds.minY) * scale,
                    width: rect.width * scale,
                    height: rect.height * scale))
            }
        }
        guard let image = context.makeImage() else {
            throw RedactError.unwritable("could not rasterize a page")
        }
        let nsImage = NSImage(cgImage: image, size: bounds.size)
        guard let replacement = PDFPage(image: nsImage) else {
            throw RedactError.unwritable("could not rebuild a rasterized page")
        }
        return replacement
    }
}
