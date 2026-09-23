@tool
extends RefCounted

## This retired module intentionally has no solver implementation.
##
## Terrain height maps now drive fragment-stage parallax only, so canonical
## terrain vertices cannot develop height-map seams. The active viewport and
## material paths no longer load this file.
