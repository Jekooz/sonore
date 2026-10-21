"""
Every number the recommender uses, in one place.

Nothing here is a magic constant scattered through the sources: the weights
decide how much each layer counts, the thresholds decide what counts as a
signal, and the timeouts decide how long an optional service may take before
it is written off. Changing the feel of the recommender means changing this
file and nothing else.
"""

from __future__ import annotations

# ---------------- source names ----------------

#: The provider itself. Always the largest weight.
SOURCE_YOUTUBE = "yt"

#: What this device learned from playing, skipping and liking.
SOURCE_LOCAL = "local"

#: Outside services (ListenBrainz, Last.fm). Optional and off by default.
SOURCE_EXTERNAL = "external"

#: Every source the blender knows about, in weight order.
SOURCES = (SOURCE_YOUTUBE, SOURCE_LOCAL, SOURCE_EXTERNAL)


# ---------------- blender weights ----------------

#: YouTube Music's own recommendation, the dominant signal.
WEIGHT_YOUTUBE = 0.65

#: The local taste layer: plays, completions, likes and skips.
WEIGHT_LOCAL = 0.25

#: Outside signals, when they are configured and answering.
WEIGHT_EXTERNAL = 0.10

#: The weights as the blender consumes them.
WEIGHTS = {
    SOURCE_YOUTUBE: WEIGHT_YOUTUBE,
    SOURCE_LOCAL: WEIGHT_LOCAL,
    SOURCE_EXTERNAL: WEIGHT_EXTERNAL,
}


# ---------------- caching ----------------

#: How long a provider answer is reused, in seconds. Radio changes slowly
#: enough that asking again for every track boundary would be wasteful.
YT_CACHE_TTL = 300

#: How long the local layer's affinity view is reused. The store itself is
#: always current; only the derived scores are cached.
LOCAL_CACHE_TTL = 60

#: How long an outside answer is reused. These services change least often.
EXTERNAL_CACHE_TTL = 900

#: The longest an outside service may take before the request is given up on.
EXTERNAL_TIMEOUT = 5.0

#: The longest an outside service may answer with, in bytes. A sane cap so a
#: broken endpoint cannot fill memory.
EXTERNAL_MAX_BYTES = 2 * 1024 * 1024


# ---------------- local taste model ----------------

#: A skip in the first fraction of the track is a negative signal: the
#: listener heard a moment and moved on.
SKIP_NEGATIVE_FRACTION = 0.30

#: A skip after that fraction is a weak negative: the track was heard.
SKIP_MILD_FRACTION = 0.90

#: How long a play stays interesting, in days. The weight of a play halves
#: every half-life, so yesterday counts for twice what last month does.
RECENCY_HALFLIFE_DAYS = 14.0

#: What a completed play is worth.
PLAY_AFFINITY = 0.60

#: What finishing a track adds on top of playing it.
COMPLETION_BONUS = 0.40

#: What a like is worth — the strongest positive signal there is, and worth
#: more than a play that was heard to the end.
LIKE_AFFINITY = 1.40

#: What an early skip takes away.
SKIP_PENALTY = 0.80

#: What a mild skip takes away.
MILD_SKIP_PENALTY = 0.20

#: How much of the local score a track's own history may contribute. The
#: artist carries the rest, so one track cannot make an artist.
TRACK_SHARE = 0.40

#: The most plays kept per track, so a looped track cannot dominate.
MAX_PLAYS_PER_TRACK = 50

#: The most events kept per table, so the store cannot grow without bound.
MAX_ROWS = 5000


# ---------------- filtering and variety ----------------

#: How many distinct recently played tracks are kept out of the results.
RECENT_BLOCK_COUNT = 20

#: How many tracks of one artist may appear in one result list.
MAX_PER_ARTIST = 2

#: How many results a request may ask for.
MAX_CANDIDATES = 50

#: The default number of results.
DEFAULT_LIMIT = 12


# ---------------- outside services ----------------

#: The ListenBrainz account the external source reads, when a token for it is
#: configured. Not a secret: it is a public user name.
LISTENBRAINZ_USER = "jekooz"

#: The endpoints the external source talks to.
LISTENBRAINZ_LISTENS_URL = (
    "https://api.listenbrainz.org/1/user/{user}/listens"
)
LISTENBRAINZ_PLAYLISTS_URL = (
    "https://api.listenbrainz.org/1/user/{user}/playlists/created"
)
LASTFM_SIMILAR_ARTIST_URL = (
    "https://ws.audioscrobbler.com/2.0/"
    "?method=artist.getsimilar&format=json&limit={limit}&artist={artist}"
)
LASTFM_SIMILAR_TRACK_URL = (
    "https://ws.audioscrobbler.com/2.0/"
    "?method=track.getsimilar&format=json&limit={limit}&artist={artist}&track={track}"
)

#: How many similar artists/tracks are asked for per call.
EXTERNAL_SIMILAR_LIMIT = 20

#: How much of the outside weight a same-song match contributes. A match on
#: the song itself is the strongest thing an outside service can say.
EXTERNAL_SONG_BOOST = 1.0

#: How much of the outside weight a same-artist match contributes. Weaker,
#: because two songs by one artist are not the same taste.
EXTERNAL_ARTIST_BOOST = 0.6

#: The artist whose similar artists and tracks are asked for when no seed
#: track is known. The external source is a *refinement*, so it only needs
#: one artist to start from.
EXTERNAL_SEED_ARTIST = "Karan Aujla"


# ---------------- storage ----------------

#: The file the local taste layer lives in, inside the app's data directory.
TASTE_DB_FILENAME = "taste.db"

#: The file the recommender's settings live in, inside the app's data
#: directory and encrypted with the same DPAPI helper as the install token.
RECOMMENDER_SETTINGS_FILENAME = "recommender_settings.dat"
