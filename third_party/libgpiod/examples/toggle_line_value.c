// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2023 Kent Gibson <warthog618@gmail.com>

/* Minimal example of toggling a single line. */

#include <errno.h>
#include <gpiod.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static struct gpiod_line_request *
request_output_line(const char *chip_path, unsigned int offset,
		    enum gpiod_line_value value, const char *consumer)
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

	gpiod_line_settings_set_direction(settings,
					  GPIOD_LINE_DIRECTION_OUTPUT);
	gpiod_line_settings_set_output_value(settings, value);

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

static enum gpiod_line_value toggle_line_value(enum gpiod_line_value value)
{
	return (value == GPIOD_LINE_VALUE_ACTIVE) ? GPIOD_LINE_VALUE_INACTIVE :
						    GPIOD_LINE_VALUE_ACTIVE;
}

static const char * value_str(enum gpiod_line_value value)
{
	if (value == GPIOD_LINE_VALUE_ACTIVE)
		return "Active";
	else if (value == GPIOD_LINE_VALUE_INACTIVE) {
		return "Inactive";
	} else {
		return "Unknown";
	}
}

int main(void)
{
	/* Example configuration - customize to suit your situation. */
	static const char *const chip_path = "/dev/gpiochip0";
	static const unsigned int line_offset = 5;

	enum gpiod_line_value value = GPIOD_LINE_VALUE_ACTIVE;
	struct gpiod_line_request *request;

	request = request_output_line(chip_path, line_offset, value,
				      "toggle-line-value");
	if (!request) {
		fprintf(stderr, "failed to request line: %s\n",
			strerror(errno));
		return EXIT_FAILURE;
	}

	for (;;) {
		printf("%d=%s\n", line_offset, value_str(value));
		sleep(1);
		value = toggle_line_value(value);
		gpiod_line_request_set_value(request, line_offset, value);
	}

	gpiod_line_request_release(request);

	return EXIT_SUCCESS;
}
