class_name GdLinkCore
extends RefCounted

## Channel used for GdLink communications
const CHANNEL_GDLINK := 3
## Channels reserved to be used by transports/users at their discretion
const RESERVED_CHANNEL_LIMIT := 3
## Max bytes per packet payload
const MAX_PAYLOAD_BYTES := 4096

## Time before dropping unauthenticated peer
const AUTHENTICATION_TIMEOUT_SECONDS := 10.0

## Rate-limit on failed authenication attempts per player identity
const AUTHENTICATION_ATTEMPTS_PER_MINUTE := 5

## Reason given to client for their disconnect
enum DisconnectReason {
	NONE = 0,
	VOLUNTARY,
	KICKED,
	TRANSPORT_FAILURE,
	POOR_CONNECTION,
	
	AUTH_REJECT_TIMEOUT,
	AUTH_REJECT_VERSION_MISMATCH,
	AUTH_REJECT_GAME_MISMATCH,
	AUTH_REJECT_FULL_SESSION,
	AUTH_REJECT_PRIVATE_SESSION,
	AUTH_REJECT_INCORRECT_PASSWORD,
	AUTH_REJECT_RATE_LIMITED,
	AUTH_REJECT_BANNED,
	}

# Logging
enum LogLevel { ERROR, WARN, INFO, DEBUG, TRACE }
const SETTING_LOG_LEVEL := "gdlink/logging/level"
const CLI_LOG_PREFIX := "--gdlink-log="

static var current_level: int = LogLevel.INFO

static func register_settings() -> void:
	if not ProjectSettings.has_setting(SETTING_LOG_LEVEL):
		ProjectSettings.set_setting(SETTING_LOG_LEVEL, LogLevel.INFO)
	ProjectSettings.set_initial_value(SETTING_LOG_LEVEL, LogLevel.INFO)
	ProjectSettings.add_property_info({
		"name": SETTING_LOG_LEVEL,
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Error,Warn,Info,Debug,Trace",
	})

static func configure_logging() -> void:
	current_level = int(ProjectSettings.get_setting(SETTING_LOG_LEVEL, LogLevel.INFO))
	# Check for cmdl override
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(CLI_LOG_PREFIX):
			var parsed_level := parse_level(argument.trim_prefix(CLI_LOG_PREFIX))
			if parsed_level >= 0: current_level = parsed_level

static func parse_level(level_name: String) -> int:
	var key := level_name.to_upper()
	if LogLevel.has(key):
		return LogLevel[key]
	return -1

static func is_level_enabled(level: int) -> bool:
	return level <= current_level

static func log_message(level: int, message: String) -> void:
	if !is_level_enabled(level): return
	var line := "[GdLink][%s] %s" % [LogLevel.keys()[level], message]
	if level <= LogLevel.WARN:
		printerr(line)
	else:
		print(line)
