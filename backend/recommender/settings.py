"""
The recommender's own settings: whether local learning is on, and the
credentials for the optional outside services.

Where they live
----------------
One file in the app's own data directory
(``%LOCALAPPDATA%\\Sonore\\recommender_settings.dat``), encrypted with the
same DPAPI helper the install token uses, so the ListenBrainz token and the
Last.fm key are never readable by another process on the machine and never
appear in a backup of the data folder as plain text.

The values are never hardcoded, never logged, and never committed. An install
that has never been configured simply has no settings file, and every
outside service is skipped.
"""

from __future__ import annotations

import json
import logging
from dataclasses import asdict, dataclass

from services.ytmusic_client import secret_delete, secret_get, secret_path, secret_set

from .config import LISTENBRAINZ_USER, RECOMMENDER_SETTINGS_FILENAME

logger = logging.getLogger("ytmusic-backend")


@dataclass
class RecommenderSettings:
    """
    What the recommender is allowed to do.

    local_learning:      whether the local taste layer is used at all, and
                         whether new events are recorded
    listenbrainz_token:  the user's ListenBrainz token, or ""
    lastfm_api_key:      the user's Last.fm API key, or ""
    listenbrainz_user:   the account the ListenBrainz signal is read from
    """

    local_learning: bool = True
    listenbrainz_token: str = ""
    lastfm_api_key: str = ""
    listenbrainz_user: str = LISTENBRAINZ_USER

    @property
    def has_external(self) -> bool:
        """True when at least one outside service is configured."""
        return bool(self.listenbrainz_token or self.lastfm_api_key)

    def to_json(self) -> dict:
        return asdict(self)

    @classmethod
    def from_json(cls, raw: object) -> "RecommenderSettings":
        if not isinstance(raw, dict):
            return cls()
        learning = raw.get("local_learning")
        return cls(
            local_learning=bool(learning) if learning is not None else True,
            listenbrainz_token=str(raw.get("listenbrainz_token") or "")[:200],
            lastfm_api_key=str(raw.get("lastfm_api_key") or "")[:200],
            listenbrainz_user=str(
                raw.get("listenbrainz_user") or LISTENBRAINZ_USER
            )[:80],
        )


def settings_path() -> str:
    """Where the settings file lives."""
    return secret_path(RECOMMENDER_SETTINGS_FILENAME)


class SettingsStore:
    """
    The recommender's settings, encrypted at rest.

    Every read and write is best-effort: a settings file that cannot be
    decrypted (a different machine, a changed key) is treated as "not
    configured" rather than an error, so the recommender simply runs without
    the outside services.
    """

    def __init__(self, name: str = RECOMMENDER_SETTINGS_FILENAME):
        self._name = name

    def load(self) -> RecommenderSettings:
        """The stored settings, or the defaults."""
        try:
            plain = secret_get(self._name)
            if plain is None:
                return RecommenderSettings()
            return RecommenderSettings.from_json(json.loads(plain))
        except Exception as exc:  # noqa: BLE001 - never fatal
            logger.info("recommender settings unreadable: %s", type(exc).__name__)
            return RecommenderSettings()

    def save(self, settings: RecommenderSettings) -> bool:
        """Store the settings. Returns True when they were written."""
        try:
            payload = json.dumps(settings.to_json(), separators=(",", ":"))
            secret_set(self._name, payload)
        except Exception as exc:  # noqa: BLE001 - never fatal
            logger.info(
                "could not store recommender settings: %s", type(exc).__name__
            )
            return False
        return True

    def clear(self) -> None:
        """Forget the settings, including any stored credentials."""
        secret_delete(self._name)
