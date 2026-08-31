//
//  TextRedaction.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  Destroying findings in text. Replacement runs back-to-front so earlier
//  ranges stay valid, and the output carries `[REDACTED-CARD]` markers —
//  a reader should know something was removed and what kind; hiding the
//  hole is how redactions get missed in review.
//

import Foundation

/// Applying findings to text.
public enum TextRedaction {

    /// `text` with every finding replaced by its type's marker.
    public static func apply(_ findings: [TextFinding], to text: String) -> String {
        let mutable = NSMutableString(string: text)
        for finding in findings.sorted(by: { $0.range.location > $1.range.location }) {
            mutable.replaceCharacters(in: finding.range, with: finding.type.replacement)
        }
        return mutable as String
    }
}
