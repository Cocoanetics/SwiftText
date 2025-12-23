import Foundation

public protocol DOMNode
{
	var name: String { get }
	func markdown() -> String
	func markdown(imageResolver: ((String) -> String?)?) -> String
	func text() -> String
}

private let blockLevelElements: Set<String> = [
	"p", "div", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6",
	"blockquote", "pre", "figure", "table", "noscript"
]

public extension DOMNode
{
	var isBlockLevelElement: Bool
	{
		blockLevelElements.contains(name)
	}
}
