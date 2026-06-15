import Foundation

// Proves the writer can produce a NATIVE table with custom content: regenerate
// Table.pages through our Snappy+framing+STORED-zip, but rewrite the DataList
// (type 6005) cell strings. If Pages shows the new text in a real grid, native
// table writing works.

enum Snappy {
    static func decompress(_ input: [UInt8]) -> [UInt8] {
        var pos = 0
        func rvar() -> Int { var s = 0, r = 0; while pos < input.count { let b = input[pos]; pos += 1; r |= Int(b & 0x7F) << s; if b & 0x80 == 0 { break }; s += 7 }; return r }
        func rle(_ n: Int) -> Int { var v = 0; for i in 0..<n { v |= Int(input[pos+i]) << (8*i) }; pos += n; return v }
        _ = rvar(); var out = [UInt8]()
        while pos < input.count {
            let tag = input[pos]; pos += 1; let t = tag & 0x03
            if t == 0 { var len = Int(tag >> 2); if len >= 60 { len = rle(len-59) }; len += 1; out.append(contentsOf: input[pos..<pos+len]); pos += len }
            else { var len = 0, off = 0; switch t { case 1: len = Int((tag>>2)&0x07)+4; off = (Int(tag>>5)<<8)|Int(input[pos]); pos += 1; case 2: len = Int(tag>>2)+1; off = rle(2); default: len = Int(tag>>2)+1; off = rle(4) }; var s = out.count-off; for _ in 0..<len { out.append(out[s]); s += 1 } }
        }
        return out
    }
    static func compress(_ input: [UInt8]) -> [UInt8] {
        var output = [UInt8](); appendVarint(UInt64(input.count), to: &output); var ws = 0; let win = 1 << 16
        while ws < input.count { let we = min(ws+win, input.count); window(input, ws, we, &output); ws = we }; return output
    }
    private static func window(_ input: [UInt8], _ start: Int, _ end: Int, _ output: inout [UInt8]) {
        var nextEmit = start
        if end-start >= 4 { var table = [Int](repeating: -1, count: 1<<14); let shift = UInt32(32-14); let lim = end-4; var i = start
            while i <= lim { let w = load32(input,i); let h = Int((w &* 0x1e35a7bd) >> shift); let c = table[h]; table[h] = i
                if c >= start, c < i, i-c <= 65535, load32(input,c)==w { lit(input,nextEmit,i,&output); var m = 4; while i+m<end, input[c+m]==input[i+m] { m += 1 }; copy(i-c,m,&output); i += m; nextEmit = i } else { i += 1 } } }
        lit(input,nextEmit,end,&output)
    }
    private static func load32(_ i: [UInt8], _ x: Int) -> UInt32 { UInt32(i[x]) | (UInt32(i[x+1])<<8) | (UInt32(i[x+2])<<16) | (UInt32(i[x+3])<<24) }
    private static func appendVarint(_ v: UInt64, to o: inout [UInt8]) { var r = v; repeat { var b = UInt8(r & 0x7F); r >>= 7; if r > 0 { b |= 0x80 }; o.append(b) } while r > 0 }
    private static func lit(_ i: [UInt8], _ from: Int, _ to: Int, _ o: inout [UInt8]) { let n = to-from; guard n>0 else { return }; let m = n-1; if m<60 { o.append(UInt8(m<<2)) } else { var lb = [UInt8](); var v = m; while v>0 { lb.append(UInt8(v&0xFF)); v >>= 8 }; o.append(UInt8((59+lb.count)<<2)); o.append(contentsOf: lb) }; o.append(contentsOf: i[from..<to]) }
    private static func copy(_ off: Int, _ len: Int, _ o: inout [UInt8]) { var r = len; while r>0 { if r>=4, r<=11, off<=2047 { o.append(UInt8(((off>>8)<<5)|((r-4)<<2)|0x01)); o.append(UInt8(off&0xFF)); r = 0 } else { let t = min(r,64); o.append(UInt8(((t-1)<<2)|0x02)); o.append(UInt8(off&0xFF)); o.append(UInt8((off>>8)&0xFF)); r -= t } } }
}
func varint(_ v: UInt64) -> [UInt8] { var r = v; var o = [UInt8](); repeat { var b = UInt8(r&0x7F); r >>= 7; if r>0 { b |= 0x80 }; o.append(b) } while r>0; return o }
struct Field { var num: Int; var wire: Int; var value: [UInt8] }
func pbDecode(_ b: [UInt8]) -> [Field] {
    var f = [Field](); var pos = 0
    func rv() -> UInt64? { var s = UInt64(0), r = UInt64(0); while pos < b.count { let x = b[pos]; pos += 1; r |= UInt64(x&0x7F)<<s; if x&0x80==0 { return r }; s += 7 }; return nil }
    while pos < b.count { guard let k = rv() else { break }; let n = Int(k>>3); let w = Int(k&7)
        switch w { case 0: let st = pos; _ = rv(); f.append(Field(num:n,wire:0,value:Array(b[st..<pos]))); case 1: f.append(Field(num:n,wire:1,value:Array(b[pos..<pos+8]))); pos+=8; case 2: guard let l = rv() else { return f }; let e = pos+Int(l); f.append(Field(num:n,wire:2,value:Array(b[pos..<e]))); pos=e; case 5: f.append(Field(num:n,wire:5,value:Array(b[pos..<pos+4]))); pos+=4; default: return f } }
    return f
}
func pbEncode(_ fs: [Field]) -> [UInt8] { var o = [UInt8](); for f in fs { o.append(contentsOf: varint(UInt64(f.num)<<3|UInt64(f.wire))); if f.wire==2 { o.append(contentsOf: varint(UInt64(f.value.count))) }; o.append(contentsOf: f.value) }; return o }
func pbv(_ b: [UInt8]) -> UInt64 { var s = UInt64(0), r = UInt64(0); for x in b { r |= UInt64(x&0x7F)<<s; if x&0x80==0 { break }; s += 7 }; return r }
func decompressFile(_ d: [UInt8]) -> [UInt8] { var pos = 0; var s = [UInt8](); while pos+4 <= d.count { let len = Int(d[pos+1])|Int(d[pos+2])<<8|Int(d[pos+3])<<16; pos += 4; s.append(contentsOf: Snappy.decompress(Array(d[pos..<pos+len]))); pos += len }; return s }
func encodeStream(_ s: [UInt8]) -> [UInt8] { var o = [UInt8](); var pos = 0; let mb = 1<<16; while pos < s.count { let e = min(pos+mb, s.count); let blk = Snappy.compress(Array(s[pos..<e])); o.append(0x00); o.append(UInt8(blk.count&0xFF)); o.append(UInt8((blk.count>>8)&0xFF)); o.append(UInt8((blk.count>>16)&0xFF)); o.append(contentsOf: blk); pos = e }; return o }

// Walk the IWA record stream; for the 6005 DataList object, rewrite its cell strings.
func editStream(_ stream: [UInt8], replacements: [String: String]) -> [UInt8] {
    var out = [UInt8](); var pos = 0
    func rvAt(_ s: [UInt8], _ p: inout Int) -> UInt64 { var sh = UInt64(0), r = UInt64(0); while p < s.count { let x = s[p]; p += 1; r |= UInt64(x&0x7F)<<sh; if x&0x80==0 { break }; sh += 7 }; return r }
    while pos < stream.count {
        let aiLen = Int(rvAt(stream, &pos)); let ai = pbDecode(Array(stream[pos..<pos+aiLen])); pos += aiLen
        let mis = ai.filter { $0.num==2 && $0.wire==2 }
        var payloads = [[UInt8]]()
        for mi in mis { let m = pbDecode(mi.value); let len = Int(m.first { $0.num==3 && $0.wire==0 }.map { pbv($0.value) } ?? 0); payloads.append(Array(stream[pos..<pos+len])); pos += len }
        // Type of first MI:
        let type = mis.first.flatMap { pbDecode($0.value).first { $0.num==1 && $0.wire==0 } }.map { pbv($0.value) } ?? 0
        if type == 6005, var p = payloads.first {
            // 6005: repeated #3 { #1 key, #2 1, #3 string }. Replace #3 strings.
            var fields = pbDecode(p)
            for i in fields.indices where fields[i].num == 3 && fields[i].wire == 2 {
                var entry = pbDecode(fields[i].value)
                for j in entry.indices where entry[j].num == 3 && entry[j].wire == 2 {
                    let s = String(decoding: entry[j].value, as: UTF8.self)
                    if let r = replacements[s] { entry[j].value = Array(r.utf8) }
                }
                fields[i].value = pbEncode(entry)
            }
            p = pbEncode(fields)
            // rebuild record with updated MI length
            var mi = pbDecode(mis[0].value)
            mi = mi.map { $0.num==3 && $0.wire==0 ? Field(num:3,wire:0,value:varint(UInt64(p.count))) : $0 }
            var newAI = ai
            if let idx = newAI.firstIndex(where: { $0.num==2 && $0.wire==2 }) { newAI[idx].value = pbEncode(mi) }
            let aiBytes = pbEncode(newAI)
            out.append(contentsOf: varint(UInt64(aiBytes.count))); out.append(contentsOf: aiBytes); out.append(contentsOf: p)
        } else {
            // verbatim: re-emit ai + payloads
            let aiBytes = pbEncode(ai)
            out.append(contentsOf: varint(UInt64(aiBytes.count))); out.append(contentsOf: aiBytes)
            for pl in payloads { out.append(contentsOf: pl) }
        }
    }
    return out
}

let args = Array(CommandLine.arguments.dropFirst())
let srcDir = args[0]; let outDir = args[1]
let repl = ["H1":"Fruit","H2":"Qty","H3":"Ripe","H4":"Note","row1":"Apple","row2":"Pear","row3":"Plum","row4":"Fig"]
let fm = FileManager.default
try? fm.removeItem(atPath: outDir)
try fm.createDirectory(atPath: outDir+"/Index/Tables", withIntermediateDirectories: true)
try fm.createDirectory(atPath: outDir+"/Metadata", withIntermediateDirectories: true)
// Re-emit every file verbatim through our Snappy+framing; only walk records to
// edit the one DataList that holds the cell strings.
func process(_ path: String, edit: Bool) throws {
    let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: srcDir+"/"+path)))
    let stream = decompressFile(data)
    let out = edit ? editStream(stream, replacements: repl) : stream
    try Data(encodeStream(out)).write(to: URL(fileURLWithPath: outDir+"/"+path))
}
for f in (try fm.contentsOfDirectory(atPath: srcDir+"/Index")) where f.hasSuffix(".iwa") {
    try process("Index/"+f, edit: false)
}
for f in (try fm.contentsOfDirectory(atPath: srcDir+"/Index/Tables")) where f.hasSuffix(".iwa") {
    try process("Index/Tables/"+f, edit: f == "DataList.iwa")
}
for f in (try fm.contentsOfDirectory(atPath: srcDir+"/Metadata")) { try fm.copyItem(atPath: srcDir+"/Metadata/"+f, toPath: outDir+"/Metadata/"+f) }
for f in (try fm.contentsOfDirectory(atPath: srcDir)) where f.hasPrefix("preview") { try fm.copyItem(atPath: srcDir+"/"+f, toPath: outDir+"/"+f) }
print("OK -> \(outDir)")
