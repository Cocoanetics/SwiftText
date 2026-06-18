import Foundation

/// A minimal, read-only model of an Apple Keynote presentation: the deck's slides in
/// order, each carrying its title, body paragraphs, and presenter notes as plain text.
/// Theme layout (master) slides are excluded — only the slides actually in the deck appear.
public struct KeynoteDocument: Sendable, Codable {
	public struct Slide: Sendable, Codable {
		/// The slide's title placeholder text, if any.
		public var title: String?
		/// Body text, one entry per non-empty body placeholder / text shape. Each entry
		/// may itself contain newlines (a bulleted list within one placeholder).
		public var body: [String]
		/// Presenter notes, if any.
		public var notes: String?

		public init(title: String?, body: [String], notes: String?) {
			self.title = title
			self.body = body
			self.notes = notes
		}
	}

	public var slides: [Slide]

	public init(slides: [Slide]) {
		self.slides = slides
	}
}
