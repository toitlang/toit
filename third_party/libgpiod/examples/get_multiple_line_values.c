// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2023 Kent Gibson <warthog618@gmail.com>

/* Minimal example of reading multiple lines. */

#include <errno.h>
#include <gpiod.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NUM_LINES 3

/* Request a line as input. */
static struct gpiod_line_request *
request_input_lines(const char *chip_path, const unsigned int *offsets,
		    unsigned int num_lines, const char *consumer)
{
	struct gpiod_request_config *req_cfg = NULL;
	struct gpiod_line_request *request = NULL;
	struct gpiod_line_settings *settings;
	struct gpiod_line_config *line_cfg;
	struct gpiod_chip *chip;
	unsigned int i;
	int ret;

	chip = gpiod_chip_open(chip_path);
	if (!chip)
		return NULL;

	settings = gpiod_line_settings_new();
	if (!settings)
		goto close_chip;

	gpiod_line_settings_set_direction(settings, GPIOD_LINE_DIRECTION_INPUT);

	line_cfg = gpiod_line_config_new();
	if (!line_cfg)
		goto free_settings;

	for (i = 0; i < num_lines; i++) {
		ret = gpiod_line_config_add_line_settings(line_cfg, &offsets[i],
							  1, settings);
		if (ret)
			goto free_line_config;
	}

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

static int print_values(const unsigned int *offsets, unsigned int num_lines,
			enum gpiod_line_value *values)
{
	unsigned int i;

	for (i = 0; i < num_lines; i++) {
		if (values[i] == GPIOD_LINE_VALUE_ACTIVE)
			printf("%d=Active ", offsets[i]);
		else if (values[i] == GPIOD_LINE_VALUE_INACTIVE) {
			printf("%d=Inactive ", offsets[i]);
		} else {
			fprintf(stderr, "error reading value: %s\n",
				strerror(errno));
			return EXIT_FAILURE;
		}
	}

	printf("\n");

	return EXIT_SUCCESS;
}

int main(void)
{
	/* Example configuration - customize to suit your situation. */
	static const char *const chip_path = "/dev/gpiochip0";
	static const unsigned int line_offsets[NUM_LINES] = { 5, 3, 7 };

	enum gpiod_line_value values[NUM_LINES];
	struct gpiod_line_request *request;
	int ret;

	request = request_input_lines(chip_path, line_offsets, NUM_LINES,
				      "get-multiple-line-values");
	if (!request) {
		fprintf(stderr, "failed to request lines: %s\n",
			strerror(errno));
		return EXIT_FAILURE;
	}

	ret = gpiod_line_request_get_values(request, values);
	if (ret == -1) {
		fprintf(stderr, "failed to get values: %s\n", strerror(errno));
		return EXIT_FAILURE;
	}

	return print_values(line_offsets, NUM_LINES, values);
}
