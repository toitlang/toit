# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2017-2021 Bartosz Golaszewski <bartekgola@gmail.com>

lib_LTLIBRARIES = libgpiod.la
libgpiod_la_SOURCES = \
	chip.c \
	chip-info.c \
	edge-event.c \
	info-event.c \
	internal.h \
	internal.c \
	line-config.c \
	line-info.c \
	line-request.c \
	line-settings.c \
	misc.c \
	request-config.c \
	uapi/gpio.h

libgpiod_la_CFLAGS = -Wall -Wextra -g -std=gnu89
libgpiod_la_CFLAGS += -fvisibility=hidden -I$(top_srcdir)/include/
libgpiod_la_CFLAGS += -include $(top_builddir)/config.h
libgpiod_la_CFLAGS += $(PROFILING_CFLAGS)
libgpiod_la_LDFLAGS = -version-info $(subst .,:,$(ABI_VERSION))
libgpiod_la_LDFLAGS+= $(PROFILING_LDFLAGS)

pkgconfigdir = $(libdir)/pkgconfig
pkgconfig_DATA = libgpiod.pc
