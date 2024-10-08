// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2017-2022 Bartosz Golaszewski <bartekgola@gmail.com>

#include <gpiod.h>

#include "internal.h"

GPIOD_API bool gpiod_is_gpiochip_device(const char *path)
{
	return gpiod_check_gpiochip_device(path, false);
}

GPIOD_API const char *gpiod_api_version(void)
{
	return GPIOD_VERSION_STR;
}
