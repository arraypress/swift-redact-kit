//
//  RedactionOutcome.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  What happened to one file — the ledger entry a batch reports. Findings
//  are carried masked; the raw values never leave the redactors.
//

import Foundation

/// What happened to one file.
public struct RedactionOutcome: Codable, Sendable {

    /// The terminal states a file can reach.
    public enum Status: String, Codable, Sendable {
        /// Findings were located and destroyed in the output copy.
        case redacted
        /// A dry run: findings located, nothing written.
        case wouldRedact = "would-redact"
        /// Nothing sensitive found (or output already current); no copy written.
        case skipped
        /// The file could not be processed.
        case failed
    }

    /// The input file's path.
    public let input: String
    /// The written copy's path, when one was written.
    public let output: String?
    /// The terminal state.
    public let status: Status
    /// Masked findings by kind: `["card": ["••••1111"]]`.
    public let findings: [String: [String]]
    /// A human note — what was stripped, why a file was skipped.
    public let detail: String?

    /// How many values were found across all kinds.
    public var found: Int { findings.values.reduce(0) { $0 + $1.count } }

    public init(input: String, output: String? = nil, status: Status,
                findings: [String: [String]] = [:], detail: String? = nil) {
        self.input = input
        self.output = output
        self.status = status
        self.findings = findings
        self.detail = detail
    }

    /// Findings grouped for the ledger: masked values keyed by type name.
    public static func grouped(_ findings: [TextFinding]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for finding in findings {
            out[finding.type.rawValue, default: []].append(finding.masked)
        }
        return out
    }
}
