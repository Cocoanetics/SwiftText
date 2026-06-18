#!/usr/bin/env swift
//
// GenerateIWAModels.swift — proto2 → Swift wire-model generator.
//
// Reads iWork `.proto` schemas — NOT vendored here; fetch them from
// psobot/keynote-parser (MIT), see Docs/IWA-PROTOBUF-SCHEMAS.md — and emits Swift
// structs/enums backed by SwiftText's own `ProtobufReader`/`ProtobufWriter`
// (no swift-protobuf runtime dependency). Each generated message:
//   • has typed properties (optional scalars, arrays for `repeated`, nested
//     generated structs for message fields, `Int32` for enum fields),
//   • decodes from a `ProtobufMessage`,
//   • encodes back via `ProtobufWriter`,
//   • preserves any unknown / un-modeled fields verbatim (lossless round-trip).
//
// Usage:  swift Scripts/GenerateIWAModels.swift <protos-dir> Sources/SwiftTextPages/Generated/IWA
//
import Foundation

// MARK: - Lexer

struct Lexer {
    private let scalars: [Character]
    private var pos = 0
    init(_ text: String) { scalars = Array(text) }

    mutating func tokens() -> [String] {
        var out = [String]()
        while pos < scalars.count {
            let c = scalars[pos]
            if c == "/" && pos + 1 < scalars.count && scalars[pos + 1] == "/" {        // line comment
                while pos < scalars.count && scalars[pos] != "\n" { pos += 1 }
            } else if c == "/" && pos + 1 < scalars.count && scalars[pos + 1] == "*" {  // block comment
                pos += 2
                while pos + 1 < scalars.count && !(scalars[pos] == "*" && scalars[pos + 1] == "/") { pos += 1 }
                pos += 2
            } else if c.isWhitespace {
                pos += 1
            } else if c == "\"" {                                                        // string literal
                pos += 1
                var s = "\""
                while pos < scalars.count && scalars[pos] != "\"" { s.append(scalars[pos]); pos += 1 }
                s.append("\""); pos += 1
                out.append(s)
            } else if "{}[]()=;,<>".contains(c) {                                        // punctuation
                out.append(String(c)); pos += 1
            } else {                                                                     // word (ident / qualified name / number)
                var s = ""
                while pos < scalars.count && !scalars[pos].isWhitespace && !"{}[]()=;,<>\"".contains(scalars[pos]) {
                    s.append(scalars[pos]); pos += 1
                }
                out.append(s)
            }
        }
        return out
    }
}

// MARK: - AST

final class ProtoMessage {
    let fqn: String                 // fully-qualified, e.g. "TST.TableModelArchive.Nested"
    var fields: [ProtoField] = []
    init(fqn: String) { self.fqn = fqn }
}
struct ProtoField {
    let label: String               // optional / required / repeated
    let type: String                // raw type token (may be qualified / leading-dot)
    let name: String
    let number: Int
    let packed: Bool
}
struct ProtoEnum { let fqn: String }

// MARK: - Parser

final class Parser {
    private let tk: [String]
    private var i = 0
    private(set) var messages: [ProtoMessage] = []
    private(set) var enums: [ProtoEnum] = []
    private var pkg = ""

    init(_ tokens: [String]) { tk = tokens }

    private func peek() -> String? { i < tk.count ? tk[i] : nil }
    @discardableResult private func next() -> String { guard i < tk.count else { return "" }; defer { i += 1 }; return tk[i] }
    private func skipTo(_ token: String) { while i < tk.count && tk[i] != token { i += 1 }; if i < tk.count { i += 1 } }
    private func skipBlock() {                       // assumes current token is "{"; consumes to matching "}"
        var depth = 0
        while i < tk.count {
            let t = next()
            if t == "{" { depth += 1 } else if t == "}" { depth -= 1; if depth == 0 { return } }
        }
    }

    func parse() {
        while let t = peek() {
            switch t {
            case "syntax", "option": next(); skipTo(";")
            case "package": next(); pkg = next(); skipTo(";")
            case "import": next(); skipTo(";")
            case "message": next(); parseMessage(scope: pkg.isEmpty ? [] : [pkg])
            case "enum": next(); parseEnum(scope: pkg.isEmpty ? [] : [pkg])
            case "extend": next(); _ = next(); if peek() == "{" { skipBlock() }   // skip extension blocks
            default: next()
            }
        }
    }

    private func parseMessage(scope: [String]) {
        let name = next()
        let fqn = (scope + [name]).joined(separator: ".")
        let msg = ProtoMessage(fqn: fqn)
        messages.append(msg)
        let inner = scope + [name]
        guard next() == "{" else { return }
        while let t = peek(), t != "}" {
            switch t {
            case "message": next(); parseMessage(scope: inner)
            case "enum": next(); parseEnum(scope: inner)
            case "extend": next(); _ = next(); if peek() == "{" { skipBlock() }
            case "oneof": next(); _ = next(); _ = next()                            // flatten oneof members → optional fields
                while let u = peek(), u != "}" { parseField(into: msg, forcedLabel: "optional") }
                _ = next()
            case "extensions", "reserved", "option": next(); skipTo(";")
            case ";": next()
            default: parseField(into: msg, forcedLabel: nil)
            }
        }
        _ = next()                                       // consume "}"
    }

    private func parseField(into msg: ProtoMessage, forcedLabel: String?) {
        var label = forcedLabel ?? "optional"
        if forcedLabel == nil, let t = peek(), t == "optional" || t == "required" || t == "repeated" { label = next() }
        guard let type = peek(), type != ";" else { if peek() == ";" { next() }; return }
        next()                                          // type
        let name = next()
        guard next() == "=" else { skipTo(";"); return }
        let number = Int(next()) ?? -1
        var packed = false
        if peek() == "[" {                              // field options
            while let u = peek(), u != "]" { if u == "packed" { packed = true }; next() }
            if peek() == "]" { next() }
        }
        if peek() == ";" { next() }
        if number > 0 { msg.fields.append(ProtoField(label: label, type: type, name: name, number: number, packed: packed)) }
    }

    private func parseEnum(scope: [String]) {
        let name = next()
        enums.append(ProtoEnum(fqn: (scope + [name]).joined(separator: ".")))
        guard next() == "{" else { return }
        i -= 1; skipBlock()                             // enum values not needed: enum fields decode as Int32
    }
}

// MARK: - Type system

private let scalarSwift: [String: String] = [
    "double": "Double", "float": "Float",
    "int32": "Int32", "int64": "Int64", "uint32": "UInt32", "uint64": "UInt64",
    "sint32": "Int32", "sint64": "Int64",
    "fixed32": "UInt32", "fixed64": "UInt64", "sfixed32": "Int32", "sfixed64": "Int64",
    "bool": "Bool", "string": "String", "bytes": "[UInt8]",
]
enum Wire { case varint, zigzag, fixed32, fixed64, lengthString, lengthBytes, message, enumVarint, unresolved }

private func swiftTypeName(_ fqn: String) -> String { fqn.replacingOccurrences(of: ".", with: "_") }

private let swiftKeywords: Set<String> = [
    "default","in","is","as","where","class","struct","enum","func","let","var","return","self","super",
    "protocol","extension","case","switch","for","while","repeat","do","try","throw","throws","rethrows",
    "public","private","internal","static","import","init","deinit","operator","subscript","associatedtype",
    "typealias","fileprivate","open","guard","defer","break","continue","fallthrough","nil","true","false",
    "Any","Self","Type","extension","public","required","optional",
]
private func camel(_ snake: String) -> String {
    let parts = snake.split(separator: "_").map(String.init)
    guard let first = parts.first else { return snake }
    var name = first.lowercased() + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    if name.isEmpty { name = "field" }
    if let f = name.first, f.isNumber { name = "f" + name }
    return swiftKeywords.contains(name) ? "`\(name)`" : name
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write(Data("usage: GenerateIWAModels <protoDir> <outDir>\n".utf8)); exit(2) }
let inDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let protoFiles = try FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "proto" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

var allMessages: [ProtoMessage] = []
var enumFQNs = Set<String>()
var perFile: [(name: String, messages: [ProtoMessage])] = []

for file in protoFiles {
    let text = try String(contentsOf: file, encoding: .utf8)
    var lexer = Lexer(text)
    let parser = Parser(lexer.tokens())
    parser.parse()
    allMessages.append(contentsOf: parser.messages)
    for e in parser.enums { enumFQNs.insert(e.fqn) }
    perFile.append((file.deletingPathExtension().lastPathComponent, parser.messages))
}

let messageFQNs = Set(allMessages.map(\.fqn))

// Resolve a field's type token (in a message's scope) to (swiftType, wire, isRepeatedElementScalar).
func resolve(_ type: String, scopeFQN: String) -> (swift: String, wire: Wire) {
    if let s = scalarSwift[type] {
        switch type {
        case "double": return (s, .fixed64)
        case "float": return (s, .fixed32)
        case "fixed64", "sfixed64": return (s, .fixed64)
        case "fixed32", "sfixed32": return (s, .fixed32)
        case "sint32", "sint64": return (s, .zigzag)
        case "string": return (s, .lengthString)
        case "bytes": return (s, .lengthBytes)
        default: return (s, .varint)                       // int32/64, uint32/64, bool
        }
    }
    // Resolve message/enum reference: absolute (leading dot) first, then walk scope outward.
    let normalized = type.hasPrefix(".") ? String(type.dropFirst()) : type
    func lookup(_ candidate: String) -> (String, Wire)? {
        if messageFQNs.contains(candidate) { return (swiftTypeName(candidate), .message) }
        if enumFQNs.contains(candidate) { return ("Int32", .enumVarint) }
        return nil
    }
    if let hit = lookup(normalized) { return hit }
    if !type.hasPrefix(".") {
        var scope = scopeFQN.split(separator: ".").map(String.init)
        while !scope.isEmpty {
            if let hit = lookup((scope + [normalized]).joined(separator: ".")) { return hit }
            scope.removeLast()
        }
    }
    return ("", .unresolved)                               // type from an un-vendored archive (or an
                                                            // enum we don't have) → not modeled as a typed
                                                            // field; preserved verbatim via unknownFields so
                                                            // any wire type round-trips losslessly.
}

// Emit support runtime once.
let support = """
// Generated by Scripts/GenerateIWAModels.swift — do not edit.
import Foundation

/// Common interface for every generated iWork archive model: decode from a
/// `ProtobufMessage`, re-encode, and expose the fields it didn't model. Enables the
/// reflective `IWACatalog` (used to derive type-number bindings by best-fit).
protocol IWAMessage {
    init(_ message: ProtobufMessage)
    func encoded() -> [UInt8]
    var unknownFields: [ProtobufField] { get }
}

/// Wire helpers shared by the generated iWork archive models.
enum IWAWire {
    static func u32(_ b: [UInt8]) -> UInt32 {
        b.count >= 4 ? UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24 : 0
    }
    static func u64(_ b: [UInt8]) -> UInt64 {
        guard b.count >= 8 else { return 0 }
        var v: UInt64 = 0; for k in 0..<8 { v |= UInt64(b[k]) << (8 * k) }; return v
    }
    static func unzigzag32(_ v: UInt64) -> Int32 {
        let u = UInt32(truncatingIfNeeded: v); return Int32(bitPattern: (u >> 1) ^ (~(u & 1) &+ 1))
    }
    static func unzigzag64(_ v: UInt64) -> Int64 {
        Int64(bitPattern: (v >> 1) ^ (~(v & 1) &+ 1))
    }
    static func zigzag32(_ n: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: (n << 1) ^ (n >> 31)))
    }
    static func zigzag64(_ n: Int64) -> UInt64 {
        UInt64(bitPattern: (n << 1) ^ (n >> 63))
    }
    static func unpackVarints(_ b: [UInt8]) -> [UInt64] {
        var out = [UInt64](); var pos = 0
        while pos < b.count {
            var shift: UInt64 = 0, value: UInt64 = 0
            while pos < b.count { let byte = b[pos]; pos += 1; value |= UInt64(byte & 0x7F) << shift; if byte & 0x80 == 0 { break }; shift += 7 }
            out.append(value)
        }
        return out
    }
}
"""
try support.write(to: outDir.appendingPathComponent("IWAWire.swift"), atomically: true, encoding: .utf8)

// Per-message emission. Locals are underscore-prefixed (`_pb`,`_f`,`_v`,`_w`,`_x`,`_u`)
// so they can never collide with a generated property name (proto field → camelCase,
// which never starts with an underscore). Messages are reference types so self- and
// mutually-recursive schemas (e.g. number-format conditions) have finite size.
func emitMessage(_ msg: ProtoMessage) -> String {
    let typeName = swiftTypeName(msg.fqn)
    var props = [String]()
    var decodeCases = [String]()
    var encodeLines = [String]()

    for f in msg.fields {
        let (swift, wire) = resolve(f.type, scopeFQN: msg.fqn)
        if wire == .unresolved { continue }   // leave to unknownFields — lossless, any wire type
        let prop = camel(f.name)
        let repeated = f.label == "repeated"

        props.append(repeated ? "    var \(prop): [\(swift)] = []" : "    var \(prop): \(swift)?")

        let read: String
        switch wire {
        case .varint:       read = swift == "Bool" ? "if case .varint(let _u) = _f.value { _v = _u != 0 }" : "if case .varint(let _u) = _f.value { _v = \(swift)(truncatingIfNeeded: _u) }"
        case .enumVarint:   read = "if case .varint(let _u) = _f.value { _v = Int32(truncatingIfNeeded: _u) }"
        case .zigzag:       read = "if case .varint(let _u) = _f.value { _v = IWAWire.unzigzag\(swift == "Int32" ? "32" : "64")(_u) }"
        case .fixed32:      read = swift == "Float" ? "if case .fixed32(let _b) = _f.value { _v = Float(bitPattern: IWAWire.u32(_b)) }" : (swift == "Int32" ? "if case .fixed32(let _b) = _f.value { _v = Int32(bitPattern: IWAWire.u32(_b)) }" : "if case .fixed32(let _b) = _f.value { _v = IWAWire.u32(_b) }")
        case .fixed64:      read = swift == "Double" ? "if case .fixed64(let _b) = _f.value { _v = Double(bitPattern: IWAWire.u64(_b)) }" : (swift == "Int64" ? "if case .fixed64(let _b) = _f.value { _v = Int64(bitPattern: IWAWire.u64(_b)) }" : "if case .fixed64(let _b) = _f.value { _v = IWAWire.u64(_b) }")
        case .lengthString: read = "if case .lengthDelimited(let _b) = _f.value { _v = String(decoding: _b, as: UTF8.self) }"
        case .lengthBytes:  read = "if case .lengthDelimited(let _b) = _f.value { _v = _b }"
        case .message:      read = "if case .lengthDelimited(let _b) = _f.value { _v = \(swift)(ProtobufMessage(_b)) }"
        case .unresolved:   read = ""   // unreachable (skipped above), present for exhaustiveness
        }

        if repeated && (wire == .varint || wire == .enumVarint || wire == .zigzag) {
            decodeCases.append("""
                    case \(f.number):
                        if case .varint(let _u) = _f.value { \(prop).append(\(scalarFromVarint(swift, wire))) }
                        else if case .lengthDelimited(let _b) = _f.value { for _u in IWAWire.unpackVarints(_b) { \(prop).append(\(scalarFromVarint(swift, wire))) } }
            """)
        } else if repeated {
            decodeCases.append("""
                    case \(f.number):
                        var _v: \(swift)?
                        \(read)
                        if let _v { \(prop).append(_v) }
            """)
        } else {
            decodeCases.append("""
                    case \(f.number):
                        var _v: \(swift)?
                        \(read)
                        if let _v { \(prop) = _v }
            """)
        }

        if repeated && f.packed && (wire == .varint || wire == .enumVarint || wire == .zigzag) {
            let mapped: String
            switch wire {
            case .zigzag: mapped = swift == "Int32" ? "IWAWire.zigzag32($0)" : "IWAWire.zigzag64($0)"
            default:      mapped = swift == "Bool" ? "($0 ? 1 : 0)" : "UInt64(truncatingIfNeeded: $0)"
            }
            encodeLines.append("        if !\(prop).isEmpty { _w.packedVarintField(\(f.number), \(prop).map { \(mapped) }) }")
        } else {
            let writeOne = encodeStatement(field: f.number, wire: wire, swift: swift, valueExpr: "_x")
            encodeLines.append(repeated ? "        for _x in \(prop) { \(writeOne) }" : "        if let _x = \(prop) { \(writeOne) }")
        }
    }

    let cases = decodeCases.joined(separator: "\n")
    let encode = encodeLines.joined(separator: "\n")
    return """
    /// Generated wire model for `\(msg.fqn)`.
    final class \(typeName): IWAMessage {
    \(props.joined(separator: "\n"))
        /// Fields not modeled above, preserved verbatim for lossless round-trip.
        var unknownFields: [ProtobufField] = []

        init() {}
        init(_ _pb: ProtobufMessage) {
            for _f in _pb.fields {
                switch _f.number {
    \(cases.isEmpty ? "" : cases + "\n")                default: unknownFields.append(_f)
                }
            }
        }
        func encoded() -> [UInt8] {
            var _w = ProtobufWriter()
    \(encode)
            for _f in unknownFields { _w.append(_f) }
            return _w.bytes
        }
    }
    """
}

func scalarFromVarint(_ swift: String, _ wire: Wire) -> String {
    switch wire {
    case .zigzag: return swift == "Int32" ? "IWAWire.unzigzag32(_u)" : "IWAWire.unzigzag64(_u)"
    default: return swift == "Bool" ? "(_u != 0)" : "\(swift)(truncatingIfNeeded: _u)"
    }
}

func encodeStatement(field: Int, wire: Wire, swift: String, valueExpr x: String) -> String {
    switch wire {
    case .varint:       return swift == "Bool" ? "_w.varintField(\(field), \(x) ? 1 : 0)" : "_w.varintField(\(field), UInt64(truncatingIfNeeded: \(x)))"
    case .enumVarint:   return "_w.varintField(\(field), UInt64(truncatingIfNeeded: \(x)))"
    case .zigzag:       return swift == "Int32" ? "_w.varintField(\(field), IWAWire.zigzag32(\(x)))" : "_w.varintField(\(field), IWAWire.zigzag64(\(x)))"
    case .fixed32:      return swift == "Float" ? "_w.fixed32Field(\(field), \(x).bitPattern)" : (swift == "Int32" ? "_w.fixed32Field(\(field), UInt32(bitPattern: \(x)))" : "_w.fixed32Field(\(field), \(x))")
    case .fixed64:      return swift == "Double" ? "_w.fixed64Field(\(field), \(x).bitPattern)" : (swift == "Int64" ? "_w.fixed64Field(\(field), UInt64(bitPattern: \(x)))" : "_w.fixed64Field(\(field), \(x))")
    case .lengthString: return "_w.stringField(\(field), \(x))"
    case .lengthBytes:  return "_w.bytesField(\(field), \(x))"
    case .message:      return "_w.bytesField(\(field), \(x).encoded())"
    case .unresolved:   return ""   // unreachable (skipped above)
    }
}

func identifier(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber ? $0 : "_" }) }
var emittedFiles = 0
var registrars = [String]()
for file in perFile where !file.messages.isEmpty {
    let reg = "registerIWA_\(identifier(file.name))"
    registrars.append(reg)
    var out = "// Generated by Scripts/GenerateIWAModels.swift from \(file.name).proto — do not edit.\n\nimport Foundation\nimport SwiftTextIWA\n\n"
    out += file.messages.map(emitMessage).joined(separator: "\n\n")
    out += "\n\n/// Registers this file's archives into the reflective catalog.\n"
    out += "func \(reg)(_ into: inout [(name: String, decode: (ProtobufMessage) -> IWAMessage)]) {\n"
    for m in file.messages { out += "    into.append((\"\(m.fqn)\", { \(swiftTypeName(m.fqn))($0) as IWAMessage }))\n" }
    out += "}\n"
    try out.write(to: outDir.appendingPathComponent("\(file.name).gen.swift"), atomically: true, encoding: .utf8)
    emittedFiles += 1
}

// Reflective catalog: every generated archive model, for best-fit type-number binding.
var catalog = "// Generated by Scripts/GenerateIWAModels.swift — do not edit.\n\nimport Foundation\nimport SwiftTextIWA\n\n"
catalog += "/// Every generated iWork archive model, by proto full name + a decode factory.\n"
catalog += "/// Lets a binder match an unknown object's type number to its best-fit message.\n"
catalog += "enum IWACatalog {\n"
catalog += "    static func all() -> [(name: String, decode: (ProtobufMessage) -> IWAMessage)] {\n"
catalog += "        var a = [(name: String, decode: (ProtobufMessage) -> IWAMessage)]()\n"
for reg in registrars { catalog += "        \(reg)(&a)\n" }
catalog += "        return a\n    }\n}\n"
try catalog.write(to: outDir.appendingPathComponent("IWACatalog.gen.swift"), atomically: true, encoding: .utf8)

// Type registry: map IWA persistence type numbers → generated models (only those we
// emit; types pointing into un-vendored archives are left out → raw passthrough).
let mappingURL = inDir.appendingPathComponent("mapping.py")
if let mapping = try? String(contentsOf: mappingURL, encoding: .utf8) {
    var cases = [String]()
    var decodeCases = [String]()
    var nameCases = [String]()
    var seen = 0
    for line in mapping.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Lines look like:  6001: "TST.TableModelArchive",
        guard let colon = trimmed.firstIndex(of: ":"),
              let number = Int(trimmed[trimmed.startIndex..<colon].trimmingCharacters(in: .whitespaces)),
              let q1 = trimmed.firstIndex(of: "\""), let q2 = trimmed[trimmed.index(after: q1)...].firstIndex(of: "\"") else { continue }
        let fqn = String(trimmed[trimmed.index(after: q1)..<q2])
        seen += 1
        nameCases.append("        case \(number): return \"\(fqn)\"")
        if messageFQNs.contains(fqn) {
            cases.append("        case \(number): return \(swiftTypeName(fqn))(m).encoded()")
            decodeCases.append("        case \(number): return \(swiftTypeName(fqn))(m)")
        }
    }
    let registry = """
    // Generated by Scripts/GenerateIWAModels.swift from mapping.py — do not edit.
    import Foundation

    /// Maps IWA persistence type numbers to the generated wire models, so any object
    /// can be decoded into its typed form and re-encoded. Types whose message lives in
    /// an un-vendored archive (TSCE/TSCK/charts/Keynote) are absent — callers treat a
    /// `nil` result as "pass the original bytes through unchanged".
    enum IWATypeRegistry {
        /// Round-trips a known object payload through its typed model (decode → encode).
        /// Returns nil for types this build does not model.
        static func reencode(type: UInt64, payload: [UInt8]) -> [UInt8]? {
            let m = ProtobufMessage(payload)
            switch type {
    \(cases.joined(separator: "\n"))
            default: return nil
            }
        }

        /// Decodes a known object payload into its typed model. Returns nil for types
        /// this build does not model (the caller keeps the raw bytes).
        static func decode(type: UInt64, payload: [UInt8]) -> IWAMessage? {
            let m = ProtobufMessage(payload)
            switch type {
    \(decodeCases.joined(separator: "\n"))
            default: return nil
            }
        }

        /// The fully-qualified persistence name (e.g. "TST.TableModelArchive") for an
        /// IWA type number, across every type in the registry — modeled or not — for
        /// diagnostics, blueprints, and binder output. Nil for unknown numbers.
        static func typeName(_ type: UInt64) -> String? {
            switch type {
    \(nameCases.joined(separator: "\n"))
            default: return nil
            }
        }

        /// The set of IWA type numbers this build can decode into a typed model.
        static let modeledTypes: Set<UInt64> = [\(cases.map { $0.split(separator: " ").compactMap { Int($0.replacingOccurrences(of: ":", with: "")) }.first }.compactMap { $0 }.map(String.init).joined(separator: ", "))]
    }
    """
    try registry.write(to: outDir.appendingPathComponent("IWATypeRegistry.swift"), atomically: true, encoding: .utf8)
    print("Type registry: \(cases.count) modeled of \(seen) total type numbers")
}

print("Generated \(allMessages.count) messages (\(enumFQNs.count) enums) into \(emittedFiles) files at \(outDir.path)")
