import Foundation

/// Resolves a document's embedded images: it reads the data registry (which maps
/// each asset's internal data id to its `Data/` file name), classifies the
/// placed content images apart from thumbnails and theme decorations, assigns
/// each a stable unique reference name, and resolves a text attachment to the
/// content image it displays.
///
/// The registry and drawable layout are matched **structurally** (a message that
/// carries an image file name in field 4; an attachment whose field 1 links to a
/// drawable that carries a data reference), so it does not depend on iWork's
/// version-specific archive type numbers.
struct PagesImageCatalog {
	/// A placed content image: its on-disk `Data/` name and the cleaned, unique
	/// name used both in Markdown references and when extracting to disk.
	struct Asset {
		let dataID: UInt64
		let dataFileName: String
		let referenceName: String
	}

	/// Content images in stable order, each with a unique `referenceName`.
	let assets: [Asset]

	private let store: IWAObjectStore
	/// Reference name for every *content* data id (thumbnails/assets excluded).
	private let referenceNameByDataID: [UInt64: String]

	init(store: IWAObjectStore) {
		self.store = store

		// 1. Read the data registry: data id -> on-disk file name.
		var diskNameByDataID = [UInt64: String]()
		for object in store.objects {
			PagesImageCatalog.collectRegistry(ProtobufMessage(object.payload), depth: 0, into: &diskNameByDataID)
		}

		// 2. Keep placed content images; drop thumbnails and theme decorations.
		let contentIDs = diskNameByDataID
			.filter { !PagesImageCatalog.isThumbnail($0.value) && !PagesImageCatalog.isDecorativeAsset($0.value) }

		// 3. Assign each a cleaned, collision-free reference name (stable order).
		var assets = [Asset]()
		var referenceNames = [UInt64: String]()
		var used = Set<String>()
		for dataID in contentIDs.keys.sorted() {
			let diskName = contentIDs[dataID]!
			let referenceName = PagesImageCatalog.uniqueName(PagesImageCatalog.logicalName(diskName), used: &used)
			referenceNames[dataID] = referenceName
			assets.append(Asset(dataID: dataID, dataFileName: diskName, referenceName: referenceName))
		}
		self.assets = assets
		self.referenceNameByDataID = referenceNames
	}

	/// The reference name of the content image displayed by a text attachment,
	/// or `nil` when the attachment is not an image (a text box, smart field, …).
	func imageReferenceName(forAttachment objectID: UInt64) -> String? {
		guard let dataID = resolveDataID(objectID, depth: 0) else { return nil }
		return referenceNameByDataID[dataID]
	}

	// MARK: Registry

	/// Recursively finds registry entries — messages carrying an image file name
	/// in field 4 (the on-disk name) keyed by the data id in field 1.
	private static func collectRegistry(_ message: ProtobufMessage, depth: Int, into result: inout [UInt64: String]) {
		guard depth < 8 else { return }
		if let dataID = message.varint(1), let nameBytes = message.bytes(4) {
			let name = String(decoding: nameBytes, as: UTF8.self)
			if isImageName(name) {
				result[dataID] = name
			}
		}
		for field in message.fields {
			if case .lengthDelimited(let bytes) = field.value, bytes.count >= 2 {
				collectRegistry(ProtobufMessage(bytes), depth: depth + 1, into: &result)
			}
		}
	}

	// MARK: Attachment → image resolution

	/// Follows an attachment to the content image it shows: it inspects the
	/// object's direct data references, then follows the field-1 attachment →
	/// drawable link. Deliberately shallow so it never wanders the wider graph
	/// (e.g. into a text box's contents).
	private func resolveDataID(_ objectID: UInt64, depth: Int) -> UInt64? {
		guard depth <= 3, let object = store.object(objectID) else { return nil }
		let message = ProtobufMessage(object.payload)

		// 1. A direct data reference on this node, e.g. an image drawable's
		//    `{1: dataID}` field pointing at a content image.
		for field in message.fields {
			if case .lengthDelimited(let bytes) = field.value,
			   let value = ProtobufMessage(bytes).varint(1),
			   referenceNameByDataID[value] != nil {
				return value
			}
		}

		// 2. Otherwise follow the field-1 link (attachment → drawable).
		if let linkBytes = message.bytes(1),
		   let next = ProtobufMessage(linkBytes).varint(1),
		   store.object(next) != nil {
			return resolveDataID(next, depth: depth + 1)
		}
		return nil
	}

	// MARK: Naming helpers (shared with the file-listing fallback)

	static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "pdf"]

	static func isImageName(_ name: String) -> Bool {
		guard !name.isEmpty, !name.contains("/") else { return false }
		return imageExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
	}

	/// Strips Pages' trailing `-<id>` so `image1-31.png` becomes `image1.png`.
	static func logicalName(_ fileName: String) -> String {
		guard let dot = fileName.lastIndex(of: ".") else { return fileName }
		let stem = fileName[..<dot]
		let ext = fileName[dot...]
		guard let suffix = stem.range(of: "-[0-9]+$", options: .regularExpression) else {
			return fileName
		}
		return String(stem[..<suffix.lowerBound]) + String(ext)
	}

	/// Downscaled previews Pages generates alongside each image carry `-small`.
	static func isThumbnail(_ fileName: String) -> Bool {
		fileName.lowercased().contains("-small")
	}

	/// Theme/template decorations (preset image fills, list-bullet glyphs).
	static func isDecorativeAsset(_ fileName: String) -> Bool {
		let name = logicalName(fileName).lowercased()
		return name.hasPrefix("presetimagefill") || name.contains("bullet")
	}

	/// Returns `candidate`, or a `-N`-suffixed variant, not already in `used`.
	static func uniqueName(_ candidate: String, used: inout Set<String>) -> String {
		if used.insert(candidate).inserted { return candidate }
		let url = URL(fileURLWithPath: candidate)
		let stem = url.deletingPathExtension().lastPathComponent
		let ext = url.pathExtension
		var counter = 1
		while true {
			let name = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
			if used.insert(name).inserted { return name }
			counter += 1
		}
	}
}
