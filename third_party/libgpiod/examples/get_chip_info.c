// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2023 Kent Gibson <warthog618@gmail.com>

/* Minimal example of reading the info for a chip. */

#include <errno.h>
#include <gpiod.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
	/* Example configuration - customize to suit your situation. */
	static const char *const chip_path = "/dev/gpiochip0";

	struct gpiod_chip_info *info;
	struct gpiod_chip *chip;

	chip = gpiod_chip_open(chip_path);
	if (!chip) {
		fprintf(stderr, "failed to open chip: %s\n", strerror(errno));
		return EXIT_FAILURE;
	}

	info = gpiod_chip_get_info(chip);
	if (!info) {
		fprintf(stderr, "failed to read info: %s\n", strerror(errno));
		return EXIT_FAILURE;
	}

	printf("%s [%s] (%zu lines)\n", gpiod_chip_info_get_name(info),
	       gpiod_chip_info_get_label(info),
	       gpiod_chip_info_get_num_lines(info));

	gpiod_chip_info_free(info);
	gpiod_chip_close(chip);

	return EXIT_SUCCESS;
}
