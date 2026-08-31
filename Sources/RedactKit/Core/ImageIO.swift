//
//  ImageIO.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  Reading and writing stills for redaction. Orientation is baked into the
//  pixels on load — a stripped copy must not carry the orientation flag it
//  no longer has, and covers must land where the eye sees the text. Writes
//  attach NO source metadata unless the caller keeps the capture date.
//

import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Still image reading and writing, metadata-aware.
public enum ImageIO {

    /// The image with orientation baked into the pixels, plus the source's
    /// property dictionary for metadata reporting.
    static func loadUpright(_ url: URL) throws -> (CGImage, [String: Any]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw RedactError.unreadable("\(url.lastPathComponent) is not a readable image")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [String: Any] ?? [:]
        guard let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              let upright = CIContext().createCGImage(ci, from: ci.extent) else {
            throw RedactError.unreadable("could not decode \(url.lastPathComponent)")
        }
        return (upright, properties)
    }

    /// The identifying metadata present in a property dictionary, named for
    /// the ledger: what the strip is about to destroy.
    static func sensitiveMetadata(in properties: [String: Any]) -> [String] {
        var found: [String] = []
        if properties[kCGImagePropertyGPSDictionary as String] != nil { found.append("GPS") }
        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            if tiff[kCGImagePropertyTIFFMake as String] != nil
                || tiff[kCGImagePropertyTIFFModel as String] != nil { found.append("camera") }
        }
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if exif[kCGImagePropertyExifBodySerialNumber as String] != nil
                || exif[kCGImagePropertyExifLensSerialNumber as String] != nil {
                found.append("serial numbers")
            }
            if exif[kCGImagePropertyExifDateTimeOriginal as String] != nil {
                found.append("capture date")
            }
        }
        if properties[kCGImagePropertyIPTCDictionary as String] != nil { found.append("IPTC") }
        return found
    }

    /// The source's capture date, when it has one.
    static func captureDate(in properties: [String: Any]) -> String? {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        return exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String
    }

    /// Writes pixels to `output` with no source metadata — except, when
    /// asked, the capture date alone.
    static func write(_ image: CGImage, to output: URL,
                      keepDates: Bool, from sourceProperties: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let type = destinationType(for: output.pathExtension)
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, type as CFString, 1, nil) else {
            throw RedactError.unwritable("could not create \(output.lastPathComponent)")
        }
        var properties: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: 0.92,
        ]
        if keepDates, let date = captureDate(in: sourceProperties) {
            properties[kCGImagePropertyExifDictionary as String] =
                [kCGImagePropertyExifDateTimeOriginal as String: date]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RedactError.unwritable("could not encode \(output.lastPathComponent)")
        }
    }

    /// The UTI to encode as, from the output's extension; PNG when the
    /// extension names no encodable type on this system.
    static func destinationType(for ext: String) -> String {
        guard let type = UTType(filenameExtension: ext.lowercased()),
              let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String],
              identifiers.contains(type.identifier) else {
            return UTType.png.identifier
        }
        return type.identifier
    }

    /// Whether this system can encode the given extension at all — the
    /// caller falls back to PNG (and says so) when it cannot.
    public static func canEncode(_ ext: String) -> Bool {
        guard let type = UTType(filenameExtension: ext.lowercased()),
              let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] else {
            return false
        }
        return identifiers.contains(type.identifier)
    }
}
