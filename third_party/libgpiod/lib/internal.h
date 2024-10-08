/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* SPDX-FileCopyrightText: 2021 Bartosz Golaszewski <bgolaszewski@baylibre.com> */

#ifndef __LIBGPIOD_GPIOD_INTERNAL_H__
#define __LIBGPIOD_GPIOD_INTERNAL_H__

#include <gpiod.h>
#include <stddef.h>
#include <stdint.h>

#include "uapi/gpio.h"

/* For internal library use only. */

#define GPIOD_API	__attribute__((visibility("default")))
#define GPIOD_BIT(nr)	(1UL << (nr))

bool gpiod_check_gpiochip_device(const char *path, bool set_errno);

struct gpiod_chip_info *
gpiod_chip_info_from_uapi(struct gpiochip_info *uapi_info);
struct gpiod_line_info *
gpiod_line_info_from_uapi(struct gpio_v2_line_info *uapi_info);
void gpiod_request_config_to_uapi(struct gpiod_request_config *config,
				  struct gpio_v2_line_request *uapi_req);
int gpiod_line_config_to_uapi(struct gpiod_line_config *config,
			      struct gpio_v2_line_request *uapi_cfg);
struct gpiod_line_request *
gpiod_line_request_from_uapi(struct gpio_v2_line_request *uapi_req,
			     const char *chip_name);
int gpiod_edge_event_buffer_read_fd(int fd,
				    struct gpiod_edge_event_buffer *buffer,
				    size_t max_events);
struct gpiod_info_event *
gpiod_info_event_from_uapi(struct gpio_v2_line_info_changed *uapi_evt);
struct gpiod_info_event *gpiod_info_event_read_fd(int fd);

int gpiod_poll_fd(int fd, int64_t timeout);
int gpiod_set_output_value(enum gpiod_line_value in,
			   enum gpiod_line_value *out);
int gpiod_ioctl(int fd, unsigned long request, void *arg);

void gpiod_line_mask_zero(uint64_t *mask);
bool gpiod_line_mask_test_bit(const uint64_t *mask, int nr);
void gpiod_line_mask_set_bit(uint64_t *mask, unsigned int nr);
void gpiod_line_mask_assign_bit(uint64_t *mask, unsigned int nr, bool value);

#endif /* __LIBGPIOD_GPIOD_INTERNAL_H__ */
