// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2022 Bartosz Golaszewski <brgl@bgdev.pl>

#include <assert.h>
#include <gpiod.h>
#include <stdlib.h>
#include <string.h>

#include "internal.h"

struct gpiod_chip_info {
	size_t num_lines;
	char name[GPIO_MAX_NAME_SIZE + 1];
	char label[GPIO_MAX_NAME_SIZE + 1];
};

GPIOD_API void gpiod_chip_info_free(struct gpiod_chip_info *info)
{
	free(info);
}

GPIOD_API const char *gpiod_chip_info_get_name(struct gpiod_chip_info *info)
{
	assert(info);

	return info->name;
}

GPIOD_API const char *gpiod_chip_info_get_label(struct gpiod_chip_info *info)
{
	assert(info);

	return info->label;
}

GPIOD_API size_t gpiod_chip_info_get_num_lines(struct gpiod_chip_info *info)
{
	assert(info);

	return info->num_lines;
}

struct gpiod_chip_info *
gpiod_chip_info_from_uapi(struct gpiochip_info *uapi_info)
{
	struct gpiod_chip_info *info;

	info = malloc(sizeof(*info));
	if (!info)
		return NULL;

	memset(info, 0, sizeof(*info));

	info->num_lines = uapi_info->lines;

	/*
	 * GPIO device must have a name - don't bother checking this field. In
	 * the worst case (would have to be a weird kernel bug) it'll be empty.
	 */
	strncpy(info->name, uapi_info->name, sizeof(info->name));

	/*
	 * The kernel sets the label of a GPIO device to "unknown" if it
	 * hasn't been defined in DT, board file etc. On the off-chance that
	 * we got an empty string, do the same.
	 */
	if (uapi_info->label[0] == '\0')
		strncpy(info->label, "unknown", sizeof(info->label));
	else
		strncpy(info->label, uapi_info->label, sizeof(info->label));

	return info;
}
