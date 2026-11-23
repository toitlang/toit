// Copyright (C) 2025 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "dtoa.h"
#include <math.h>
#include "dragonbox/dragonbox.h"

#include "top.h"

namespace toit {

static int write_shortest_decimal(char* buffer, const char* digits, int digit_count, int exponent, bool is_negative) {
  int pos = 0;
  if (is_negative) {
    buffer[pos++] = '-';
  }

  // Similar to EcmaScript:
  // Anything in the range [10^-6, 10^21) is represented as a normal
  // decimal number.  Outside that range, scientific notation is used.
  int decimal_in_shortest_low = -6;
  int decimal_in_shortest_high = 21;

  int adjusted_exponent = exponent + digit_count - 1;
  if (decimal_in_shortest_low <= adjusted_exponent &&
      adjusted_exponent < decimal_in_shortest_high) {
    // Decimal representation.
    if (exponent >= 0) {
      // Integer with trailing zeros.
      for (int i = digit_count - 1; i >= 0; i--) {
        // Remember, that the digits are in reverse order.
        buffer[pos++] = digits[i];
      }
      for (int i = 0; i < exponent; i++) {
        buffer[pos++] = '0';
      }
      buffer[pos++] = '.';
      buffer[pos++] = '0';
    } else if (adjusted_exponent >= 0) {
      // Decimal point inside the number.
      for (int i = digit_count - 1; i >= 0; i--) {
        buffer[pos++] = digits[i];
        if (i == -exponent) {
          buffer[pos++] = '.';
        }
      }
    } else {
      // Decimal point before the number.
      buffer[pos++] = '0';
      buffer[pos++] = '.';
      for (int i = 0; i < -adjusted_exponent - 1; i++) {
        buffer[pos++] = '0';
      }
      for (int i = digit_count - 1; i >= 0; i--) {
        buffer[pos++] = digits[i];
      }
    }
  } else {
    // Exponential representation.
    // One digit before the decimal point.
    buffer[pos++] = digits[digit_count - 1];
    if (digit_count > 1) {
      buffer[pos++] = '.';
      for (int i = digit_count - 2; i >= 0; i--) {
        buffer[pos++] = digits[i];
      }
    }
    buffer[pos++] = 'e';
    if (adjusted_exponent < 0) {
      buffer[pos++] = '-';
      adjusted_exponent = -adjusted_exponent;
    }
    // Write exponent as at least two digits.
    if (adjusted_exponent >= 100) {
      int hundreds = adjusted_exponent / 100;
      buffer[pos++] = '0' + hundreds;
      adjusted_exponent -= hundreds * 100;
    }
    int tens = adjusted_exponent / 10;
    buffer[pos++] = '0' + tens;
    adjusted_exponent -= tens * 10;
    buffer[pos++] = '0' + adjusted_exponent;
  }
  buffer[pos] = '\0';
  return pos;
}

static int format_shortest_decimal(char* buffer, uint64 significand, int exponent, bool is_negative) {
  // A binary64 shortest decimal has at most 17 digits. Check the conversion
  // result before using it to size or index either buffer.
  if (significand >= 100000000000000000ULL || exponent < -340 || exponent > 308) return -1;
  char digits[17];
  int digit_count = 0;
  while (true) {
    digits[digit_count++] = '0' + (significand % 10);
    significand /= 10;
    if (significand == 0) break;
  }
  return write_shortest_decimal(buffer, digits, digit_count, exponent, is_negative);
}

static uint64 shortest_significand(double value, int* exponent) {
  auto v = jkj::dragonbox::to_decimal(value,
    jkj::dragonbox::policy::sign::ignore
#ifdef TOIT_FREERTOS
    , jkj::dragonbox::policy::cache::compact
#endif
  );
  *exponent = v.exponent;
  return v.significand;
}

int double_to_shortest(double value, char* buffer, size_t buffer_size) {
  if (buffer_size < MAX_BUFFER_SIZE_DOUBLE_TO_SHORTEST) {
    return -1;
  }
  bool is_negative = signbit(value);
  int exponent;
  uint64 significand = shortest_significand(value, &exponent);
  return format_shortest_decimal(buffer, significand, exponent, is_negative);
}

} // namespace toit


/*
  int decimal_point;
  bool sign;
  const int kDecimalRepCapacity = kBase10MaximalLength + 1;
  char decimal_rep[kDecimalRepCapacity];
  int decimal_rep_length;

  DoubleToAscii(value, mode, 0, decimal_rep, kDecimalRepCapacity,
                &sign, &decimal_rep_length, &decimal_point);

  bool unique_zero = (flags_ & UNIQUE_ZERO) != 0;
  if (sign && (value != 0.0 || !unique_zero)) {
    result_builder->AddCharacter('-');
  }

  int exponent = decimal_point - 1;
  if ((decimal_in_shortest_low_ <= exponent) &&
      (exponent < decimal_in_shortest_high_)) {
    CreateDecimalRepresentation(decimal_rep, decimal_rep_length,
                                decimal_point,
                                (std::max)(0, decimal_rep_length - decimal_point),
                                result_builder);
  } else {
    CreateExponentialRepresentation(decimal_rep, decimal_rep_length, exponent,
                                    result_builder);
  }
*/
