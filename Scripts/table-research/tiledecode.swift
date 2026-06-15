import Foundation
// Decode the TST.Tile (type 6002) cell-storage format precisely.
enum Snappy {
    static func decompress(_ input: [UInt8]) -> [UInt8] {
        var pos = 0
        func rvar() -> Int { var s = 0, r = 0; while pos < input.count { let b = input[pos]; pos += 1; r |= Int(b & 0x7F) << s; if b & 0x80 == 0 { break }; s += 7 }; return r }
        func rle(_ n: Int) -> Int { var v = 0; for i in 0..<n { v |= Int(input[pos+i]) << (8*i) }; pos += n; return v }
        _ = rvar(); var out = [UInt8]()
        while pos < input.count { let tag = input[pos]; pos += 1; let t = tag & 3
            if t == 0 { var len = Int(tag >> 2); if len >= 60 { len = rle(len-59) }; len += 1; out.append(contentsOf: input[pos..<pos+len]); pos += len }
            else { var len = 0, off = 0; switch t { case 1: len = Int((tag>>2)&7)+4; off=(Int(tag>>5)<<8)|Int(input[pos]); pos+=1; case 2: len=Int(tag>>2)+1; off=rle(2); default: len=Int(tag>>2)+1; off=rle(4) }; var s=out.count-off; for _ in 0..<len { out.append(out[s]); s+=1 } } }
        return out
    }
}
struct F { var num: Int; var wire: Int; var value: [UInt8] }
func dec(_ b: [UInt8]) -> [F] { var f=[F](); var p=0
    func rv()->UInt64?{var s=UInt64(0),r=UInt64(0);while p<b.count{let x=b[p];p+=1;r|=UInt64(x&0x7F)<<s;if x&0x80==0{return r};s+=7};return nil}
    while p<b.count{guard let k=rv() else{break};let n=Int(k>>3);let w=Int(k&7)
        switch w{case 0:let st=p;_=rv();f.append(F(num:n,wire:0,value:Array(b[st..<p])));case 1:f.append(F(num:n,wire:1,value:Array(b[p..<p+8])));p+=8;case 2:guard let l=rv() else{return f};let e=p+Int(l);f.append(F(num:n,wire:2,value:Array(b[p..<e])));p=e;case 5:f.append(F(num:n,wire:5,value:Array(b[p..<p+4])));p+=4;default:return f}}
    return f }
func pbVarint(_ b: [UInt8]) -> UInt64 { var s=UInt64(0),r=UInt64(0); for x in b { r|=UInt64(x&0x7F)<<s; if x&0x80==0 {break}; s+=7 }; return r }
func hexs(_ b: ArraySlice<UInt8>) -> String { b.map { String(format:"%02x",$0) }.joined(separator:" ") }
func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i+1])<<8 }

let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
var pos = 0; var stream = [UInt8]()
while pos+4 <= data.count { let len = Int(data[pos+1])|Int(data[pos+2])<<8|Int(data[pos+3])<<16; pos+=4; stream.append(contentsOf: Snappy.decompress(Array(data[pos..<pos+len]))); pos+=len }
// parse first object payload
pos = 0
func rvAt() -> UInt64 { var s=UInt64(0),r=UInt64(0); while pos<stream.count{let x=stream[pos];pos+=1;r|=UInt64(x&0x7F)<<s;if x&0x80==0{break};s+=7};return r }
let aiLen = Int(rvAt()); let ai = dec(Array(stream[pos..<pos+aiLen])); pos+=aiLen
let mi = dec(ai.first(where: {$0.num==2})!.value); let plen = Int(pbVarint(mi.first(where: {$0.num==3})!.value))
let payload = Array(stream[pos..<pos+plen])
let tile = dec(payload)
print("Tile top fields: \(tile.map{ "#\($0.num)(w\($0.wire),\($0.value.count)b)" }.joined(separator:" "))")
var rowIdx = 0
for row in tile where row.num == 5 && row.wire == 2 {
    let r = dec(row.value)
    let rIndex = r.first{$0.num==1}.map{_ in "?"} ?? "?"
    let cols = r.first{$0.num==2}
    let f4 = r.first{$0.num==4}?.value ?? []
    let f6 = r.first{$0.num==6}?.value ?? []
    // #4 = uint16 column offsets into #6, terminated by 0xffff
    var offs = [Int](); var i = 0
    while i+1 < f4.count { let v = u16(f4,i); if v == 0xffff { break }; offs.append(v); i += 2 }
    print("--- row \(rowIdx): fields \(r.map{"#\($0.num)(\($0.value.count)b)"}.joined(separator:" ")); colOffsets=\(offs)")
    print("    #6(\(f6.count)b): \(hexs(f6[0..<min(f6.count,64)]))")
    // split #6 by offsets
    for (ci,o) in offs.enumerated() {
        let end = ci+1 < offs.count ? offs[ci+1] : f6.count
        if o <= f6.count && end <= f6.count && o < end { print("      cell[\(ci)] @\(o): \(hexs(f6[o..<end]))") }
    }
    rowIdx += 1
    if rowIdx >= 2 { break }
}
