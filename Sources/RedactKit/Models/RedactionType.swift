//
//  RedactionType.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  The kinds of sensitive value this tool knows how to find. The vocabulary
//  only — how each one is detected lives in Support/PatternRules, and the
//  check digits that separate a card number from eleven digits of phone
//  number live in Support/Checksums.
//

import Foundation

/// A kind of sensitive value.
public enum RedactionType: String, CaseIterable, Codable, Sendable {
    /// A payment card number that passes its Luhn check and length rules.
    case card
    /// A passport machine-readable zone line (ICAO 9303 TD3).
    case mrz
    /// An IBAN that passes its mod-97 check.
    case iban
    /// An email address.
    case email
    /// A phone number. Heuristic and false-positive-prone, so callers opt in.
    case phone
    /// A US Social Security number in dashed form.
    case ssn
    /// An API key, token or credential, via the secret scanner's catalogue.
    case secret
    /// A caller-supplied pattern.
    case custom
    /// A barcode or QR code in an image or on a page. Found by Vision, not
    /// by reading text, and never reported by its payload — a boarding
    /// pass's code IS the passenger's name and booking. The idea is
    /// PrivacyCam's.
    case barcode

    /// The replacement written into redacted text: `[REDACTED-CARD]`.
    public var replacement: String { "[REDACTED-\(rawValue.uppercased())]" }

    /// The default set: everything except `phone`, which cries wolf on
    /// invoice numbers and IDs, and `custom`, which needs a pattern.
    public static let defaults: Set<RedactionType> =
        [.card, .mrz, .iban, .email, .ssn, .secret, .barcode]

    /// Whether finding this kind means reading text.
    public var isTextual: Bool { self != .barcode }
}
