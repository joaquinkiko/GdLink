@tool
extends EditorPlugin

func _enter_tree() -> void:
	GdLinkCore.register_settings()
	add_autoload_singleton("GdLink", "./gdlink.gd")

func _exit_tree() -> void:
	remove_autoload_singleton("./gdlink.gd")
