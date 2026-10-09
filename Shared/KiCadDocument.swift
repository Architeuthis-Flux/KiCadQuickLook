import Foundation
import os.log

private let loaderLogger = Logger(subsystem: "com.kevincappuccio.KiCadQuickLook", category: "loader")

/// The kind of KiCad document KiCanvas should render.
enum KiCadDocumentType: String {
    case board
    case schematic
}

/// A 3D model format rendered by the Online 3D Viewer page.
enum ModelFormat: String {
    case step
    case threeMF = "3mf"

    /// Extension of the document resource served to the page; the viewer
    /// picks its importer from it.
    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .step: return "STEP"
        case .threeMF: return "3MF"
        }
    }
}

/// What the preview should display for a given file.
enum PreviewContent {
    case document(type: KiCadDocumentType, content: String)
    case model(format: ModelFormat, data: Data)
    case message(title: String, detail: String)
}

enum KiCadFileError: LocalizedError {
    case unreadable(URL)
    case tooLarge(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "Could not read \(url.lastPathComponent)"
        case .tooLarge(let url):
            return "\(url.lastPathComponent) is too large to preview"
        }
    }
}

enum KiCadFileLoader {
    /// KiCanvas parses everything in memory; keep a sane upper bound.
    static let maximumFileSize = 96 * 1024 * 1024

    /// Board file versions older than KiCad 6 (s-expression `(version YYYYMMDD)`)
    /// are not parseable by KiCanvas.
    static let minimumBoardVersion = 20_211_014

    /// Largest model file worth attempting.
    ///
    /// STEP files are read and tessellated by Open CASCADE compiled to
    /// WebAssembly. Time is about 1 s per MB in the offscreen harness,
    /// but memory is the binding limit: the kernel's STEP reader keeps the
    /// whole entity graph in memory at 30–70 MB per MB of file (a 21 MB
    /// connector grew the heap to 0.6 GB, a 17 MB KiCad board export to
    /// 1.1 GB), and the WebAssembly module can address at most 2 GB.
    /// Previews are attempted up to 64 MB: light files that size fit,
    /// dense ones fail with an out-of-memory message from the kernel
    /// rather than a timeout. Beyond that nothing fits, so the message
    /// explains why. KiCad board exports with every drill hole and
    /// component modelled run to hundreds of MB and are out of reach of
    /// this kernel.
    ///
    /// 3MF packages are unzipped and parsed as XML (about 0.35 s per MB of
    /// package, the XML expanding roughly tenfold in memory). Thumbnails
    /// have about 15 s including WebAssembly start-up; their caps leave a
    /// 2× margin.
    static func maximumModelSize(for format: ModelFormat, thumbnail: Bool) -> Int {
        let megabytes: Int
        switch format {
        case .step: megabytes = thumbnail ? 8 : 64
        case .threeMF: megabytes = thumbnail ? 12 : 24
        }
        return megabytes * 1024 * 1024
    }

    /// Rough Open CASCADE memory needed to read a STEP file of the given
    /// size (see `maximumModelSize`).
    static func estimatedSTEPMemory(forFileSize size: Int) -> Int {
        80 * 1024 * 1024 + size * 50
    }

    /// - Parameter thumbnail: Whether the content feeds the thumbnail
    ///   extension, whose much shorter deadline lowers the model size cap.
    static func loadPreviewContent(for url: URL, thumbnail: Bool = false) throws -> PreviewContent {
        switch url.pathExtension.lowercased() {
        case "kicad_pcb":
            let text = try readText(url)
            return contentForBoard(text)
        case "kicad_sch":
            let text = try readText(url)
            return .document(type: .schematic, content: sanitizeArcs(text))
        case "kicad_pro":
            return try loadProject(url)
        case "step", "stp":
            return try loadModel(url, format: .step, thumbnail: thumbnail)
        case "3mf":
            return try loadModel(url, format: .threeMF, thumbnail: thumbnail)
        default:
            // Fall back to sniffing the content; QL should only hand us
            // declared types, but be forgiving.
            let data = try readData(url)
            if looksLikeSTEP(data) {
                return try loadModel(url, format: .step, thumbnail: thumbnail)
            }
            let text = try decodeText(data, from: url)
            if text.hasPrefix("(kicad_pcb") { return contentForBoard(text) }
            if text.hasPrefix("(kicad_sch") { return .document(type: .schematic, content: text) }
            return .message(
                title: url.lastPathComponent,
                detail: "Not a recognized KiCad document."
            )
        }
    }

    // MARK: - 3D models

    private static func loadModel(_ url: URL, format: ModelFormat, thumbnail: Bool) throws -> PreviewContent {
        let maximumSize = maximumModelSize(for: format, thumbnail: thumbnail)
        if let size = fileSize(url), size > maximumSize {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            var detail = "This \(format.displayName) file is \(formatter.string(fromByteCount: Int64(size))); "
                + "the previewer renders \(format.displayName) models up to "
                + "\(formatter.string(fromByteCount: Int64(maximumSize)))."
            if format == .step, !thumbnail {
                let needed = formatter.string(fromByteCount: Int64(estimatedSTEPMemory(forFileSize: size)))
                detail += " Reading it would take roughly \(needed) of memory, more than the 2 GB the "
                    + "WebAssembly CAD kernel can address. KiCad exports get this large when every "
                    + "drill hole and component is modelled; exporting without holes or without "
                    + "component models gives a previewable file."
            }
            return .message(title: url.lastPathComponent, detail: detail)
        }
        let data = try readData(url, limit: maximumSize)
        switch format {
        case .step:
            guard looksLikeSTEP(data) else {
                return .message(
                    title: url.lastPathComponent,
                    detail: "Not a STEP file (no ISO-10303-21 header)."
                )
            }
        case .threeMF:
            guard looksLikeZip(data) else {
                return .message(
                    title: url.lastPathComponent,
                    detail: "Not a 3MF package (expected a zip container)."
                )
            }
        }
        return .model(format: format, data: data)
    }

    /// STEP Part 21 files open with `ISO-10303-21;`, possibly after a BOM
    /// or whitespace. The `.stp` extension is also used by unrelated
    /// formats (SystemTap scripts, HTML Help projects), so sniff.
    static func looksLikeSTEP(_ data: Data) -> Bool {
        data.prefix(256).range(of: Data("ISO-10303-21".utf8)) != nil
    }

    /// 3MF packages are OPC zip containers.
    static func looksLikeZip(_ data: Data) -> Bool {
        data.starts(with: [0x50, 0x4B, 0x03, 0x04])
    }

    // MARK: - Project resolution

    /// For `foo.kicad_pro`: prefer the sibling PCB unless it is effectively
    /// blank, in which case fall back to the schematic.
    private static func loadProject(_ url: URL) throws -> PreviewContent {
        let base = url.deletingPathExtension()
        let pcbURL = base.appendingPathExtension("kicad_pcb")
        let schURL = base.appendingPathExtension("kicad_sch")
        let fm = FileManager.default

        let pcbText = fm.fileExists(atPath: pcbURL.path) ? try? readText(pcbURL) : nil
        let schText = fm.fileExists(atPath: schURL.path) ? try? readText(schURL) : nil
        loaderLogger.info("project \(url.lastPathComponent, privacy: .public): pcb=\(pcbText != nil), sch=\(schText != nil)")

        if let pcb = pcbText, !boardIsBlank(pcb) {
            return contentForBoard(pcb)
        }
        if let sch = schText {
            return .document(type: .schematic, content: sanitizeArcs(sch))
        }
        if let pcb = pcbText {
            // Blank board but no schematic either; show the board anyway.
            return contentForBoard(pcb)
        }
        return .message(
            title: url.deletingPathExtension().lastPathComponent,
            detail: "KiCad project — no board or schematic file found next to it."
        )
    }

    // MARK: - Arc sanitizing

    /// KiCanvas computes an arc's center from its three points; when the
    /// points are collinear or duplicated (seen in imported graphics, where
    /// tools emit nanometer-scale "arcs" that are really line segments) the
    /// math yields NaN and the whole paint aborts. Nudge the mid point of
    /// any degenerate arc off the chord so the arc renders as the
    /// near-straight line it represents; drop zero-length arcs entirely.
    static func sanitizeArcs(_ text: String) -> String {
        // Fast path: bail out without copying if there are no arcs at all.
        guard text.contains("(mid ") else { return text }

        let pointsPattern = try! NSRegularExpression(
            pattern: #"\(start\s+([-\d.]+)\s+([-\d.]+)\)\s*\(mid\s+([-\d.]+)\s+([-\d.]+)\)"#
        )

        var result = ""
        result.reserveCapacity(text.utf8.count)
        var cursor = text.startIndex

        while let midRange = text.range(of: "(mid ", range: cursor..<text.endIndex) {
            // Find the enclosing arc block: scan back to the opening paren
            // of the containing element (start/mid/end triplets only occur
            // inside arc-like elements).
            guard let blockStart = enclosingBlockStart(in: text, before: midRange.lowerBound),
                  let blockEnd = balancedBlockEnd(in: text, from: blockStart)
            else {
                result += text[cursor..<midRange.upperBound]
                cursor = midRange.upperBound
                continue
            }

            result += text[cursor..<blockStart]
            let block = String(text[blockStart..<blockEnd])
            result += sanitizeArcBlock(block, pointsPattern: pointsPattern)
            cursor = blockEnd
        }
        result += text[cursor...]
        return result
    }

    /// Scans backwards from `index` to the "(" that opens the element
    /// containing it (skipping over any complete sibling elements).
    private static func enclosingBlockStart(in text: String, before index: String.Index) -> String.Index? {
        var depth = 0
        var i = index
        while i > text.startIndex {
            i = text.index(before: i)
            let ch = text[i]
            if ch == ")" {
                depth += 1
            } else if ch == "(" {
                if depth == 0 { return i }
                depth -= 1
            }
        }
        return nil
    }

    /// Returns the index just past the ")" matching the "(" at `start`.
    private static func balancedBlockEnd(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth == 0 { return text.index(after: i) }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func sanitizeArcBlock(_ block: String, pointsPattern: NSRegularExpression) -> String {
        let ns = block as NSString
        guard let match = pointsPattern.firstMatch(in: block, range: NSRange(location: 0, length: ns.length)),
              let sx = Double(ns.substring(with: match.range(at: 1))),
              let sy = Double(ns.substring(with: match.range(at: 2))),
              let mx = Double(ns.substring(with: match.range(at: 3))),
              let my = Double(ns.substring(with: match.range(at: 4)))
        else { return block }

        // Locate the end point (may carry extra tokens between mid and end).
        guard let endMatch = try? NSRegularExpression(pattern: #"\(end\s+([-\d.]+)\s+([-\d.]+)\)"#)
                .firstMatch(in: block, range: NSRange(location: 0, length: ns.length)),
              let ex = Double(ns.substring(with: endMatch.range(at: 1))),
              let ey = Double(ns.substring(with: endMatch.range(at: 2)))
        else { return block }

        let cross = (mx - sx) * (ey - sy) - (my - sy) * (ex - sx)
        let duplicated = (sx == mx && sy == my) || (mx == ex && my == ey) || (sx == ex && sy == ey)
        guard duplicated || abs(cross) < 1e-9 else { return block }

        let dx = ex - sx
        let dy = ey - sy
        let chord = (dx * dx + dy * dy).squareRoot()

        // Zero-length arc: nothing sensible to draw; drop the element.
        guard chord > 0 else { return "" }

        // Nudge the mid point perpendicular to the chord. The offset is tiny
        // relative to the chord, so the "arc" stays visually a straight line
        // but the center computation becomes well-defined.
        let offset = max(chord * 1e-4, 1e-6)
        let newMidX = (sx + ex) / 2 + (-dy / chord) * offset
        let newMidY = (sy + ey) / 2 + (dx / chord) * offset

        guard let midRange = block.range(of: "(mid ") else { return block }
        guard let midEnd = balancedBlockEnd(in: block, from: midRange.lowerBound) else { return block }
        return block[..<midRange.lowerBound]
            + String(format: "(mid %.6f %.6f)", newMidX, newMidY)
            + block[midEnd...]
    }

    // MARK: - Polygon decimation

    /// Threshold above which boards get polygon decimation.
    static let decimationFileSizeThreshold = 2 * 1024 * 1024
    /// Points closer than this (in mm, Manhattan distance) to the previously
    /// kept point are dropped — far below what a preview pixel resolves.
    static let decimationEpsilonMM = 0.05
    /// Only blocks with at least this many points are touched.
    static let decimationMinimumPoints = 32

    /// Thins dense `(pts (xy …) …)` point lists in large boards.
    ///
    /// KiCanvas triangulates every filled polygon on the main thread;
    /// imported artwork and zone fills routinely carry hundreds of
    /// thousands of near-coincident points (flattened curves at nanometer
    /// resolution), which is what makes big boards take tens of seconds to
    /// paint. Dropping points that are closer than a preview pixel keeps
    /// the rendered shape identical while cutting triangulation work.
    ///
    /// Blocks containing non-`(xy)` children (e.g. `(arc)`) are left alone.
    static func decimatePolygonPoints(_ text: String, epsilon: Double = decimationEpsilonMM) -> String {
        var bytes = Array(text.utf8)
        bytes.append(0)

        var output = [UInt8]()
        output.reserveCapacity(bytes.count)

        let ptsToken: [UInt8] = Array("(pts".utf8)
        let open = UInt8(ascii: "(")
        let close = UInt8(ascii: ")")

        var kept = 0
        var dropped = 0

        bytes.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            let count = buffer.count - 1  // exclude terminator

            func findPts(from start: Int) -> Int? {
                guard count >= 4 else { return nil }
                var i = start
                while i <= count - 4 {
                    if base[i] == open,
                       base[i + 1] == ptsToken[1],
                       base[i + 2] == ptsToken[2],
                       base[i + 3] == ptsToken[3],
                       // Must be exactly "(pts", not e.g. "(ptsomething"
                       base[i + 4] == UInt8(ascii: " ") || base[i + 4] == UInt8(ascii: "\n")
                        || base[i + 4] == UInt8(ascii: "\t") || base[i + 4] == UInt8(ascii: "\r")
                        || base[i + 4] == close {
                        return i
                    }
                    i += 1
                }
                return nil
            }

            var cursor = 0
            while let ptsStart = findPts(from: cursor) {
                output.append(contentsOf: UnsafeBufferPointer(start: base + cursor, count: ptsStart - cursor))

                // Collect the direct children of the pts block.
                struct Child {
                    let start: Int
                    let end: Int   // exclusive
                    let x: Double
                    let y: Double
                    let isXY: Bool
                }
                var children: [Child] = []
                var allXY = true

                var i = ptsStart + 4
                var depth = 1
                var blockEnd = ptsStart + 4
                while i < count && depth > 0 {
                    let ch = base[i]
                    if ch == open {
                        if depth == 1 {
                            // Child element: find its balanced end.
                            let childStart = i
                            var childDepth = 0
                            var j = i
                            while j < count {
                                if base[j] == open { childDepth += 1 }
                                if base[j] == close {
                                    childDepth -= 1
                                    if childDepth == 0 { break }
                                }
                                j += 1
                            }
                            let childEnd = min(j + 1, count)
                            let isXY = childStart + 3 < count
                                && base[childStart + 1] == UInt8(ascii: "x")
                                && base[childStart + 2] == UInt8(ascii: "y")
                                && (base[childStart + 3] == UInt8(ascii: " ")
                                    || base[childStart + 3] == UInt8(ascii: "\n")
                                    || base[childStart + 3] == UInt8(ascii: "\t"))
                            var x = 0.0, y = 0.0
                            if isXY {
                                var endPointer: UnsafeMutablePointer<CChar>?
                                let numberStart = UnsafeRawPointer(base + childStart + 3)
                                    .assumingMemoryBound(to: CChar.self)
                                x = strtod(numberStart, &endPointer)
                                if let next = endPointer {
                                    y = strtod(next, &endPointer)
                                }
                            } else {
                                allXY = false
                            }
                            children.append(Child(start: childStart, end: childEnd, x: x, y: y, isXY: isXY))
                            i = childEnd
                            continue
                        }
                        depth += 1
                    } else if ch == close {
                        depth -= 1
                        if depth == 0 {
                            blockEnd = i + 1
                        }
                    }
                    i += 1
                }
                if depth != 0 { blockEnd = count }

                if !allXY || children.count < decimationMinimumPoints {
                    output.append(contentsOf: UnsafeBufferPointer(start: base + ptsStart, count: blockEnd - ptsStart))
                } else {
                    output.append(contentsOf: ptsToken)
                    var lastX = Double.infinity
                    var lastY = Double.infinity
                    for (index, child) in children.enumerated() {
                        let isEndpoint = index == 0 || index == children.count - 1
                        if !isEndpoint,
                           abs(child.x - lastX) + abs(child.y - lastY) < epsilon {
                            dropped += 1
                            continue
                        }
                        lastX = child.x
                        lastY = child.y
                        kept += 1
                        output.append(UInt8(ascii: " "))
                        output.append(contentsOf: UnsafeBufferPointer(start: base + child.start, count: child.end - child.start))
                    }
                    output.append(close)
                }
                cursor = blockEnd
            }
            output.append(contentsOf: UnsafeBufferPointer(start: base + cursor, count: count - cursor))
        }

        if dropped > 0 {
            loaderLogger.info("decimated polygons: kept \(kept), dropped \(dropped) points")
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// A board with no footprints, tracks, graphics, or zones is "blank".
    /// Tokens include the trailing space to avoid matching similarly-named
    /// settings like `(viasonmask` or `(zone_45_only`.
    static func boardIsBlank(_ text: String) -> Bool {
        let tokens = ["(footprint ", "(module ", "(segment ", "(arc ", "(via ", "(zone ", "(gr_"]
        return !tokens.contains { text.contains($0) }
    }

    private static func contentForBoard(_ text: String) -> PreviewContent {
        if let version = documentVersion(text), version < minimumBoardVersion {
            return .message(
                title: "KiCad 5 board",
                detail: "This board was saved by KiCad 5 or earlier, which KiCanvas cannot render. Re-save it with KiCad 6 or newer."
            )
        }
        var content = text
        if content.utf8.count > decimationFileSizeThreshold {
            content = decimatePolygonPoints(content)
        }
        return .document(type: .board, content: sanitizeArcs(content))
    }

    /// Extracts `(version YYYYMMDD)` from the file header.
    static func documentVersion(_ text: String) -> Int? {
        let head = text.prefix(512)
        guard let range = head.range(of: #"\(version\s+(\d+)"#, options: .regularExpression),
              let numberRange = head[range].range(of: #"\d+"#, options: .regularExpression)
        else { return nil }
        return Int(head[numberRange])
    }

    // MARK: - IO

    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    private static func readData(_ url: URL, limit: Int = maximumFileSize) throws -> Data {
        if let size = fileSize(url), size > limit {
            throw KiCadFileError.tooLarge(url)
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw KiCadFileError.unreadable(url)
        }
        return data
    }

    private static func readText(_ url: URL) throws -> String {
        try decodeText(try readData(url), from: url)
    }

    private static func decodeText(_ data: Data, from url: URL) throws -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        guard let text = String(data: data, encoding: .isoLatin1) else {
            throw KiCadFileError.unreadable(url)
        }
        return text
    }
}
