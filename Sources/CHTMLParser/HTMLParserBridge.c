// DTHTMLParserBridge.c

#include "DTHTMLParser-Bridging-Header.h"

#if __has_include(<libxml/HTMLparser.h>)
#include <libxml/HTMLparser.h>
#elif __has_include(<libxml2/libxml/HTMLparser.h>)
#include <libxml2/libxml/HTMLparser.h>
#else
#include <libxml/HTMLparser.h>
#endif

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

struct swifttext_html_parser
{
	htmlParserCtxtPtr context;
	htmlSAXHandler handler;
	void *swift_context;
	htmlparser_sax_callbacks callbacks;
};

static struct swifttext_html_parser *htmlparser_from_ctx(void *ctx)
{
	return (struct swifttext_html_parser *)ctx;
}

static void htmlparser_start_document_bridge(void *ctx)
{
	struct swifttext_html_parser *parser = htmlparser_from_ctx(ctx);
	if (parser != NULL && parser->callbacks.startDocument != NULL)
	{
		parser->callbacks.startDocument(parser->swift_context);
	}
}

static void htmlparser_end_document_bridge(void *ctx)
{
	struct swifttext_html_parser *parser = htmlparser_from_ctx(ctx);
	if (parser != NULL && parser->callbacks.endDocument != NULL)
	{
		parser->callbacks.endDocument(parser->swift_context);
	}
}

static void htmlparser_start_element_bridge(void *ctx, const xmlChar *name, const xmlChar **atts)
{
	struct swifttext_html_parser *parser = htmlparser_from_ctx(ctx);
	if (parser != NULL && parser->callbacks.startElement != NULL)
	{
		parser->callbacks.startElement(parser->swift_context, (const char *)name, (const char **)atts);
	}
}

static void htmlparser_end_element_bridge(void *ctx, const xmlChar *name)
{
	struct swifttext_html_parser *parser = htmlparser_from_ctx(ctx);
	if (parser != NULL && parser->callbacks.endElement != NULL)
	{
		parser->callbacks.endElement(parser->swift_context, (const char *)name);
	}
}

static void htmlparser_characters_bridge(void *ctx, const xmlChar *chars, int len)
{
	struct swifttext_html_parser *parser = htmlparser_from_ctx(ctx);
	if (parser != NULL && parser->callbacks.characters != NULL)
	{
		parser->callbacks.characters(parser->swift_context, chars, (int32_t)len);
	}
}

static void htmlparser_comment_bridge(void *ctx, const xmlChar *value)
{
	struct swifttext_html_parser *parser = htmlparser_from_ctx(ctx);
	if (parser != NULL && parser->callbacks.comment != NULL)
	{
		parser->callbacks.comment(parser->swift_context, (const char *)value);
	}
}

static void htmlparser_cdata_bridge(void *ctx, const xmlChar *value, int len)
{
	struct swifttext_html_parser *parser = htmlparser_from_ctx(ctx);
	if (parser != NULL && parser->callbacks.cdataBlock != NULL)
	{
		parser->callbacks.cdataBlock(parser->swift_context, value, (int32_t)len);
	}
}

static void htmlparser_processing_instruction_bridge(void *ctx, const xmlChar *target, const xmlChar *data)
{
	struct swifttext_html_parser *parser = htmlparser_from_ctx(ctx);
	if (parser != NULL && parser->callbacks.processingInstruction != NULL)
	{
		parser->callbacks.processingInstruction(parser->swift_context, (const char *)target, (const char *)data);
	}
}

static void htmlparser_error_bridge(void *ctx, const char *msg, ...)
{
	struct swifttext_html_parser *parser = htmlparser_from_ctx(ctx);
	if (parser == NULL || parser->callbacks.error == NULL)
	{
		return;
	}

	va_list args;
	va_start(args, msg);
	int length = vsnprintf(NULL, 0, msg, args);
	va_end(args);

	if (length < 0)
	{
		return;
	}

	char *formatted_message = (char *)malloc((size_t)length + 1);
	if (formatted_message == NULL)
	{
		return;
	}

	va_start(args, msg);
	vsnprintf(formatted_message, (size_t)length + 1, msg, args);
	va_end(args);

	parser->callbacks.error(parser->swift_context, formatted_message);
	free(formatted_message);
}

htmlparser_parser_t htmlparser_create(
	const void *buffer,
	int32_t size,
	void *swift_context,
	htmlparser_sax_callbacks callbacks,
	int32_t encoding
)
{
	struct swifttext_html_parser *parser = calloc(1, sizeof(struct swifttext_html_parser));
	if (parser == NULL)
	{
		return NULL;
	}

	parser->swift_context = swift_context;
	parser->callbacks = callbacks;

	parser->handler.startDocument = htmlparser_start_document_bridge;
	parser->handler.endDocument = htmlparser_end_document_bridge;
	parser->handler.startElement = htmlparser_start_element_bridge;
	parser->handler.endElement = htmlparser_end_element_bridge;
	parser->handler.characters = htmlparser_characters_bridge;
	parser->handler.comment = htmlparser_comment_bridge;
	parser->handler.cdataBlock = htmlparser_cdata_bridge;
	parser->handler.processingInstruction = htmlparser_processing_instruction_bridge;
	parser->handler.error = (errorSAXFunc)htmlparser_error_bridge;

	xmlCharEncoding char_encoding = XML_CHAR_ENCODING_NONE;
	if (encoding == HTMLPARSER_ENCODING_UTF8)
	{
		char_encoding = XML_CHAR_ENCODING_UTF8;
	}

	parser->context = htmlCreatePushParserCtxt(
		&parser->handler,
		parser,
		buffer,
		size,
		NULL,
		char_encoding
	);

	if (parser->context == NULL)
	{
		free(parser);
		return NULL;
	}

	return parser;
}

void htmlparser_free(htmlparser_parser_t parser)
{
	if (parser == NULL)
	{
		return;
	}

	if (parser->context != NULL)
	{
		htmlFreeParserCtxt(parser->context);
	}

	free(parser);
}

int32_t htmlparser_parse(htmlparser_parser_t parser, int32_t options)
{
	if (parser == NULL || parser->context == NULL)
	{
		return -1;
	}

	htmlCtxtUseOptions(parser->context, options);
	return (int32_t)htmlParseDocument(parser->context);
}

void htmlparser_stop(htmlparser_parser_t parser)
{
	if (parser != NULL && parser->context != NULL)
	{
		xmlStopParser(parser->context);
		parser->context = NULL;
	}
}

int32_t htmlparser_line_number(htmlparser_parser_t parser)
{
	if (parser == NULL)
	{
		return 0;
	}

	return (int32_t)xmlSAX2GetLineNumber(parser->context);
}

int32_t htmlparser_column_number(htmlparser_parser_t parser)
{
	if (parser == NULL)
	{
		return 0;
	}

	return (int32_t)xmlSAX2GetColumnNumber(parser->context);
}

const char *htmlparser_system_id(htmlparser_parser_t parser)
{
	if (parser == NULL)
	{
		return NULL;
	}

	return (const char *)xmlSAX2GetSystemId(parser->context);
}

const char *htmlparser_public_id(htmlparser_parser_t parser)
{
	if (parser == NULL)
	{
		return NULL;
	}

	return (const char *)xmlSAX2GetPublicId(parser->context);
}
