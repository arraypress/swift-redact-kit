//
//  RedactError.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  What can go wrong, in words a person can act on.
//

import Foundation

/// A failure the kit can name.
public enum RedactError: Error, CustomStringConvertible, Sendable {
    /// A file could not be read in the expected format.
    case unreadable(String)
    /// A file could not be written.
    case unwritable(String)
    /// The caller asked for something that cannot be done.
    case usage(String)
    /// The copy was written but failed its own check — something that
    /// should have gone was still in it — so it was deleted.
    case unverified(String)

    public var description: String {
        switch self {
        case .unreadable(let detail): return "could not read: \(detail)"
        case .unwritable(let detail): return "could not write: \(detail)"
        case .usage(let detail): return detail
        case .unverified(let detail): return "the redacted copy failed its check and was deleted: \(detail)"
        }
    }
}

extension RedactError: LocalizedError {
    /// The same words everywhere: a ledger that renders
    /// "The operation couldn't be completed" has hidden the reason.
    public var errorDescription: String? { description }
}
