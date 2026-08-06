/*
** asm.c -- diagnostic assembly-listing dump of the emitted x64 machine code.
**
** This is a MINIMAL decoder. The goal is a readable listing for the ~30
** opcodes clua/src/codegen/x64_emit.c actually emits, not a fully general
** x64 disassembler. Anything the tables below do not recognise is printed
** as its raw bytes followed by `; ???`, so the listing stays faithful to
** what is really in the compiled function: no byte is ever hidden.
**
** Format per line:
**     <hex-offset>  <space-separated bytes>  <mnemonic> <operands>
**
** Register names use the Intel canonical spelling; memory operands render
** as `[base + disp]` with the disp in hex when it does not fit an int8.
**
** Structure of the decoder: for each instruction we consume an optional
** REX prefix, then dispatch on the primary opcode. Multi-byte prefixes
** (0x0F, and the F2/F3/66 SSE selectors) go through a small secondary
** dispatch. Anything not covered leaves the state machine at the failed
** byte and falls out through the `???` bucket so we do not desync.
*/
#include "dump/emit.h"

#include "codegen/codegen.h"

#include <stdio.h>
#include <stdint.h>
#include <string.h>

/* Canonical 64-bit register names for the low bank; high bank gets the
** REX-extended `r8..r15` names. */
static const char *kReg64Lo[ 8 ] = {
    "rax","rcx","rdx","rbx","rsp","rbp","rsi","rdi"
};
static const char *kReg64Hi[ 8 ] = {
    "r8", "r9", "r10","r11","r12","r13","r14","r15"
};
static const char *kReg32Lo[ 8 ] = {
    "eax","ecx","edx","ebx","esp","ebp","esi","edi"
};

static const char *Gpr64( int idx, int rex_b ) {
    idx = ( idx & 7 ) | ( rex_b ? 8 : 0 );
    return ( idx < 8 ) ? kReg64Lo[ idx ] : kReg64Hi[ idx - 8 ];
}
static const char *Gpr32( int idx, int rex_b ) {
    /* Only the low bank is emitted with a 32-bit view by codegen (eax used
    ** for the tag word and imm32 stores); a REX.B for a 32-bit view would
    ** be an r8d..r15d name -- we spell those explicitly rather than lie. */
    if ( rex_b ) {
        static const char *hi[ 8 ] = {
            "r8d","r9d","r10d","r11d","r12d","r13d","r14d","r15d"
        };
        return hi[ idx & 7 ];
    }
    return kReg32Lo[ idx & 7 ];
}

/* Print a memory operand [base + disp] using the given REX.B for base
** extension. Handles the RSP/R12 SIB byte (rm==4) that always follows
** ModR/M in that case. Assumes the caller has already advanced past
** ModR/M; consumes SIB (if needed) and the disp bytes from p. Returns
** the number of bytes consumed after ModR/M. */
static int PrintMem( FILE *out, int mod, int rm, int rex_b,
                     const uint8_t *p, size_t left ) {
    int n = 0;
    int base = rm;
    int have_sib = ( ( rm & 7 ) == 4 );
    if ( have_sib ) {
        if ( ( size_t )n >= left ) return -1;
        /* SIB: [scale index base]. codegen only uses scale=0, index=none. */
        base = p[ n ] & 7;
        n++;
    }
    int32_t disp = 0;
    if ( mod == 1 ) {
        if ( ( size_t )n >= left ) return -1;
        disp = ( int32_t )( int8_t )p[ n ];
        n += 1;
    } else if ( mod == 2 ) {
        if ( ( size_t )n + 4 > left ) return -1;
        memcpy( &disp, p + n, 4 );
        n += 4;
    } else if ( mod == 0 && ( ( rm & 7 ) == 5 ) && !have_sib ) {
        /* RIP-relative disp32. */
        if ( ( size_t )n + 4 > left ) return -1;
        memcpy( &disp, p + n, 4 );
        n += 4;
        fprintf( out, "[rip%+d]", disp );
        return n;
    }
    fprintf( out, "[%s", Gpr64( base, rex_b ) );
    if ( disp != 0 ) fprintf( out, "%+d", disp );
    fputc( ']', out );
    return n;
}

/* Print a raw-bytes fallback line for `len` bytes starting at `p`. */
static void PrintRaw( FILE *out, size_t off, const uint8_t *p, int len ) {
    int i;
    fprintf( out, "  %08zx  ", off );
    for ( i = 0; i < len; i++ ) fprintf( out, "%02x ", p[ i ] );
    /* pad to a stable column, then annotate. */
    for ( i = len; i < 8; i++ ) fputs( "   ", out );
    fputs( " ??? ; unknown byte\n", out );
}

/* Print an instruction line prefix: offset + hex bytes. */
static void PrintPrefix( FILE *out, size_t off, const uint8_t *p, int len ) {
    int i;
    fprintf( out, "  %08zx  ", off );
    for ( i = 0; i < len; i++ ) fprintf( out, "%02x ", p[ i ] );
    for ( i = len; i < 10; i++ ) fputs( "   ", out );
    fputc( ' ', out );
}

/* Decode ONE instruction starting at p (with `left` bytes remaining) and
** print its line. Returns the number of bytes consumed, or 0 if we could
** not decode -- caller prints raw for one byte and advances. */
static int DecodeOne( FILE *out, size_t off, const uint8_t *p, size_t left ) {
    int      n     = 0;
    int      rex_w = 0, rex_r = 0, rex_b = 0;
    uint8_t  op;

    if ( left == 0 ) return 0;

    /* Optional REX prefix (0x40..0x4F). rex.X is emitted only by the
    ** general SIB encoder codegen never reaches, so we do not track it. */
    if ( ( p[ 0 ] & 0xF0 ) == 0x40 ) {
        rex_w = ( p[ 0 ] >> 3 ) & 1;
        rex_r = ( p[ 0 ] >> 2 ) & 1;
        rex_b = ( p[ 0 ]      ) & 1;
        n++;
        if ( ( size_t )n >= left ) return 0;
    }

    /* SSE prefix byte -- codegen emits F2 (movsd/addsd/subsd/mulsd/divsd),
    ** F3 (movss) and 66 (ucomisd, movq). Not fully decoded; we just print
    ** the family name and consume enough bytes so we do not desync. */
    if ( p[ n ] == 0xF2 || p[ n ] == 0xF3 || p[ n ] == 0x66 ) {
        uint8_t pfx = p[ n ]; n++;
        /* Optional REX after the sse prefix (66 REX.W 0F 6E/7E for movq).
        ** REX.W is captured for completeness -- movq's 64-bit form always
        ** sets it and the listing does not currently distinguish widths. */
        if ( ( size_t )n < left && ( p[ n ] & 0xF0 ) == 0x40 ) {
            rex_w = ( p[ n ] >> 3 ) & 1;
            rex_r = ( p[ n ] >> 2 ) & 1;
            rex_b = ( p[ n ]      ) & 1;
            (void)rex_w;
            n++;
        }
        if ( ( size_t )n + 2 > left || p[ n ] != 0x0F ) return 0;
        n++;  /* consume 0F */
        uint8_t sop = p[ n ]; n++;
        if ( ( size_t )n >= left ) return 0;
        uint8_t modrm = p[ n ]; n++;
        int mod = ( modrm >> 6 ) & 3;
        int reg = ( modrm >> 3 ) & 7;
        int rm  = ( modrm      ) & 7;
        const char *mnem = "sse";
        if ( pfx == 0xF2 ) {
            if ( sop == 0x10 ) mnem = "movsd";
            else if ( sop == 0x11 ) mnem = "movsd";
            else if ( sop == 0x58 ) mnem = "addsd";
            else if ( sop == 0x5C ) mnem = "subsd";
            else if ( sop == 0x59 ) mnem = "mulsd";
            else if ( sop == 0x5E ) mnem = "divsd";
        } else if ( pfx == 0xF3 ) {
            if ( sop == 0x10 || sop == 0x11 ) mnem = "movss";
        } else if ( pfx == 0x66 ) {
            if ( sop == 0x2E ) mnem = "ucomisd";
            else if ( sop == 0x6E ) mnem = "movq";
            else if ( sop == 0x7E ) mnem = "movq";
        }
        PrintPrefix( out, off, p, n );
        fprintf( out, "%s xmm%d, ", mnem, reg + ( rex_r ? 8 : 0 ) );
        if ( mod == 3 ) {
            fprintf( out, "xmm%d", rm + ( rex_b ? 8 : 0 ) );
        } else {
            int extra = PrintMem( out, mod, rm, rex_b, p + n, left - n );
            if ( extra < 0 ) { fputs( " ; truncated", out ); }
            else n += extra;
        }
        fputc( '\n', out );
        return n;
    }

    op = p[ n ]; n++;

    /* PUSH r64 (50+r). */
    if ( op >= 0x50 && op <= 0x57 ) {
        PrintPrefix( out, off, p, n );
        fprintf( out, "push %s\n", Gpr64( op - 0x50, rex_b ) );
        return n;
    }
    /* POP r64 (58+r). */
    if ( op >= 0x58 && op <= 0x5F ) {
        PrintPrefix( out, off, p, n );
        fprintf( out, "pop  %s\n", Gpr64( op - 0x58, rex_b ) );
        return n;
    }
    /* RET. */
    if ( op == 0xC3 ) {
        PrintPrefix( out, off, p, n );
        fputs( "ret\n", out );
        return n;
    }
    /* MOV r64, imm64 (REX.W B8+r imm64). */
    if ( rex_w && op >= 0xB8 && op <= 0xBF ) {
        if ( ( size_t )n + 8 > left ) return 0;
        uint64_t imm; memcpy( &imm, p + n, 8 ); n += 8;
        PrintPrefix( out, off, p, n );
        fprintf( out, "mov  %s, 0x%llx\n",
                 Gpr64( op - 0xB8, rex_b ),
                 ( unsigned long long )imm );
        return n;
    }
    /* MOV r32, imm32 (B8+r imm32) -- 32-bit form used when the value is
    ** positive and REX.W is absent. */
    if ( !rex_w && op >= 0xB8 && op <= 0xBF ) {
        if ( ( size_t )n + 4 > left ) return 0;
        int32_t imm; memcpy( &imm, p + n, 4 ); n += 4;
        PrintPrefix( out, off, p, n );
        fprintf( out, "mov  %s, 0x%x\n",
                 Gpr32( op - 0xB8, rex_b ),
                 ( unsigned )imm );
        return n;
    }
    /* Register-form ALU: XOR r32, r32 (31 /r) used for xor eax, eax. */
    if ( op == 0x31 ) {
        if ( ( size_t )n >= left ) return 0;
        uint8_t modrm = p[ n ]; n++;
        int mod = ( modrm >> 6 ) & 3;
        int reg = ( modrm >> 3 ) & 7;
        int rm  = ( modrm      ) & 7;
        PrintPrefix( out, off, p, n );
        if ( mod == 3 ) {
            fprintf( out, "xor  %s, %s\n",
                     Gpr32( rm, rex_b ), Gpr32( reg, rex_r ) );
        } else {
            fprintf( out, "xor  ??? ; unhandled modrm\n" );
        }
        return n;
    }
    /* MOV r/m64, r64 (89 /r) and MOV r64, r/m64 (8B /r), plus LEA (8D). */
    if ( op == 0x89 || op == 0x8B || op == 0x8D ) {
        if ( ( size_t )n >= left ) return 0;
        uint8_t modrm = p[ n ]; n++;
        int mod = ( modrm >> 6 ) & 3;
        int reg = ( modrm >> 3 ) & 7;
        int rm  = ( modrm      ) & 7;
        const char *mnem = ( op == 0x8D ) ? "lea"
                          : ( op == 0x8B ) ? "mov" : "mov";
        int width_rex = rex_w;
        PrintPrefix( out, off, p, n );
        if ( mod == 3 ) {
            /* register form: only 89 lands here in codegen (MovRegToReg). */
            const char *dst = width_rex ? Gpr64( rm, rex_b )
                                        : Gpr32( rm, rex_b );
            const char *src = width_rex ? Gpr64( reg, rex_r )
                                        : Gpr32( reg, rex_r );
            fprintf( out, "%s  %s, %s\n", mnem, dst, src );
        } else if ( op == 0x89 ) {
            const char *src = width_rex ? Gpr64( reg, rex_r )
                                        : Gpr32( reg, rex_r );
            fprintf( out, "%s  ", mnem );
            int extra = PrintMem( out, mod, rm, rex_b, p + n, left - n );
            if ( extra < 0 ) { fputs( " ; truncated\n", out ); return n; }
            n += extra;
            fprintf( out, ", %s\n", src );
        } else {
            const char *dst = width_rex ? Gpr64( reg, rex_r )
                                        : Gpr32( reg, rex_r );
            fprintf( out, "%s  %s, ", mnem, dst );
            int extra = PrintMem( out, mod, rm, rex_b, p + n, left - n );
            if ( extra < 0 ) { fputs( " ; truncated\n", out ); return n; }
            n += extra;
            fputc( '\n', out );
        }
        return n;
    }
    /* ALU r64, r/m64: ADD 03, SUB 2B, AND 23, OR 0B, XOR 33, CMP 3B. */
    if ( op == 0x03 || op == 0x2B || op == 0x23 || op == 0x0B ||
         op == 0x33 || op == 0x3B ) {
        if ( ( size_t )n >= left ) return 0;
        uint8_t modrm = p[ n ]; n++;
        int mod = ( modrm >> 6 ) & 3;
        int reg = ( modrm >> 3 ) & 7;
        int rm  = ( modrm      ) & 7;
        const char *mnem =
            ( op == 0x03 ) ? "add" :
            ( op == 0x2B ) ? "sub" :
            ( op == 0x23 ) ? "and" :
            ( op == 0x0B ) ? "or"  :
            ( op == 0x33 ) ? "xor" : "cmp";
        const char *dst = rex_w ? Gpr64( reg, rex_r ) : Gpr32( reg, rex_r );
        PrintPrefix( out, off, p, n );
        if ( mod == 3 ) {
            const char *src = rex_w ? Gpr64( rm, rex_b ) : Gpr32( rm, rex_b );
            fprintf( out, "%s  %s, %s\n", mnem, dst, src );
        } else {
            fprintf( out, "%s  %s, ", mnem, dst );
            int extra = PrintMem( out, mod, rm, rex_b, p + n, left - n );
            if ( extra < 0 ) { fputs( " ; truncated\n", out ); return n; }
            n += extra;
            fputc( '\n', out );
        }
        return n;
    }
    /* 0F prefix: two-byte opcodes we care about. Jcc rel32 (0F 8x id) and
    ** IMUL r64, r/m64 (0F AF /r). */
    if ( op == 0x0F ) {
        if ( ( size_t )n >= left ) return 0;
        uint8_t sop = p[ n ]; n++;
        if ( sop >= 0x80 && sop <= 0x8F ) {
            if ( ( size_t )n + 4 > left ) return 0;
            int32_t rel; memcpy( &rel, p + n, 4 ); n += 4;
            static const char *jcc[ 16 ] = {
              "jo","jno","jb","jae","je","jne","jbe","ja",
              "js","jns","jp","jnp","jl","jge","jle","jg"
            };
            PrintPrefix( out, off, p, n );
            fprintf( out, "%s  rel32 %+d\n", jcc[ sop & 0xF ], rel );
            return n;
        }
        if ( sop == 0xAF ) {
            if ( ( size_t )n >= left ) return 0;
            uint8_t modrm = p[ n ]; n++;
            int mod = ( modrm >> 6 ) & 3;
            int reg = ( modrm >> 3 ) & 7;
            int rm  = ( modrm      ) & 7;
            const char *dst = rex_w ? Gpr64( reg, rex_r )
                                    : Gpr32( reg, rex_r );
            PrintPrefix( out, off, p, n );
            if ( mod == 3 ) {
                fprintf( out, "imul %s, %s\n", dst,
                         rex_w ? Gpr64( rm, rex_b )
                               : Gpr32( rm, rex_b ) );
            } else {
                fprintf( out, "imul %s, ", dst );
                int extra = PrintMem( out, mod, rm, rex_b, p + n, left - n );
                if ( extra < 0 ) { fputs( " ; truncated\n", out ); return n; }
                n += extra;
                fputc( '\n', out );
            }
            return n;
        }
        /* Unknown 0F <op>: give up and let caller emit raw. */
        return 0;
    }
    /* 83 /n ib -- ADD/OR/ADC/SBB/AND/SUB/XOR/CMP r/m64, imm8 (with REX.W). */
    if ( op == 0x83 ) {
        if ( ( size_t )n >= left ) return 0;
        uint8_t modrm = p[ n ]; n++;
        int mod = ( modrm >> 6 ) & 3;
        int sub = ( modrm >> 3 ) & 7;
        int rm  = ( modrm      ) & 7;
        static const char *subops[ 8 ] = {
            "add","or","adc","sbb","and","sub","xor","cmp"
        };
        PrintPrefix( out, off, p, n );
        if ( mod == 3 ) {
            if ( ( size_t )n >= left ) return 0;
            int8_t imm = ( int8_t )p[ n ]; n++;
            fprintf( out, "%s  %s, %d\n",
                     subops[ sub ],
                     rex_w ? Gpr64( rm, rex_b ) : Gpr32( rm, rex_b ),
                     imm );
        } else {
            fprintf( out, "%s  ", subops[ sub ] );
            int extra = PrintMem( out, mod, rm, rex_b, p + n, left - n );
            if ( extra < 0 ) { fputs( " ; truncated\n", out ); return n; }
            n += extra;
            if ( ( size_t )n >= left ) return 0;
            int8_t imm = ( int8_t )p[ n ]; n++;
            fprintf( out, ", %d\n", imm );
        }
        return n;
    }
    /* 81 /n id -- same subop table, 32-bit immediate. */
    if ( op == 0x81 ) {
        if ( ( size_t )n >= left ) return 0;
        uint8_t modrm = p[ n ]; n++;
        int mod = ( modrm >> 6 ) & 3;
        int sub = ( modrm >> 3 ) & 7;
        int rm  = ( modrm      ) & 7;
        static const char *subops[ 8 ] = {
            "add","or","adc","sbb","and","sub","xor","cmp"
        };
        PrintPrefix( out, off, p, n );
        if ( mod == 3 ) {
            if ( ( size_t )n + 4 > left ) return 0;
            int32_t imm; memcpy( &imm, p + n, 4 ); n += 4;
            fprintf( out, "%s  %s, %d\n",
                     subops[ sub ],
                     rex_w ? Gpr64( rm, rex_b ) : Gpr32( rm, rex_b ),
                     imm );
        } else {
            fprintf( out, "%s  ", subops[ sub ] );
            int extra = PrintMem( out, mod, rm, rex_b, p + n, left - n );
            if ( extra < 0 ) { fputs( " ; truncated\n", out ); return n; }
            n += extra;
            if ( ( size_t )n + 4 > left ) return 0;
            int32_t imm; memcpy( &imm, p + n, 4 ); n += 4;
            fprintf( out, ", %d\n", imm );
        }
        return n;
    }
    /* C7 /0 id -- MOV r/m32, imm32 (used for tag stores). */
    if ( op == 0xC7 ) {
        if ( ( size_t )n >= left ) return 0;
        uint8_t modrm = p[ n ]; n++;
        int mod = ( modrm >> 6 ) & 3;
        int sub = ( modrm >> 3 ) & 7;
        int rm  = ( modrm      ) & 7;
        PrintPrefix( out, off, p, n );
        if ( sub != 0 ) {
            fputs( "??? ; unhandled C7 subop\n", out );
            return n;
        }
        if ( mod == 3 ) {
            if ( ( size_t )n + 4 > left ) return 0;
            int32_t imm; memcpy( &imm, p + n, 4 ); n += 4;
            fprintf( out, "mov  %s, %d\n",
                     rex_w ? Gpr64( rm, rex_b ) : Gpr32( rm, rex_b ),
                     imm );
        } else {
            fputs( "mov  ", out );
            int extra = PrintMem( out, mod, rm, rex_b, p + n, left - n );
            if ( extra < 0 ) { fputs( " ; truncated\n", out ); return n; }
            n += extra;
            if ( ( size_t )n + 4 > left ) return 0;
            int32_t imm; memcpy( &imm, p + n, 4 ); n += 4;
            fprintf( out, ", %d\n", imm );
        }
        return n;
    }
    /* 80 /7 ib -- CMP r/m8, imm8. */
    if ( op == 0x80 ) {
        if ( ( size_t )n >= left ) return 0;
        uint8_t modrm = p[ n ]; n++;
        int mod = ( modrm >> 6 ) & 3;
        int sub = ( modrm >> 3 ) & 7;
        int rm  = ( modrm      ) & 7;
        PrintPrefix( out, off, p, n );
        if ( sub == 7 && mod != 3 ) {
            fputs( "cmp  byte ", out );
            int extra = PrintMem( out, mod, rm, rex_b, p + n, left - n );
            if ( extra < 0 ) { fputs( " ; truncated\n", out ); return n; }
            n += extra;
            if ( ( size_t )n >= left ) return 0;
            int8_t imm = ( int8_t )p[ n ]; n++;
            fprintf( out, ", %d\n", imm );
            return n;
        }
        fputs( "??? ; unhandled 80\n", out );
        return n;
    }
    /* F6 /0 ib -- TEST r/m8, imm8. */
    if ( op == 0xF6 ) {
        if ( ( size_t )n >= left ) return 0;
        uint8_t modrm = p[ n ]; n++;
        int mod = ( modrm >> 6 ) & 3;
        int sub = ( modrm >> 3 ) & 7;
        int rm  = ( modrm      ) & 7;
        PrintPrefix( out, off, p, n );
        if ( sub == 0 && mod != 3 ) {
            fputs( "test byte ", out );
            int extra = PrintMem( out, mod, rm, rex_b, p + n, left - n );
            if ( extra < 0 ) { fputs( " ; truncated\n", out ); return n; }
            n += extra;
            if ( ( size_t )n >= left ) return 0;
            int8_t imm = ( int8_t )p[ n ]; n++;
            fprintf( out, ", %d\n", imm );
            return n;
        }
        fputs( "??? ; unhandled F6\n", out );
        return n;
    }
    /* Short jumps. */
    if ( op == 0x74 || op == 0x75 || op == 0x76 || op == 0xEB ) {
        if ( ( size_t )n >= left ) return 0;
        int8_t rel = ( int8_t )p[ n ]; n++;
        const char *mnem = ( op == 0x74 ) ? "je"  :
                           ( op == 0x75 ) ? "jne" :
                           ( op == 0x76 ) ? "jbe" : "jmp";
        PrintPrefix( out, off, p, n );
        fprintf( out, "%s  rel8 %+d\n", mnem, rel );
        return n;
    }
    /* CALL rel32 / JMP rel32. */
    if ( op == 0xE8 || op == 0xE9 ) {
        if ( ( size_t )n + 4 > left ) return 0;
        int32_t rel; memcpy( &rel, p + n, 4 ); n += 4;
        PrintPrefix( out, off, p, n );
        fprintf( out, "%s rel32 %+d\n", ( op == 0xE8 ) ? "call" : "jmp ", rel );
        return n;
    }
    /* TEST eax, eax (85 C0) and CMP eax, imm8 (83 F8 ib is already 83 above).
    ** 85 /r is a general TEST r/m32, r32; we cover the eax,eax variant here. */
    if ( op == 0x85 ) {
        if ( ( size_t )n >= left ) return 0;
        uint8_t modrm = p[ n ]; n++;
        int mod = ( modrm >> 6 ) & 3;
        int reg = ( modrm >> 3 ) & 7;
        int rm  = ( modrm      ) & 7;
        PrintPrefix( out, off, p, n );
        if ( mod == 3 ) {
            fprintf( out, "test %s, %s\n",
                     Gpr32( rm, rex_b ), Gpr32( reg, rex_r ) );
        } else {
            fputs( "test ??? ; unhandled\n", out );
        }
        return n;
    }
    /* FF /2 -- CALL r/m64 (indirect call, used after mov rax, imm64). */
    if ( op == 0xFF ) {
        if ( ( size_t )n >= left ) return 0;
        uint8_t modrm = p[ n ]; n++;
        int mod = ( modrm >> 6 ) & 3;
        int sub = ( modrm >> 3 ) & 7;
        int rm  = ( modrm      ) & 7;
        PrintPrefix( out, off, p, n );
        if ( sub == 2 && mod == 3 ) {
            fprintf( out, "call %s\n", Gpr64( rm, rex_b ) );
        } else {
            fputs( "??? ; unhandled FF\n", out );
        }
        return n;
    }

    /* Did not decode. Back up to before we consumed the opcode so the raw
    ** fallback prints the failed byte and only that byte. */
    return 0;
}

static void DumpOneFunc( FILE *out, const LcCompiledFunc *f ) {
    size_t   off = 0;
    fprintf( out, "-- %s: %zu bytes, %zu relocs\n",
             f->name, f->code_len, f->nrelocs );
    while ( off < f->code_len ) {
        int step = DecodeOne( out, off, f->code + off, f->code_len - off );
        if ( step <= 0 ) {
            /* Print one byte raw, then advance -- keeps us in sync at the
            ** next instruction boundary the codegen guarantees. */
            PrintRaw( out, off, f->code + off, 1 );
            step = 1;
        }
        off += ( size_t )step;
    }
}

int Lc_DumpAsm( FILE *out, const LcCodeModule *cm ) {
    uint32_t i;
    if ( out == NULL || cm == NULL ) return 0;
    fprintf( out, "; asm dump (%u function%s)\n",
             cm->nfuncs, cm->nfuncs == 1 ? "" : "s" );
    for ( i = 0; i < cm->nfuncs; i++ ) {
        if ( i > 0 ) fputc( '\n', out );
        DumpOneFunc( out, &cm->funcs[ i ] );
    }
    return 1;
}
