//  DefaultStylesheet.swift
//  SwiftTextEPUB
//
//  The bundled reading stylesheet, referenced by every content document. Tuned
//  for long-form prose: a serif face, first-line-indented paragraphs with no
//  inter-paragraph gap (the print-book convention), a centered scene-break rule,
//  each chapter starting on a new page, and a centered title page. User CSS
//  passed to the converter is appended after this so author rules win.

enum DefaultStylesheet {
	static let css = """
	/* SwiftText EPUB base stylesheet */
	html {
	  font-family: Georgia, "Times New Roman", serif;
	  line-height: 1.5;
	  color: #1a1a1a;
	}
	body {
	  margin: 0 5%;
	  widows: 2;
	  orphans: 2;
	}
	h1, h2, h3, h4, h5, h6 {
	  font-weight: bold;
	  line-height: 1.2;
	  text-align: left;
	  page-break-after: avoid;
	  break-after: avoid;
	  page-break-inside: avoid;
	}
	h1 {
	  font-size: 1.8em;
	  margin: 1em 0 0.8em;
	  page-break-before: always;
	  break-before: page;
	}
	h2 { font-size: 1.4em; margin: 1.2em 0 0.6em; }
	h3 { font-size: 1.15em; margin: 1em 0 0.4em; }
	h4, h5, h6 { font-size: 1em; margin: 1em 0 0.3em; }
	p {
	  margin: 0;
	  text-indent: 1.2em;
	  text-align: justify;
	}
	/* The opening paragraph of a section or after a scene break is not indented. */
	h1 + p, h2 + p, h3 + p, h4 + p, h5 + p, h6 + p, hr + p, blockquote > p:first-child {
	  text-indent: 0;
	}
	blockquote {
	  margin: 1em 1.5em;
	  font-style: italic;
	}
	blockquote p { text-align: left; }
	hr {
	  border: none;
	  width: 25%;
	  margin: 1.5em auto;
	  border-top: 1px solid currentColor;
	}
	em { font-style: italic; }
	strong { font-weight: bold; }
	del { text-decoration: line-through; }
	a { color: inherit; text-decoration: underline; }
	code {
	  font-family: "SFMono-Regular", Menlo, Consolas, monospace;
	  font-size: 0.9em;
	}
	pre {
	  margin: 1em 0;
	  white-space: pre-wrap;
	  overflow-wrap: break-word;
	  font-size: 0.9em;
	}
	pre code { font-size: inherit; }
	ul, ol { margin: 1em 0 1em 1.5em; padding: 0; }
	li { margin: 0.2em 0; }
	li.task-list-item { list-style: none; margin-left: -1.2em; }
	table { border-collapse: collapse; margin: 1em 0; }
	th, td { border: 1px solid #888; padding: 0.3em 0.6em; text-align: left; }
	th { font-weight: bold; }
	img { max-width: 100%; height: auto; }
	sup { vertical-align: super; font-size: smaller; }
	sub { vertical-align: sub; font-size: smaller; }

	/* Title page */
	section.titlepage {
	  text-align: center;
	  margin-top: 20%;
	}
	h1.title {
	  font-size: 2.4em;
	  margin: 0 0 0.6em;
	  page-break-before: avoid;
	  break-before: avoid;
	}
	p.author {
	  font-size: 1.3em;
	  text-indent: 0;
	  text-align: center;
	  margin: 0.3em 0;
	}

	/* Cover */
	body.cover, section.cover { margin: 0; padding: 0; text-align: center; }
	#cover-image { margin: 0; padding: 0; }
	#cover-image img { max-width: 100%; max-height: 100%; }

	/* Navigation document */
	nav#toc ol { list-style-type: none; padding: 0; margin: 0 0 0 1em; }
	nav#toc ol li { margin: 0.4em 0; }
	nav#toc a { text-decoration: none; }
	"""
}
