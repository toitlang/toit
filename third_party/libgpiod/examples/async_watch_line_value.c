// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2023 Kent Gibson <warthog618@gmail.com>

/* Minimal example of asynchronously watching for edges on a single line. */

#include <errno.h>
#include <gpiod.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Request a line as input with edge detection. */
static struct gpiod_line_request *request_input_line(const char *chip_path,
						     unsigned int offset,
						     const char *consumer)
{
	struct gpiod_request_config *req_cfg = NULL;
	struct gpiod_line_request *request = NULL;
	struct gpiod_line_settings *settings;
	struct gpiod_line_config *line_cfg;
	struct gpiod_chip *chip;
	int ret;

	chip = gpiod_chip_open(chip_path);
	if (!chip)
		return NULL;

	settings = gpiod_line_settings_new();
	if (!settings)
		goto close_chip;

	gpiod_line_settings_set_direction(settings, GPIOD_LINE_DIRECTION_INPUT);
	gpiod_line_settings_set_edge_detection(settings, GPIOD_LINE_EDGE_BOTH);
	/* Assume a button connecting the pin to ground, so pull it up... */
	gpiod_line_settings_set_bias(settings, GPIOD_LINE_BIAS_PULL_UP);
	/* ... and provide some debounce. */
	gpiod_line_settings_set_debounce_period_us(settings, 10000);

	line_cfg = gpiod_line_config_new();
	if (!line_cfg)
		goto free_settings;

	ret = gpiod_line_config_add_line_settings(line_cfg, &offset, 1,
						  settings);
	if (ret)
		goto free_line_config;

	if (consumer) {
		req_cfg = gpiod_request_config_new();
		if (!req_cfg)
			goto free_line_config;

		gpiod_request_config_set_consumer(req_cfg, consumer);
	}

	request = gpiod_chip_request_lines(chip, req_cfg, line_cfg);

	gpiod_request_config_free(req_cfg);

free_line_config:
	gpiod_line_config_free(line_cfg);

free_settings:
	gpiod_line_settings_free(settings);

close_chip:
	gpiod_chip_close(chip);

	return request;
}

static const char *edge_event_type_str(struct gpiod_edge_event *event)
{
	switch (gpiod_edge_event_get_event_type(event)) {
	case GPIOD_EDGE_EVENT_RISING_EDGE:
		return "Rising";
	case GPIOD_EDGE_EVENT_FALLING_EDGE:
		return "Falling";
	default:
		return "Unknown";
	}
}

int main(void)
{
	/* Example configuration - customize to suit your situation. */
	static const char *const chip_path = "/dev/gpiochip0";
	static const unsigned int line_offset = 5;

	struct gpiod_edge_event_buffer *event_buffer;
	struct gpiod_line_request *request;
	struct gpiod_edge_event *event;
	int i, ret, event_buf_size;
	struct pollfd pollfd;

	request = request_input_line(chip_path, line_offset,
				     "async-watch-line-value");
	if (!request) {
		fprintf(stderr, "failed to request line: %s\n",
			strerror(errno));
		return EXIT_FAILURE;
	}

	/*
	 * A larger buffer is an optimisation for reading bursts of events from
	 * the kernel, but that is not necessary in this case, so 1 is fine.
	 */
	event_buf_size = 1;
	event_buffer = gpiod_edge_event_buffer_new(event_buf_size);
	if (!event_buffer) {
		fprintf(stderr, "failed to create event buffer: %s\n",
			strerror(errno));
		return EXIT_FAILURE;
	}

	pollfd.fd = gpiod_line_request_get_fd(request);
	pollfd.events = POLLIN;

	for (;;) {
		ret = poll(&pollfd, 1, -1);
		if (ret == -1) {
			fprintf(stderr, "error waiting for edge events: %s\n",
				strerror(errno));
			return EXIT_FAILURE;
		}
		ret = gpiod_line_request_read_edge_events(request, event_buffer,
							  event_buf_size);
		if (ret == -1) {
			fprintf(stderr, "error reading edge events: %s\n",
				strerror(errno));
			return EXIT_FAILURE;
		}
		for (i = 0; i < ret; i++) {
			event = gpiod_edge_event_buffer_get_event(event_buffer,
								  i);
			printf("offset: %d  type: %-7s  event #%ld\n",
			       gpiod_edge_event_get_line_offset(event),
			       edge_event_type_str(event),
			       gpiod_edge_event_get_line_seqno(event));
		}
	}
}
