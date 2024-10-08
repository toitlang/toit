// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2021 Bartosz Golaszewski <brgl@bgdev.pl>

#include <assert.h>
#include <errno.h>
#include <gpiod.h>
#include <stdlib.h>
#include <string.h>

#include "internal.h"

struct gpiod_request_config {
	char consumer[GPIO_MAX_NAME_SIZE];
	size_t event_buffer_size;
};

GPIOD_API struct gpiod_request_config *gpiod_request_config_new(void)
{
	struct gpiod_request_config *config;

	config = malloc(sizeof(*config));
	if (!config)
		return NULL;

	memset(config, 0, sizeof(*config));

	return config;
}

GPIOD_API void gpiod_request_config_free(struct gpiod_request_config *config)
{
	free(config);
}

GPIOD_API void
gpiod_request_config_set_consumer(struct gpiod_request_config *config,
				  const char *consumer)
{
	assert(config);

	if (!consumer) {
		config->consumer[0] = '\0';
	} else {
		strncpy(config->consumer, consumer, GPIO_MAX_NAME_SIZE - 1);
		config->consumer[GPIO_MAX_NAME_SIZE - 1] = '\0';
	}
}

GPIOD_API const char *
gpiod_request_config_get_consumer(struct gpiod_request_config *config)
{
	assert(config);

	return config->consumer[0] == '\0' ? NULL : config->consumer;
}

GPIOD_API void
gpiod_request_config_set_event_buffer_size(struct gpiod_request_config *config,
					   size_t event_buffer_size)
{
	assert(config);

	config->event_buffer_size = event_buffer_size;
}

GPIOD_API size_t
gpiod_request_config_get_event_buffer_size(struct gpiod_request_config *config)
{
	assert(config);

	return config->event_buffer_size;
}

void gpiod_request_config_to_uapi(struct gpiod_request_config *config,
				  struct gpio_v2_line_request *uapi_req)
{
	strcpy(uapi_req->consumer, config->consumer);
	uapi_req->event_buffer_size = config->event_buffer_size;
}
