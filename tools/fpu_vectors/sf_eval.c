/*
 * Evaluates single SoftFloat operations, for the directed vectors in
 * gen_vectors.py (testfloat_gen only makes random inputs). Build it against
 * the same SoftFloat as testfloat_gen (SPECIALIZE_TYPE=RISCV); README.md has
 * the command.
 *
 * stdin, one per line (hex operands, rm is the RISC-V encoding 0-4):
 *     <function> <rm> <a> [<b> [<c>]]
 * stdout, one per line:
 *     <result> <flags>
 * Functions: f32_add f32_sub f32_mul f32_mulAdd f32_div f32_sqrt f32_eq
 * f32_le f32_lt i32_to_f32 ui32_to_f32 f32_to_i32 f32_to_ui32. The
 * conversions to integer are exact (raise NX), like RISC-V fcvt.w[u].s.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "softfloat.h"

static float32_t f(uint32_t v) {
    float32_t r;
    r.v = v;
    return r;
}

int main(void) {
    char line[256], fn[32];
    unsigned rm, a, b, c;
    softfloat_detectTininess = softfloat_tininess_afterRounding;
    while (fgets(line, sizeof line, stdin)) {
        a = b = c = 0;
        if (sscanf(line, "%31s %u %x %x %x", fn, &rm, &a, &b, &c) < 3)
            continue;
        softfloat_roundingMode = (uint_fast8_t)rm;
        softfloat_exceptionFlags = 0;
        uint32_t r;
        if (!strcmp(fn, "f32_add"))          r = f32_add(f(a), f(b)).v;
        else if (!strcmp(fn, "f32_sub"))     r = f32_sub(f(a), f(b)).v;
        else if (!strcmp(fn, "f32_mul"))     r = f32_mul(f(a), f(b)).v;
        else if (!strcmp(fn, "f32_mulAdd"))  r = f32_mulAdd(f(a), f(b), f(c)).v;
        else if (!strcmp(fn, "f32_div"))     r = f32_div(f(a), f(b)).v;
        else if (!strcmp(fn, "f32_sqrt"))    r = f32_sqrt(f(a)).v;
        else if (!strcmp(fn, "f32_eq"))      r = f32_eq(f(a), f(b));
        else if (!strcmp(fn, "f32_le"))      r = f32_le(f(a), f(b));
        else if (!strcmp(fn, "f32_lt"))      r = f32_lt(f(a), f(b));
        else if (!strcmp(fn, "i32_to_f32"))  r = i32_to_f32((int32_t)a).v;
        else if (!strcmp(fn, "ui32_to_f32")) r = ui32_to_f32(a).v;
        else if (!strcmp(fn, "f32_to_i32"))  r = (uint32_t)f32_to_i32(f(a), (uint_fast8_t)rm, true);
        else if (!strcmp(fn, "f32_to_ui32")) r = f32_to_ui32(f(a), (uint_fast8_t)rm, true);
        else {
            fprintf(stderr, "sf_eval: unknown function %s\n", fn);
            return 1;
        }
        printf("%08X %02X\n", r, softfloat_exceptionFlags);
    }
    return 0;
}
