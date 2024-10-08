// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2021 Bartosz Golaszewski <brgl@bgdev.pl>

#include <assert.h>
#include <errno.h>
#include <gpiod.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "internal.h"

/* As defined in the kernel. */
#define EVENT_BUFFER_MAX_CAPACITY (GPIO_V2_LINES_MAX * 16)

struct gpiod_edge_event {
	enum gpiod_edge_event_type event_type;
	uint64_t timestamp;
	unsigned int line_offset;
	unsigned long global_seqno;
	unsigned long line_seqno;
};

struct gpiod_edge_event_buffer {
	size_t capacity;
	size_t num_events;
	struct gpiod_edge_event *events;
	struct gpio_v2_line_event *event_data;
};

GPIOD_API void gpiod_edge_event_free(struct gpiod_edge_event *event)
{
	free(event);
}

GPIOD_API struct gpiod_edge_event *
gpiod_edge_event_copy(struct gpiod_edge_event *event)
{
	struct gpiod_edge_event *copy;

	assert(event);

	copy = malloc(sizeof(*event));
	if (!copy)
		return NULL;

	memcpy(copy, event, sizeof(*event));

	return copy;
}

GPIOD_API enum gpiod_edge_event_type
gpiod_edge_event_get_event_type(struct gpiod_edge_event *event)
{
	assert(event);

	return event->event_type;
}

GPIOD_API uint64_t
gpiod_edge_event_get_timestamp_ns(struct gpiod_edge_event *event)
{
	assert(event);

	return event->timestamp;
}

GPIOD_API unsigned int
gpiod_edge_event_get_line_offset(struct gpiod_edge_event *event)
{
	assert(event);

	return event->line_offset;
}

GPIOD_API unsigned long
gpiod_edge_event_get_global_seqno(struct gpiod_edge_event *event)
{
	assert(event);

	return event->global_seqno;
}

GPIOD_API unsigned long
gpiod_edge_event_get_line_seqno(struct gpiod_edge_event *event)
{
	assert(event);

	return event->line_seqno;
}

GPIOD_API struct gpiod_edge_event_buffer *
gpiod_edge_event_buffer_new(size_t capacity)
{
	struct gpiod_edge_event_buffer *buf;

	if (capacity == 0)
		capacity = 64;
	if (capacity > EVENT_BUFFER_MAX_CAPACITY)
		capacity = EVENT_BUFFER_MAX_CAPACITY;

	buf = malloc(sizeof(*buf));
	if (!buf)
		return NULL;

	memset(buf, 0, sizeof(*buf));
	buf->capacity = capacity;

	buf->events = calloc(capacity, sizeof(*buf->events));
	if (!buf->events) {
		free(buf);
		return NULL;
	}

	buf->event_data = calloc(capacity, sizeof(*buf->event_data));
	if (!buf->event_data) {
		free(buf->events);
		free(buf);
		return NULL;
	}

	return buf;
}

GPIOD_API size_t
gpiod_edge_event_buffer_get_capacity(struct gpiod_edge_event_buffer *buffer)
{
	assert(buffer);

	return buffer->capacity;
}

GPIOD_API void
gpiod_edge_event_buffer_free(struct gpiod_edge_event_buffer *buffer)
{
	if (!buffer)
		return;

	free(buffer->events);
	free(buffer->event_data);
	free(buffer);
}

GPIOD_API struct gpiod_edge_event *
gpiod_edge_event_buffer_get_event(struct gpiod_edge_event_buffer *buffer,
				  unsigned long index)
{
	assert(buffer);

	if (index >= buffer->num_events) {
		errno = EINVAL;
		return NULL;
	}

	return &buffer->events[index];
}

GPIOD_API size_t
gpiod_edge_event_buffer_get_num_events(struct gpiod_edge_event_buffer *buffer)
{
	assert(buffer);

	return buffer->num_events;
}

int gpiod_edge_event_buffer_read_fd(int fd,
				    struct gpiod_edge_event_buffer *buffer,
				    size_t max_events)
{
	struct gpio_v2_line_event *curr;
	struct gpiod_edge_event *event;
	size_t i;
	ssize_t rd;

	if (!buffer) {
		errno = EINVAL;
		return -1;
	}

	memset(buffer->event_data, 0,
	       sizeof(*buffer->event_data) * buffer->capacity);
	memset(buffer->events, 0, sizeof(*buffer->events) * buffer->capacity);

	if (max_events > buffer->capacity)
		max_events = buffer->capacity;

	rd = read(fd, buffer->event_data,
		  max_events * sizeof(*buffer->event_data));
	if (rd < 0) {
		return -1;
	} else if ((unsigned int)rd < sizeof(*buffer->event_data)) {
		errno = EIO;
		return -1;
	}

	buffer->num_events = rd / sizeof(*buffer->event_data);

	for (i = 0; i < buffer->num_events; i++) {
		curr = &buffer->event_data[i];
		event = &buffer->events[i];

		event->line_offset = curr->offset;
		event->event_type = curr->id == GPIO_V2_LINE_EVENT_RISING_EDGE ?
					    GPIOD_EDGE_EVENT_RISING_EDGE :
					    GPIOD_EDGE_EVENT_FALLING_EDGE;
		event->timestamp = curr->timestamp_ns;
		event->global_seqno = curr->seqno;
		event->line_seqno = curr->line_seqno;
	}

	return i;
}
