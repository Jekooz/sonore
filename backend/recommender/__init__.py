"""
The layered recommender: YouTube Music first, local taste and external
signals refining it.

The shape of the thing
----------------------
Three *sources* produce candidates and one *blender* merges them:

    sources/youtube.py   the provider itself — radio for a seed, the home feed
                         for the "Recommended for you" row
    sources/local.py     what this device has learned: plays, skips and likes
    sources/external.py  optional outside signals (ListenBrainz, Last.fm)
    blender.py           the weighted merge, dedupe, filters and diversity cap

Why a package and not four more functions in ``services/``: the ranking
already there (``services/ranking.py``) is a *ranker* over one provider's
candidates. This is a different job — several candidate streams, each with its
own confidence, merged into one list — and it needs its own tests, its own
cache and its own store.

The rules this package holds to:

  * YouTube Music dominates. Its weight is the largest one, and a request
    that only the provider can answer is still answered by the provider.
  * The other two layers *refine*. They never replace what the provider
    believes, and a failure in either is invisible to the caller.
  * Nothing is stored outside the app's own data directory.
  * No secret is hardcoded, logged or committed. The external services are
    optional and off until the user supplies a token.
  * A future local-library source (the Gonic/FLAC v2 plan) slots in beside
    the other two: a source is a callable that returns candidates, and the
    blender does not care where they came from.

Where the numbers live
----------------------
Every weight, threshold and timeout is a named constant in
``recommender/config.py`` and nowhere else. This file is the single place to
change how much any one layer counts.
"""

from __future__ import annotations

from .blender import blend
from .config import (
    SOURCE_EXTERNAL,
    SOURCE_LOCAL,
    SOURCE_YOUTUBE,
    WEIGHT_EXTERNAL,
    WEIGHT_LOCAL,
    WEIGHT_YOUTUBE,
)
from .engine import recommend_home, recommend_next
from .settings import RecommenderSettings, SettingsStore
from .sources.external import external_candidates
from .sources.local import local_candidates
from .sources.youtube import home_candidates, seed_candidates
from .store import TasteStore

#: The shared local taste layer and the shared settings store.
#:
#: They are created here (and not in the API layer) so that every caller
#: uses the same store, and so a test can point them somewhere else.
taste_store = TasteStore()
settings_store = SettingsStore()

__all__ = [
    "RecommenderSettings",
    "SettingsStore",
    "SOURCE_EXTERNAL",
    "SOURCE_LOCAL",
    "SOURCE_YOUTUBE",
    "TasteStore",
    "WEIGHT_EXTERNAL",
    "WEIGHT_LOCAL",
    "WEIGHT_YOUTUBE",
    "blend",
    "external_candidates",
    "home_candidates",
    "local_candidates",
    "recommend_home",
    "recommend_next",
    "seed_candidates",
    "settings_store",
    "taste_store",
]
