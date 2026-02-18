// Shim header for libxml2 system library target.
// The actual headers are resolved via pkg-config (libxml-2.0).
#if __has_include(<libxml/HTMLparser.h>)
#include <libxml/HTMLparser.h>
#elif __has_include(<libxml2/libxml/HTMLparser.h>)
#include <libxml2/libxml/HTMLparser.h>
#endif
