// DTHTMLParser-Bridging-Header.h

#ifndef DTHTMLParser_Bridging_Header_h
#define DTHTMLParser_Bridging_Header_h

#if __has_include(<libxml/HTMLparser.h>)
#include <libxml/HTMLparser.h>
#elif __has_include(<libxml2/libxml/HTMLparser.h>)
#include <libxml2/libxml/HTMLparser.h>
#else
#include <libxml/HTMLparser.h>
#endif

// Function to format variadic arguments into a string and call a Swift handler
void htmlparser_error_sax_handler(void *ctx, const char *msg, ...);

// Function to set the error handler
void htmlparser_set_error_handler(htmlSAXHandlerPtr sax_handler);

#endif /* DTHTMLParser_Bridging_Header_h */

