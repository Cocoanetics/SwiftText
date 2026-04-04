// DTHTMLParser-Bridging-Header.h

#ifndef DTHTMLParser_Bridging_Header_h
#define DTHTMLParser_Bridging_Header_h

// Keep libxml2 out of CHTMLParser's *public* module interface on Linux.
// Swift 6.3 bundles its own ICU, and exposing system libxml2 transitively via
// this header causes a UErrorCode module clash on Ubuntu 24.04.
//
// On Darwin we still import libxml2 here because there is no separate CLibXML2
// SwiftPM system module in this package.
#if defined(__linux__)
typedef struct _xmlSAXHandler * htmlSAXHandlerPtr;
#else
  #if __has_include(<libxml/HTMLparser.h>)
  #include <libxml/HTMLparser.h>
  #elif __has_include(<libxml2/libxml/HTMLparser.h>)
  #include <libxml2/libxml/HTMLparser.h>
  #else
  #include <libxml/HTMLparser.h>
  #endif
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

