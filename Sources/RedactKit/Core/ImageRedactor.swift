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

        // OCR the upright pixels; boxes come back in the same space they
        // will be painted in.
        var boxes: [CGRect] = []
        var findings: [TextFinding] = []
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let found = try PatternRules.findings(
                in: candidate.string, types: options.types,
                customPatterns: options.customPatterns)
            guard !found.isEmpty else { continue }
            findings.append(contentsOf: found)
            let box = observation.boundingBox
            boxes.append(CGRect(
                x: box.origin.x * CGFloat(image.width),
                y: box.origin.y * CGFloat(image.height),
                width: box.width * CGFloat(image.width),
                height: box.height * CGFloat(image.height)
            ).insetBy(dx: -options.padding, dy: -options.padding))
        }

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
