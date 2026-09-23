@tool
extends RefCounted

## Binding behavior for BoardDocument.
## The host retains Godot identity, signals, and authoritative state.

## Bind the authoritative asset library used to resolve placement references.
static func bind_library(host: BoardDocument, library: AssetLibrary) -> void:
	host._library = library
	host.rebuild_indexes()
