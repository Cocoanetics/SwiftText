// DTHTMLParser-Bridging-Header.h

#ifndef DTHTMLParser_Bridging_Header_h
#define DTHTMLParser_Bridging_Header_h

#include <stdint.h>

// Keep libxml2 headers out of CHTMLParser's public module interface. On Linux,
// importing libxml2 transitively also imports the system ICU headers, which
// collides with Swift 6.3 Foundation's bundled ICU module.
typedef struct swifttext_html_parser * htmlparser_parser_t;

typedef void (*htmlparser_start_document_callback)(void *ctx);
typedef void (*htmlparser_end_document_callback)(void *ctx);
typedef void (*htmlparser_start_element_callback)(void *ctx, const char *name, const char **atts);
typedef void (*htmlparser_end_element_callback)(void *ctx, const char *name);
typedef void (*htmlparser_characters_callback)(void *ctx, const unsigned char *chars, int32_t len);
typedef void (*htmlparser_comment_callback)(void *ctx, const char *comment);
typedef void (*htmlparser_cdata_callback)(void *ctx, const unsigned char *value, int32_t len);
typedef void (*htmlparser_processing_instruction_callback)(void *ctx, const char *target, const char *data);
typedef void (*htmlparser_error_callback)(void *ctx, const char *msg);

typedef struct htmlparser_sax_callbacks {
	htmlparser_start_document_callback startDocument;
	htmlparser_end_document_callback endDocument;
	htmlparser_start_element_callback startElement;
	htmlparser_end_element_callback endElement;
	htmlparser_characters_callback characters;
	htmlparser_comment_callback comment;
	htmlparser_cdata_callback cdataBlock;
	htmlparser_processing_instruction_callback processingInstruction;
	htmlparser_error_callback error;
} htmlparser_sax_callbacks;

enum {
	HTMLPARSER_ENCODING_NONE = 0,
	HTMLPARSER_ENCODING_UTF8 = 1,
};

htmlparser_parser_t htmlparser_create(
	const void *buffer,
	int32_t size,
	void *swift_context,
	htmlparser_sax_callbacks callbacks,
	int32_t encoding
);

void htmlparser_free(htmlparser_parser_t parser);
int32_t htmlparser_parse(htmlparser_parser_t parser, int32_t options);
void htmlparser_stop(htmlparser_parser_t parser);
int32_t htmlparser_line_number(htmlparser_parser_t parser);
int32_t htmlparser_column_number(htmlparser_parser_t parser);
const char *htmlparser_system_id(htmlparser_parser_t parser);
const char *htmlparser_public_id(htmlparser_parser_t parser);

#endif /* DTHTMLParser_Bridging_Header_h */
