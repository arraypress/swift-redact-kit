//
//  TextFinding.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  One sensitive value found in text: what kind, where, and a masked form
//  safe to show. The raw value is deliberately NOT stored — a redaction
//  tool that carries the secrets it found around in its own reports has
//  misunderstood its job. The range is enough to destroy it.
//

import Foundation

/// One sensitive value located in a piece of text.
public struct TextFinding: Equatable, Sendable {
    /// What kind of value matched.
    public let type: RedactionType
    /// Where it sits in the scanned text, in UTF-16 units.
    public let range: NSRange
    /// The value with its tail visible and the rest hidden: `••••1111`.
    public let masked: String

    public init(type: RedactionType, range: NSRange, masked: String) {
        self.type = type
        self.range = range
        self.masked = masked
    }
}
