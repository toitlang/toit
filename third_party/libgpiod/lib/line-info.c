// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2021 Bartosz Golaszewski <brgl@bgdev.pl>

#include <assert.h>
#include <gpiod.h>
#include <stdlib.h>
#include <string.h>

#include "internal.h"

struct gpiod_line_info {
	unsigned int offset;
	char name[GPIO_MAX_NAME_SIZE + 1];
	bool used;
	char consumer[GPIO_MAX_NAME_SIZE + 1];
	enum gpiod_line_direction direction;
	bool active_low;
	enum gpiod_line_bias bias;
	enum gpiod_line_drive drive;
	enum gpiod_line_edge edge;
	enum gpiod_line_clock event_clock;
	bool debounced;
	unsigned long debounce_period_us;
};

GPIOD_API void gpiod_line_info_free(struct gpiod_line_info *info)
{
	free(info);
}

GPIOD_API struct gpiod_line_info *
gpiod_line_info_copy(struct gpiod_line_info *info)
{
	struct gpiod_line_info *copy;

	assert(info);

	copy = malloc(sizeof(*info));
	if (!copy)
		return NULL;

	memcpy(copy, info, sizeof(*info));

	return copy;
}

GPIOD_API unsigned int gpiod_line_info_get_offset(struct gpiod_line_info *info)
{
	assert(info);

	return info->offset;
}

GPIOD_API const char *gpiod_line_info_get_name(struct gpiod_line_info *info)
{
	assert(info);

	return info->name[0] == '\0' ? NULL : info->name;
}

GPIOD_API bool gpiod_line_info_is_used(struct gpiod_line_info *info)
{
	assert(info);

	return info->used;
}

GPIOD_API const char *gpiod_line_info_get_consumer(struct gpiod_line_info *info)
{
	assert(info);

	return info->consumer[0] == '\0' ? NULL : info->consumer;
}

GPIOD_API enum gpiod_line_direction
gpiod_line_info_get_direction(struct gpiod_line_info *info)
{
	assert(info);

	return info->direction;
}

GPIOD_API bool gpiod_line_info_is_active_low(struct gpiod_line_info *info)
{
	assert(info);

	return info->active_low;
}

GPIOD_API enum gpiod_line_bias
gpiod_line_info_get_bias(struct gpiod_line_info *info)
{
	assert(info);

	return info->bias;
}

GPIOD_API enum gpiod_line_drive
gpiod_line_info_get_drive(struct gpiod_line_info *info)
{
	assert(info);

	return info->drive;
}

GPIOD_API enum gpiod_line_edge
gpiod_line_info_get_edge_detection(struct gpiod_line_info *info)
{
	assert(info);

	return info->edge;
}

GPIOD_API enum gpiod_line_clock
gpiod_line_info_get_event_clock(struct gpiod_line_info *info)
{
	assert(info);

	return info->event_clock;
}

GPIOD_API bool gpiod_line_info_is_debounced(struct gpiod_line_info *info)
{
	assert(info);

	return info->debounced;
}

GPIOD_API unsigned long
gpiod_line_info_get_debounce_period_us(struct gpiod_line_info *info)
{
	assert(info);

	return info->debounce_period_us;
}

struct gpiod_line_info *
gpiod_line_info_from_uapi(struct gpio_v2_line_info *uapi_info)
{
	struct gpio_v2_line_attribute *attr;
	struct gpiod_line_info *info;
	size_t i;

	info = malloc(sizeof(*info));
	if (!info)
		return NULL;

	memset(info, 0, sizeof(*info));

	info->offset = uapi_info->offset;
	strncpy(info->name, uapi_info->name, GPIO_MAX_NAME_SIZE);

	info->used = !!(uapi_info->flags & GPIO_V2_LINE_FLAG_USED);
	strncpy(info->consumer, uapi_info->consumer, GPIO_MAX_NAME_SIZE);

	if (uapi_info->flags & GPIO_V2_LINE_FLAG_OUTPUT)
		info->direction = GPIOD_LINE_DIRECTION_OUTPUT;
	else
		info->direction = GPIOD_LINE_DIRECTION_INPUT;

	if (uapi_info->flags & GPIO_V2_LINE_FLAG_ACTIVE_LOW)
		info->active_low = true;

	if (uapi_info->flags & GPIO_V2_LINE_FLAG_BIAS_PULL_UP)
		info->bias = GPIOD_LINE_BIAS_PULL_UP;
	else if (uapi_info->flags & GPIO_V2_LINE_FLAG_BIAS_PULL_DOWN)
		info->bias = GPIOD_LINE_BIAS_PULL_DOWN;
	else if (uapi_info->flags & GPIO_V2_LINE_FLAG_BIAS_DISABLED)
		info->bias = GPIOD_LINE_BIAS_DISABLED;
	else
		info->bias = GPIOD_LINE_BIAS_UNKNOWN;

	if (uapi_info->flags & GPIO_V2_LINE_FLAG_OPEN_DRAIN)
		info->drive = GPIOD_LINE_DRIVE_OPEN_DRAIN;
	else if (uapi_info->flags & GPIO_V2_LINE_FLAG_OPEN_SOURCE)
		info->drive = GPIOD_LINE_DRIVE_OPEN_SOURCE;
	else
		info->drive = GPIOD_LINE_DRIVE_PUSH_PULL;

	if ((uapi_info->flags & GPIO_V2_LINE_FLAG_EDGE_RISING) &&
	    (uapi_info->flags & GPIO_V2_LINE_FLAG_EDGE_FALLING))
		info->edge = GPIOD_LINE_EDGE_BOTH;
	else if (uapi_info->flags & GPIO_V2_LINE_FLAG_EDGE_RISING)
		info->edge = GPIOD_LINE_EDGE_RISING;
	else if (uapi_info->flags & GPIO_V2_LINE_FLAG_EDGE_FALLING)
		info->edge = GPIOD_LINE_EDGE_FALLING;
	else
		info->edge = GPIOD_LINE_EDGE_NONE;

	if (uapi_info->flags & GPIO_V2_LINE_FLAG_EVENT_CLOCK_REALTIME)
		info->event_clock = GPIOD_LINE_CLOCK_REALTIME;
	else if (uapi_info->flags & GPIO_V2_LINE_FLAG_EVENT_CLOCK_HTE)
		info->event_clock = GPIOD_LINE_CLOCK_HTE;
	else
		info->event_clock = GPIOD_LINE_CLOCK_MONOTONIC;

	/*
	 * We assume that the kernel returns correct configuration and that no
	 * attributes repeat.
	 */
	for (i = 0; i < uapi_info->num_attrs; i++) {
		attr = &uapi_info->attrs[i];

		if (attr->id == GPIO_V2_LINE_ATTR_ID_DEBOUNCE) {
			info->debounced = true;
			info->debounce_period_us = attr->debounce_period_us;
		}
	}

	return info;
}
