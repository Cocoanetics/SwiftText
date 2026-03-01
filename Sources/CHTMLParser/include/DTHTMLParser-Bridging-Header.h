// DTHTMLParser-Bridging-Header.h

#ifndef DTHTMLParser_Bridging_Header_h
#define DTHTMLParser_Bridging_Header_h

// On macOS the SDK exposes libxml2 at <libxml/...>.
// On Linux (libxml2-dev) the headers live under /usr/include/libxml2/,
// and CLibXML2's pkg-config cflags add -I/usr/include/libxml2, so
// <libxml/HTMLparser.h> resolves correctly on both platforms.
#if __has_include(<libxml/HTMLparser.h>)
#include <libxml/HTMLparser.h>
#elif __has_include(<libxml2/libxml/HTMLparser.h>)
#include <libxml2/libxml/HTMLparser.h>
#else
#include <libxml/HTMLparser.h>
#endif

// Callback type for forwarding formatted error messages to Swift
typedef void (*htmlparser_error_callback)(void *ctx, const char *msg);

// Register the Swift error callback (must be called before parsing)
void htmlparser_register_error_callback(htmlparser_error_callback callback);

// Function to format variadic arguments into a string and call the registered callback
void htmlparser_error_sax_handler(void *ctx, const char *msg, ...);

// Function to set the error handler in a SAX handler struct
void htmlparser_set_error_handler(htmlSAXHandlerPtr sax_handler);

#endif /* DTHTMLParser_Bridging_Header_h */

