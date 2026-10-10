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

    /// A page with fewer readable characters than this is treated as a
    /// picture of a page — a scan — and read by recognising its pixels.
    /// A real text page carries hundreds; a scan carries none, or a stray
    /// page number its scanner stamped on.
    static let scannedPageThreshold = 16

    /// What one page needs done to it.
    struct PagePlan {
        let index: Int
        /// Text-layer findings, in page coordinates.
        var rects: [CGRect] = []
        /// Visual findings, in pixels of `image`.
        var boxes: [CGRect] = []
        var fullPage = false
        /// The page as already rendered for looking, reused for painting.
        var image: CGImage?
    }

    /// Redacts one PDF to `output` (or only reports, when `dryRun`).
    ///
    /// Each page is read from its text layer; a page with no real text layer
    /// — a scan — is read by recognising its pixels instead, and every page
    /// is looked at for barcodes when they are asked for. Document attributes
    /// (author, title, producer, dates) are stripped from the copy as well —
    /// a redacted report that still names its author in metadata is half a
    /// redaction. The copy is then re-read and refused unless the flattened
    /// pages carry no text, the attributes are gone, and no rule finds
    /// anything left anywhere in it.
    public static func redact(
        pdfAt url: URL, options: Options, to output: URL, dryRun: Bool
    ) throws -> RedactionOutcome {
        guard let document = PDFDocument(url: url) else {
            throw RedactError.unreadable("\(url.lastPathComponent) is not a readable PDF")
        }

        var allFindings: [TextFinding] = []
        var affected: [PagePlan] = []
        var scannedPages = 0
        let textual = options.types.filter(\.isTextual)

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var plan = PagePlan(index: index)
            let text = page.string ?? ""
            let isScan = text.filter { !$0.isWhitespace }.count < scannedPageThreshold

            if !isScan {
                let findings = try PatternRules.findings(
                    in: text, types: textual, customPatterns: options.customPatterns)
                allFindings += findings
                for finding in findings {
                    if page.rotation == 0, let bounds = page.selection(for: finding.range)?
                        .bounds(for: page).insetBy(dx: -2, dy: -2), !bounds.isEmpty {
                        plan.rects.append(bounds)
                    } else {
                        // A rotated page's selection bounds and draw transform
                        // disagree, and a finding that cannot be located still
                        // MUST be destroyed: the whole page is the fallback.
                        plan.fullPage = true
                    }
                }
            }

            // Looking: the whole of a scan, and every page for barcodes.
            if isScan || options.types.contains(.barcode) {
                let image = try render(page, scale: options.scale)
                let wanted: Set<RedactionType> = isScan ? options.types : [.barcode]
                let scan = try VisualScan.scan(image, types: wanted,
                                               customPatterns: isScan ? options.customPatterns : [],
                                               padding: 2 * options.scale)
                if isScan { scannedPages += 1 }
                if !scan.findings.isEmpty {
                    allFindings += scan.findings
                    plan.boxes = scan.boxes
                    plan.image = image
                    if page.rotation != 0 { plan.fullPage = true }
                }
            }
            if plan.fullPage || !plan.rects.isEmpty || !plan.boxes.isEmpty { affected.append(plan) }
        }

        let grouped = RedactionOutcome.grouped(allFindings)
        let scanNote = scannedPages > 0 ? "; \(scannedPages) scanned page(s) read by recognition" : ""
        if dryRun {
            return RedactionOutcome(
                input: url.path, status: allFindings.isEmpty ? .skipped : .wouldRedact,
                findings: grouped,
                detail: (allFindings.isEmpty ? "no findings" : "\(affected.count) page(s) would be rasterized") + scanNote)
        }
        guard !allFindings.isEmpty else {
            return RedactionOutcome(input: url.path, status: .skipped, detail: "no findings" + scanNote)
        }

        for plan in affected {
            guard let page = document.page(at: plan.index) else { continue }
            let replacement = try rasterize(page, plan: plan, scale: options.scale)
            document.removePage(at: plan.index)
            document.insert(replacement, at: plan.index)
        }
        document.documentAttributes = [:]

        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard document.write(to: output) else {
            throw RedactError.unwritable("could not write \(output.lastPathComponent)")
        }
        try verify(output, flattened: affected.map(\.index), options: options)

        let fullPages = affected.filter(\.fullPage).count
        var detail = "\(affected.count) page(s) rasterized; selectable text lost on those pages" + scanNote
        if fullPages > 0 { detail += "; \(fullPages) covered whole (rotated or unlocatable bounds)" }
        return RedactionOutcome(input: url.path, output: output.path,
                                status: .redacted, findings: grouped, detail: detail)
    }

    // MARK: - Checking

    /// The attributes a redacted copy must not carry.
    static let identifyingAttributes: [PDFDocumentAttribute] = [
        .authorAttribute, .titleAttribute, .subjectAttribute, .keywordsAttribute, .creatorAttribute,
    ]

    /// Re-reads a written copy and deletes it unless it is clean: no text on
    /// any flattened page, no identifying attributes, and nothing any rule
    /// still finds in whatever text is left. The idea is PrivacyCam's — PDF
    /// exports "checked for a selectable text layer".
    static func verify(_ output: URL, flattened: [Int], options: Options) throws {
        func refuse(_ why: String) throws -> Never {
            try? FileManager.default.removeItem(at: output)
            throw RedactError.unverified(why)
        }
        guard let written = PDFDocument(url: output) else { try refuse("it could not be reopened") }
        for index in flattened {
            let left = (written.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !left.isEmpty { try refuse("page \(index + 1) still has selectable text") }
        }
        let attributes = written.documentAttributes ?? [:]
        let named = identifyingAttributes.filter { attributes[$0] != nil }
        if !named.isEmpty { try refuse("it still names its \(named.map(\.rawValue).joined(separator: ", "))") }
        let textual = options.types.filter(\.isTextual)
        for index in 0..<written.pageCount {
            let text = written.page(at: index)?.string ?? ""
            if try !PatternRules.findings(in: text, types: textual, customPatterns: options.customPatterns).isEmpty {
                try refuse("page \(index + 1) still has a finding in its text")
            }
        }
    }

    // MARK: - Pixels

    /// A page drawn on white at `scale`, bottom-left origin.
    static func render(_ page: PDFPage, scale: CGFloat) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        guard let context = CGContext(
            data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RedactError.unwritable("could not create a page context") }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw RedactError.unwritable("could not render a page") }
        return image
    }

    /// The page as a picture with its findings painted out.
    private static func rasterize(_ page: PDFPage, plan: PagePlan, scale: CGFloat) throws -> PDFPage {
        let bounds = page.bounds(for: .mediaBox)
        let image = try plan.image ?? render(page, scale: scale)
        let size = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let boxes = plan.fullPage ? [size] : plan.boxes + plan.rects.map { rect in
            CGRect(x: (rect.minX - bounds.minX) * scale, y: (rect.minY - bounds.minY) * scale,
                   width: rect.width * scale, height: rect.height * scale)
        }
        let painted = try Painter.paint(boxes, over: image)
        let nsImage = NSImage(cgImage: painted, size: bounds.size)
        guard let replacement = PDFPage(image: nsImage) else {
            throw RedactError.unwritable("could not rebuild a rasterized page")
        }
        return replacement
    }
}
