//
//  Masking.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  How a finding is shown without being leaked. A dry run has to tell the
//  user WHICH card was found — `••••1111` does that; printing the number
//  would make the redaction tool the leak.
//

import Foundation

/// Masked presentation of sensitive values.
public enum Masking {

    /// The value with only its last characters visible: `••••1111`.
    ///
    /// Values too short to keep a tail safely are fully masked — showing
    /// four of six characters is most of the secret.
    public static func mask(_ value: String, keepingLast keep: Int = 4) -> String {
        let trimmed = value.replacingOccurrences(of: " ", with: "")
        guard trimmed.count > keep * 2 else {
            return String(repeating: "•", count: max(trimmed.count, 4))
        }
        return "••••" + trimmed.suffix(keep)
    }
}
