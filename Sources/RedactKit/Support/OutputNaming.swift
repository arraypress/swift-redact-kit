//
//  OutputNaming.swift
//  RedactKit
//
//  Created by David Sherlock on 2026.
//
//  Where a redacted copy goes and whether the work is already done — the
//  batch's safety rules as pure functions. Never in place: a redaction
//  tool that can overwrite the original can destroy the one copy of a
//  document, which is a different kind of destruction than the job asks.
//

import Foundation

/// Output placement and skip rules.
public enum OutputNaming {

    /// The redacted copy's URL: `name-redacted.ext` beside the input, or
    /// mirrored under `outDir` relative to `root`.
    ///
    /// - Parameter forcedExtension: Overrides the input's extension, for
    ///   formats that cannot be written back (an AVIF in, a PNG out).
    public static func output(
        for input: URL, outDir: URL?, root: URL?, forcedExtension: String? = nil
    ) -> URL {
        let ext = forcedExtension ?? input.pathExtension.lowercased()
        let name = input.deletingPathExtension().lastPathComponent + "-redacted"
        if let outDir {
            var relativeDir = ""
            if let root {
                let rootPath = root.standardizedFileURL.path
                let parent = input.deletingLastPathComponent().standardizedFileURL.path
                if parent.hasPrefix(rootPath), parent != rootPath {
                    relativeDir = String(parent.dropFirst(rootPath.count + 1))
                }
            }
            let dir = relativeDir.isEmpty ? outDir : outDir.appendingPathComponent(relativeDir)
            return dir.appendingPathComponent(name).appendingPathExtension(ext)
        }
        return input.deletingLastPathComponent()
            .appendingPathComponent(name).appendingPathExtension(ext)
    }

    /// Whether to skip: the output exists and is newer than the input, and
    /// nobody said `--force`.
    public static func shouldSkip(
        inputModified: Date?, outputModified: Date?, force: Bool
    ) -> Bool {
        guard !force, let outputModified else { return false }
        guard let inputModified else { return true }
        return outputModified > inputModified
    }
}
