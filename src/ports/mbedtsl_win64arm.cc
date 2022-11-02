// Copyright (C) 2022 Toitware ApS.
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
#if defined(_WIN32) && defined(MBEDTLS_TIMING_ALT)
extern "C" {
#include "windows.h"
unsigned long mbedtls_timing_hardclock( void )
{
  LARGE_INTEGER offset;

  QueryPerformanceCounter( &offset );

  return( (unsigned long)( offset.QuadPart ) );
}

} // extern "C"
#endif // defined(_WIN32) && defined(_ARM_)

#if defined(_WIN32)

#endif
