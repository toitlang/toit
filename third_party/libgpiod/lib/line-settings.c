// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2022 Bartosz Golaszewski <brgl@bgdev.pl>

#include <assert.h>
#include <errno.h>
#include <gpiod.h>
#include <string.h>
#include <stdlib.h>

#include "internal.h"

struct gpiod_line_settings {
	enum gpiod_line_direction direction;
	enum gpiod_line_edge edge_detection;
	enum gpiod_line_drive drive;
	enum gpiod_line_bias bias;
	bool active_low;
	enum gpiod_line_clock event_clock;
	long debounce_period_us;
	enum gpiod_line_value output_value;
};

GPIOD_API struct gpiod_line_settings *gpiod_line_settings_new(void)
{
	struct gpiod_line_settings *settings;

	settings = malloc(sizeof(*settings));
	if (!settings)
		return NULL;

	gpiod_line_settings_reset(settings);

	return settings;
}

GPIOD_API void gpiod_line_settings_free(struct gpiod_line_settings *settings)
{
	free(settings);
}

GPIOD_API void gpiod_line_settings_reset(struct gpiod_line_settings *settings)
{
	assert(settings);

	settings->direction = GPIOD_LINE_DIRECTION_AS_IS;
	settings->edge_detection = GPIOD_LINE_EDGE_NONE;
	settings->bias = GPIOD_LINE_BIAS_AS_IS;
	settings->drive = GPIOD_LINE_DRIVE_PUSH_PULL;
	settings->active_low = false;
	settings->debounce_period_us = 0;
	settings->event_clock = GPIOD_LINE_CLOCK_MONOTONIC;
	settings->output_value = GPIOD_LINE_VALUE_INACTIVE;
}

GPIOD_API struct gpiod_line_settings *
gpiod_line_settings_copy(struct gpiod_line_settings *settings)
{
	assert(settings);

	struct gpiod_line_settings *copy;

	copy = malloc(sizeof(*copy));
	if (!copy)
		return NULL;

	memcpy(copy, settings, sizeof(*copy));

	return copy;
}

GPIOD_API int
gpiod_line_settings_set_direction(struct gpiod_line_settings *settings,
				  enum gpiod_line_direction direction)
{
	assert(settings);

	switch (direction) {
	case GPIOD_LINE_DIRECTION_INPUT:
	case GPIOD_LINE_DIRECTION_OUTPUT:
	case GPIOD_LINE_DIRECTION_AS_IS:
		settings->direction = direction;
		break;
	default:
		settings->direction = GPIOD_LINE_DIRECTION_AS_IS;
		errno = EINVAL;
		return -1;
	}

	return 0;
}

GPIOD_API enum gpiod_line_direction
gpiod_line_settings_get_direction(struct gpiod_line_settings *settings)
{
	assert(settings);

	return settings->direction;
}

GPIOD_API int
gpiod_line_settings_set_edge_detection(struct gpiod_line_settings *settings,
				       enum gpiod_line_edge edge)
{
	assert(settings);

	switch (edge) {
	case GPIOD_LINE_EDGE_NONE:
	case GPIOD_LINE_EDGE_RISING:
	case GPIOD_LINE_EDGE_FALLING:
	case GPIOD_LINE_EDGE_BOTH:
		settings->edge_detection = edge;
		break;
	default:
		settings->edge_detection = GPIOD_LINE_EDGE_NONE;
		errno = EINVAL;
		return -1;
	}

	return 0;
}

GPIOD_API enum gpiod_line_edge
gpiod_line_settings_get_edge_detection(struct gpiod_line_settings *settings)
{
	assert(settings);

	return settings->edge_detection;
}

GPIOD_API int gpiod_line_settings_set_bias(struct gpiod_line_settings *settings,
					   enum gpiod_line_bias bias)
{
	assert(settings);

	switch (bias) {
	case GPIOD_LINE_BIAS_AS_IS:
	case GPIOD_LINE_BIAS_DISABLED:
	case GPIOD_LINE_BIAS_PULL_UP:
	case GPIOD_LINE_BIAS_PULL_DOWN:
		settings->bias = bias;
		break;
	default:
		settings->bias = GPIOD_LINE_BIAS_AS_IS;
		errno = EINVAL;
		return -1;
	}

	return 0;
}

GPIOD_API enum gpiod_line_bias
gpiod_line_settings_get_bias(struct gpiod_line_settings *settings)
{
	assert(settings);

	return settings->bias;
}

GPIOD_API int
gpiod_line_settings_set_drive(struct gpiod_line_settings *settings,
			      enum gpiod_line_drive drive)
{
	assert(settings);

	switch (drive) {
	case GPIOD_LINE_DRIVE_PUSH_PULL:
	case GPIOD_LINE_DRIVE_OPEN_DRAIN:
	case GPIOD_LINE_DRIVE_OPEN_SOURCE:
		settings->drive = drive;
		break;
	default:
		settings->drive = GPIOD_LINE_DRIVE_PUSH_PULL;
		errno = EINVAL;
		return -1;
	}

	return 0;
}

GPIOD_API enum gpiod_line_drive
gpiod_line_settings_get_drive(struct gpiod_line_settings *settings)
{
	assert(settings);

	return settings->drive;
}

GPIOD_API void
gpiod_line_settings_set_active_low(struct gpiod_line_settings *settings,
				   bool active_low)
{
	assert(settings);

	settings->active_low = active_low;
}

GPIOD_API bool
gpiod_line_settings_get_active_low(struct gpiod_line_settings *settings)
{
	assert(settings);

	return settings->active_low;
}

GPIOD_API void
gpiod_line_settings_set_debounce_period_us(struct gpiod_line_settings *settings,
					   unsigned long period)
{
	assert(settings);

	settings->debounce_period_us = period;
}

GPIOD_API unsigned long
gpiod_line_settings_get_debounce_period_us(struct gpiod_line_settings *settings)
{
	assert(settings);

	return settings->debounce_period_us;
}

GPIOD_API int
gpiod_line_settings_set_event_clock(struct gpiod_line_settings *settings,
				    enum gpiod_line_clock event_clock)
{
	assert(settings);

	switch (event_clock) {
	case GPIOD_LINE_CLOCK_MONOTONIC:
	case GPIOD_LINE_CLOCK_REALTIME:
	case GPIOD_LINE_CLOCK_HTE:
		settings->event_clock = event_clock;
		break;
	default:
		settings->event_clock = GPIOD_LINE_CLOCK_MONOTONIC;
		errno = EINVAL;
		return -1;
	}

	return 0;
}

GPIOD_API enum gpiod_line_clock
gpiod_line_settings_get_event_clock(struct gpiod_line_settings *settings)
{
	assert(settings);

	return settings->event_clock;
}

GPIOD_API int
gpiod_line_settings_set_output_value(struct gpiod_line_settings *settings,
				     enum gpiod_line_value value)
{
	assert(settings);

	return gpiod_set_output_value(value, &settings->output_value);
}

GPIOD_API enum gpiod_line_value
gpiod_line_settings_get_output_value(struct gpiod_line_settings *settings)
{
	assert(settings);

	return settings->output_value;
}
