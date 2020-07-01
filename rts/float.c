#include "rts.h"

// this is not intended for native compilation/testing (yet)
#ifdef __wasm__

export as_ptr float_fmt(double a, uint32_t prec, uint32_t mode) {
  // prec and mode are passed tagged:
  mode >>= 24; // untag Word8
  prec >>= 24; // untag Word8
  if (prec > 100) prec = 100;
  extern int snprintf(char *__restrict, size_t, const char *__restrict, ...);
  char buf[120]; // will be of length less than 110 for max precision
  int chars;
  switch (mode) {
    case 0: { chars = snprintf(buf, sizeof buf, "%.*f", prec, a); break; }
    case 1: { chars = snprintf(buf, sizeof buf, "%.*e", prec, a); break; }
    case 2: { chars = snprintf(buf, sizeof buf, "%.*g", prec, a); break; }
    case 3: { chars = snprintf(buf, sizeof buf, "%.*a", prec, a); break; }
    default: rts_trap_with("unrecognised float_fmt mode");
  }
  return text_of_ptr_size(buf, chars);
}

// re-export transcendental and trigonometric functions under a modified naming scheme
// e.g. pow(a, b) ==> float_pow

#define EXPORT_UNARY(IMP, A1, EXP) \
  export double float_ ## EXP(double A1) { \
    extern double IMP(double); \
    return IMP(A1); \
  }

#define EXPORT_BINARY(IMP, A1, A2, EXP) \
  export double float_ ## EXP(double A1, double A2) { \
    extern double IMP(double, double); \
    return IMP(A1, A2); \
  }

EXPORT_BINARY(pow, a, b, pow)
EXPORT_UNARY(sin, a, sin)
EXPORT_UNARY(cos, a, cos)
EXPORT_UNARY(tan, a, tan)
EXPORT_UNARY(asin, a, arcsin)
EXPORT_UNARY(acos, a, arccos)
EXPORT_UNARY(atan, a, arctan)
EXPORT_BINARY(atan2, y, x, arctan2)
EXPORT_UNARY(exp, a, exp)
EXPORT_UNARY(log, a, log)

// Remainder of `a/b`
//
// Confusingly, remainder operation on doubles in C is called `fmod` and not
// `frem`, see https://en.cppreference.com/w/c/numeric/math/fmod
EXPORT_BINARY(fmod, a, b, rem)

#endif
