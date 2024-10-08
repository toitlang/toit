// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2021 Bartosz Golaszewski <brgl@bgdev.pl>

#include <assert.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "internal.h"

struct gpiod_info_event {
	enum gpiod_info_event_type event_type;
	uint64_t timestamp;
	struct gpiod_line_info *info;
};

struct gpiod_info_event *
gpiod_info_event_from_uapi(struct gpio_v2_line_info_changed *uapi_evt)
{
	struct gpiod_info_event *event;

	event = malloc(sizeof(*event));
	if (!event)
		return NULL;

	memset(event, 0, sizeof(*event));
	event->timestamp = uapi_evt->timestamp_ns;

	switch (uapi_evt->event_type) {
	case GPIOLINE_CHANGED_REQUESTED:
		event->event_type = GPIOD_INFO_EVENT_LINE_REQUESTED;
		break;
	case GPIOLINE_CHANGED_RELEASED:
		event->event_type = GPIOD_INFO_EVENT_LINE_RELEASED;
		break;
	case GPIOLINE_CHANGED_CONFIG:
		event->event_type = GPIOD_INFO_EVENT_LINE_CONFIG_CHANGED;
		break;
	default:
		/* Can't happen unless there's a bug in the kernel. */
		errno = ENOMSG;
		free(event);
		return NULL;
	}

	event->info = gpiod_line_info_from_uapi(&uapi_evt->info);
	if (!event->info) {
		free(event);
		return NULL;
	}

	return event;
}

GPIOD_API void gpiod_info_event_free(struct gpiod_info_event *event)
{
	if (!event)
		return;

	gpiod_line_info_free(event->info);
	free(event);
}

GPIOD_API enum gpiod_info_event_type
gpiod_info_event_get_event_type(struct gpiod_info_event *event)
{
	assert(event);

	return event->event_type;
}

GPIOD_API uint64_t
gpiod_info_event_get_timestamp_ns(struct gpiod_info_event *event)
{
	assert(event);

	return event->timestamp;
}

GPIOD_API struct gpiod_line_info *
gpiod_info_event_get_line_info(struct gpiod_info_event *event)
{
	assert(event);

	return event->info;
}

struct gpiod_info_event *gpiod_info_event_read_fd(int fd)
{
	struct gpio_v2_line_info_changed uapi_evt;
	ssize_t rd;

	memset(&uapi_evt, 0, sizeof(uapi_evt));

	rd = read(fd, &uapi_evt, sizeof(uapi_evt));
	if (rd < 0) {
		return NULL;
	} else if ((unsigned int)rd < sizeof(uapi_evt)) {
		errno = EIO;
		return NULL;
	}

	return gpiod_info_event_from_uapi(&uapi_evt);
}
