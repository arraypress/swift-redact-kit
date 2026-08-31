//
//  RedactKitTests.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  Two kinds of pin. The pure rules are checked against hand-computed
//  examples — ICAO 9303's own sample fields, real IBANs, exact redacted
//  strings. The redactors are checked ADVERSARIALLY: every guarantee is
//  verified by trying to recover what was destroyed — re-OCR the image,
//  re-read the metadata, re-extract the PDF text. A redaction test that
//  never attempts recovery tests the paint, not the destruction.
//

import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import RedactKit

final class RedactKitTests: XCTestCase {

    // MARK: - Checksums (hand-computed ICAO 9303 sample fields)

    func testMRZCheckDigits() {
        // Doc 9303's worked example: document number, birth date, expiry.
        XCTAssertEqual(Checksums.mrzCheckDigit("L898902C3"), 6)
        XCTAssertEqual(Checksums.mrzCheckDigit("740812"), 2)
        XCTAssertEqual(Checksums.mrzCheckDigit("120415"), 9)
        XCTAssertNil(Checksums.mrzCheckDigit("bad!"), "Outside the MRZ alphabet is no digit at all")
    }

    func testMRZLineValidation() {
        let line2 = "L898902C36UTO7408122F1204159ZE184226B<<<<<10"
        XCTAssertEqual(line2.count, 44)
        XCTAssertTrue(Checksums.isMRZSecondLine(line2))
        // One corrupted check digit and it is no longer a passport.
        XCTAssertFalse(Checksums.isMRZSecondLine(line2.replacingOccurrences(of: "C36", with: "C37")))
        // The composite (position 43, over 0–9 + 13–19 + 21–42) is
        // checked too: corrupt only it and the line fails.
        XCTAssertFalse(Checksums.isMRZSecondLine(String(line2.dropLast()) + "1"))
        let line1 = "P<UTOERIKSSON<<ANNA<MARIA" + String(repeating: "<", count: 19)
        XCTAssertEqual(line1.count, 44)
        XCTAssertTrue(Checksums.isMRZFirstLine(line1))
        XCTAssertFalse(Checksums.isMRZFirstLine(String(repeating: "A", count: 44)),
                       "44 letters without the P< prefix is not an MRZ")
    }

    func testIBANMod97() {
        XCTAssertTrue(Checksums.isValidIBAN("GB82WEST12345698765432"))
        XCTAssertTrue(Checksums.isValidIBAN("DE89370400440532013000"))
        XCTAssertFalse(Checksums.isValidIBAN("GB82WEST12345698765433"), "One digit off fails mod-97")
        XCTAssertFalse(Checksums.isValidIBAN("GB82"), "Too short to be an IBAN")
    }

    func testIBANLengthRegistryCutsRunOnText() throws {
        // The IBAN is 22 characters; the text runs straight on with three
        // more digits. Without the registry the candidate would be all 25
        // characters, mod-97 would fail, and the IBAN would escape.
        let text = "ref GB82WEST12345698765432123 ok"
        let findings = try PatternRules.findings(in: text, types: [.iban])
        XCTAssertEqual(findings.map(\.type), [.iban])
        XCTAssertEqual(TextRedaction.apply(findings, to: text),
                       "ref [REDACTED-IBAN]123 ok",
                       "The cut lands exactly where the country's length says")
        XCTAssertEqual(Checksums.ibanLength(forCountry: "GB"), 22)
        XCTAssertNil(Checksums.ibanLength(forCountry: "ZZ"))
    }

    // MARK: - Masking

    func testMasking() {
        XCTAssertEqual(Masking.mask("4111111111111111"), "••••1111")
        XCTAssertEqual(Masking.mask("4111 1111 1111 1111"), "••••1111", "Spaces do not widen the tail")
        XCTAssertEqual(Masking.mask("abc123"), "••••••", "Short values are fully masked")
    }

    // MARK: - Pattern rules

    func testFindingsInMixedText() throws {
        let text = """
            Card: 4111 1111 1111 1111 and IBAN GB82WEST12345698765432.
            Reach me at anna@example.com, SSN 078-05-1120.
            L898902C36UTO7408122F1204159ZE184226B<<<<<10
            aws key AKIAIOSFODNN7EXAMPLE ok
            """
        let findings = try PatternRules.findings(
            in: text, types: [.card, .iban, .email, .ssn, .mrz, .secret])
        let types = findings.map(\.type.rawValue).sorted()
        XCTAssertEqual(types, ["card", "email", "iban", "mrz", "secret", "ssn"])
        let card = findings.first { $0.type == .card }
        XCTAssertEqual(card?.masked, "••••1111", "The dry run shows the tail, never the number")
    }

    func testTypeSelectionAndLuhnRejection() throws {
        let text = "not a card: 4111 1111 1111 1112, a mail: a@b.co"
        XCTAssertTrue(try PatternRules.findings(in: text, types: [.card]).isEmpty,
                      "Fails Luhn, so it is not destroyed")
        let onlyEmail = try PatternRules.findings(in: text, types: [.email])
        XCTAssertEqual(onlyEmail.map(\.type), [.email])
    }

    func testPhoneIsOptInAndHeuristic() throws {
        let text = "Call +353 87 123 4567 or quote order 123456789."
        XCTAssertTrue(try PatternRules.findings(in: text, types: [.card, .email]).isEmpty)
        let withPhone = try PatternRules.findings(in: text, types: [.phone])
        XCTAssertEqual(withPhone.count, 1, "The formatted number matches; the bare integer does not")
    }

    func testCustomPatternOutranksAndRejectsBadRegex() throws {
        let found = try PatternRules.findings(
            in: "ticket ACME-1234 closed", types: [], customPatterns: [#"ACME-\d{4}"#])
        XCTAssertEqual(found.map(\.type), [.custom])
        XCTAssertThrowsError(try PatternRules.findings(
            in: "x", types: [], customPatterns: ["("])) { error in
            XCTAssertTrue("\(error)".contains("invalid --pattern"))
        }
    }

    // MARK: - Text redaction (exact strings)

    func testTextRedactionExact() throws {
        let text = "card 4111 1111 1111 1111 mail a@b.co"
        let findings = try PatternRules.findings(in: text, types: [.card, .email])
        XCTAssertEqual(TextRedaction.apply(findings, to: text),
                       "card [REDACTED-CARD] mail [REDACTED-EMAIL]")
    }

    // MARK: - Output naming

    func testOutputNaming() {
        let input = URL(fileURLWithPath: "/data/scans/inbox/doc.pdf")
        XCTAssertEqual(OutputNaming.output(for: input, outDir: nil, root: nil).path,
                       "/data/scans/inbox/doc-redacted.pdf")
        let mirrored = OutputNaming.output(
            for: input, outDir: URL(fileURLWithPath: "/out"),
            root: URL(fileURLWithPath: "/data/scans"))
        XCTAssertEqual(mirrored.path, "/out/inbox/doc-redacted.pdf")
        let forced = OutputNaming.output(for: input, outDir: nil, root: nil, forcedExtension: "png")
        XCTAssertEqual(forced.lastPathComponent, "doc-redacted.png")
    }

    func testSkipRule() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        XCTAssertTrue(OutputNaming.shouldSkip(inputModified: older, outputModified: newer, force: false))
        XCTAssertFalse(OutputNaming.shouldSkip(inputModified: newer, outputModified: older, force: false),
                       "A changed input re-redacts")
        XCTAssertFalse(OutputNaming.shouldSkip(inputModified: older, outputModified: newer, force: true))
        XCTAssertFalse(OutputNaming.shouldSkip(inputModified: older, outputModified: nil, force: false))
    }

    // MARK: - Adversarial: images

    func testImageRedactionSurvivesRecoveryAttempt() throws {
        let dir = try scratch()
        let input = dir.appendingPathComponent("statement.jpg")
        try writeJPEG(makeTextImage(lines: [
            "Invoice from ACME Ltd",
            "Card 4111 1111 1111 1111",
            "Contact anna@example.com",
        ]), to: input, properties: sensitiveEXIF)

        let output = dir.appendingPathComponent("statement-redacted.jpg")
        let outcome = try ImageRedactor.redact(
            imageAt: input, options: .init(types: [.card, .email]),
            to: output, dryRun: false)
        XCTAssertEqual(outcome.status, .redacted)
        XCTAssertEqual(outcome.findings["card"], ["••••1111"])

        // Recovery attempt 1: OCR the output. The card and the address
        // must be gone; the harmless line must survive.
        let recovered = try ocrText(of: output)
        XCTAssertFalse(recovered.contains("4111"), "The card digits must not OCR back")
        XCTAssertFalse(recovered.contains("anna"), "The address must not OCR back")
        XCTAssertTrue(recovered.contains("ACME"), "Unmatched lines stay legible")

        // Recovery attempt 2: read the metadata back. Nothing identifying
        // may survive the re-encode.
        let properties = readProperties(of: output)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil((properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?["Make"])
        XCTAssertNil((properties[kCGImagePropertyExifDictionary as String] as? [String: Any])?[
            kCGImagePropertyExifDateTimeOriginal as String])
    }

    func testImageWithoutFindingsIsSkipped() throws {
        let dir = try scratch()
        let input = dir.appendingPathComponent("clean.png")
        try writeJPEG(makeTextImage(lines: ["Nothing sensitive here"]), to: input, properties: [:])
        let output = dir.appendingPathComponent("clean-redacted.png")
        let outcome = try ImageRedactor.redact(
            imageAt: input, options: .init(), to: output, dryRun: false)
        XCTAssertEqual(outcome.status, .skipped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "No findings, no copy — the batch stays honest")
    }

    // MARK: - Adversarial: EXIF strip

    func testExifStripDestroysMetadataAndBakesOrientation() throws {
        let dir = try scratch()
        let input = dir.appendingPathComponent("photo.jpg")
        var properties = sensitiveEXIF
        properties[kCGImagePropertyOrientation as String] = 6 // 90° CW
        try writeJPEG(makeTextImage(lines: ["hello"], width: 300, height: 100),
                      to: input, properties: properties)

        let output = dir.appendingPathComponent("photo-redacted.jpg")
        let outcome = try ExifStripper.strip(imageAt: input, keepDates: false,
                                             to: output, dryRun: false)
        XCTAssertEqual(outcome.status, .redacted)
        XCTAssertEqual(Set(outcome.findings["metadata"] ?? []),
                       ["GPS", "camera", "serial numbers", "capture date"])

        let out = readProperties(of: output)
        XCTAssertNil(out[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(out[kCGImagePropertyTIFFDictionary as String])
        XCTAssertEqual(out[kCGImagePropertyPixelWidth as String] as? Int, 100,
                       "Orientation 6 is baked into the pixels: width and height swap")
        XCTAssertEqual(out[kCGImagePropertyPixelHeight as String] as? Int, 300)

        // keep-dates keeps exactly the capture date and nothing else.
        let kept = dir.appendingPathComponent("kept-redacted.jpg")
        _ = try ExifStripper.strip(imageAt: input, keepDates: true, to: kept, dryRun: false)
        let keptProperties = readProperties(of: kept)
        XCTAssertEqual((keptProperties[kCGImagePropertyExifDictionary as String] as? [String: Any])?[
            kCGImagePropertyExifDateTimeOriginal as String] as? String, "2026:01:01 10:00:00")
        XCTAssertNil(keptProperties[kCGImagePropertyGPSDictionary as String])
    }

    // MARK: - Adversarial: PDFs

    func testPDFRedactionSurvivesTextExtraction() throws {
        let dir = try scratch()
        let input = dir.appendingPathComponent("report.pdf")
        try makePDF(pages: [
            "Payment with card 4111 1111 1111 1111 confirmed.",
            "Nothing here but ordinary prose.",
        ], to: input)

        let output = dir.appendingPathComponent("report-redacted.pdf")
        let outcome = try PDFRedactor.redact(
            pdfAt: input, options: .init(types: [.card]), to: output, dryRun: false)
        XCTAssertEqual(outcome.status, .redacted)
        XCTAssertEqual(outcome.findings["card"], ["••••1111"])

        // Recovery attempt: extract the text layer back out.
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(reopened.pageCount, 2)
        let page1Text = reopened.page(at: 0)?.string ?? ""
        XCTAssertFalse(page1Text.contains("4111"), "The rasterized page must not carry live text")
        XCTAssertTrue(reopened.page(at: 1)?.string?.contains("ordinary prose") == true,
                      "Untouched pages keep their text layer")
        XCTAssertNil(reopened.documentAttributes?[PDFDocumentAttribute.authorAttribute],
                     "Document metadata goes with the redaction")
    }

    // MARK: - Fixtures

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private var sensitiveEXIF: [String: Any] {
        [
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 53.3498,
                kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 6.2603,
                kCGImagePropertyGPSLongitudeRef as String: "W",
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Apple",
                kCGImagePropertyTIFFModel as String: "iPhone 15 Pro",
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2026:01:01 10:00:00",
                kCGImagePropertyExifBodySerialNumber as String: "SN-12345",
            ],
        ]
    }

    /// A white image with black Menlo lines — deterministic OCR bait.
    private func makeTextImage(lines: [String], width: Int = 1200, height: Int = 500) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 36, nil)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key:
                    CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 40, y: CGFloat(height - 80 - index * 60))
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return context.makeImage()!
    }

    private func writeJPEG(_ image: CGImage, to url: URL, properties: [String: Any]) throws {
        let type = url.pathExtension == "png" ? UTType.png : UTType.jpeg
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func readProperties(of url: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return [:] }
        return properties
    }

    private func ocrText(of url: URL) throws -> String {
        let (image, _) = try ImageIO.loadUpright(url)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// A PDF with one line of REAL text per page — a live text layer, so
    /// the recovery attempt means something.
    private func makePDF(pages: [String], to url: URL) throws {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        var mediaBox = bounds
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, [
            kCGPDFContextAuthor as String: "David Sherlock",
            kCGPDFContextTitle as String: "Fixture",
        ] as CFDictionary)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for text in pages {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(string: text, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key:
                    CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
