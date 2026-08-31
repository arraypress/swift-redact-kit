//
//  TextFileRedactor.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  The trivial case done properly: find, replace with typed markers, and
//  write a copy — never the original.
//

import Foundation

/// Text redaction on plain-text files.
public enum TextFileRedactor {

    /// Redacts one text file to `output` (or only reports, when `dryRun`).
    public static func redact(
        fileAt url: URL,
        types: Set<RedactionType>,
        customPatterns: [String],
        to output: URL,
        dryRun: Bool
    ) throws -> RedactionOutcome {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw RedactError.unreadable("\(url.lastPathComponent) is not UTF-8 text")
        }
        let findings = try PatternRules.findings(
            in: text, types: types, customPatterns: customPatterns)
        let grouped = RedactionOutcome.grouped(findings)

        if dryRun {
            return RedactionOutcome(input: url.path,
                                    status: findings.isEmpty ? .skipped : .wouldRedact,
                                    findings: grouped)
        }
        guard !findings.isEmpty else {
            return RedactionOutcome(input: url.path, status: .skipped,
                                    detail: "no findings")
        }
        let redacted = TextRedaction.apply(findings, to: text)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try redacted.write(to: output, atomically: true, encoding: .utf8)
        return RedactionOutcome(input: url.path, output: output.path,
                                status: .redacted, findings: grouped)
    }
}
