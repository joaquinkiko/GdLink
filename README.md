# GdLink

**Transport agnostic multiplayer connection, authentication, and session management for [Godot 4.7+](https://godotengine.org/)**

[![Godot](https://img.shields.io/badge/Godot-4.7%2B-478cbf?logo=godot-engine&logoColor=white)](https://godotengine.org/download)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-WIP-orange)](#install)

## Features

- **Transport Agnostic**: Switch betwen ENet, SteamRelay, or Offline modes without altering game logic
- **Authenticated Joins**: Version validation and optional server passwords
- **Scene Flow**: Server-driven loading gates to ensure everyone is on the same scene at the same time
- **Server Managed Kick/Ban**: Control who has access to server
- **Server-Authoritative Meta**: Replicate data like player nicknames and server info automatically
- **RPC Routing**: Use Godot's built-in RPC logic regardless of transport method
- **Network Stats**: Toggle runtime available stats for easy debugging
- **Host Migration**: (planned/optional)

## Install

After adding the latest [Release](../../releases/latest) to your project, enable the addon in your project settings.
 
> **Note:** GdLink is still in early development (WIP). APIs and features may change before a stable release.

## Quickstart

### 1. Wire the transport and authenticator

Call `setup()` once, before any `host()` or `join()`.

```gdscript
# Tell session to use ENet as transport method, and simple version based authentication
var transport := ENetTransport.new()
var authenticator := VersionAuthenticator.new()
GdLink.session.setup(transport, authenticator)
```

### 2. Host

ENet's bind address is the port only. Assign the RPC peer before hosting so no signals are missed.

```gdscript
func start_host(port: int) -> Error:
	var error := GdLink.session.host(str(port))
	if error != OK:
		push_error("Host failed: %s" % error_string(error))
	return error
```

To stop hosting:

```gdscript
GdLink.session.stop_hosting()
```

### 3. Join

ENet's join address is `ip:port`.

```gdscript
func join(address: String, port: int) -> Error:
	var error := GdLink.session.join("%s:%d" % [address, port])
	if error != OK:
		push_error("Join failed: %s" % error_string(error))
	return error

func _ready() -> void:
	GdLink.session.join_succeeded.connect(func(_assigned_identifier: int) -> void:
		print("Joined")
		)
	GdLink.session.join_failed.connect(func(reason: GdLinkCore.DisconnectReason) -> void:
		print("Join failed: %s" % reason)
		)
	GdLink.session.session_closed.connect(func(reason: GdLinkCore.DisconnectReason) -> void:
		print("Session closed: %s" % reason)
		)
```

To leave:

```gdscript
GdLink.session.leave()
```

## Support

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/joaquinkiko)

## License

This project is licensed under the [MIT License](LICENSE).
