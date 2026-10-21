"""
The candidate sources.

Each source is a small, honest function over one kind of signal:

    youtube.py   what the provider itself believes
    local.py     what this device has learned
    external.py  what two optional outside services believe

They all return candidates in the shape the blender expects, and they all
fail quietly: a source that cannot answer returns nothing rather than raising,
because a missing layer must never take the request down.
"""

from __future__ import annotations

from . import external, local, youtube

__all__ = ["external", "local", "youtube"]
