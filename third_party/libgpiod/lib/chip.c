// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2021 Bartosz Golaszewski <brgl@bgdev.pl>

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <gpiod.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "internal.h"

struct gpiod_chip {
	int fd;
	char *path;
};

GPIOD_API struct gpiod_chip *gpiod_chip_open(const char *path)
{
	struct gpiod_chip *chip;
	int fd;

	if (!path) {
		errno = EINVAL;
		return NULL;
	}

	if (!gpiod_check_gpiochip_device(path, true))
		return NULL;

	fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return NULL;

	chip = malloc(sizeof(*chip));
	if (!chip)
		goto err_close_fd;

	memset(chip, 0, sizeof(*chip));

	chip->path = strdup(path);
	if (!chip->path)
		goto err_free_chip;

	chip->fd = fd;

	return chip;

err_free_chip:
	free(chip);
err_close_fd:
	close(fd);

	return NULL;
}

GPIOD_API void gpiod_chip_close(struct gpiod_chip *chip)
{
	if (!chip)
		return;

	close(chip->fd);
	free(chip->path);
	free(chip);
}

static int read_chip_info(int fd, struct gpiochip_info *info)
{
	int ret;

	memset(info, 0, sizeof(*info));

	ret = gpiod_ioctl(fd, GPIO_GET_CHIPINFO_IOCTL, info);
	if (ret)
		return -1;

	return 0;
}

GPIOD_API struct gpiod_chip_info *gpiod_chip_get_info(struct gpiod_chip *chip)
{
	struct gpiochip_info info;
	int ret;

	assert(chip);

	ret = read_chip_info(chip->fd, &info);
	if (ret)
		return NULL;

	return gpiod_chip_info_from_uapi(&info);
}

GPIOD_API const char *gpiod_chip_get_path(struct gpiod_chip *chip)
{
	assert(chip);

	return chip->path;
}

static int chip_read_line_info(int fd, unsigned int offset,
			       struct gpio_v2_line_info *info, bool watch)
{
	int ret, cmd;

	memset(info, 0, sizeof(*info));
	info->offset = offset;

	cmd = watch ? GPIO_V2_GET_LINEINFO_WATCH_IOCTL :
		      GPIO_V2_GET_LINEINFO_IOCTL;

	ret = gpiod_ioctl(fd, cmd, info);
	if (ret)
		return -1;

	return 0;
}

static struct gpiod_line_info *
chip_get_line_info(struct gpiod_chip *chip, unsigned int offset, bool watch)
{
	struct gpio_v2_line_info info;
	int ret;

	assert(chip);

	ret = chip_read_line_info(chip->fd, offset, &info, watch);
	if (ret)
		return NULL;

	return gpiod_line_info_from_uapi(&info);
}

GPIOD_API struct gpiod_line_info *
gpiod_chip_get_line_info(struct gpiod_chip *chip, unsigned int offset)
{
	return chip_get_line_info(chip, offset, false);
}

GPIOD_API struct gpiod_line_info *
gpiod_chip_watch_line_info(struct gpiod_chip *chip, unsigned int offset)
{
	return chip_get_line_info(chip, offset, true);
}

GPIOD_API int gpiod_chip_unwatch_line_info(struct gpiod_chip *chip,
					   unsigned int offset)
{
	assert(chip);

	return gpiod_ioctl(chip->fd, GPIO_GET_LINEINFO_UNWATCH_IOCTL, &offset);
}

GPIOD_API int gpiod_chip_get_fd(struct gpiod_chip *chip)
{
	assert(chip);

	return chip->fd;
}

GPIOD_API int gpiod_chip_wait_info_event(struct gpiod_chip *chip,
					 int64_t timeout_ns)
{
	assert(chip);

	return gpiod_poll_fd(chip->fd, timeout_ns);
}

GPIOD_API struct gpiod_info_event *
gpiod_chip_read_info_event(struct gpiod_chip *chip)
{
	assert(chip);

	return gpiod_info_event_read_fd(chip->fd);
}

GPIOD_API int gpiod_chip_get_line_offset_from_name(struct gpiod_chip *chip,
						   const char *name)
{
	struct gpio_v2_line_info linfo;
	struct gpiochip_info chinfo;
	unsigned int offset;
	int ret;

	assert(chip);

	if (!name) {
		errno = EINVAL;
		return -1;
	}

	ret = read_chip_info(chip->fd, &chinfo);
	if (ret)
		return -1;

	for (offset = 0; offset < chinfo.lines; offset++) {
		ret = chip_read_line_info(chip->fd, offset, &linfo, false);
		if (ret)
			return -1;

		if (strcmp(name, linfo.name) == 0)
			return offset;
	}

	errno = ENOENT;
	return -1;
}

GPIOD_API struct gpiod_line_request *
gpiod_chip_request_lines(struct gpiod_chip *chip,
			 struct gpiod_request_config *req_cfg,
			 struct gpiod_line_config *line_cfg)
{
	struct gpio_v2_line_request uapi_req;
	struct gpiod_line_request *request;
	struct gpiochip_info info;
	int ret;

	assert(chip);

	if (!line_cfg) {
		errno = EINVAL;
		return NULL;
	}

	memset(&uapi_req, 0, sizeof(uapi_req));

	if (req_cfg)
		gpiod_request_config_to_uapi(req_cfg, &uapi_req);

	ret = gpiod_line_config_to_uapi(line_cfg, &uapi_req);
	if (ret)
		return NULL;

	ret = read_chip_info(chip->fd, &info);
	if (ret)
		return NULL;

	ret = gpiod_ioctl(chip->fd, GPIO_V2_GET_LINE_IOCTL, &uapi_req);
	if (ret)
		return NULL;

	request = gpiod_line_request_from_uapi(&uapi_req, info.name);
	if (!request) {
		close(uapi_req.fd);
		return NULL;
	}

	return request;
}
