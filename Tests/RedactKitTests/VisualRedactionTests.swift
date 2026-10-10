//
//  VisualRedactionTests.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  What used to get through: a card number on a SCANNED page (no text
//  layer, so nothing was read), and barcodes, which no text rule can see.
//  Checked the same adversarial way as the rest — re-OCR the output, look
//  for the code again, re-read the text layer — and the copy's own check
//  is made to refuse a file it should refuse.
//

import CoreImage
import CoreText
import PDFKit
import Vision
import XCTest
@testable import RedactKit

final class VisualRedactionTests: XCTestCase {

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("redact-visual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A white page image with black text lines and, optionally, a QR code.
    private func pageImage(lines: [String], qr: String? = nil, width: Int = 1224, height: Int = 1584) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 40, nil)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0, green: 0, blue: 0, alpha: 1)])
            context.textPosition = CGPoint(x: 80, y: CGFloat(height - 160 - index * 80))
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        if let qr {
            let filter = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data(qr.utf8)])!
            let code = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
            let rendered = CIContext().createCGImage(code, from: code.extent)!
            context.interpolationQuality = .none
            context.draw(rendered, in: CGRect(x: 80, y: 200, width: rendered.width, height: rendered.height))
        }
        return context.makeImage()!
    }

    private func codes(in image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    private func ocr(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// A PDF whose single page is only a picture — what a scanner makes.
    private func scannedPDF(_ image: CGImage, to url: URL) throws {
        let document = PDFDocument()
        document.insert(PDFPage(image: NSImage(cgImage: image, size: NSSize(width: 612, height: 792)))!, at: 0)
        XCTAssertTrue(document.write(to: url))
    }

    // MARK: - Scanned pages

    func testACardOnAScannedPageIsFoundAndDestroyed() throws {
        let dir = try scratch()
        let input = dir.appendingPathComponent("scan.pdf")
        try scannedPDF(pageImage(lines: ["Statement for ACME Ltd", "Card 4111 1111 1111 1111"]), to: input)
        XCTAssertEqual(PDFDocument(url: input)?.page(at: 0)?.string ?? "", "", "the fixture has no text layer")

        let output = dir.appendingPathComponent("scan-redacted.pdf")
        let outcome = try PDFRedactor.redact(pdfAt: input, options: .init(types: [.card]), to: output, dryRun: false)
        XCTAssertEqual(outcome.status, .redacted)
        XCTAssertEqual(outcome.findings["card"], ["••••1111"])
        XCTAssertTrue(outcome.detail?.contains("scanned") == true)

        // Recovery: render the redacted page and read it again.
        let page = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
        let recovered = try ocr(PDFRedactor.render(page, scale: 2))
        XCTAssertFalse(recovered.contains("4111"), "the card digits must not OCR back")
        XCTAssertTrue(recovered.contains("ACME"), "unmatched lines stay legible")
    }

    // MARK: - Barcodes

    func testAQRCodeInAnImageIsCoveredAndNeverPrinted() throws {
        let dir = try scratch()
        let input = dir.appendingPathComponent("pass.png")
        let image = pageImage(lines: ["Boarding pass"], qr: "M1SMITH/ANNA EABC123 DUBLHRAA 0123")
        XCTAssertEqual(try codes(in: image), ["M1SMITH/ANNA EABC123 DUBLHRAA 0123"], "the fixture's code reads")
        let destination = CGImageDestinationCreateWithURL(input as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let output = dir.appendingPathComponent("pass-redacted.png")
        let outcome = try ImageRedactor.redact(imageAt: input, options: .init(), to: output, dryRun: false)
        XCTAssertEqual(outcome.status, .redacted)
        XCTAssertEqual(outcome.findings["barcode"], ["QR ••••"])
        XCTAssertFalse(String(describing: outcome).contains("SMITH"), "the payload is never reported")

        let (redacted, _) = try ImageIO.loadUpright(output)
        XCTAssertEqual(try codes(in: redacted), [], "the code must not scan back")
    }

    func testBarcodesCanBeLeftAlone() throws {
        let dir = try scratch()
        let input = dir.appendingPathComponent("pass.png")
        let destination = CGImageDestinationCreateWithURL(input as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, pageImage(lines: ["Boarding pass"], qr: "hello"), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let outcome = try ImageRedactor.redact(imageAt: input, options: .init(types: [.card]),
                                               to: dir.appendingPathComponent("out.png"), dryRun: false)
        XCTAssertEqual(outcome.status, .skipped)
    }

    func testAQRCodeOnATextPageIsFound() throws {
        let dir = try scratch()
        let input = dir.appendingPathComponent("ticket.pdf")
        // A page with a real text layer AND a code drawn on it.
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(input as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Your ticket for the 18:05 to Galway, platform 4", attributes: [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 16, nil)]))
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        let qr = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data("TICKET-778812".utf8)])!.outputImage!
            .transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        context.interpolationQuality = .none
        context.draw(CIContext().createCGImage(qr, from: qr.extent)!, in: CGRect(x: 72, y: 400, width: 150, height: 150))
        context.endPDFPage()
        context.closePDF()

        let output = dir.appendingPathComponent("ticket-redacted.pdf")
        let outcome = try PDFRedactor.redact(pdfAt: input, options: .init(), to: output, dryRun: false)
        XCTAssertEqual(outcome.findings["barcode"], ["QR ••••"])
        let page = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
        XCTAssertEqual(try codes(in: PDFRedactor.render(page, scale: 2)), [])
    }

    // MARK: - The copy's own check

    func testTheCheckRefusesAFlattenedPageThatStillHasText() throws {
        let dir = try scratch()
        let url = dir.appendingPathComponent("leaky.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "still here", attributes: [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 16, nil)])), context)
        context.endPDFPage()
        context.closePDF()

        XCTAssertThrowsError(try PDFRedactor.verify(url, flattened: [0], options: .init())) { error in
            guard case RedactError.unverified = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a copy that fails is deleted")
    }

    func testTheCheckRefusesACopyThatStillNamesItsAuthor() throws {
        let dir = try scratch()
        let url = dir.appendingPathComponent("named.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextAuthor as String: "Anna Smith"] as CFDictionary)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        XCTAssertThrowsError(try PDFRedactor.verify(url, flattened: [], options: .init()))
    }
}
