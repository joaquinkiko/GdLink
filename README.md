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

## Support

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/joaquinkiko)

## License

This project is licensed under the [MIT License](LICENSE).
