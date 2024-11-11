// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2023 Kent Gibson <warthog618@gmail.com>

/*
 * Example of a bi-directional line requested as input and then switched
 * to output.
 */

#include <errno.h>
#include <gpiod.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Request a line as input. */
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

static int reconfigure_as_output_line(struct gpiod_line_request *request,
				      unsigned int offset,
				      enum gpiod_line_value value)
{
	struct gpiod_request_config *req_cfg = NULL;
	struct gpiod_line_settings *settings;
	struct gpiod_line_config *line_cfg;
	int ret = -1;

	settings = gpiod_line_settings_new();
	if (!settings)
		return -1;

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

	ret = gpiod_line_request_reconfigure_lines(request, line_cfg);

	gpiod_request_config_free(req_cfg);

free_line_config:
	gpiod_line_config_free(line_cfg);

free_settings:
	gpiod_line_settings_free(settings);

	return ret;
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

	struct gpiod_line_request *request;
	enum gpiod_line_value value;
	int ret;

	/* request the line initially as an input */
	request = request_input_line(chip_path, line_offset,
				     "reconfigure-input-to-output");
	if (!request) {
		fprintf(stderr, "failed to request line: %s\n",
			strerror(errno));
		return EXIT_FAILURE;
	}

	/* read the current line value */
	value = gpiod_line_request_get_value(request, line_offset);
	printf("%d=%s (input)\n", line_offset, value_str(value));

	/* switch the line to an output and drive it low */
	ret = reconfigure_as_output_line(request, line_offset,
					 GPIOD_LINE_VALUE_INACTIVE);

	/* report the current driven value */
	value = gpiod_line_request_get_value(request, line_offset);
	printf("%d=%s (output)\n", line_offset, value_str(value));

	/* not strictly required here, but if the app wasn't exiting... */
	gpiod_line_request_release(request);

	return ret;
}
