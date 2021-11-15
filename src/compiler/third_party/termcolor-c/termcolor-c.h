/**
 * termcolor-c
 * -----------
 * A header-only ANSI C library for printing colored messages to the terminal
 * Based on termcolor for C++ by Ihor Kalnytskyi (3-clause BSD license)
 * -----------
 * Copyright (c) 2018, Alex Arslan
 *
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * * Redistributions of source code must retain the above copyright notice, this
 *   list of conditions and the following disclaimer.
 *
 * * Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
#ifndef _TERMCOLOR_C_H_
#define _TERMCOLOR_C_H_

#ifdef __cplusplus
extern "C" {
#endif

#if !(defined(__unix__) || defined(__unix) || (defined(__APPLE__) && defined(__MACH__)))
#error Your platform is currently unsupported
#endif

#include <unistd.h>
#include <stdio.h>
#include <stdbool.h>

#define ANSI_CODE_RESET      "\033[00m"
#define ANSI_CODE_BOLD       "\033[1m"
#define ANSI_CODE_DARK       "\033[2m"
#define ANSI_CODE_UNDERLINE  "\033[4m"
#define ANSI_CODE_BLINK      "\033[5m"
#define ANSI_CODE_REVERSE    "\033[7m"
#define ANSI_CODE_CONCEALED  "\033[8m"
#define ANSI_CODE_GRAY       "\033[30m"
#define ANSI_CODE_GREY       "\033[30m"
#define ANSI_CODE_RED        "\033[31m"
#define ANSI_CODE_GREEN      "\033[32m"
#define ANSI_CODE_YELLOW     "\033[33m"
#define ANSI_CODE_BLUE       "\033[34m"
#define ANSI_CODE_MAGENTA    "\033[35m"
#define ANSI_CODE_CYAN       "\033[36m"
#define ANSI_CODE_WHITE      "\033[37m"
#define ANSI_CODE_BG_GRAY    "\033[40m"
#define ANSI_CODE_BG_GREY    "\033[40m"
#define ANSI_CODE_BG_RED     "\033[41m"
#define ANSI_CODE_BG_GREEN   "\033[42m"
#define ANSI_CODE_BG_YELLOW  "\033[43m"
#define ANSI_CODE_BG_BLUE    "\033[44m"
#define ANSI_CODE_BG_MAGENTA "\033[45m"
#define ANSI_CODE_BG_CYAN    "\033[46m"
#define ANSI_CODE_BG_WHITE   "\033[47m"

/* TODO: Maybe non-TTYs support color? idk */
bool supports_color(FILE* stream) {
    return isatty(fileno(stream));
}

/**
 * These functions affect the appearance of text, i.e. the foreground, in the stream
 */
#define DEFUN_T(c, code) \
    FILE* text_##c(FILE* stream) { \
        if (supports_color(stream)) { \
            fputs(ANSI_CODE_##code, stream); \
        } \
        return stream; \
    }
DEFUN_T(bold, BOLD);
DEFUN_T(dark, DARK);
DEFUN_T(underline, UNDERLINE);
DEFUN_T(blink, BLINK);
DEFUN_T(reverse, REVERSE);
DEFUN_T(concealed, CONCEALED);
DEFUN_T(gray, GRAY);
DEFUN_T(grey, GREY);
DEFUN_T(red, RED);
DEFUN_T(green, GREEN);
DEFUN_T(yellow, YELLOW);
DEFUN_T(blue, BLUE);
DEFUN_T(magenta, MAGENTA);
DEFUN_T(cyan, CYAN);
DEFUN_T(white, WHITE);
#undef DEFUN_T

/**
 * These functions affect the appearance of the background of text in the stream
 */
#define DEFUN_B(c, code) \
    FILE* background_##c(FILE* stream) { \
        if (supports_color(stream)) { \
            fputs(ANSI_CODE_BG_##code, stream); \
        } \
        return stream; \
    }
DEFUN_B(gray, GRAY);
DEFUN_B(grey, GREY);
DEFUN_B(red, RED);
DEFUN_B(green, GREEN);
DEFUN_B(yellow, YELLOW);
DEFUN_B(blue, BLUE);
DEFUN_B(magenta, MAGENTA);
DEFUN_B(cyan, CYAN);
DEFUN_B(white, WHITE);
#undef DEFUN_B

void reset_colors(FILE* stream) {
    if (supports_color(stream)) {
        fputs(ANSI_CODE_RESET, stream);
    }
}

#ifdef __cplusplus
}
#endif

#endif /* _TERMCOLOR_C_H_ */
