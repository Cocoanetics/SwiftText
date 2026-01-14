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
