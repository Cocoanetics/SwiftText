extension String
{
	/// Ensure the receiver has two trailing newlines for a paragraph break.
	mutating func ensureTwoTrailingNewlines()
	{
		guard !isEmpty else
		{
			return
		}

		var trailingNewlines = 0

		for char in self.reversed() {
			if char == "\n" {
				trailingNewlines += 1
			} else {
				break
			}
		}

		if trailingNewlines == 0 {
			self += "\n\n"
		} else if trailingNewlines == 1 {
			self += "\n"
		}
	}
}

