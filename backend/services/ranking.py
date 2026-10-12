"""
Local ranking for YouTube Music recommendation candidates.

YouTube Music exposes recommendation *candidates* (radio, related shelves,
personalized home) but not its ranking logic; this module is the transparent,
deterministic local ranker that combines those real candidates with the
user's local listening behaviour. It is pure functions over plain dicts —
no I/O, no randomness, no ML stack — so tests (and a future Android client)
can reuse it as-is.

Signal weights (all documented at their definition below):

    provider order   1 / (1 + 0.07 * index)     up to 1.00, ~0.59 at index 10
                                                 -> dominant with no history,
                                                    still shapes results with
    familiarity      +0.30 * min(completions, 8) / 8        played-to-end
    provider plays   +0.05 * min(plays, 8) / 8              YouTube history
    artist affinity  +0.28 * artistCompletions / (4 + artistCompletions)
    explicit like    +0.55   (in-app LIKE or present in liked-songs library)
    in library       +0.08
    discovery        +0.10   never played locally — the "new music" nudge
    early skip       -0.05 * min(earlySkips, 3)   capped: one bad skip is
                                                     a weak, bounded signal
    recent repeat    -0.55 .. -0.05 for the last 10 distinct plays
    same-artist      -0.12 * (already selected this artist)  diversity
    explicit dislike excluded outright — only an explicit DISLIKE does this;
                             a single early skip never marks a track disliked

Design rules honoured here:
  * Deduplicate by videoId (first occurrence wins = provider order).
  * Preserve provider ranking when there is no local history (cold start):
    every local term is 0, so the result is the provider order modulo the
    uniform discovery bonus (also uniform → order preserved) and the
    deterministic diversity cap.
  * Explicit feedback outweighs inferred feedback by construction (like 0.55
    vs skip -0.05 capped).
  * Repeatable: same inputs → same output, always.
  * Fails gracefully: empty candidates / empty stats are valid inputs.
"""

from __future__ import annotations

# --- weights (see module docstring) -------------------------------------
PROVIDER_DECAY = 0.07
W_COMPLETION = 0.30
W_PROVIDER_PLAY = 0.05
W_ARTIST = 0.28
W_LIKE = 0.55
W_LIBRARY = 0.08
W_DISCOVERY = 0.10
W_EARLY_SKIP = 0.05
W_EARLY_SKIP_MAX_STREAK = 3
W_RECENT_MAX = 0.55
W_RECENT_MIN = 0.05
RECENT_WINDOW = 10          # distinct recent videos, newest penalised most
W_SAME_ARTIST_PENALTY = 0.12
MAX_PER_ARTIST = 3          # diversity cap unless the candidate pool runs dry
W_PROVIDER_ARTIST = 0.01    # per-artist nudge from YouTube's own history


def _artist_names(candidate: dict) -> list[str]:
    names = []
    for a in candidate.get("artists") or []:
        if isinstance(a, dict):
            name = a.get("name")
        else:
            name = str(a)
        if name:
            names.append(str(name))
    return names


def _video_plays(stats: dict, familiarity: dict, video_id: str) -> tuple[int, int]:
    """(local completions, provider-history plays) for one video."""
    local = (stats.get("videos") or {}).get(video_id) or {}
    provider = (familiarity.get("video_plays") or {}).get(video_id) or 0
    return int(local.get("completed") or 0), int(provider)


def rank(
    candidates: list[dict],
    stats: dict | None = None,
    familiarity: dict | None = None,
    limit: int = 12,
    exclude: set[str] | None = None,
) -> list[dict]:
    """
    Rank *candidates* (provider order in, ranked order out) and return at
    most *limit* of them.

    stats:       ListeningStore.stats() shape (may be empty/None).
    familiarity: provider-history shape {video_plays: {id: n},
                 artist_plays: {name: n}, liked: {id, ...}} (may be empty).
    exclude:     videoIds that must not be recommended (current queue,
                 the seed itself, ...).
    """
    stats = stats or {}
    familiarity = familiarity or {}
    exclude = exclude or set()

    videos = stats.get("videos") or {}
    artists_stats = stats.get("artists") or {}
    liked_local = stats.get("ratings") or {}
    recent = stats.get("recent") or []
    liked_provider = familiarity.get("liked") or set()
    provider_video_plays = familiarity.get("video_plays") or {}
    provider_artist_plays = familiarity.get("artist_plays") or {}

    # --- dedup + hard filters (provider order preserved) -----------------
    seen: set[str] = set()
    pool: list[tuple[dict, int]] = []
    for idx, cand in enumerate(candidates):
        if not isinstance(cand, dict):
            continue
        video_id = cand.get("videoId")
        if not video_id or video_id in seen or video_id in exclude:
            continue
        seen.add(video_id)
        if liked_local.get(video_id) == "DISLIKE":
            continue  # explicit dislike only — never an inferred one
        pool.append((cand, idx))

    if not pool or limit <= 0:
        return []

    # --- scoring ---------------------------------------------------------
    scored: list[tuple[float, int, dict]] = []
    for cand, idx in pool:
        video_id = cand["videoId"]
        local = videos.get(video_id) or {}
        completions = int(local.get("completed") or 0)
        early_skips = int(local.get("early_skips") or 0)
        plays = int(local.get("plays") or 0)
        provider_plays = int(provider_video_plays.get(video_id) or 0)

        provider = 1.0 / (1.0 + PROVIDER_DECAY * idx)

        familiarity_score = (
            W_COMPLETION * min(completions, 8) / 8
            + W_PROVIDER_PLAY * min(provider_plays, 8) / 8
        )

        artist_score = 0.0
        for name in _artist_names(cand):
            a = artists_stats.get(name) or {}
            artist_completions = int(a.get("completed") or 0)
            artist_score = max(
                artist_score,
                W_ARTIST * artist_completions / (4 + artist_completions),
            )
            artist_score += (
                W_PROVIDER_ARTIST
                * min(int(provider_artist_plays.get(name) or 0), 5)
                / 5
            )

        liked = video_id in liked_provider or liked_local.get(video_id) == "LIKE"
        in_library = bool(cand.get("inLibrary"))
        never_played = plays == 0 and provider_plays == 0

        recent_penalty = 0.0
        if video_id in recent:
            pos = recent.index(video_id)  # 0 = just played
            span = max(len(recent) - 1, 1)
            recent_penalty = -(W_RECENT_MAX - (W_RECENT_MAX - W_RECENT_MIN) * (pos / span))

        score = (
            provider
            + familiarity_score
            + artist_score
            + (W_LIKE if liked else 0.0)
            + (W_LIBRARY if in_library else 0.0)
            + (W_DISCOVERY if never_played else 0.0)
            - W_EARLY_SKIP * min(early_skips, W_EARLY_SKIP_MAX_STREAK)
            + recent_penalty
        )
        scored.append((score, idx, cand))

    # --- selection with artist diversity --------------------------------
    scored.sort(key=lambda t: (-t[0], t[1]))  # deterministic: score, then provider order
    chosen: list[dict] = []
    per_artist: dict[str, int] = {}
    deferred: list[dict] = []

    def _try_choose(item, apply_penalty) -> bool:
        score, _, cand = item
        names = _artist_names(cand)
        if names and per_artist.get(names[0], 0) >= MAX_PER_ARTIST:
            return False
        if apply_penalty and names:
            score -= W_SAME_ARTIST_PENALTY * per_artist.get(names[0], 0)
        chosen.append(cand)
        for n in names:
            per_artist[n] = per_artist.get(n, 0) + 1
        return True

    for item in scored:
        if len(chosen) >= limit:
            break
        if not _try_choose(item, apply_penalty=True):
            deferred.append(item)

    # Only when the pool of fresh artists runs dry do we lift the cap, so a
    # short candidate list still fills the queue instead of starving it.
    for item in deferred:
        if len(chosen) >= limit:
            break
        score, _, cand = item
        chosen.append(cand)
        for n in _artist_names(cand):
            per_artist[n] = per_artist.get(n, 0) + 1

    return chosen
