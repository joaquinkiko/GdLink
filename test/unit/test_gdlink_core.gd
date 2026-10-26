extends GutTest

func before_each() -> void:
	GdLinkCore.current_level = GdLinkCore.LogLevel.INFO

func test_control_channel_is_outside_reserved_range() -> void:
	assert_gte(GdLinkCore.CHANNEL_GDLINK, GdLinkCore.RESERVED_CHANNEL_LIMIT)

func test_parse_level_is_case_insensitive() -> void:
	assert_eq(GdLinkCore.parse_level("debug"), GdLinkCore.LogLevel.DEBUG)

func test_parse_level_rejects_unknown_name() -> void:
	assert_eq(GdLinkCore.parse_level("loud"), -1)

func test_level_filter_drops_more_verbose_levels() -> void:
	GdLinkCore.current_level = GdLinkCore.LogLevel.WARN
	assert_true(GdLinkCore.is_level_enabled(GdLinkCore.LogLevel.ERROR))
	assert_false(GdLinkCore.is_level_enabled(GdLinkCore.LogLevel.DEBUG))
