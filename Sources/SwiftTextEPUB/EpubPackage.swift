//  EpubPackage.swift
//  SwiftTextEPUB
//
//  Assembles every file in the EPUB: the OCF `container.xml`, the OPF package
//  document (Dublin Core metadata + manifest + spine), the EPUB3 nav document
//  and legacy NCX, the optional cover and generated title page, and one XHTML
//  content document per chapter. Emits an ordered `[EpubFile]` for the archive
//  writer, with `mimetype` first and stored.

import Foundation

enum EpubPackageBuilder {

	/// The container directory holding the OPF and content — `OEBPS` by convention.
	private static let contentDirectory = "OEBPS"

	/// Builds the ordered file list for an EPUB from its parts.
	static func build(metadata: EpubMetadata, chapters: [EpubChapter], cover: CoverImage?, userCSS: String?) -> [EpubFile] {
		var files: [EpubFile] = []

		// 1. mimetype — MUST be first and stored, per the OCF spec.
		files.append(EpubFile(path: "mimetype", data: Data("application/epub+zip".utf8), compression: .stored))

		// 2. OCF container pointing at the package document.
		files.append(text("META-INF/container.xml", containerXML()))

		// 3. Stylesheet (bundled default + optional appended user CSS).
		var css = DefaultStylesheet.css
		if let userCSS, !userCSS.isEmpty {
			css += "\n\n/* User stylesheet */\n" + userCSS
		}
		files.append(text("\(contentDirectory)/styles/stylesheet.css", css))

		// 4. Cover image + cover page.
		if let cover {
			files.append(EpubFile(path: "\(contentDirectory)/\(cover.path)", data: cover.data, compression: .stored))
			files.append(text("\(contentDirectory)/text/cover.xhtml", coverXHTML(cover: cover, language: metadata.language)))
		}

		// 5. Generated title page.
		files.append(text("\(contentDirectory)/text/titlepage.xhtml", titlePageXHTML(metadata: metadata)))

		// 6. Chapter content documents.
		for chapter in chapters {
			files.append(text("\(contentDirectory)/text/\(chapter.id).xhtml", chapterXHTML(chapter: chapter, language: metadata.language)))
		}

		// 7. Navigation documents.
		files.append(text("\(contentDirectory)/nav.xhtml", navXHTML(metadata: metadata, chapters: chapters, hasCover: cover != nil)))
		files.append(text("\(contentDirectory)/toc.ncx", ncx(metadata: metadata, chapters: chapters)))

		// 8. The package document last (its content depends on all the above).
		files.append(text("\(contentDirectory)/content.opf", opf(metadata: metadata, chapters: chapters, cover: cover)))

		return files
	}

	// MARK: - File helpers

	private static func text(_ path: String, _ content: String) -> EpubFile {
		EpubFile(path: path, data: Data(content.utf8), compression: .deflate)
	}

	/// Wraps a body fragment in a complete XHTML document.
	private static func xhtmlDocument(title: String, cssHref: String, bodyType: String?, bodyClass: String?, body: String, language: String) -> String {
		let lang = XML.escapeAttribute(language)
		let bodyAttrs = [
			bodyType.map { "epub:type=\"\($0)\"" },
			bodyClass.map { "class=\"\($0)\"" }
		].compactMap { $0 }.joined(separator: " ")
		let bodyTag = bodyAttrs.isEmpty ? "<body>" : "<body \(bodyAttrs)>"
		return """
		<?xml version="1.0" encoding="UTF-8"?>
		<!DOCTYPE html>
		<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(lang)" xml:lang="\(lang)">
		<head>
		<meta charset="utf-8"/>
		<title>\(XML.escapeText(title))</title>
		<link rel="stylesheet" type="text/css" href="\(cssHref)"/>
		</head>
		\(bodyTag)
		\(body)
		</body>
		</html>
		"""
	}

	// MARK: - Container

	private static func containerXML() -> String {
		"""
		<?xml version="1.0" encoding="UTF-8"?>
		<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
		  <rootfiles>
		    <rootfile full-path="\(contentDirectory)/content.opf" media-type="application/oebps-package+xml"/>
		  </rootfiles>
		</container>
		"""
	}

	// MARK: - Content documents

	private static func chapterXHTML(chapter: EpubChapter, language: String) -> String {
		let bodyType = chapter.isFrontmatter ? "frontmatter" : "bodymatter"
		let sectionType = chapter.isFrontmatter ? "frontmatter" : "chapter"
		let section = """
		<section id="\(chapter.id)" epub:type="\(sectionType)">
		\(chapter.bodyXHTML)
		</section>
		"""
		return xhtmlDocument(
			title: chapter.title,
			cssHref: "../styles/stylesheet.css",
			bodyType: bodyType,
			bodyClass: nil,
			body: section,
			language: language
		)
	}

	private static func titlePageXHTML(metadata: EpubMetadata) -> String {
		var body = "<section epub:type=\"titlepage\" class=\"titlepage\">\n"
		body += "<h1 class=\"title\">\(XML.escapeText(metadata.title))</h1>\n"
		for author in metadata.authors where !author.isEmpty {
			body += "<p class=\"author\">\(XML.escapeText(author))</p>\n"
		}
		body += "</section>"
		return xhtmlDocument(
			title: metadata.title,
			cssHref: "../styles/stylesheet.css",
			bodyType: "frontmatter",
			bodyClass: nil,
			body: body,
			language: metadata.language
		)
	}

	private static func coverXHTML(cover: CoverImage, language: String) -> String {
		let href = "../\(cover.path)"
		let inner: String
		if let width = cover.width, let height = cover.height, width > 0, height > 0 {
			// An SVG wrapper scaled to the image lets the cover fill the screen
			// while preserving aspect ratio — the technique reading systems expect.
			inner = """
			<div id="cover-image">
			<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" width="100%" height="100%" viewBox="0 0 \(width) \(height)" preserveAspectRatio="xMidYMid meet">
			<image width="\(width)" height="\(height)" xlink:href="\(XML.escapeAttribute(href))"/>
			</svg>
			</div>
			"""
		} else {
			inner = "<div id=\"cover-image\"><img src=\"\(XML.escapeAttribute(href))\" alt=\"Cover\"/></div>"
		}
		return xhtmlDocument(
			title: "Cover",
			cssHref: "../styles/stylesheet.css",
			bodyType: "cover",
			bodyClass: "cover",
			body: inner,
			language: language
		)
	}

	// MARK: - Navigation

	private static func navXHTML(metadata: EpubMetadata, chapters: [EpubChapter], hasCover: Bool) -> String {
		let tocItems = chapters.filter { !$0.isFrontmatter }.map { chapter in
			"      <li><a href=\"text/\(chapter.id).xhtml#\(chapter.id)\">\(XML.escapeText(chapter.title))</a></li>"
		}.joined(separator: "\n")

		var landmarks = ""
		if hasCover {
			landmarks += "      <li><a href=\"text/cover.xhtml\" epub:type=\"cover\">Cover</a></li>\n"
		}
		landmarks += "      <li><a href=\"text/titlepage.xhtml\" epub:type=\"titlepage\">Title Page</a></li>\n"
		landmarks += "      <li><a href=\"nav.xhtml#toc\" epub:type=\"toc\">Table of Contents</a></li>"
		if let firstBody = chapters.first(where: { !$0.isFrontmatter }) {
			landmarks += "\n      <li><a href=\"text/\(firstBody.id).xhtml\" epub:type=\"bodymatter\">Beginning</a></li>"
		}

		let body = """
		<nav epub:type="toc" id="toc" role="doc-toc">
		<h1>\(XML.escapeText(metadata.title))</h1>
		    <ol>
		\(tocItems)
		    </ol>
		</nav>
		<nav epub:type="landmarks" id="landmarks" hidden="hidden">
		    <ol>
		\(landmarks)
		    </ol>
		</nav>
		"""
		return xhtmlDocument(
			title: "Table of Contents",
			cssHref: "styles/stylesheet.css",
			bodyType: "frontmatter",
			bodyClass: nil,
			body: body,
			language: metadata.language
		)
	}

	private static func ncx(metadata: EpubMetadata, chapters: [EpubChapter]) -> String {
		var navPoints = ""
		var order = 0
		for chapter in chapters where !chapter.isFrontmatter {
			order += 1
			navPoints += """
			    <navPoint id="navPoint-\(order)" playOrder="\(order)">
			      <navLabel><text>\(XML.escapeText(chapter.title))</text></navLabel>
			      <content src="text/\(chapter.id).xhtml#\(chapter.id)"/>
			    </navPoint>

			"""
		}
		return """
		<?xml version="1.0" encoding="UTF-8"?>
		<ncx version="2005-1" xmlns="http://www.daisy.org/z3986/2005/ncx/">
		  <head>
		    <meta name="dtb:uid" content="\(XML.escapeAttribute(metadata.identifier))"/>
		    <meta name="dtb:depth" content="1"/>
		    <meta name="dtb:totalPageCount" content="0"/>
		    <meta name="dtb:maxPageNumber" content="0"/>
		  </head>
		  <docTitle><text>\(XML.escapeText(metadata.title))</text></docTitle>
		  <navMap>
		\(navPoints)  </navMap>
		</ncx>
		"""
	}

	// MARK: - Package document (OPF)

	private static func opf(metadata: EpubMetadata, chapters: [EpubChapter], cover: CoverImage?) -> String {
		// Metadata
		var meta = "    <dc:identifier id=\"pub-id\">\(XML.escapeText(metadata.identifier))</dc:identifier>\n"
		meta += "    <dc:title>\(XML.escapeText(metadata.title))</dc:title>\n"
		meta += "    <dc:language>\(XML.escapeText(metadata.language))</dc:language>\n"
		for (index, author) in metadata.authors.enumerated() where !author.isEmpty {
			let id = "creator-\(index + 1)"
			meta += "    <dc:creator id=\"\(id)\">\(XML.escapeText(author))</dc:creator>\n"
			meta += "    <meta refines=\"#\(id)\" property=\"role\" scheme=\"marc:relators\">aut</meta>\n"
		}
		meta += "    <meta property=\"dcterms:modified\">\(metadata.modifiedUTCString)</meta>"
		if cover != nil {
			meta += "\n    <meta name=\"cover\" content=\"cover-image\"/>"
		}

		// Manifest
		var manifest = "    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
		manifest += "    <item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n"
		manifest += "    <item id=\"css\" href=\"styles/stylesheet.css\" media-type=\"text/css\"/>\n"
		if let cover {
			manifest += "    <item id=\"cover-image\" href=\"\(cover.path)\" media-type=\"\(cover.mediaType)\" properties=\"cover-image\"/>\n"
			let svgProperty = (cover.width != nil && cover.height != nil) ? " properties=\"svg\"" : ""
			manifest += "    <item id=\"cover\" href=\"text/cover.xhtml\" media-type=\"application/xhtml+xml\"\(svgProperty)/>\n"
		}
		manifest += "    <item id=\"titlepage\" href=\"text/titlepage.xhtml\" media-type=\"application/xhtml+xml\"/>\n"
		for chapter in chapters {
			manifest += "    <item id=\"\(chapter.id)\" href=\"text/\(chapter.id).xhtml\" media-type=\"application/xhtml+xml\"/>\n"
		}

		// Spine: cover, title page, nav, then chapters in document order.
		var spine = ""
		if cover != nil {
			spine += "    <itemref idref=\"cover\" linear=\"no\"/>\n"
		}
		spine += "    <itemref idref=\"titlepage\"/>\n"
		spine += "    <itemref idref=\"nav\"/>\n"
		for chapter in chapters {
			spine += "    <itemref idref=\"\(chapter.id)\"/>\n"
		}

		return """
		<?xml version="1.0" encoding="UTF-8"?>
		<package xmlns="http://www.idpf.org/2007/opf" version="3.0" xml:lang="\(XML.escapeAttribute(metadata.language))" unique-identifier="pub-id">
		  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
		\(meta)
		  </metadata>
		  <manifest>
		\(manifest)  </manifest>
		  <spine toc="ncx">
		\(spine)  </spine>
		</package>
		"""
	}
}
