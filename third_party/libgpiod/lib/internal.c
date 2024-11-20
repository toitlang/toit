// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2021-2022 Bartosz Golaszewski <brgl@bgdev.pl>

#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <unistd.h>

#include "internal.h"

bool gpiod_check_gpiochip_device(const char *path, bool set_errno)
{
	char *realname, *sysfsp, devpath[64];
	struct stat statbuf;
	bool ret = false;
	int rv;

	if (!path) {
		errno = EINVAL;
		goto out;
	}

	rv = lstat(path, &statbuf);
	if (rv)
		goto out;

	/*
	 * Is it a symbolic link? We have to resolve it before checking
	 * the rest.
	 */
	realname = S_ISLNK(statbuf.st_mode) ? realpath(path, NULL) :
					      strdup(path);
	if (realname == NULL)
		goto out;

	rv = stat(realname, &statbuf);
	if (rv)
		goto out_free_realname;

	/* Is it a character device? */
	if (!S_ISCHR(statbuf.st_mode)) {
		errno = ENOTTY;
		goto out_free_realname;
	}

	/* Is the device associated with the GPIO subsystem? */
	snprintf(devpath, sizeof(devpath), "/sys/dev/char/%u:%u/subsystem",
		 major(statbuf.st_rdev), minor(statbuf.st_rdev));

	sysfsp = realpath(devpath, NULL);
	if (!sysfsp)
		goto out_free_realname;

	/*
	 * In glibc, if any of the underlying readlink() calls fail (which is
	 * perfectly normal when resolving paths), errno is not cleared.
	 */
	errno = 0;

	if (strcmp(sysfsp, "/sys/bus/gpio") != 0) {
		/* This is a character device but not the one we're after. */
		errno = ENODEV;
		goto out_free_sysfsp;
	}

	ret = true;

out_free_sysfsp:
	free(sysfsp);
out_free_realname:
	free(realname);
out:
	if (!set_errno)
		errno = 0;
	return ret;
}

int gpiod_poll_fd(int fd, int64_t timeout_ns)
{
	struct timespec ts;
	struct pollfd pfd;
	int ret;

	memset(&pfd, 0, sizeof(pfd));
	pfd.fd = fd;
	pfd.events = POLLIN | POLLPRI;

	if (timeout_ns >= 0) {
		ts.tv_sec = timeout_ns / 1000000000ULL;
		ts.tv_nsec = timeout_ns % 1000000000ULL;
	}

	ret = ppoll(&pfd, 1, timeout_ns < 0 ? NULL : &ts, NULL);
	if (ret < 0)
		return -1;
	else if (ret == 0)
		return 0;

	return 1;
}

int gpiod_set_output_value(enum gpiod_line_value in, enum gpiod_line_value *out)
{
	switch (in) {
	case GPIOD_LINE_VALUE_INACTIVE:
	case GPIOD_LINE_VALUE_ACTIVE:
		*out = in;
		break;
	default:
		*out = GPIOD_LINE_VALUE_INACTIVE;
		errno = EINVAL;
		return -1;
	}

	return 0;
}

int gpiod_ioctl(int fd, unsigned long request, void *arg)
{
	int ret;

	ret = ioctl(fd, request, arg);
	if (ret <= 0)
		return ret;

	errno = EBADE;
	return -1;
}

void gpiod_line_mask_zero(uint64_t *mask)
{
	*mask = 0ULL;
}

bool gpiod_line_mask_test_bit(const uint64_t *mask, int nr)
{
	return *mask & (1ULL << nr);
}

void gpiod_line_mask_set_bit(uint64_t *mask, unsigned int nr)
{
	*mask |= (1ULL << nr);
}

void gpiod_line_mask_assign_bit(uint64_t *mask, unsigned int nr, bool value)
{
	if (value)
		gpiod_line_mask_set_bit(mask, nr);
	else
		*mask &= ~(1ULL << nr);
}
