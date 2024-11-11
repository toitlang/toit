// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2022 Bartosz Golaszewski <brgl@bgdev.pl>

#include <assert.h>
#include <errno.h>
#include <gpiod.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>

#include "internal.h"

#define LINES_MAX (GPIO_V2_LINES_MAX)

struct settings_node {
	struct settings_node *next;
	struct gpiod_line_settings *settings;
};

struct per_line_config {
	unsigned int offset;
	struct settings_node *node;
};

struct gpiod_line_config {
	struct per_line_config line_configs[LINES_MAX];
	size_t num_configs;
	enum gpiod_line_value output_values[LINES_MAX];
	size_t num_output_values;
	struct settings_node *sref_list;
};

GPIOD_API struct gpiod_line_config *gpiod_line_config_new(void)
{
	struct gpiod_line_config *config;

	config = malloc(sizeof(*config));
	if (!config)
		return NULL;

	memset(config, 0, sizeof(*config));

	return config;
}

static void free_refs(struct gpiod_line_config *config)
{
	struct settings_node *node, *tmp;

	for (node = config->sref_list; node;) {
		tmp = node->next;
		gpiod_line_settings_free(node->settings);
		free(node);
		node = tmp;
	}
}

GPIOD_API void gpiod_line_config_free(struct gpiod_line_config *config)
{
	if (!config)
		return;

	free_refs(config);
	free(config);
}

GPIOD_API void gpiod_line_config_reset(struct gpiod_line_config *config)
{
	assert(config);

	free_refs(config);
	memset(config, 0, sizeof(*config));
}

static struct per_line_config *find_config(struct gpiod_line_config *config,
					   unsigned int offset)
{
	struct per_line_config *per_line;
	size_t i;

	for (i = 0; i < config->num_configs; i++) {
		per_line = &config->line_configs[i];

		if (offset == per_line->offset)
			return per_line;
	}

	return &config->line_configs[config->num_configs++];
}

GPIOD_API int gpiod_line_config_add_line_settings(
	struct gpiod_line_config *config, const unsigned int *offsets,
	size_t num_offsets, struct gpiod_line_settings *settings)
{
	struct per_line_config *per_line;
	struct settings_node *node;
	size_t i;

	assert(config);

	if (!offsets || num_offsets == 0) {
		errno = EINVAL;
		return -1;
	}

	if ((config->num_configs + num_offsets) > LINES_MAX) {
		errno = E2BIG;
		return -1;
	}

	node = malloc(sizeof(*node));
	if (!node)
		return -1;

	if (!settings)
		node->settings = gpiod_line_settings_new();
	else
		node->settings = gpiod_line_settings_copy(settings);
	if (!node->settings) {
		free(node);
		return -1;
	}

	node->next = config->sref_list;
	config->sref_list = node;

	for (i = 0; i < num_offsets; i++) {
		per_line = find_config(config, offsets[i]);

		per_line->offset = offsets[i];
		per_line->node = node;
	}

	return 0;
}

GPIOD_API struct gpiod_line_settings *
gpiod_line_config_get_line_settings(struct gpiod_line_config *config,
				    unsigned int offset)
{
	struct gpiod_line_settings *settings;
	struct per_line_config *per_line;
	size_t i;
	int ret;

	assert(config);

	for (i = 0; i < config->num_configs; i++) {
		per_line = &config->line_configs[i];

		if (per_line->offset == offset) {
			settings = gpiod_line_settings_copy(
					per_line->node->settings);
			if (!settings)
				return NULL;

			/*
			 * If a global output value was set for this line - use
			 * it and override the one stored in settings.
			 */
			if (config->num_output_values > i) {
				ret = gpiod_line_settings_set_output_value(
						settings,
						config->output_values[i]);
				if (ret) {
					gpiod_line_settings_free(settings);
					return NULL;
				}
			}

			return settings;
		}
	}

	errno = ENOENT;
	return NULL;
}

GPIOD_API int
gpiod_line_config_set_output_values(struct gpiod_line_config *config,
				    const enum gpiod_line_value *values,
				    size_t num_values)
{
	size_t i;
	int ret;

	assert(config);

	if (!num_values || num_values > LINES_MAX || !values) {
		errno = EINVAL;
		return -1;
	}

	for (i = 0; i < num_values; i++) {
		ret = gpiod_set_output_value(values[i],
					     &config->output_values[i]);
		if (ret) {
			config->num_output_values = 0;
			return ret;
		}
	}

	config->num_output_values = num_values;

	return 0;
}

GPIOD_API size_t
gpiod_line_config_get_num_configured_offsets(struct gpiod_line_config *config)
{
	assert(config);

	return config->num_configs;
}

GPIOD_API size_t
gpiod_line_config_get_configured_offsets(struct gpiod_line_config *config,
					 unsigned int *offsets,
					 size_t max_offsets)
{
	size_t num_offsets, i;

	assert(config);

	if (!offsets || !max_offsets || !config->num_configs)
		return 0;

	num_offsets = MIN(config->num_configs, max_offsets);

	for (i = 0; i < num_offsets; i++)
		offsets[i] = config->line_configs[i].offset;

	return num_offsets;
}

static void set_offsets(struct gpiod_line_config *config,
			struct gpio_v2_line_request *uapi_cfg)
{
	size_t i;

	uapi_cfg->num_lines = config->num_configs;

	for (i = 0; i < config->num_configs; i++)
		uapi_cfg->offsets[i] = config->line_configs[i].offset;
}

static bool has_at_least_one_output_direction(struct gpiod_line_config *config)
{
	size_t i;

	for (i = 0; i < config->num_configs; i++) {
		if (gpiod_line_settings_get_direction(
			    config->line_configs[i].node->settings) ==
		    GPIOD_LINE_DIRECTION_OUTPUT)
			return true;
	}

	return false;
}

static void set_output_value(uint64_t *vals, size_t bit,
			     enum gpiod_line_value value)
{
	gpiod_line_mask_assign_bit(vals, bit,
				   value == GPIOD_LINE_VALUE_ACTIVE ? 1 : 0);
}

static void set_kernel_output_values(uint64_t *mask, uint64_t *vals,
				     struct gpiod_line_config *config)
{
	struct per_line_config *per_line;
	enum gpiod_line_value value;
	size_t i;

	gpiod_line_mask_zero(mask);
	gpiod_line_mask_zero(vals);

	for (i = 0; i < config->num_configs; i++) {
		per_line = &config->line_configs[i];

		if (gpiod_line_settings_get_direction(
			    per_line->node->settings) !=
		    GPIOD_LINE_DIRECTION_OUTPUT)
			continue;

		gpiod_line_mask_set_bit(mask, i);
		value = gpiod_line_settings_get_output_value(
			per_line->node->settings);
		set_output_value(vals, i, value);
	}

	/* "Global" output values override the ones from per-line settings. */
	for (i = 0; i < config->num_output_values; i++) {
		gpiod_line_mask_set_bit(mask, i);
		value = config->output_values[i];
		set_output_value(vals, i, value);
	}
}

static void set_output_values(struct gpiod_line_config *config,
			      struct gpio_v2_line_request *uapi_cfg,
			      unsigned int *attr_idx)
{
	struct gpio_v2_line_config_attribute *attr;
	uint64_t mask, values;

	if (!has_at_least_one_output_direction(config))
		return;

	attr = &uapi_cfg->config.attrs[(*attr_idx)++];
	attr->attr.id = GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES;
	set_kernel_output_values(&mask, &values, config);
	attr->attr.values = values;
	attr->mask = mask;
}

static int set_debounce_periods(struct gpiod_line_config *config,
				struct gpio_v2_line_config *uapi_cfg,
				unsigned int *attr_idx)
{
	struct gpio_v2_line_config_attribute *attr;
	unsigned long period_i, period_j;
	uint64_t done, mask;
	size_t i, j;

	gpiod_line_mask_zero(&done);

	for (i = 0; i < config->num_configs; i++) {
		if (gpiod_line_mask_test_bit(&done, i))
			continue;

		gpiod_line_mask_set_bit(&done, i);
		gpiod_line_mask_zero(&mask);

		period_i = gpiod_line_settings_get_debounce_period_us(
				config->line_configs[i].node->settings);
		if (!period_i)
			continue;

		if (*attr_idx == GPIO_V2_LINE_NUM_ATTRS_MAX) {
			errno = E2BIG;
			return -1;
		}

		attr = &uapi_cfg->attrs[(*attr_idx)++];
		attr->attr.id = GPIO_V2_LINE_ATTR_ID_DEBOUNCE;
		attr->attr.debounce_period_us = period_i;
		gpiod_line_mask_set_bit(&mask, i);

		for (j = i; j < config->num_configs; j++) {
			period_j = gpiod_line_settings_get_debounce_period_us(
					config->line_configs[j].node->settings);
			if (period_i == period_j) {
				gpiod_line_mask_set_bit(&mask, j);
				gpiod_line_mask_set_bit(&done, j);
			}
		}

		attr->mask = mask;
	}

	return 0;
}

static uint64_t make_kernel_flags(struct gpiod_line_settings *settings)
{
	uint64_t flags = 0;

	switch (gpiod_line_settings_get_direction(settings)) {
	case GPIOD_LINE_DIRECTION_INPUT:
		flags |= GPIO_V2_LINE_FLAG_INPUT;
		break;
	case GPIOD_LINE_DIRECTION_OUTPUT:
		flags |= GPIO_V2_LINE_FLAG_OUTPUT;
		break;
	default:
		break;
	}

	switch (gpiod_line_settings_get_edge_detection(settings)) {
	case GPIOD_LINE_EDGE_FALLING:
		flags |= (GPIO_V2_LINE_FLAG_EDGE_FALLING |
			  GPIO_V2_LINE_FLAG_INPUT);
		break;
	case GPIOD_LINE_EDGE_RISING:
		flags |= (GPIO_V2_LINE_FLAG_EDGE_RISING |
			  GPIO_V2_LINE_FLAG_INPUT);
		break;
	case GPIOD_LINE_EDGE_BOTH:
		flags |= (GPIO_V2_LINE_FLAG_EDGE_FALLING |
			  GPIO_V2_LINE_FLAG_EDGE_RISING |
			  GPIO_V2_LINE_FLAG_INPUT);
		break;
	default:
		break;
	}

	switch (gpiod_line_settings_get_drive(settings)) {
	case GPIOD_LINE_DRIVE_OPEN_DRAIN:
		flags |= GPIO_V2_LINE_FLAG_OPEN_DRAIN;
		break;
	case GPIOD_LINE_DRIVE_OPEN_SOURCE:
		flags |= GPIO_V2_LINE_FLAG_OPEN_SOURCE;
		break;
	default:
		break;
	}

	switch (gpiod_line_settings_get_bias(settings)) {
	case GPIOD_LINE_BIAS_DISABLED:
		flags |= GPIO_V2_LINE_FLAG_BIAS_DISABLED;
		break;
	case GPIOD_LINE_BIAS_PULL_UP:
		flags |= GPIO_V2_LINE_FLAG_BIAS_PULL_UP;
		break;
	case GPIOD_LINE_BIAS_PULL_DOWN:
		flags |= GPIO_V2_LINE_FLAG_BIAS_PULL_DOWN;
		break;
	default:
		break;
	}

	if (gpiod_line_settings_get_active_low(settings))
		flags |= GPIO_V2_LINE_FLAG_ACTIVE_LOW;

	switch (gpiod_line_settings_get_event_clock(settings)) {
	case GPIOD_LINE_CLOCK_REALTIME:
		flags |= GPIO_V2_LINE_FLAG_EVENT_CLOCK_REALTIME;
		break;
	case GPIOD_LINE_CLOCK_HTE:
		flags |= GPIO_V2_LINE_FLAG_EVENT_CLOCK_HTE;
		break;
	default:
		break;
	}

	return flags;
}

static bool settings_equal(struct gpiod_line_settings *left,
			   struct gpiod_line_settings *right)
{
	if (gpiod_line_settings_get_direction(left) !=
	    gpiod_line_settings_get_direction(right))
		return false;

	if (gpiod_line_settings_get_edge_detection(left) !=
	    gpiod_line_settings_get_edge_detection(right))
		return false;

	if (gpiod_line_settings_get_bias(left) !=
	    gpiod_line_settings_get_bias(right))
		return false;

	if (gpiod_line_settings_get_drive(left) !=
	    gpiod_line_settings_get_drive(right))
		return false;

	if (gpiod_line_settings_get_active_low(left) !=
	    gpiod_line_settings_get_active_low(right))
		return false;

	if (gpiod_line_settings_get_event_clock(left) !=
	    gpiod_line_settings_get_event_clock(right))
		return false;

	return true;
}

static int set_flags(struct gpiod_line_config *config,
		     struct gpio_v2_line_config *uapi_cfg,
		     unsigned int *attr_idx)
{
	struct gpiod_line_settings *settings_i, *settings_j;
	struct gpio_v2_line_config_attribute *attr;
	bool globals_taken = false;
	uint64_t done, mask;
	size_t i, j;

	gpiod_line_mask_zero(&done);

	for (i = 0; i < config->num_configs; i++) {
		if (gpiod_line_mask_test_bit(&done, i))
			continue;

		gpiod_line_mask_set_bit(&done, i);

		settings_i = config->line_configs[i].node->settings;

		if (!globals_taken) {
			globals_taken = true;
			uapi_cfg->flags = make_kernel_flags(settings_i);

			for (j = i; j < config->num_configs; j++) {
				settings_j =
					config->line_configs[j].node->settings;
				if (settings_equal(settings_i, settings_j))
					gpiod_line_mask_set_bit(&done, j);
			}
		} else {
			gpiod_line_mask_zero(&mask);
			gpiod_line_mask_set_bit(&mask, i);

			if (*attr_idx == GPIO_V2_LINE_NUM_ATTRS_MAX) {
				errno = E2BIG;
				return -1;
			}

			attr = &uapi_cfg->attrs[(*attr_idx)++];
			attr->attr.id = GPIO_V2_LINE_ATTR_ID_FLAGS;
			attr->attr.flags = make_kernel_flags(settings_i);

			for (j = i; j < config->num_configs; j++) {
				settings_j =
					config->line_configs[j].node->settings;
				if (settings_equal(settings_i, settings_j)) {
					gpiod_line_mask_set_bit(&done, j);
					gpiod_line_mask_set_bit(&mask, j);
				}
			}

			attr->mask = mask;
		}
	}

	return 0;
}

int gpiod_line_config_to_uapi(struct gpiod_line_config *config,
			      struct gpio_v2_line_request *uapi_cfg)
{
	unsigned int attr_idx = 0;
	int ret;

	set_offsets(config, uapi_cfg);
	set_output_values(config, uapi_cfg, &attr_idx);

	ret = set_debounce_periods(config, &uapi_cfg->config, &attr_idx);
	if (ret)
		return -1;

	ret = set_flags(config, &uapi_cfg->config, &attr_idx);
	if (ret)
		return -1;

	uapi_cfg->config.num_attrs = attr_idx;

	return 0;
}
