// HTMLParserOptions.h

#ifndef HTMLParserOptions_h
#define HTMLParserOptions_h

#if defined(__APPLE__)
#import <Foundation/Foundation.h>
#else
#include <stdint.h>
// On Linux, Foundation/Foundation.h is unavailable.
// Mirror Apple's NS_OPTIONS definition pattern using Clang's flag_enum attribute
// so Swift's Clang importer bridges the type as OptionSet-compatible.
// Note: the macro body does NOT start with "typedef"; the usage site does that.
#if !defined(NS_OPTIONS)
#  if defined(__clang__) && __has_attribute(flag_enum) && __has_attribute(enum_extensibility)
#    define NS_OPTIONS(_type, _name) \
         _type _name; \
         enum __attribute__((flag_enum, enum_extensibility(open))) : _type
#  else
#    define NS_OPTIONS(_type, _name) _type _name; enum
#  endif
#endif
#endif

typedef NS_OPTIONS(int32_t, HTMLParserOptions) {
	HTMLParserOptionRecover       = 1 << 0,
	HTMLParserOptionNoError       = 1 << 1,
	HTMLParserOptionNoWarning     = 1 << 2,
	HTMLParserOptionPedantic      = 1 << 3,
	HTMLParserOptionNoBlanks      = 1 << 4,
	HTMLParserOptionNoNet         = 1 << 5,
	HTMLParserOptionCompact       = 1 << 6
};

#endif /* HTMLParserOptions_h */
