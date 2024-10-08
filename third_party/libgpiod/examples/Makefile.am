# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2023 Kent Gibson <warthog618@gmail.com>

AM_CFLAGS = -I$(top_srcdir)/include/ -include $(top_builddir)/config.h
AM_CFLAGS += -Wall -Wextra -g -std=gnu89

LDADD = $(top_builddir)/lib/libgpiod.la

noinst_PROGRAMS = \
	async_watch_line_value \
	find_line_by_name \
	get_chip_info \
	get_line_info \
	get_line_value \
	get_multiple_line_values \
	reconfigure_input_to_output \
	toggle_line_value \
	toggle_multiple_line_values \
	watch_line_info \
	watch_line_rising \
	watch_line_value \
	watch_multiple_line_values
