// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2023 Kent Gibson <warthog618@gmail.com>

/* Minimal example of watching for info changes on particular lines. */

#include <errno.h>
#include <gpiod.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NUM_LINES 3

static const char *event_type(struct gpiod_info_event *event)
{
	switch (gpiod_info_event_get_event_type(event)) {
	case GPIOD_INFO_EVENT_LINE_REQUESTED:
		return "Requested";
	case GPIOD_INFO_EVENT_LINE_RELEASED:
		return "Released";
	case GPIOD_INFO_EVENT_LINE_CONFIG_CHANGED:
		return "Reconfig";
	default:
		return "Unknown";
	}
}

int main(void)
{
	/* Example configuration - customize to suit your situation. */
	static const char *const chip_path = "/dev/gpiochip0";
	static const unsigned int line_offsets[NUM_LINES] = { 5, 3, 7 };

	struct gpiod_info_event *event;
	struct gpiod_line_info *info;
	struct gpiod_chip *chip;
	uint64_t timestamp_ns;
	unsigned int i;

	chip = gpiod_chip_open(chip_path);
	if (!chip) {
		fprintf(stderr, "failed to open chip: %s\n", strerror(errno));
		return EXIT_FAILURE;
	}

	for (i = 0; i < NUM_LINES; i++) {
		info = gpiod_chip_watch_line_info(chip, line_offsets[i]);
		if (!info) {
			fprintf(stderr, "failed to read info: %s\n",
				strerror(errno));
			return EXIT_FAILURE;
		}
	}

	for (;;) {
		/* Blocks until an event is available. */
		event = gpiod_chip_read_info_event(chip);
		if (!event) {
			fprintf(stderr, "failed to read event: %s\n",
				strerror(errno));
			return EXIT_FAILURE;
		}

		info = gpiod_info_event_get_line_info(event);
		timestamp_ns = gpiod_info_event_get_timestamp_ns(event);
		printf("line %3d: %-9s %" PRIu64 ".%" PRIu64 "\n",
		       gpiod_line_info_get_offset(info), event_type(event),
		       timestamp_ns / 1000000000, timestamp_ns % 1000000000);

		gpiod_info_event_free(event);
	}
}
