import SwiftTextIWA
import Foundation
import SwiftTextCore

/// Builds the iWork object graph for inline images: each image becomes a
/// `TSD.ImageArchive` drawable (type 3005) referencing the placed media via a
/// `TSP.DataReference`, wrapped in a drawable attachment (type 2003) that the body's
/// `#9` run table anchors at a `U+FFFC` character. The media bytes go into the
/// package's `Data/` folder, registered by a `TSP.DataInfo` in `PackageMetadata`.
///
/// Structure verified by pasting an image into Pages and dissecting the saved file
/// (see notes): the image references the template's built-in image style (1731560),
/// carries the natural pixel size (#9) and the page-fitted display size (#4), and the
/// `DataInfo` carries the file's SHA-1 (#2), a preferred name (#3) and on-disk name (#4).
enum PagesImageBuilder {
    /// One resolved image to embed: the raw bytes and a base reference name.
    struct Input {
        let bytes: [UInt8]
        /// A cleaned base name (no extension) used to derive the `Data/` file name.
        let baseName: String
        /// File extension including dot inference, e.g. "png"/"jpeg".
        let pathExtension: String
    }

    /// Everything the writer needs to splice images into the document.
    struct Artifacts {
        /// The drawable-attachment object id for each input image, in order — the body
        /// run table anchors each `U+FFFC` to its attachment.
        let attachmentIDs: [UInt64]
        /// New objects (image drawable + attachment) to append to `Index/Document.iwa`.
        let objects: [IWAObject]
        /// `Data/<name>` file entries to add to the package.
        let dataFiles: [(path: String, bytes: [UInt8])]
        /// `TSP.DataInfo` payloads to register in `PackageMetadata` (`#4`).
        let dataInfos: [[UInt8]]
        /// Highest object id used (for the PackageMetadata high-water mark).
        let maxObjectID: UInt64
    }

    /// The template's built-in image style ("image-0-imageStyle").
    static let imageStyleID: UInt64 = 1731560
    /// Object ids for synthesized image objects start well above the template range
    /// and the synthesized character-style range (`PagesStyleID.synthesizedBase`).
    static let objectBase: UInt64 = 6_500_000
    /// Data ids start safely above the blank template's existing media (max 23).
    static let dataBase: UInt64 = 1000
    /// The default body text-column width (points) — pasted images are scaled to fit it.
    static let columnWidth: Float = 481.89

    static func build(_ inputs: [Input], bodyStorageID: UInt64) -> Artifacts {
        var objects = [IWAObject]()
        var dataFiles = [(path: String, bytes: [UInt8])]()
        var dataInfos = [[UInt8]]()
        var attachmentIDs = [UInt64]()
        var nextObject = objectBase
        var nextData = dataBase

        for (i, input) in inputs.enumerated() {
            let dataID = nextData; nextData += 1
            let imageID = nextObject; nextObject += 1
            let attachmentID = nextObject; nextObject += 1

            let (pw, ph) = ImageDimensions.dimensions(of: input.bytes) ?? (Int(columnWidth), Int(columnWidth))
            let natW = Float(pw), natH = Float(ph)
            // Scale to the column width if wider, preserving aspect ratio.
            let dispW = min(natW, columnWidth)
            let dispH = natW > 0 ? dispW * (natH / natW) : natH

            // Media file + its registry entry.
            let onDisk = "\(input.baseName)-\(dataID).\(input.pathExtension)"
            let preferred = "\(input.baseName).\(input.pathExtension)"
            dataFiles.append((path: "Data/\(onDisk)", bytes: input.bytes))
            dataInfos.append(dataInfo(dataID: dataID, sha1: SHA1.hash(input.bytes), preferred: preferred, onDisk: onDisk))

            objects.append(IWAObject(identifier: imageID, type: 3005,
                                     payload: imageArchive(dataID: dataID, bodyStorageID: bodyStorageID,
                                                           displayW: dispW, displayH: dispH, naturalW: natW, naturalH: natH)))
            objects.append(IWAObject(identifier: attachmentID, type: 2003,
                                     payload: attachmentArchive(drawableID: imageID)))
            attachmentIDs.append(attachmentID)
            _ = i
        }
        return Artifacts(attachmentIDs: attachmentIDs, objects: objects, dataFiles: dataFiles,
                         dataInfos: dataInfos, maxObjectID: nextObject - 1)
    }

    // MARK: Object payloads

    /// `TSD.ImageArchive` (type 3005). Field layout dissected from a Pages-saved file.
    private static func imageArchive(dataID: UInt64, bodyStorageID: UInt64,
                                     displayW: Float, displayH: Float, naturalW: Float, naturalH: Float) -> [UInt8] {
        // #1.#1 geometry: position {0,0}, size {displayW,displayH}, #3=3, #4=0.
        var geometry = ProtobufWriter()
        var pos = ProtobufWriter(); pos.fixed32Field(1, Float(0).bitPattern); pos.fixed32Field(2, Float(0).bitPattern)
        var size = ProtobufWriter(); size.fixed32Field(1, displayW.bitPattern); size.fixed32Field(2, displayH.bitPattern)
        geometry.bytesField(1, pos.bytes)
        geometry.bytesField(2, size.bytes)
        geometry.varintField(3, 3)
        geometry.fixed32Field(4, Float(0).bitPattern)

        // #1.#3: a drawable defaults message Pages always writes.
        var defaults = ProtobufWriter()
        defaults.varintField(1, 4); defaults.varintField(2, 2); defaults.varintField(3, 1)
        defaults.fixed32Field(4, Float(12).bitPattern); defaults.fixed32Field(5, Float(0.5).bitPattern); defaults.varintField(6, 0)

        var drawable = ProtobufWriter()              // TSD.DrawableArchive super
        drawable.bytesField(1, geometry.bytes)
        drawable.bytesField(2, reference(bodyStorageID))   // parent storage
        drawable.bytesField(3, defaults.bytes)
        drawable.varintField(5, 0)
        drawable.varintField(7, 1)
        drawable.varintField(12, 0)
        drawable.varintField(13, 0)

        var image = ProtobufWriter()
        image.bytesField(1, drawable.bytes)
        image.bytesField(3, reference(imageStyleID))       // image style
        var disp = ProtobufWriter(); disp.fixed32Field(1, displayW.bitPattern); disp.fixed32Field(2, displayH.bitPattern)
        image.bytesField(4, disp.bytes)                    // display size
        image.varintField(7, 0)
        var nat = ProtobufWriter(); nat.fixed32Field(1, naturalW.bitPattern); nat.fixed32Field(2, naturalH.bitPattern)
        image.bytesField(9, nat.bytes)                     // natural size
        image.bytesField(11, reference(dataID))            // DataReference → media
        image.varintField(18, 0)
        return image.bytes
    }

    /// Drawable attachment (type 2003): `{#1:{#1: drawableID}, #2:0, #3:0, #4:0, #5:0}`.
    private static func attachmentArchive(drawableID: UInt64) -> [UInt8] {
        var w = ProtobufWriter()
        w.bytesField(1, reference(drawableID))
        w.varintField(2, 0)
        w.fixed32Field(3, Float(0).bitPattern)
        w.varintField(4, 0)
        w.fixed32Field(5, Float(0).bitPattern)
        return w.bytes
    }

    /// `TSP.DataInfo`: `{#1: id, #2: sha1(20B), #3: preferredName, #4: onDiskName}`.
    private static func dataInfo(dataID: UInt64, sha1: [UInt8], preferred: String, onDisk: String) -> [UInt8] {
        var w = ProtobufWriter()
        w.varintField(1, dataID)
        w.bytesField(2, sha1)
        w.stringField(3, preferred)
        w.stringField(4, onDisk)
        return w.bytes
    }

    /// A `TSP.Reference` `{#1: identifier}`.
    private static func reference(_ id: UInt64) -> [UInt8] {
        var w = ProtobufWriter(); w.varintField(1, id); return w.bytes
    }
}

/// Minimal SHA-1 (RFC 3174) — `PackageMetadata` registers each media file by its digest.
enum SHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        var msg = message
        let bitLen = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in stride(from: 56, through: 0, by: -8) { msg.append(UInt8((bitLen >> UInt64(i)) & 0xff)) }

        func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 { (v << n) | (v >> (32 - n)) }
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for t in 0..<16 {
                let j = chunk + t * 4
                w[t] = UInt32(msg[j]) << 24 | UInt32(msg[j + 1]) << 16 | UInt32(msg[j + 2]) << 8 | UInt32(msg[j + 3])
            }
            for t in 16..<80 { w[t] = rotl(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1) }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for t in 0..<80 {
                let f: UInt32, k: UInt32
                switch t {
                case 0..<20:  f = (b & c) | (~b & d);            k = 0x5A82_7999
                case 20..<40: f = b ^ c ^ d;                     k = 0x6ED9_EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d);   k = 0x8F1B_BCDC
                default:      f = b ^ c ^ d;                     k = 0xCA62_C1D6
                }
                let tmp = rotl(a, 5) &+ f &+ e &+ k &+ w[t]
                e = d; d = c; c = rotl(b, 30); b = a; a = tmp
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
        }
        var out = [UInt8]()
        for v in h { for i in stride(from: 24, through: 0, by: -8) { out.append(UInt8((v >> UInt32(i)) & 0xff)) } }
        return out
    }
}
