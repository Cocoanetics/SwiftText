// DTHTMLParserBridge.c

#include "DTHTMLParser-Bridging-Header.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

// Registered callback — set from Swift before parsing begins.
static htmlparser_error_callback _error_callback = NULL;

/**
 Register the Swift error callback.

 @param callback A function pointer that receives (ctx, formatted_msg).
 */
void htmlparser_register_error_callback(htmlparser_error_callback callback)
{
	_error_callback = callback;
}

/**
 Handles SAX parser errors by formatting the error message and passing it
 to the registered Swift callback.

 @param ctx A context pointer passed to the handler.
 @param msg A format string for the error message.
 @param ... Additional arguments for the format string.

 @discussion
 This function is necessary when using Swift because Swift's native error handling and
 string formatting mechanisms are different from those in C. By creating a C function
 that formats the error message and then calls a Swift callback via a function pointer,
 we can seamlessly integrate C-based error handling with Swift's error management system.
 Using a function pointer (instead of the previous `extern` / `@_cdecl` approach)
 avoids undefined-symbol linker errors in Xcode archive (release) builds where
 cross-module `@_cdecl` symbols may be stripped.
 */
void htmlparser_error_sax_handler(void *ctx, const char *msg, ...)
{
	if (ctx == NULL || _error_callback == NULL) return;

	va_list args;
	va_start(args, msg);

	// Determine the length of the formatted string
	int length = vsnprintf(NULL, 0, msg, args);
	va_end(args);

	if (length < 0) return;

	// Allocate memory for the formatted string
	char *formattedMsg = (char *)malloc((length + 1) * sizeof(char));
	if (!formattedMsg) return;

	// Format the string
	va_start(args, msg);
	vsnprintf(formattedMsg, length + 1, msg, args);
	va_end(args);

	// Call the registered Swift callback
	_error_callback(ctx, formattedMsg);

	// Free the allocated memory
	free(formattedMsg);
}

/**
 Sets the error handler in the SAX handler structure.

 @param sax_handler A pointer to the SAX handler structure.
 */
void htmlparser_set_error_handler(htmlSAXHandlerPtr sax_handler)
{
	if (sax_handler != NULL)
	{
		sax_handler->error = (errorSAXFunc)htmlparser_error_sax_handler;
	}
}
