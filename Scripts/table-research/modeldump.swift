import Foundation
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
struct F { var num: Int; var wire: Int; var v: [UInt8] }
func dec(_ b: [UInt8]) -> [F] { var f=[F](); var p=0
    func rv()->UInt64?{var s=UInt64(0),r=UInt64(0);while p<b.count{let x=b[p];p+=1;r|=UInt64(x&0x7F)<<s;if x&0x80==0{return r};s+=7};return nil}
    while p<b.count{guard let k=rv() else{break};let n=Int(k>>3);let w=Int(k&7)
        switch w{case 0:let st=p;_=rv();f.append(F(num:n,wire:0,v:Array(b[st..<p])));case 1:f.append(F(num:n,wire:1,v:Array(b[p..<p+8])));p+=8;case 2:guard let l=rv() else{return f};let e=p+Int(l);f.append(F(num:n,wire:2,v:Array(b[p..<e])));p=e;case 5:f.append(F(num:n,wire:5,v:Array(b[p..<p+4])));p+=4;default:return f}}
    return f }
func pbv(_ b: [UInt8]) -> UInt64 { var s=UInt64(0),r=UInt64(0); for x in b { r|=UInt64(x&0x7F)<<s; if x&0x80==0 {break}; s+=7 }; return r }
let wantType = UInt64(CommandLine.arguments[2])!
let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
var pos = 0; var stream = [UInt8]()
while pos+4 <= data.count { let len = Int(data[pos+1])|Int(data[pos+2])<<8|Int(data[pos+3])<<16; pos+=4; stream.append(contentsOf: Snappy.decompress(Array(data[pos..<pos+len]))); pos+=len }
pos = 0
func rvAt() -> UInt64 { var s=UInt64(0),r=UInt64(0); while pos<stream.count{let x=stream[pos];pos+=1;r|=UInt64(x&0x7F)<<s;if x&0x80==0{break};s+=7};return r }
while pos < stream.count {
    let aiLen = Int(rvAt()); let ai = dec(Array(stream[pos..<pos+aiLen])); pos+=aiLen
    for mi in ai where mi.num==2 && mi.wire==2 {
        let m = dec(mi.v); let type = pbv(m.first(where:{$0.num==1})?.v ?? []); let plen = Int(pbv(m.first(where:{$0.num==3})?.v ?? []))
        let payload = Array(stream[pos..<pos+plen]); pos += plen
        if type == wantType {
            print("type \(type), \(plen) bytes:")
            for f in dec(payload) {
                switch f.wire {
                case 0: print("  #\(f.num) varint: \(pbv(f.v))")
                case 2: let s = String(decoding: f.v, as: UTF8.self); let printable = f.v.allSatisfy { $0>=0x20 && $0<0x7f }; print("  #\(f.num) bytes(\(f.v.count))\(printable && !f.v.isEmpty ? " \"\(s)\"" : ""): \(f.v.prefix(20).map{String(format:"%02x",$0)}.joined(separator:" "))")
                case 5: print("  #\(f.num) f32: \(f.v.map{String(format:"%02x",$0)}.joined())")
                default: print("  #\(f.num) w\(f.wire)")
                }
            }
            exit(0)
        }
    }
}
