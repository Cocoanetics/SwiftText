import Foundation
import Testing
@testable import SwiftTextHTML

struct EMLHTMLExtractorTests {
	private func eml(_ headers: String, _ body: String) -> Data {
		Data((headers + "\n\n" + body).utf8)
	}

	private func multipart(partHeaders: String, body: String) -> Data {
		eml("From: shop@example.com\nTo: customer@example.com\nSubject: Receipt\nMIME-Version: 1.0\nContent-Type: multipart/alternative; boundary=\"b1\"",
			"--b1\n\(partHeaders)\n\n\(body)\n--b1--\n")
	}

	@Test func quotedPrintableUTF8() throws {
		let data = multipart(
			partHeaders: "Content-Type: text/html; charset=UTF-8\nContent-Transfer-Encoding: quoted-printable",
			body: "<html><body><p>Total: =E2=82=AC 19,99 =E2=80=93 Gr=C3=B6=C3=9Fe=\n M=C2=A0=E2=80=BA</p></body></html>")
		let html = try #require(extractHTMLFromEML(data))
		#expect(html.contains("Total: € 19,99 – Größe M\u{00A0}›"))
	}

	@Test func softBreakInsideMultiByteSequence() throws {
		let data = multipart(
			partHeaders: "Content-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: quoted-printable",
			body: "<html>=E2=82=\n=AC</html>")
		#expect(try #require(extractHTMLFromEML(data)).contains("€"))
	}

	@Test func quotedPrintableLeavesNonHexLiteral() throws {
		let data = multipart(
			partHeaders: "Content-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: quoted-printable",
			body: "<html>a=ZZb +1=</html>")
		#expect(try #require(extractHTMLFromEML(data)).contains("a=ZZb +1="))
	}

	@Test func quotedPrintableLatin1() throws {
		let data = multipart(
			partHeaders: "Content-Type: text/html; CHARSET=\"ISO-8859-1\"\nContent-Transfer-Encoding: quoted-printable",
			body: "<html>B=E4r</html>")
		#expect(try #require(extractHTMLFromEML(data)).contains("Bär"))
	}

	@Test func base64UTF8AndLatin1() throws {
		let utf8 = Data("<html>Größe €</html>".utf8).base64EncodedString(options: .lineLength64Characters)
		let d1 = multipart(
			partHeaders: "Content-Type: text/html; charset=UTF-8\nContent-Transfer-Encoding: base64",
			body: utf8)
		#expect(try #require(extractHTMLFromEML(d1)).contains("Größe €"))

		let latin = Data("<html>Bär</html>".data(using: .isoLatin1)!).base64EncodedString()
		let d2 = multipart(
			partHeaders: "Content-Type: text/html; charset=iso-8859-1\nContent-Transfer-Encoding: base64",
			body: latin)
		#expect(try #require(extractHTMLFromEML(d2)).contains("Bär"))
	}

	@Test func eightBitLatin1Data() throws {
		var data = Data("Content-Type: text/html; charset=ISO-8859-1\nContent-Transfer-Encoding: 8bit\n\n<html>B".utf8)
		data.append(0xE4)
		data.append(contentsOf: Array("r</html>".utf8))
		#expect(try #require(extractHTMLFromEML(data)).contains("Bär"))
	}

	@Test func unknownCharsetFallsBackToUTF8() throws {
		let data = multipart(
			partHeaders: "Content-Type: text/html; charset=x-made-up\nContent-Transfer-Encoding: quoted-printable",
			body: "<html>=E2=82=AC</html>")
		#expect(try #require(extractHTMLFromEML(data)).contains("€"))
	}

	@Test func missingCharsetFallsBackToLatin1WhenNotUTF8() throws {
		let data = multipart(
			partHeaders: "Content-Type: text/html\nContent-Transfer-Encoding: quoted-printable",
			body: "<html>B=E4r</html>")
		#expect(try #require(extractHTMLFromEML(data)).contains("Bär"))
	}

	@Test func singlePartHTML() throws {
		let data = eml("From: shop@example.com\nContent-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: quoted-printable",
					   "<html>=E2=82=AC</html>")
		#expect(try #require(extractHTMLFromEML(data)).contains("€"))
	}

	@Test func nestedMultipart() throws {
		let body = """
		--outer
		Content-Type: multipart/alternative; boundary="inner"

		--inner
		Content-Type: text/plain

		plain
		--inner
		Content-Type: text/html; charset=utf-8
		Content-Transfer-Encoding: quoted-printable

		<html>Gr=C3=B6=C3=9Fe</html>
		--inner--
		--outer--
		"""
		let data = eml("Content-Type: multipart/mixed; boundary=outer", body)
		#expect(try #require(extractHTMLFromEML(data)).contains("Größe"))
	}
}
