// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2023 Kent Gibson <warthog618@gmail.com>

/* Minimal example of reading the info for a line. */

#include <errno.h>
#include <gpiod.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
	/* Example configuration - customize to suit your situation. */
	static const char *const chip_path = "/dev/gpiochip0";
	static const unsigned int line_offset = 3;

	const char *name, *consumer, *dir;
	struct gpiod_line_info *info;
	struct gpiod_chip *chip;

	chip = gpiod_chip_open(chip_path);
	if (!chip) {
		fprintf(stderr, "failed to open chip: %s\n", strerror(errno));
		return EXIT_FAILURE;
	}

	info = gpiod_chip_get_line_info(chip, line_offset);
	if (!info) {
		fprintf(stderr, "failed to read info: %s\n", strerror(errno));
		return EXIT_FAILURE;
	}

	name = gpiod_line_info_get_name(info);
	if (!name)
		name = "unnamed";

	consumer = gpiod_line_info_get_consumer(info);
	if (!consumer)
		consumer = "unused";

	dir = (gpiod_line_info_get_direction(info) ==
	       GPIOD_LINE_DIRECTION_INPUT) ?
		      "input" :
		      "output";

	printf("line %3d: %12s %12s %8s %10s\n",
	       gpiod_line_info_get_offset(info), name, consumer, dir,
	       gpiod_line_info_is_active_low(info) ? "active-low" :
						     "active-high");

	gpiod_line_info_free(info);
	gpiod_chip_close(chip);

	return EXIT_SUCCESS;
}
