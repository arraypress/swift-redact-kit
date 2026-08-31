//
//  ExifStripper.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  Metadata-only redaction: the pixels stay, everything identifying goes.
//  GPS is the classic leak — share a photo, publish your address — but
//  camera serials, owner fields and capture times identify too. The
//  orientation flag is baked into the pixels first so the stripped copy
//  still displays the right way up.
//

import Foundation

/// EXIF/GPS/IPTC stripping with untouched pixels.
public enum ExifStripper {

    /// Strips one image's metadata into a copy at `output`.
    public static func strip(
        imageAt url: URL, keepDates: Bool, to output: URL, dryRun: Bool
    ) throws -> RedactionOutcome {
        let (image, properties) = try ImageIO.loadUpright(url)
        var present = ImageIO.sensitiveMetadata(in: properties)
        if keepDates { present.removeAll { $0 == "capture date" } }

        if dryRun {
            let detail = present.isEmpty
                ? "nothing identifying to strip"
                : "would strip: \(present.joined(separator: ", "))"
            return RedactionOutcome(
                input: url.path, status: present.isEmpty ? .skipped : .wouldRedact,
                findings: present.isEmpty ? [:] : ["metadata": present], detail: detail)
        }
        guard !present.isEmpty else {
            return RedactionOutcome(input: url.path, status: .skipped,
                                    detail: "nothing identifying to strip")
        }
        try ImageIO.write(image, to: output, keepDates: keepDates, from: properties)
        return RedactionOutcome(
            input: url.path, output: output.path, status: .redacted,
            findings: ["metadata": present],
            detail: "stripped: \(present.joined(separator: ", "))")
    }
}
