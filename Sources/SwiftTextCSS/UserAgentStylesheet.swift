//  UserAgentStylesheet.swift
//  SwiftTextCSS
//
//  A compact HTML user-agent stylesheet, distilled from WeasyPrint's
//  html5_ua.css (which is itself based on the HTML5 rendering spec and CSS 2.1).
//  Only rules expressible with the supported selector subset are included;
//  dir/:is()/case-insensitive-attribute rules are intentionally omitted.

let userAgentCSS = """
html, address, article, aside, blockquote, body, center, dd, details, dir, \
div, dl, dt, fieldset, figure, figcaption, footer, form, h1, h2, h3, h4, h5, \
h6, header, hgroup, hr, legend, listing, main, menu, nav, ol, p, plaintext, \
pre, section, summary, ul, xmp { display: block }

li { display: list-item }
ul, menu, dir { list-style-type: disc }
ol { list-style-type: decimal }
table { display: table; border-spacing: 2px }
caption { display: table-caption }
thead { display: table-header-group }
tbody { display: table-row-group }
tfoot { display: table-footer-group }
tr { display: table-row }
td, th { display: table-cell; padding: 1px }
button, input, select, textarea { display: inline-block }
area, base, basefont, datalist, head, link, meta, noembed, noframes, param, \
script, style, template, title { display: none }

blockquote, dl, figure, menu, ol, p, pre, ul { margin-top: 1em; margin-bottom: 1em }
body { margin: 8px }
h1 { font-size: 2em; font-weight: bold; margin-top: .67em; margin-bottom: .67em }
h2 { font-size: 1.5em; font-weight: bold; margin-top: .83em; margin-bottom: .83em }
h3 { font-size: 1.17em; font-weight: bold; margin-top: 1em; margin-bottom: 1em }
h4 { font-weight: bold; margin-top: 1.33em; margin-bottom: 1.33em }
h5 { font-size: .83em; font-weight: bold; margin-top: 1.67em; margin-bottom: 1.67em }
h6 { font-size: .67em; font-weight: bold; margin-top: 2.33em; margin-bottom: 2.33em }
blockquote, figure { margin-left: 40px; margin-right: 40px }
dd { margin-left: 40px }
dir, menu, ol, ul { padding-left: 40px }
hr { margin-top: .5em; margin-bottom: .5em; border-width: 1px; border-style: inset }

b, strong, th { font-weight: bold }
i, em, cite, var, dfn, address { font-style: italic }
code, kbd, listing, plaintext, pre, samp, tt, xmp { font-family: monospace }
pre, listing, plaintext, xmp { white-space: pre }
nobr { white-space: nowrap }
big { font-size: larger }
small { font-size: smaller }
a { color: #0000ee; text-decoration: underline }
del, s, strike { text-decoration: line-through }
ins, u { text-decoration: underline }
mark { background-color: #ffff00 }
"""
