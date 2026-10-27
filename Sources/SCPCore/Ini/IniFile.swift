import Foundation

/// Minimal, order-preserving INI reader matching what WinSCP writes.
/// Section and key lookups are case-insensitive, like the Windows INI API.
public struct IniFile {
    public struct Section {
        public let name: String
        public private(set) var entries: [(key: String, value: String)] = []

        public subscript(key: String) -> String? {
            let k = key.lowercased()
            return entries.last(where: { $0.key.lowercased() == k })?.value
        }

        mutating func set(_ key: String, _ value: String) {
            entries.append((key, value))
        }
    }

    public private(set) var sections: [Section] = []

    public init(text: String) {
        var current: Section?
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                if let c = current { sections.append(c) }
                current = Section(name: String(line.dropFirst().dropLast()))
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if current == nil { current = Section(name: "") }
            current?.set(key, value)
        }
        if let c = current { sections.append(c) }
    }

    /// Decodes bytes as UTF-8 (with or without BOM), falling back to Windows-1252,
    /// which older WinSCP versions used for ANSI INI files.
    public init(data: Data) {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if bytes.starts(with: [0xFF, 0xFE]), let s = String(data: bytes, encoding: .utf16LittleEndian) {
            self.init(text: s)
        } else if let s = String(data: bytes, encoding: .utf8) {
            self.init(text: s)
        } else {
            self.init(text: String(data: bytes, encoding: .windowsCP1252) ?? "")
        }
    }

    public func section(_ name: String) -> Section? {
        let n = name.lowercased()
        return sections.last(where: { $0.name.lowercased() == n })
    }
}

/// WinSCP escapes INI section names and string values as %XX UTF-8 sequences.
public func winscpUnmunge(_ s: String) -> String {
    s.removingPercentEncoding ?? s
}
