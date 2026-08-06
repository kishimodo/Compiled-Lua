/* Route Lua's three __mingw_* stdio references to the UCRT, preserving MinGW's
** observable output exactly.
**
** WHY: lua-5.4/src/lprefix.h sets _XOPEN_SOURCE 600, which flips mingw-w64 to its
** ANSI-stdio implementation. That makes the Lua core reference __mingw_sprintf,
** __mingw_fprintf and __mingw_strtod -- three symbols, six references, all from
** the Lua core (lobject.o, lstrlib.o, lauxlib.o, ldblib.o, liolib.o) and none from
** ours. Satisfying them from libmingwex drags in __mingw_pformat, __gdtoa,
** __strtodg and the gdtoa bignum support: 14 archive members and 38,816 bytes,
** 33.9% of hello.exe's .text, to format numbers the UCRT in ucrtbase.dll already
** formats. Defining them here shadows the archive members, and the exe imports
** the conversions instead of carrying them.
**
** WHERE THIS IS LINKED, AND WHY IT MATTERS: this file is added to AOT_RT_SRCS
** only (build/Makefile), so it lands in runtime-aot.a and affects compiled output
** alone. It must NOT go in RUNTIME_SRCS: that list also feeds runtime.a, which
** clua-interp.exe links -- and moving the oracle onto the same implementation
** would make the differential suite agree by moving both sides, which defeats
** the whole point of the suite. The oracle stays on MinGW gdtoa deliberately,
** so the differential is comparing two different implementations.
**
** The first line below is load-bearing. Without it, mingw's stdio.h redirects the
** sprintf/vfprintf/strtod calls in this file back to __mingw_* and each function
** calls itself. */
#define __USE_MINGW_ANSI_STDIO 0

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

/* MinGW's pformat prints every NaN as "nan" (or "NAN"), ignoring both the sign
** bit and the payload. The UCRT prints "-nan(ind)" for a negative NaN and
** "nan(snan)" for a signalling one, and it honours width, precision, flags and
** case while doing so.
**
** Canonicalising the whole bit pattern to the positive quiet NaN with a zero
** payload is what makes those agree, and it has to be the bit pattern rather than
** fabs(): fabs clears the sign bit but leaves the quiet bit alone, so a
** signalling NaN still prints "nan(snan)" and the output diverges. That is
** reachable from pure Lua with no FFI and no arithmetic --
**   string.unpack("<d", "\x01\x00\x00\x00\x00\x00\xf0\x7f")
** stores the raw pattern straight into a TValue, and the x64 varargs path moves
** it in an xmm register without quieting it.
**
** Mapping every NaN to one pattern is exactly right rather than merely close,
** because the target implementation cannot distinguish them either: MinGW prints
** "nan" for all of them. Doing it this way is also 64 bytes SMALLER than the
** fabs() version, since dropping isnan/fabs drops the libm references. */
static double canon_nan( double D ) {
    if ( D != D ) {                       /* the only value unequal to itself */
        unsigned long long Q = 0x7ff8000000000000ULL;
        memcpy( &D, &Q, sizeof D );
    }
    return D;
}

/* Classify the single conversion in a Lua-emitted format string.
**
** Sound because Lua emits exactly ONE conversion per call into these functions:
** lobject.c's tostringbuff uses the fixed LUA_NUMBER_FMT, and lstrlib.c's
** str_format calls l_sprintf once per specifier with a format built by getformat,
** which strspn's only flags and digits and '.' before taking a single conversion
** character. So there is no '*' width, no second specifier, and no user-supplied
** length modifier to mis-parse.
**
** Returns 'f' for any floating conversion, 'p' for a pointer, 0 otherwise. */
static int fmt_kind( const char *F ) {
    if ( !F || *F != '%' ) return 0;
    F++;
    while ( *F && strchr( "-+ #0'", *F ) ) F++;      /* flags   */
    while ( *F >= '0' && *F <= '9' ) F++;            /* width   */
    if ( *F == '.' ) {
        F++;
        while ( *F >= '0' && *F <= '9' ) F++;        /* precision */
    }
    while ( *F && strchr( "hlLqjzt", *F ) ) F++;     /* length  */
    if ( *F && strchr( "aAeEfFgG", *F ) ) return 'f';
    if ( *F == 'p' ) return 'p';
    return 0;
}

/* MinGW's %p differs from the UCRT's in TWO ways, both observable, and the second
** one is easy to miss:
**
**   %p        MinGW: 16 lowercase hex digits, zero-padded, no "0x"
**             UCRT:  16 UPPERCASE hex digits
**   %20p      MinGW: MINIMAL lowercase hex, space-padded to the field width
**   %-20p     UCRT:  still 16 zero-padded uppercase digits, then space-padded
**
** So an explicit width makes MinGW drop the zero fill entirely. Measured against
** the oracle: "%p" -> [000000000072cb70], "%20p" -> [              72cb70],
** "%-20p" -> [72cb70              ], "%2p" -> [72cb70].
**
** The reachable set is only those two shapes, because Lua's own checkformat
** rejects everything else for 'p' before it reaches us -- "%08p", "%.4p", "%#p",
** "%+p", "% p" and "%020p" all raise "invalid conversion specification". So this
** handles a plain %p and an optional '-' plus width, and nothing more.
**
** Strategy: render the digits ourselves (lowercase, guaranteed), then let sprintf
** apply the flags and width by rewriting the conversion to 's'. That reproduces
** the padding rules exactly without reimplementing them.
**
** Checked by tests/differential/aot_pointer_case.lua, which asserts the shape
** rather than the value -- addresses are nondeterministic, so a stdout diff
** against the oracle would pass whatever case we emitted. */
static void ptr_hex( char *Out, const void *P, int Padded ) {
    static const char kHex[] = "0123456789abcdef";
    unsigned long long V = ( unsigned long long )( uintptr_t )P;
    int I, N = 0;
    if ( Padded ) {
        for ( I = 0; I < 16; I++ ) Out[ N++ ] = kHex[ ( V >> ( 60 - 4 * I ) ) & 0xf ];
    } else {
        int Started = 0;
        for ( I = 0; I < 16; I++ ) {
            unsigned D = ( unsigned )( ( V >> ( 60 - 4 * I ) ) & 0xf );
            if ( D || Started || I == 15 ) { Out[ N++ ] = kHex[ D ]; Started = 1; }
        }
    }
    Out[ N ] = '\0';
}

/* Copy Fmt with its trailing 'p' replaced by 's'. Bounded; returns 0 if the
** format is longer than anything Lua can produce for %p (flags + width digits). */
static int ptr_fmt_as_str( char *Out, size_t Cap, const char *Fmt ) {
    size_t L = strlen( Fmt );
    if ( L == 0 || L + 1 > Cap || Fmt[ L - 1 ] != 'p' ) return 0;
    memcpy( Out, Fmt, L );
    Out[ L - 1 ] = 's';
    Out[ L ]     = '\0';
    return 1;
}

/* No size parameter: luaconf.h defines LUA_USE_C89 on Windows, so Lua's
** l_sprintf expands to the unbounded sprintf rather than snprintf. The buffers
** Lua passes are sized for the longest conversion it can emit. */
int __mingw_sprintf( char *S, const char *Fmt, ... ) {
    va_list Ap;
    int     N;
    int     Kind = fmt_kind( Fmt );

    va_start( Ap, Fmt );
    if ( Kind == 'f' ) {
        double D = va_arg( Ap, double );
        N = sprintf( S, Fmt, canon_nan( D ) );
    } else if ( Kind == 'p' ) {
        char Hex[ 20 ], SFmt[ 24 ];
        int  Plain = ( strcmp( Fmt, "%p" ) == 0 );
        ptr_hex( Hex, va_arg( Ap, void * ), Plain );
        if ( Plain ) {
            memcpy( S, Hex, 17 );
            N = 16;
        } else if ( ptr_fmt_as_str( SFmt, sizeof SFmt, Fmt ) ) {
            N = sprintf( S, SFmt, Hex );
        } else {
            N = sprintf( S, "%s", Hex );   /* unreachable via Lua; stay lowercase */
        }
    } else {
        N = vsprintf( S, Fmt, Ap );
    }
    va_end( Ap );
    return N;
}

int __mingw_fprintf( FILE *F, const char *Fmt, ... ) {
    va_list Ap;
    int     N;
    int     Kind = fmt_kind( Fmt );

    va_start( Ap, Fmt );
    if ( Kind == 'f' ) {
        double D = va_arg( Ap, double );
        N = fprintf( F, Fmt, canon_nan( D ) );
    } else if ( Kind == 'p' ) {
        /* Not reachable from Lua today -- the only fprintf formats are liolib's
        ** "%lld" and LUA_NUMBER_FMT plus lua_writestringerror's "%s" -- but keep
        ** the two entry points symmetric so a future %p in an error message cannot
        ** diverge in case from the same conversion done through sprintf. */
        char Hex[ 20 ], SFmt[ 24 ];
        int  Plain = ( strcmp( Fmt, "%p" ) == 0 );
        ptr_hex( Hex, va_arg( Ap, void * ), Plain );
        if ( !Plain && ptr_fmt_as_str( SFmt, sizeof SFmt, Fmt ) )
            N = fprintf( F, SFmt, Hex );
        else
            N = fprintf( F, "%s", Hex );
    } else {
        N = vfprintf( F, Fmt, Ap );
    }
    va_end( Ap );
    return N;
}

/* The UCRT's strtod is already byte-identical to MinGW's on decimals, hex floats,
** subnormals and halfway ties; tests/differential/aot_strformat.lua exercises the
** round trip. */
double __mingw_strtod( const char *S, char **End ) {
    return strtod( S, End );
}
