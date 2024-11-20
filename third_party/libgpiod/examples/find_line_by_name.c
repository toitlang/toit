// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2023 Kent Gibson <warthog618@gmail.com>

/* Minimal example of finding a line with the given name. */

#include <dirent.h>
#include <errno.h>
#include <gpiod.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static int chip_dir_filter(const struct dirent *entry)
{
	struct stat sb;
	int ret = 0;
	char *path;

	if (asprintf(&path, "/dev/%s", entry->d_name) < 0)
		return 0;

	if ((lstat(path, &sb) == 0) && (!S_ISLNK(sb.st_mode)) &&
	    gpiod_is_gpiochip_device(path))
		ret = 1;

	free(path);

	return ret;
}

static int all_chip_paths(char ***paths_ptr)
{
	int i, j, num_chips, ret = 0;
	struct dirent **entries;
	char **paths;

	num_chips = scandir("/dev/", &entries, chip_dir_filter, versionsort);
	if (num_chips < 0)
		return 0;

	paths = calloc(num_chips, sizeof(*paths));
	if (!paths)
		return 0;

	for (i = 0; i < num_chips; i++) {
		if (asprintf(&paths[i], "/dev/%s", entries[i]->d_name) < 0) {
			for (j = 0; j < i; j++)
				free(paths[j]);

			free(paths);
			return 0;
		}
	}

	*paths_ptr = paths;
	ret = num_chips;

	for (i = 0; i < num_chips; i++)
		free(entries[i]);

	free(entries);
	return ret;
}

int main(void)
{
	/* Example configuration - customize to suit your situation. */
	static const char *const line_name = "GPIO19";

	struct gpiod_chip_info *cinfo;
	int i, num_chips, offset;
	struct gpiod_chip *chip;
	char **chip_paths;

	/*
	 * Names are not guaranteed unique, so this finds the first line with
	 * the given name.
	 */
	num_chips = all_chip_paths(&chip_paths);
	for (i = 0; i < num_chips; i++) {
		chip = gpiod_chip_open(chip_paths[i]);
		if (!chip)
			continue;

		offset = gpiod_chip_get_line_offset_from_name(chip, line_name);
		if (offset == -1)
			goto close_chip;

		cinfo = gpiod_chip_get_info(chip);
		if (!cinfo)
			goto close_chip;

		printf("%s: %s %d\n", line_name,
		       gpiod_chip_info_get_name(cinfo), offset);

		return EXIT_SUCCESS;

close_chip:
		gpiod_chip_close(chip);
	}

	printf("line '%s' not found\n", line_name);
	return EXIT_FAILURE;
}
