// libxml2_bridging.h — umbrella header for the CLibXML2 system library module.
// Uses the <libxml2/libxml/...> prefix so the headers can be found without any
// extra search path; the pkg-config cflags (-I/usr/include/libxml2) are then
// propagated to all targets that depend on CLibXML2, making the nested
// <libxml/...> includes inside the libxml2 headers resolve correctly.

#ifndef libxml2_bridging_h
#define libxml2_bridging_h

#include <libxml2/libxml/HTMLparser.h>
#include <libxml2/libxml/SAX2.h>

#endif /* libxml2_bridging_h */
