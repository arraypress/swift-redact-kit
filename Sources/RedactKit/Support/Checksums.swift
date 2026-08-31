//
//  Checksums.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  The arithmetic that separates a sensitive value from a lookalike: the
//  ICAO 9303 7-3-1 check digit that passports carry, and the mod-97 check
//  that IBANs carry. Pure functions, pinned to hand-computed examples in
//  the tests — a redaction tool must not guess about what it destroys,
//  and must not destroy what merely looks the part.
//

import Foundation

/// Document check-digit arithmetic.
public enum Checksums {

    // MARK: - ICAO 9303 (passport MRZ)

    /// The 7-3-1 check digit over an MRZ field.
    ///
    /// Digits count as themselves, `A`–`Z` as 10–35, the filler `<` as 0;
    /// weights cycle 7, 3, 1. `nil` for characters outside the MRZ alphabet.
    public static func mrzCheckDigit(_ field: String) -> Int? {
        let weights = [7, 3, 1]
        var sum = 0
        for (index, character) in field.enumerated() {
            let value: Int
            switch character {
            case "0"..."9": value = Int(String(character))!
            case "A"..."Z": value = Int(character.asciiValue! - Character("A").asciiValue!) + 10
            case "<": value = 0
            default: return nil
            }
            sum += value * weights[index % 3]
        }
        return sum % 10
    }

    /// Whether a 44-character line is a valid TD3 MRZ second line.
    ///
    /// Three of the line's own check digits must hold: the document number
    /// (positions 0–8, check at 9), the birth date (13–18, check at 19) and
    /// the expiry date (21–26, check at 27). Three passing checks on one
    /// line is not a coincidence — it is a passport.
    public static func isMRZSecondLine(_ line: String) -> Bool {
        guard line.count == 44 else { return false }
        let chars = Array(line)
        guard chars.allSatisfy({ $0 == "<" || ($0 >= "A" && $0 <= "Z") || $0.isNumber }) else {
            return false
        }
        func field(_ range: ClosedRange<Int>) -> String { String(chars[range]) }
        func digit(_ index: Int) -> Int? { chars[index].isNumber ? Int(String(chars[index])) : nil }
        guard let documentCheck = digit(9), let birthCheck = digit(19),
              let expiryCheck = digit(27), let compositeCheck = digit(43)
        else { return false }
        // The final composite runs over the document block, the birth
        // block and the expiry-through-personal block (0–9, 13–19,
        // 21–42), checked at 43 — four passing checks is a passport.
        let composite = field(0...9) + field(13...19) + field(21...42)
        return mrzCheckDigit(field(0...8)) == documentCheck
            && mrzCheckDigit(field(13...18)) == birthCheck
            && mrzCheckDigit(field(21...26)) == expiryCheck
            && mrzCheckDigit(composite) == compositeCheck
    }

    /// Whether a 44-character line is a TD3 MRZ first line: `P<` then the
    /// issuing state and the `SURNAME<<GIVEN<NAMES` field, filler-padded.
    public static func isMRZFirstLine(_ line: String) -> Bool {
        guard line.count == 44, line.hasPrefix("P<") else { return false }
        return line.allSatisfy { $0 == "<" || ($0 >= "A" && $0 <= "Z") || $0.isNumber }
    }

    // MARK: - IBAN (mod 97)

    /// Registry of IBAN lengths by country code.
    ///
    /// An IBAN embedded in running text has no delimiter to say where it
    /// ENDS — `GB82…5432123` hides a valid 22-character IBAN inside 25
    /// characters of alphanumerics. The country prefix names the exact
    /// length, so a candidate can be cut where the IBAN actually stops.
    public static func ibanLength(forCountry code: String) -> Int? {
        let lengths: [String: Int] = [
            "AD": 24, "AE": 23, "AL": 28, "AT": 20, "BE": 16, "BG": 22,
            "CH": 21, "CY": 28, "CZ": 24, "DE": 22, "DK": 18, "EE": 20,
            "ES": 24, "FI": 18, "FR": 27, "GB": 22, "GR": 27, "HR": 21,
            "HU": 28, "IE": 22, "IS": 26, "IT": 27, "LI": 21, "LT": 20,
            "LU": 20, "LV": 21, "MC": 27, "MT": 31, "NL": 18, "NO": 15,
            "PL": 28, "PT": 25, "RO": 24, "SE": 24, "SI": 19, "SK": 24,
        ]
        return lengths[code]
    }

    /// Whether a candidate passes ISO 13616's mod-97 check.
    ///
    /// The first four characters move to the end, letters become two-digit
    /// numbers (A=10 … Z=35), and the whole number must leave remainder 1
    /// modulo 97 — computed incrementally, because an IBAN overflows Int.
    public static func isValidIBAN(_ candidate: String) -> Bool {
        guard (15...34).contains(candidate.count) else { return false }
        let rearranged = candidate.dropFirst(4) + candidate.prefix(4)
        var remainder = 0
        for character in rearranged {
            let piece: String
            switch character {
            case "0"..."9": piece = String(character)
            case "A"..."Z": piece = String(Int(character.asciiValue! - Character("A").asciiValue!) + 10)
            default: return false
            }
            for digit in piece {
                remainder = (remainder * 10 + Int(String(digit))!) % 97
            }
        }
        return remainder == 1
    }
}
