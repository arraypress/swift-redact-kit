//
//  VisualScan.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  Sensitive things found by looking rather than reading: text recognised
//  in pixels and checked against the same rules as a text layer, and
//  barcodes. One pass shared by images and by PDF pages that are pictures
//  — a scanned page used to have no text layer to read, so a card number
//  on it went through untouched.
//

import CoreGraphics
import Foundation
import Vision

/// Finds sensitive text and barcodes in an image.
enum VisualScan {

    /// What was found, and where to paint.
    struct Result {
        var findings: [TextFinding] = []
        /// Boxes in pixels, bottom-left origin — a Core Graphics context's
        /// own space, so they can be filled without conversion.
        var boxes: [CGRect] = []
    }

    /// Everything to destroy in an image.
    ///
    /// - Parameters:
    ///   - image: The pixels, upright.
    ///   - types: What to look for; text recognition runs only when a
    ///     textual type is asked for, barcode detection only for `.barcode`.
    ///   - customPatterns: Caller patterns.
    ///   - padding: How far to grow each box, in pixels.
    /// - Returns: The findings, masked, and their boxes.
    static func scan(_ image: CGImage, types: Set<RedactionType>, customPatterns: [String],
                     padding: CGFloat) throws -> Result {
        var result = Result()
        let size = CGSize(width: image.width, height: image.height)
        func pixels(_ box: CGRect) -> CGRect {
            CGRect(x: box.origin.x * size.width, y: box.origin.y * size.height,
                   width: box.width * size.width, height: box.height * size.height)
                .insetBy(dx: -padding, dy: -padding)
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        if types.contains(where: \.isTextual) || !customPatterns.isEmpty {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try handler.perform([request])
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let found = try PatternRules.findings(in: candidate.string, types: types,
                                                      customPatterns: customPatterns)
                guard !found.isEmpty else { continue }
                result.findings += found
                result.boxes.append(pixels(observation.boundingBox))
            }
        }
        if types.contains(.barcode) {
            let request = VNDetectBarcodesRequest()
            try handler.perform([request])
            for observation in request.results ?? [] {
                result.findings.append(TextFinding(
                    type: .barcode, range: NSRange(location: 0, length: 0),
                    masked: "\(symbologyName(observation.symbology)) ••••"))
                result.boxes.append(pixels(observation.boundingBox))
            }
        }
        return result
    }

    /// "QR", "EAN-13", "PDF417" — the kind, never the payload.
    static func symbologyName(_ symbology: VNBarcodeSymbology) -> String {
        symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
    }
}
