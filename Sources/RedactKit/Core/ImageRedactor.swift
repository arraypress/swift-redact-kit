//
//  ImageRedactor.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  One image, redacted: OCR the pixels, find the sensitive lines, paint
//  them out with OPAQUE boxes, re-encode without metadata. Opaque, not
//  blurred — a blur can be reversed and this tool's one promise is that
//  it cannot. The whole recognized line is covered, not just the match:
//  over-covering by a few words is safe, under-covering by a digit is not.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Text redaction on still images.
public enum ImageRedactor {

    /// How an image redaction behaves.
    public struct Options: Sendable {
        /// Which kinds of value to destroy.
        public var types: Set<RedactionType>
        /// Caller-supplied regular expressions.
        public var customPatterns: [String]
        /// Whether the EXIF capture date survives into the copy.
        public var keepDates: Bool
        /// Pixels of margin painted around each recognized line.
        public var padding: CGFloat

        public init(types: Set<RedactionType> = RedactionType.defaults,
                    customPatterns: [String] = [],
                    keepDates: Bool = false,
                    padding: CGFloat = 6) {
            self.types = types
            self.customPatterns = customPatterns
            self.keepDates = keepDates
            self.padding = padding
        }
    }

    /// Redacts one image to `output` (or only reports, when `dryRun`).
    ///
    /// The copy is re-encoded from pixels, so EXIF, GPS, IPTC and XMP are
    /// gone regardless of findings — the metadata IS sensitive content.
    public static func redact(
        imageAt url: URL, options: Options, to output: URL, dryRun: Bool
    ) throws -> RedactionOutcome {
        let (image, sourceProperties) = try ImageIO.loadUpright(url)

        // Read and look at the upright pixels; boxes come back in the same
        // space they will be painted in.
        let scan = try VisualScan.scan(image, types: options.types, customPatterns: options.customPatterns,
                                       padding: options.padding)
        let findings = scan.findings, boxes = scan.boxes

        let grouped = RedactionOutcome.grouped(findings)
        let stripped = ImageIO.sensitiveMetadata(in: sourceProperties)
        let detail = stripped.isEmpty
            ? "metadata: nothing sensitive present"
            : "metadata stripped: \(stripped.joined(separator: ", "))"

        if dryRun {
            // A dry run mirrors the real run's decision: no findings, no
            // copy — so the honest status is "skipped", not "would".
            return RedactionOutcome(input: url.path,
                                    status: findings.isEmpty ? .skipped : .wouldRedact,
                                    findings: grouped, detail: detail)
        }
        guard !findings.isEmpty else {
            return RedactionOutcome(input: url.path, status: .skipped,
                                    findings: [:], detail: "no findings; " + detail)
        }

        let painted = try Painter.paint(boxes, over: image)
        try ImageIO.write(painted, to: output,
                          keepDates: options.keepDates, from: sourceProperties)
        // Checked, not assumed: re-read the copy and refuse one that still
        // says where, with what or when it was taken.
        let left = ImageIO.sensitiveMetadata(in: ImageIO.properties(of: output))
            .filter { !(options.keepDates && $0 == "capture date") }
        guard left.isEmpty else {
            try? FileManager.default.removeItem(at: output)
            throw RedactError.unverified("\(output.lastPathComponent) still carried \(left.joined(separator: ", "))")
        }
        return RedactionOutcome(input: url.path, output: output.path,
                                status: .redacted, findings: grouped, detail: detail)
    }
}

/// Opaque boxes over pixels.
enum Painter {

    /// `image` with solid black rectangles burned in.
    static func paint(_ boxes: [CGRect], over image: CGImage) throws -> CGImage {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RedactError.unwritable("could not create a drawing context") }
        let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: frame)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for box in boxes {
            context.fill(box.intersection(frame))
        }
        guard let out = context.makeImage() else {
            throw RedactError.unwritable("could not rasterize the redacted image")
        }
        return out
    }
}
