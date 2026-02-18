// libxml2_bridging.h — intentionally minimal.
//
// CLibXML2 exists only to propagate pkg-config cflags (-I/usr/include/libxml2)
// and the -lxml2 linker flag to CHTMLParser when building on Linux.
//
// DO NOT include any libxml2 headers here.  The actual libxml2 types that
// Swift code needs are exposed through CHTMLParser's own public headers
// (DTHTMLParser-Bridging-Header.h).  Including libxml2 headers here would
// cause all of libxml2's types to be exported into every Swift module that
// (transitively) imports CHTMLParser, polluting the Swift namespace.
