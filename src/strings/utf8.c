#include "moarvm.h"

/* The below section has an MIT-style license, included here.

// Copyright (c) 2008-2010 Bjoern Hoehrmann <bjoern@hoehrmann.de>
// See http://bjoern.hoehrmann.de/utf-8/decoder/dfa/ for details.
 * 
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so, subject
 * to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
 * BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
 * ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 * CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
#define UTF8_ACCEPT 0
#define UTF8_REJECT 12

static const MVMuint8 utf8d[] = {
  // The first part of the table maps bytes to character classes that
  // to reduce the size of the transition table and create bitmasks.
   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
   1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
   7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,  7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
   8,8,2,2,2,2,2,2,2,2,2,2,2,2,2,2,  2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
  10,3,3,3,3,3,3,3,3,3,3,3,3,4,3,3, 11,6,6,6,5,8,8,8,8,8,8,8,8,8,8,8,

  // The second part is a transition table that maps a combination
  // of a state of the automaton and a character class to a state.
   0,12,24,36,60,96,84,12,12,12,48,72, 12,12,12,12,12,12,12,12,12,12,12,12,
  12, 0,12,12,12,12,12, 0,12, 0,12,12, 12,24,12,12,12,12,12,24,12,24,12,12,
  12,12,12,12,12,12,12,24,12,12,12,12, 12,24,12,12,12,12,12,12,12,24,12,12,
  12,12,12,12,12,12,12,36,12,36,12,12, 12,36,12,12,12,12,12,36,12,36,12,12,
  12,36,12,12,12,12,12,12,12,12,12,12, 
};

static MVMuint32
decode_utf8_byte(MVMuint32 *state, MVMuint32 *codep, MVMuint8 byte) {
  MVMuint32 type = utf8d[byte];

  *codep = (*state != UTF8_ACCEPT) ?
    (byte & 0x3fu) | (*codep << 6) :
    (0xff >> type) & (byte);

  *state = utf8d[256 + *state + type];
  return *state;
}
/* end Bjoern Hoehrmann section (some things were changed from the original) */

/* begin not_gerd section
// Copyright 2012 not_gerd
// see http://irclog.perlgeek.de/perl6/2012-06-04#i_5681122

Permission is granted to use, modify, and / or redistribute at will.

This includes removing authorship notices, re-use of code parts in
other software (with or without giving credit), and / or creating a
commercial product based on it.

This permission is not revocable by the author.

This software is provided as-is. Use it at your own risk. There is
no warranty whatsoever, neither expressed nor implied, and by using
this software you accept that the author(s) shall not be held liable
for any loss of data, loss of service, or other damages, be they
incidental or consequential. Your only option other than accepting
this is not to use the software at all.
*/

#include <stddef.h>
#include <stdint.h>

enum
{
    CP_CHAR            = 1 << 0,
    CP_LOW_SURROGATE   = 1 << 1,
    CP_HIGH_SURROGATE  = 1 << 2,
    CP_NONCHAR         = 1 << 3,
    CP_OVERFLOW        = 1 << 4,

    U8_SINGLE          = 1 << 5,
    U8_DOUBLE          = 1 << 6,
    U8_TRIPLE          = 1 << 7,
    U8_QUAD            = 1 << 8
};

static unsigned classify(MVMuint32 cp)
{
    /* removing these two lines 
    12:06 <not_gerd> if you want to encode NUL as a zero-byte
                 (as in proper UTF-8), you need to delete the
                 first 2 lines of classify()
    
    if(cp == 0) 
        return CP_CHAR | U8_DOUBLE;*/

    if(cp <= 0x7F)
        return CP_CHAR | U8_SINGLE;

    if(cp <= 0x07FF)
        return CP_CHAR | U8_DOUBLE;

    if(0xD800 <= cp && cp <= 0xDBFF)
        return CP_HIGH_SURROGATE | U8_TRIPLE;

    if(0xDC00 <= cp && cp <= 0xDFFF)
        return CP_LOW_SURROGATE | U8_TRIPLE;

    if(0xFDD0 <= cp && cp <= 0xFDEF)
        return CP_NONCHAR | U8_TRIPLE;

    if(cp <= 0xFFFD)
        return CP_CHAR | U8_TRIPLE;

    if(cp == 0xFFFE || cp == 0xFFFF)
        return CP_NONCHAR | U8_TRIPLE;

    if(cp <= 0x10FFFF && ((cp & 0xFFFF) == 0xFFFE || (cp & 0xFFFF) == 0xFFFF))
        return CP_NONCHAR | U8_QUAD;

    if(cp <= 0x10FFFF)
        return CP_CHAR | U8_QUAD;

    if(cp <= 0x1FFFFF)
        return CP_OVERFLOW | U8_QUAD;

    return 0;
}

static void *utf8_encode(void *bytes, MVMuint32 cp)
{
    unsigned cc = classify(cp);
    MVMuint8 *bp = bytes;

    if(!(cc & CP_CHAR))
        return NULL;

    if(cc & U8_SINGLE)
    {
        bp[0] = (MVMuint8)cp;
        return bp + 1;
    }

    if(cc & U8_DOUBLE)
    {
        bp[0] = (MVMuint8)(( 6 << 5) |  (cp >> 6));
        bp[1] = (MVMuint8)(( 2 << 6) |  (cp &  0x3F));
        return bp + 2;
    }

    if(cc & U8_TRIPLE)
    {
        bp[0] = (MVMuint8)((14 << 4) |  (cp >> 12));
        bp[1] = (MVMuint8)(( 2 << 6) | ((cp >> 6) & 0x3F));
        bp[2] = (MVMuint8)(( 2 << 6) | ( cp       & 0x3F));
        return bp + 3;
    }

    if(cc & U8_QUAD)
    {
        bp[0] = (MVMuint8)((30 << 3) |  (cp >> 18));
        bp[1] = (MVMuint8)(( 2 << 6) | ((cp >> 12) & 0x3F));
        bp[2] = (MVMuint8)(( 2 << 6) | ((cp >>  6) & 0x3F));
        bp[3] = (MVMuint8)(( 2 << 6) | ( cp        & 0x3F));
        return bp + 4;
    }

    return NULL;
}


 /* end not_gerd section */

#define UTF8_MAXINC 32 * 1024 * 1024
/* Decodes the specified number of bytes of utf8 into an NFG string, creating
 * a result of the specified type. The type must have the MVMString REPR. 
 * Only bring in the raw codepoints for now. */
MVMString * MVM_string_utf8_decode(MVMThreadContext *tc, MVMObject *result_type, char *utf8, size_t bytes) {
    MVMString *result = (MVMString *)REPR(result_type)->allocate(tc, STABLE(result_type));
    MVMuint32 count = 0;
    MVMuint32 codepoint;
    MVMuint32 line_ending = 0;
    MVMuint32 state = 0;
    MVMuint32 bufsize = 16;
    MVMuint32 *buffer = malloc(sizeof(MVMuint32) * bufsize);
    size_t orig_bytes;
    char *orig_utf8;
    MVMuint32 line;
    MVMuint32 col;
    
    if (bytes >= 3 && utf8[0] == 0xEF && utf8[1] == 0xBB && utf8[0xBF]) {
        /* disregard UTF-8 BOM if it's present */
        utf8 += 3; bytes -= 3;
    }
    orig_bytes = bytes;
    orig_utf8 = utf8;
    
    for (; bytes; ++utf8, --bytes) {
        switch(decode_utf8_byte(&state, &codepoint, *utf8)) {
        case UTF8_ACCEPT: /* got a codepoint */
            if (count == bufsize) { /* if the buffer's full make a bigger one */
                buffer = realloc(buffer, sizeof(MVMuint32) * (
                    bufsize >= UTF8_MAXINC ? (bufsize += UTF8_MAXINC) : (bufsize *= 2)
                ));
            }
            buffer[count++] = codepoint;
            break;
        case UTF8_REJECT:
            /* found a malformed sequence; parse it again this time tracking
             * line and col numbers. */
            bytes = orig_bytes; utf8 = orig_utf8; state = 0; line = 1; col = 1;
            for (; bytes; ++utf8, --bytes) {
                switch(decode_utf8_byte(&state, &codepoint, *utf8)) {
                case UTF8_ACCEPT:
                    /* this could be reorganized into several nested ugly if/else :/ */
                    if (!line_ending && (codepoint == 10 || codepoint == 13)) {
                        /* Detect the style of line endings.
                         * Select whichever comes first.
                         * First or only part of first line ending. */
                        line_ending = codepoint;
                        col = 1; line++;
                    }
                    else if (line_ending && codepoint == line_ending) {
                        /* first or only part of next line ending */
                        col = 1; line++;
                    }
                    else if (codepoint == 10 || codepoint == 13) {
                        /* second part of line ending; ignore */
                    }
                    else /* non-line ending codepoint */
                        col++;
                    break;
                case UTF8_REJECT:
                    /* XXX HALP I don't know what I'm doing here.
                     * memory leak if the exception is caught unless throw_adhoc
                     * can be taught to free it */
                    utf8 = malloc(50);
                    sprintf(utf8, "Malformed UTF-8 at line %u col %u", line, col);
                    MVM_exception_throw_adhoc(tc, utf8);
                }
            }
            MVM_exception_throw_adhoc(tc, "Concurrent modification of UTF-8 input buffer!");
            break;
        }
    }
    if (state != UTF8_ACCEPT)
        MVM_exception_throw_adhoc(tc, "Malformed termination of UTF-8 string");
    
    /* just keep the same buffer as the MVMString's buffer.  Later
     * we can add heuristics to resize it if we have enough free
     * memory */
    result->body.data = buffer;
    
    result->body.codes  = count;
    result->body.graphs = count; /* Ignore combining chars for now. */
    
    return result;
}

/* Encodes the specified string to UTF-8. */
MVMuint8 * MVM_string_utf8_encode(MVMThreadContext *tc, MVMString *str, MVMuint64 *output_size) {
    
    /* allocate the resulting string. XXX TODO: grow as we go as needed if the string is huge */
    MVMuint8 *result = malloc(sizeof(MVMuint32) * str->body.graphs);
    MVMuint8 *arr = result;
    size_t i = 0;
    while (i < str->body.graphs && (arr = utf8_encode(arr, str->body.data[i++])));
    *output_size = (MVMuint64)(arr ? arr - result : 0);
    return result;
}
