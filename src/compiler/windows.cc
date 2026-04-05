// Copyright (C) 2018 Toitware ApS.
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

#include "../top.h"

#ifdef TOIT_WINDOWS

#include <stdio.h>
#include <stdlib.h>

#include "windows.h"

size_t getline(char** lineptr, size_t* n, FILE* stream) {
    if (lineptr == NULL || stream == NULL || n == NULL) {
        return -1;
    }

    char* bufptr = *lineptr;
    size_t size = *n;

    int c = fgetc(stream);
    if (c == EOF) {
        return -1;
    }

    if (bufptr == NULL) {
        bufptr = reinterpret_cast<char*>(malloc(128));
        if (bufptr == NULL) {
            return -1;
        }
        size = 128;
    }

    size_t pos = 0;
    while (c != EOF) {
        // Ensure room for this character plus a null terminator.
        if (pos + 1 >= size) {
            size_t new_size = size + 128;
            char* new_buf = reinterpret_cast<char*>(realloc(bufptr, new_size));
            if (new_buf == NULL) {
                // On failure, realloc leaves the old block intact.
                // Write back what we have so the caller can free it.
                *lineptr = bufptr;
                *n = size;
                return -1;
            }
            bufptr = new_buf;
            size = new_size;
        }
        bufptr[pos++] = c;
        if (c == '\n') {
            break;
        }
        c = fgetc(stream);
    }

    bufptr[pos] = '\0';
    *lineptr = bufptr;
    *n = size;

    return pos;
}

#endif
