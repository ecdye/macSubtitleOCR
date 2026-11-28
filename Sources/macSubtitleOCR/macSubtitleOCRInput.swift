//
// macSubtitleOCRInput.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation

/// The kind of subtitle file an input path names, told by its extension, with the files to read.
enum macSubtitleOCRInput: Equatable {
    /// A VobSub `.sub` and its `.idx`, whichever of the two was given.
    case vobSub(sub: URL, idx: URL)
    /// A Matroska `.mkv` or `.mks`.
    case matroska(URL)
    /// A PGS `.sup`.
    case pgs(URL)

    /// Tells the kind of input from the extension of `path`, in any case, and for a VobSub finds the
    /// other file of the pair beside it.
    ///
    /// Throws `invalidInputFile` for an extension that is not supported, or for a VobSub whose other
    /// file is not there; `hint` is appended to the message for an unsupported extension.
    init(path: String, hint: String = "") throws {
        let url = URL(fileURLWithPath: path)
        switch url.pathExtension.lowercased() {
        case "sub":
            self = try .vobSub(sub: url, idx: Self.sibling(of: url, withExtension: "idx"))
        case "idx":
            self = try .vobSub(sub: Self.sibling(of: url, withExtension: "sub"), idx: url)
        case "mkv", "mks":
            self = .matroska(url)
        case "sup":
            self = .pgs(url)
        default:
            throw macSubtitleOCRError.invalidInputFile("Invalid input file type \(url.pathExtension)\(hint)")
        }
    }

    /// The `.idx` beside a VobSub `.sub`, if there is one.
    static func vobSubIndex(for sub: URL) -> URL? {
        existingSibling(of: sub, withExtension: "idx")
    }

    /// The file beside `url` with the same name and the extension `pathExtension`, which must exist.
    private static func sibling(of url: URL, withExtension pathExtension: String) throws -> URL {
        guard let sibling = existingSibling(of: url, withExtension: pathExtension) else {
            let expected = url.deletingPathExtension().appendingPathExtension(pathExtension).lastPathComponent
            throw macSubtitleOCRError.invalidInputFile(
                "Cannot find \(expected) beside \(url.lastPathComponent), a VobSub needs both its .sub and .idx")
        }
        return sibling
    }

    /// The file beside `url` with the same name and the extension `pathExtension` in any case.
    ///
    /// Only the extension is replaced, so a directory whose name has `.sub` or `.idx` in it is left
    /// alone. The extension is tried in the case of the given one, then in lower and upper case, and
    /// last the directory is searched for any other casing, so a case-sensitive volume finds
    /// `movie.IDX` beside `movie.SUB` or `movie.Idx` beside `movie.sub` all the same.
    private static func existingSibling(of url: URL, withExtension pathExtension: String) -> URL? {
        let base = url.deletingPathExtension()
        let givenIsUppercase = url.pathExtension == url.pathExtension.uppercased()
        let preferred = givenIsUppercase ? pathExtension.uppercased() : pathExtension.lowercased()
        for candidate in [preferred, pathExtension.lowercased(), pathExtension.uppercased()] {
            let sibling = base.appendingPathExtension(candidate)
            if isRegularFile(sibling) {
                return sibling
            }
        }

        let directory = base.deletingLastPathComponent()
        let name = base.lastPathComponent
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for entry in entries.sorted() {
            let entryURL = directory.appendingPathComponent(entry)
            if entryURL.deletingPathExtension().lastPathComponent == name,
               entryURL.pathExtension.lowercased() == pathExtension.lowercased(), isRegularFile(entryURL) {
                return entryURL
            }
        }
        return nil
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
