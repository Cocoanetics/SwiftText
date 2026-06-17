import Foundation

// Dev-time generator: captures the native-table object set (the delta between a
// document with one table and the blank template) into a committed Swift source
// file, `Sources/SwiftTextPages/Generated/PagesTableTemplate.swift`.
//
// Usage: extract a blank `.pages` and a `.pages` containing a single default table
// into two directories, then:
//
//   swift Scripts/GeneratePagesTableTemplate.swift <blankDir> <tableDir> > \
//       Sources/SwiftTextPages/Generated/PagesTableTemplate.swift
//
// where each dir holds Index/ (+ Index/Tables/) and Metadata/. The generator diffs
// the object-id sets, captures every object present only in the table document
// (verbatim record bytes: length-prefixed ArchiveInfo + payload, so MessageInfo
// object_references survive), and emits them grouped by file. The captured cell
// content is the table's placeholders ("H1".., "row1"..) — overwritten per-table
// by `PagesTableBuilder`, so nothing personal is embedded.

// MARK: Snappy (decompress only — reading existing files)

enum Snappy {
    static func decompress(_ i: [UInt8]) -> [UInt8] { var p = 0
        func rv() -> Int { var s = 0, r = 0; while p < i.count { let b = i[p]; p += 1; r |= Int(b & 0x7F) << s; if b & 0x80 == 0 { break }; s += 7 }; return r }
        func rl(_ n: Int) -> Int { var v = 0; for k in 0..<n { v |= Int(i[p+k]) << (8*k) }; p += n; return v }
        _ = rv(); var o = [UInt8]()
        while p < i.count { let t = i[p]; p += 1; let y = t & 3
            if y == 0 { var l = Int(t >> 2); if l >= 60 { l = rl(l-59) }; l += 1; o.append(contentsOf: i[p..<p+l]); p += l }
            else { var l = 0, f = 0; switch y { case 1: l = Int((t>>2)&7)+4; f = (Int(t>>5)<<8)|Int(i[p]); p += 1; case 2: l = Int(t>>2)+1; f = rl(2); default: l = Int(t>>2)+1; f = rl(4) }; var s = o.count-f; for _ in 0..<l { o.append(o[s]); s += 1 } } }
        return o }
}

struct F { var n: Int; var w: Int; var v: [UInt8] }
func dec(_ b: [UInt8]) -> [F] { var f = [F](); var p = 0
    func rv() -> UInt64? { var s = UInt64(0), r = UInt64(0); while p < b.count { let x = b[p]; p += 1; r |= UInt64(x & 0x7F) << s; if x & 0x80 == 0 { return r }; s += 7 }; return nil }
    while p < b.count { guard let k = rv() else { break }; let n = Int(k>>3); let w = Int(k&7)
        switch w { case 0: let st = p; _ = rv(); f.append(F(n: n, w: 0, v: Array(b[st..<p]))); case 1: f.append(F(n: n, w: 1, v: Array(b[p..<p+8]))); p += 8; case 2: guard let l = rv() else { return f }; let e = p+Int(l); f.append(F(n: n, w: 2, v: Array(b[p..<e]))); p = e; case 5: f.append(F(n: n, w: 5, v: Array(b[p..<p+4]))); p += 4; default: return f } }
    return f }
func pv(_ b: [UInt8]) -> UInt64 { var s = UInt64(0), r = UInt64(0); for x in b { r |= UInt64(x & 0x7F) << s; if x & 0x80 == 0 { break }; s += 7 }; return r }

func defile(_ d: [UInt8]) -> [UInt8] { var p = 0; var s = [UInt8](); while p+4 <= d.count { let l = Int(d[p+1])|Int(d[p+2])<<8|Int(d[p+3])<<16; p += 4; s.append(contentsOf: Snappy.decompress(Array(d[p..<p+l]))); p += l }; return s }

struct Rec { var id: UInt64; var type: UInt64; var bytes: [UInt8] }
func parseRecords(_ stream: [UInt8]) -> [Rec] {
    var recs = [Rec](); var p = 0
    func rvAt() -> UInt64 { var s = UInt64(0), r = UInt64(0); while p < stream.count { let x = stream[p]; p += 1; r |= UInt64(x & 0x7F) << s; if x & 0x80 == 0 { break }; s += 7 }; return r }
    while p < stream.count {
        let start = p; let aiLen = Int(rvAt()); let ai = dec(Array(stream[p..<p+aiLen])); p += aiLen
        let id = pv(ai.first { $0.n == 1 }?.v ?? [])
        var type: UInt64 = 0; var tot = 0
        for mi in ai where mi.n == 2 && mi.w == 2 { let m = dec(mi.v); if type == 0 { type = pv(m.first { $0.n == 1 }?.v ?? []) }; tot += Int(pv(m.first { $0.n == 3 }?.v ?? [])) }
        p += tot
        recs.append(Rec(id: id, type: type, bytes: Array(stream[start..<p])))
    }
    return recs
}
func read(_ path: String) -> [UInt8] { [UInt8]((try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()) }

let blankDir = CommandLine.arguments[1], tableDir = CommandLine.arguments[2]
let fm = FileManager.default

// 1. object-id set of the blank document (across all Index/*.iwa)
func idSet(_ dir: String) -> Set<UInt64> {
    var ids = Set<UInt64>()
    func scan(_ sub: String) {
        let base = dir + "/" + sub
        for f in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where f.hasSuffix(".iwa") {
            for r in parseRecords(defile(read(base + "/" + f))) { ids.insert(r.id) }
        }
    }
    scan("Index"); scan("Index/Tables")
    return ids
}
let blankIDs = idSet(blankDir)

// 2. capture delta records, grouped by file (relative path under the package)
struct Captured { var file: String; var id: UInt64; var type: UInt64; var base64: String }
var captured = [Captured]()
func capture(_ sub: String) {
    let base = tableDir + "/" + sub
    for f in (try? fm.contentsOfDirectory(atPath: base).sorted()) ?? [] where f.hasSuffix(".iwa") {
        for r in parseRecords(defile(read(base + "/" + f))) where !blankIDs.contains(r.id) {
            captured.append(Captured(file: sub + "/" + f, id: r.id, type: r.type, base64: Data(r.bytes).base64EncodedString()))
        }
    }
}
capture("Index"); capture("Index/Tables")

// 3. the table document's Metadata.iwa (PackageMetadata + the shared-object map),
//    used wholesale for table documents (component layout matches after injection).
let metadataBase64 = Data(read(tableDir + "/Index/Metadata.iwa")).base64EncodedString()

func chunked(_ s: String, _ n: Int = 120) -> String {
    var out = ""; var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: n, limitedBy: s.endIndex) ?? s.endIndex; out += "\t\t\"" + s[i..<j] + "\" +\n"; i = j }
    return out + "\t\t\"\""
}

// 4. emit Swift
print("// swift-format-ignore-file")
print("// Generated by Scripts/GeneratePagesTableTemplate.swift — do not edit by hand.")
print("// The native-table object set captured from a single-table .pages, minus the")
print("// blank template's objects. Records are verbatim (length-prefixed ArchiveInfo +")
print("// payload) so MessageInfo.object_references survive injection.")
print("import Foundation\n")
print("enum PagesTableTemplate {")
print("\tstruct Record { let file: String; let id: UInt64; let type: UInt64; let base64: String }")
print("\t/// Every object present in the captured table document but not the blank template.")
print("\tstatic let records: [Record] = [")
for c in captured {
    print("\t\tRecord(file: \"\(c.file)\", id: \(c.id), type: \(c.type), base64:")
    print(chunked(c.base64))
    print("\t\t),")
}
print("\t]")
print("\t/// The table document's `Index/Metadata.iwa` (PackageMetadata), used for table docs.")
print("\tstatic let metadataBase64: String =")
print(chunked(metadataBase64))
print("")
// dimension-object ids (stable for the captured table)
print("\t// Identifiers of the regenerated, dimension-dependent objects (captured table).")
print("\tstatic let columnRowUIDsID: UInt64 = 1733217")
print("\tstatic let tileID: UInt64 = 1733209")
print("\tstatic let cellStringsID: UInt64 = 1733190")
print("\tstatic let modelID: UInt64 = 1733271")
print("\tstatic let rowHeadersBucketID: UInt64 = 1733229")
print("\tstatic let columnHeadersBucketID: UInt64 = 1733266")
print("\tstatic let tableInfoID: UInt64 = 1733236")
print("\tstatic let attachmentID: UInt64 = 1734389")
print("\tstatic let bodyStorageID: UInt64 = 1732539")
let maxID = captured.map { $0.id }.max() ?? 0
print("\t/// Highest captured object id (for the package id high-water mark).")
print("\tstatic let maxObjectID: UInt64 = \(maxID)")
print("}")
