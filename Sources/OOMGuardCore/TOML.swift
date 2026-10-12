import Foundation


/// The subset of TOML a config file needs: `[tables]`, `key = value`, comments,
/// strings, integers, floats, booleans and (multi-line) arrays of those.
/// Keeping it in-tree keeps oomguard a single dependency-free binary.
public enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    case array([TOMLValue])
}

public struct TOMLError: Error, CustomStringConvertible, Equatable {
    public let line: Int
    public let message: String
    public var description: String { "line \(line): \(message)" }
}

/// Parses `text` into a flat map of dotted keys ("victim.min_size_gb") to values.
public func parseTOML(_ text: String) throws -> [String: TOMLValue] {
    var result: [String: TOMLValue] = [:]
    var table = ""
    let lines = text.components(separatedBy: "\n")
    var index = 0
    while index < lines.count {
        let lineNumber = index + 1
        var line = stripComment(lines[index]).trimmingCharacters(in: .whitespaces)
        index += 1
        if line.isEmpty { continue }
        if line.hasPrefix("[") {
            guard line.hasSuffix("]"), !line.hasPrefix("[[") else {
                throw TOMLError(line: lineNumber, message: "unsupported table header \(line)")
            }
            table = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            continue
        }
        guard let eq = line.firstIndex(of: "=") else {
            throw TOMLError(line: lineNumber, message: "expected key = value")
        }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        var raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        // Arrays may span lines until their brackets balance.
        while raw.hasPrefix("[") && !bracketsBalanced(raw) && index < lines.count {
            line = stripComment(lines[index]).trimmingCharacters(in: .whitespaces)
            index += 1
            raw += " " + line
        }
        let full = table.isEmpty ? key : "\(table).\(key)"
        if result[full] != nil { throw TOMLError(line: lineNumber, message: "duplicate key \(full)") }
        var scanner = Scanner(Array(raw))
        let value = try scanner.value(line: lineNumber)
        scanner.skipSpace()
        guard scanner.atEnd else { throw TOMLError(line: lineNumber, message: "unexpected text after value") }
        result[full] = value
    }
    return result
}

private func stripComment(_ line: String) -> String {
    var inString = false
    var escaped = false
    for (offset, ch) in line.enumerated() {
        if escaped { escaped = false; continue }
        if ch == "\\" && inString { escaped = true; continue }
        if ch == "\"" { inString.toggle() }
        if ch == "#" && !inString { return String(line.prefix(offset)) }
    }
    return line
}

private func bracketsBalanced(_ text: String) -> Bool {
    var depth = 0
    var inString = false
    var escaped = false
    for ch in text {
        if escaped { escaped = false; continue }
        if ch == "\\" && inString { escaped = true; continue }
        if ch == "\"" { inString.toggle(); continue }
        if inString { continue }
        if ch == "[" { depth += 1 }
        if ch == "]" { depth -= 1 }
    }
    return depth == 0
}

private struct Scanner {
    let chars: [Character]
    var pos = 0
    init(_ chars: [Character]) { self.chars = chars }

    var atEnd: Bool { pos >= chars.count }

    mutating func skipSpace() {
        while pos < chars.count, chars[pos] == " " || chars[pos] == "\t" { pos += 1 }
    }

    mutating func value(line: Int) throws -> TOMLValue {
        skipSpace()
        guard pos < chars.count else { throw TOMLError(line: line, message: "missing value") }
        switch chars[pos] {
        case "\"": return .string(try string(line: line))
        case "[": return .array(try array(line: line))
        default: return try scalar(line: line)
        }
    }

    mutating func string(line: Int) throws -> String {
        pos += 1
        var out = ""
        while pos < chars.count {
            let ch = chars[pos]
            pos += 1
            if ch == "\"" { return out }
            if ch == "\\" {
                guard pos < chars.count else { break }
                let esc = chars[pos]
                pos += 1
                switch esc {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: throw TOMLError(line: line, message: "unsupported escape \\\(esc)")
                }
            } else {
                out.append(ch)
            }
        }
        throw TOMLError(line: line, message: "unterminated string")
    }

    mutating func array(line: Int) throws -> [TOMLValue] {
        pos += 1
        var items: [TOMLValue] = []
        while true {
            skipSpace()
            guard pos < chars.count else { throw TOMLError(line: line, message: "unterminated array") }
            if chars[pos] == "]" { pos += 1; return items }
            items.append(try value(line: line))
            skipSpace()
            guard pos < chars.count else { throw TOMLError(line: line, message: "unterminated array") }
            if chars[pos] == "," { pos += 1 } else if chars[pos] != "]" {
                throw TOMLError(line: line, message: "expected , or ] in array")
            }
        }
    }

    mutating func scalar(line: Int) throws -> TOMLValue {
        let start = pos
        while pos < chars.count, !" \t,]".contains(chars[pos]) { pos += 1 }
        let word = String(chars[start..<pos]).replacingOccurrences(of: "_", with: "")
        if word == "true" { return .bool(true) }
        if word == "false" { return .bool(false) }
        if let int = Int(word) { return .integer(int) }
        if let double = Double(word) { return .float(double) }
        throw TOMLError(line: line, message: "cannot parse value \(word)")
    }
}
