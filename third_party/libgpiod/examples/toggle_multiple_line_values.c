// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2023 Kent Gibson <warthog618@gmail.com>

/* Minimal example of toggling multiple lines. */

#include <errno.h>
#include <gpiod.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define NUM_LINES 3

static struct gpiod_line_request *
request_output_lines(const char *chip_path, const unsigned int *offsets,
		     enum gpiod_line_value *values, unsigned int num_lines,
		     const char *consumer)
{
	struct gpiod_request_config *rconfig = NULL;
	struct gpiod_line_request *request = NULL;
	struct gpiod_line_settings *settings;
	struct gpiod_line_config *lconfig;
	struct gpiod_chip *chip;
	unsigned int i;
	int ret;

	chip = gpiod_chip_open(chip_path);
	if (!chip)
		return NULL;

	settings = gpiod_line_settings_new();
	if (!settings)
		goto close_chip;

	gpiod_line_settings_set_direction(settings,
					  GPIOD_LINE_DIRECTION_OUTPUT);

	lconfig = gpiod_line_config_new();
	if (!lconfig)
		goto free_settings;

	for (i = 0; i < num_lines; i++) {
		ret = gpiod_line_config_add_line_settings(lconfig, &offsets[i],
							  1, settings);
		if (ret)
			goto free_line_config;
	}
	gpiod_line_config_set_output_values(lconfig, values, num_lines);

	if (consumer) {
		rconfig = gpiod_request_config_new();
		if (!rconfig)
			goto free_line_config;

		gpiod_request_config_set_consumer(rconfig, consumer);
	}

	request = gpiod_chip_request_lines(chip, rconfig, lconfig);

	gpiod_request_config_free(rconfig);

free_line_config:
	gpiod_line_config_free(lconfig);

free_settings:
	gpiod_line_settings_free(settings);

close_chip:
	gpiod_chip_close(chip);

	return request;
}

static enum gpiod_line_value toggle_line_value(enum gpiod_line_value value)
{
	return (value == GPIOD_LINE_VALUE_ACTIVE) ? GPIOD_LINE_VALUE_INACTIVE :
						    GPIOD_LINE_VALUE_ACTIVE;
}

static void toggle_line_values(enum gpiod_line_value *values,
			       unsigned int num_lines)
{
	unsigned int i;

	for (i = 0; i < num_lines; i++)
		values[i] = toggle_line_value(values[i]);
}

static void print_values(const unsigned int *offsets,
			 const enum gpiod_line_value *values,
			 unsigned int num_lines)
{
	unsigned int i;

	for (i = 0; i < num_lines; i++) {
		if (values[i] == GPIOD_LINE_VALUE_ACTIVE)
			printf("%d=Active ", offsets[i]);
		else
			printf("%d=Inactive ", offsets[i]);
	}

	printf("\n");
}

int main(void)
{
	/* Example configuration - customize to suit your situation. */
	static const char *const chip_path = "/dev/gpiochip0";
	static const unsigned int line_offsets[NUM_LINES] = { 5, 3, 7 };

	enum gpiod_line_value values[NUM_LINES] = { GPIOD_LINE_VALUE_ACTIVE,
						    GPIOD_LINE_VALUE_ACTIVE,
						    GPIOD_LINE_VALUE_INACTIVE };
	struct gpiod_line_request *request;

	request = request_output_lines(chip_path, line_offsets, values,
				       NUM_LINES,
				       "toggle-multiple-line-values");
	if (!request) {
		fprintf(stderr, "failed to request line: %s\n",
			strerror(errno));
		return EXIT_FAILURE;
	}

	for (;;) {
		print_values(line_offsets, values, NUM_LINES);
		sleep(1);
		toggle_line_values(values, NUM_LINES);
		gpiod_line_request_set_values(request, values);
	}

	gpiod_line_request_release(request);

	return EXIT_SUCCESS;
}
