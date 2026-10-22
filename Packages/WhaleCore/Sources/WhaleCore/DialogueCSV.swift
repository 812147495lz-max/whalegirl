import Foundation

/// One-column CSV for user-authored speech. Quoted commas/newlines follow RFC 4180.
public enum DialogueCSV {
    public enum ParseError: Error { case malformed, empty }

    public static func decode(_ source: String) throws -> [String] {
        let text = source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source
        let input = Array(text.unicodeScalars)
        var rows: [[String]] = [], row: [String] = [], field = ""
        // 0: empty/unquoted, 1: quoted, 2: after closing quote
        var state = 0, index = 0
        while index < input.count {
            let value = input[index]
            if state == 1 {
                if value == "\"" {
                    if index + 1 < input.count, input[index + 1] == "\"" {
                        field.append("\""); index += 1
                    } else { state = 2 }
                } else { field.unicodeScalars.append(value) }
            } else if value == "," {
                row.append(field); field = ""; state = 0
            } else if value == "\r" || value == "\n" {
                row.append(field); rows.append(row); row = []; field = ""; state = 0
                if value == "\r", index + 1 < input.count, input[index + 1] == "\n" { index += 1 }
            } else if value == "\"", state == 0, field.isEmpty {
                state = 1
            } else {
                guard state != 2, value != "\"" else { throw ParseError.malformed }
                field.unicodeScalars.append(value)
            }
            index += 1
        }
        guard state != 1 else { throw ParseError.malformed }
        if !field.isEmpty || !row.isEmpty || state == 2 { row.append(field); rows.append(row) }
        var lines: [String] = [], seen = Set<String>(), firstNonempty = true
        for row in rows {
            let cells = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if cells.allSatisfy(\.isEmpty) { continue }
            guard cells.dropFirst().allSatisfy(\.isEmpty) else { throw ParseError.malformed }
            let line = cells[0]
            if firstNonempty {
                firstNonempty = false
                if ["气泡文案", "文案", "内容", "text"].contains(line.lowercased()) { continue }
            }
            if !line.isEmpty, seen.insert(line).inserted { lines.append(line) }
        }
        guard !lines.isEmpty else { throw ParseError.empty }
        return lines
    }

    public static func encode(_ lines: [String]) -> String {
        "\u{FEFF}气泡文案\r\n" + lines.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: "\r\n") + "\r\n"
    }
}
