//
//  PatternRules.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  Finding the sensitive values in a piece of text. Every rule is a
//  candidate pattern plus a verification — a Luhn check, a mod-97, real
//  MRZ check digits — because "looks like a card number" is not grounds
//  for destruction, and a missed verification in the other direction is
//  a leak. Overlaps resolve by priority: one span of text is one finding.
//

import CreditCardValidator
import Foundation
import SecretScanner

/// The detection rules, as one pure entry point.
public enum PatternRules {

    /// Every sensitive value in `text`, verified, non-overlapping, in
    /// document order.
    ///
    /// - Parameters:
    ///   - text: What to scan.
    ///   - types: Which kinds to look for. ``RedactionType/custom`` is
    ///     implied whenever `customPatterns` is non-empty.
    ///   - customPatterns: Caller-supplied regular expressions.
    /// - Throws: ``RedactError/usage(_:)`` for an invalid custom pattern.
    public static func findings(
        in text: String,
        types: Set<RedactionType> = RedactionType.defaults,
        customPatterns: [String] = []
    ) throws -> [TextFinding] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var candidates: [(priority: Int, finding: TextFinding)] = []

        func regex(_ pattern: String) -> NSRegularExpression {
            // The built-in patterns are constants; a failure here is a
            // programming error, not an input error.
            try! NSRegularExpression(pattern: pattern)
        }
        func matches(_ pattern: String) -> [NSRange] {
            regex(pattern).matches(in: text, range: full).map(\.range)
        }

        // Custom patterns outrank the built-ins: the caller has said,
        // explicitly, that this shape is sensitive here.
        for pattern in customPatterns {
            guard let compiled = try? NSRegularExpression(pattern: pattern) else {
                throw RedactError.usage("invalid --pattern: \(pattern)")
            }
            for match in compiled.matches(in: text, range: full) {
                candidates.append((0, TextFinding(
                    type: .custom, range: match.range,
                    masked: Masking.mask(ns.substring(with: match.range)))))
            }
        }

        if types.contains(.card) {
            for range in matches(#"(?<![\d])\d(?:[ \-]?\d){11,18}(?![\d])"#) {
                let digits = ns.substring(with: range).filter(\.isNumber)
                guard (12...19).contains(digits.count),
                      CreditCardValidator.validate(digits) else { continue }
                candidates.append((1, TextFinding(
                    type: .card, range: range, masked: Masking.mask(digits))))
            }
        }

        if types.contains(.iban) {
            // No trailing boundary: text can run straight on after an
            // IBAN, and the country's registered length — not the end of
            // the alphanumeric run — says where the IBAN stops.
            for match in matches(#"(?<![A-Z0-9])[A-Z]{2}\d{2}[A-Z0-9]{11,30}"#) {
                var range = match
                var candidate = ns.substring(with: range)
                if let expected = Checksums.ibanLength(forCountry: String(candidate.prefix(2))),
                   candidate.count > expected {
                    candidate = String(candidate.prefix(expected))
                    range = NSRange(location: range.location,
                                    length: (candidate as NSString).length)
                }
                guard Checksums.isValidIBAN(candidate) else { continue }
                candidates.append((2, TextFinding(
                    type: .iban, range: range, masked: Masking.mask(candidate))))
            }
        }

        if types.contains(.mrz) {
            for range in matches(#"(?<![A-Z0-9<])[A-Z0-9<]{44}(?![A-Z0-9<])"#) {
                let line = ns.substring(with: range)
                guard Checksums.isMRZFirstLine(line) || Checksums.isMRZSecondLine(line)
                else { continue }
                candidates.append((3, TextFinding(
                    type: .mrz, range: range, masked: "MRZ line (44 chars)")))
            }
        }

        if types.contains(.ssn) {
            for range in matches(#"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)"#) {
                candidates.append((4, TextFinding(
                    type: .ssn, range: range,
                    masked: Masking.mask(ns.substring(with: range)))))
            }
        }

        if types.contains(.secret) {
            // The scanner's generic assignment rules cry wolf on prose;
            // the named catalogue at medium severity and up is the useful
            // slice for redaction.
            let scanner = SecretScanner(generic: false, minimumSeverity: .medium)
            for found in scanner.scan(text) {
                var search = full
                while true {
                    let hit = ns.range(of: found.secret, options: [], range: search)
                    guard hit.location != NSNotFound else { break }
                    candidates.append((5, TextFinding(
                        type: .secret, range: hit, masked: found.masked)))
                    let next = hit.location + hit.length
                    guard next < ns.length else { break }
                    search = NSRange(location: next, length: ns.length - next)
                }
            }
        }

        if types.contains(.email) {
            for range in matches(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#) {
                candidates.append((6, TextFinding(
                    type: .email, range: range,
                    masked: Masking.mask(ns.substring(with: range)))))
            }
        }

        if types.contains(.phone) {
            for range in matches(#"(?<![\d+])(?:\+\d{1,3}[ .\-]?)?(?:\(\d{1,4}\)[ .\-]?)?\d(?:[ .\-]?\d){6,12}(?![\d])"#) {
                let value = ns.substring(with: range)
                let digits = value.filter(\.isNumber)
                // A bare run of digits is an order number as often as a
                // phone; demand international form or visible formatting.
                guard (8...15).contains(digits.count),
                      value.contains("+") || value.rangeOfCharacter(from: CharacterSet(charactersIn: " .-()")) != nil
                else { continue }
                candidates.append((7, TextFinding(
                    type: .phone, range: range, masked: Masking.mask(digits))))
            }
        }

        // One span, one finding: priority wins, then document order.
        var taken: [NSRange] = []
        var out: [TextFinding] = []
        for candidate in candidates.sorted(by: {
            $0.priority != $1.priority ? $0.priority < $1.priority
                : $0.finding.range.location < $1.finding.range.location
        }) {
            let range = candidate.finding.range
            guard !taken.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
            taken.append(range)
            out.append(candidate.finding)
        }
        return out.sorted { $0.range.location < $1.range.location }
    }
}
