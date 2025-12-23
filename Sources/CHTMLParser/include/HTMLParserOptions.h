// HTMLParserOptions.h

#ifndef HTMLParserOptions_h
#define HTMLParserOptions_h

#import <Foundation/Foundation.h>

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

