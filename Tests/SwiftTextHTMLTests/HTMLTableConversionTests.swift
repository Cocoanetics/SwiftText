import Foundation
import SwiftTextHTML
import Testing

@Test
func markdownIncludesCapabilitiesTableFromGitHubStyleHTML() async throws {
	let html = """
	<html>
	<body>
	<table>
		<thead>
			<tr>
				<th>Icon</th>
				<th>Capability</th>
				<th>Description</th>
			</tr>
		</thead>
		<tbody>
			<tr>
				<td><img src="calendar.png" alt="Calendar" /></td>
				<td>Calendar</td>
				<td>Create and manage events.</td>
			</tr>
			<tr>
				<td><img src="contacts.png" alt="Contacts" /></td>
				<td>Contacts</td>
				<td>Find people and groups.</td>
			</tr>
			<tr>
				<td><img src="location.png" alt="Location" /></td>
				<td>Location</td>
				<td>Resolve places and coordinates.</td>
			</tr>
			<tr>
				<td><img src="maps.png" alt="Maps" /></td>
				<td>Maps</td>
				<td>Search and route across maps.</td>
			</tr>
			<tr>
				<td><img src="messages.png" alt="Messages" /></td>
				<td>Messages</td>
				<td>Send and read conversations.</td>
			</tr>
			<tr>
				<td><img src="reminders.png" alt="Reminders" /></td>
				<td>Reminders</td>
				<td>Create and complete reminders.</td>
			</tr>
			<tr>
				<td><img src="weather.png" alt="Weather" /></td>
				<td>Weather</td>
				<td>Check forecasts and conditions.</td>
			</tr>
		</tbody>
	</table>
	</body>
	</html>
	"""
	let document = try await HTMLDocument(data: Data(html.utf8))
	let markdown = document.markdown()

	let capabilities = [
		"Calendar",
		"Contacts",
		"Location",
		"Maps",
		"Messages",
		"Reminders",
		"Weather"
	]

	for capability in capabilities {
		#expect(markdown.contains(capability))
	}

	let descriptions = [
		"Create and manage events.",
		"Find people and groups.",
		"Resolve places and coordinates.",
		"Search and route across maps.",
		"Send and read conversations.",
		"Create and complete reminders.",
		"Check forecasts and conditions."
	]

	for description in descriptions {
		#expect(markdown.contains(description))
	}

	#expect(markdown.contains("![Calendar](calendar.png)"))
}

@Test
func nestedTableIsLayout() async throws {
	let html = """
	<table>
		<tr><td>
			<table>
				<tr><td>Inner</td></tr>
			</table>
		</td></tr>
	</table>
	"""
	let document = try await HTMLDocument(data: Data(html.utf8))
	let markdown = document.markdown()

	#expect(!markdown.contains("|"))
}

@Test
func singleColumnIsLayout() async throws {
	let html = """
	<table>
		<tr><td>Row 1</td></tr>
		<tr><td>Row 2</td></tr>
		<tr><td>Row 3</td></tr>
	</table>
	"""
	let document = try await HTMLDocument(data: Data(html.utf8))
	let markdown = document.markdown()

	#expect(!markdown.contains("|"))
}

@Test
func imageHeavyIsLayout() async throws {
	let html = """
	<table>
		<tr>
			<td><img src="logo.png"/></td>
			<td><img src="icon.png"/></td>
		</tr>
		<tr>
			<td><img src="photo.png"/></td>
			<td>Some text</td>
		</tr>
	</table>
	"""
	let document = try await HTMLDocument(data: Data(html.utf8))
	let markdown = document.markdown()

	#expect(!markdown.contains("|"))
}

@Test
func dataTableIsPreserved() async throws {
	let html = """
	<table>
		<thead>
			<tr><th>Name</th><th>Price</th><th>Qty</th></tr>
		</thead>
		<tbody>
			<tr><td>Widget</td><td>$10</td><td>5</td></tr>
			<tr><td>Gadget</td><td>$20</td><td>3</td></tr>
		</tbody>
	</table>
	"""
	let document = try await HTMLDocument(data: Data(html.utf8))
	let markdown = document.markdown()

	#expect(markdown.contains("|"))
	#expect(markdown.contains("Name"))
	#expect(markdown.contains("Widget"))
}

@Test
func multiBlockCellIsLayout() async throws {
	let html = """
	<table>
		<tr><td>
			<p>Para 1</p>
			<p>Para 2</p>
			<div>Content</div>
			<p>Para 3</p>
		</td></tr>
	</table>
	"""
	let document = try await HTMLDocument(data: Data(html.utf8))
	let markdown = document.markdown()

	#expect(!markdown.contains("|"))
}
