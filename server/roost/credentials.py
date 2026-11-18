import re
from dataclasses import dataclass
from urllib.parse import urlsplit
from roost.database import Database
from roost.errors import NotFoundError, ValidationError
from roost.resources import ResourceStore


@dataclass
class GitCredential:
    """A token for a git hosting service, as the user registered it: the host it opens, the user name git
    gives with it, and the token itself, which never leaves the server but to a rook fetching a skill."""

    host: str
    username: str
    token: str
    updated_at: str

    CREDENTIAL_HINT_CHARS = 4

    def as_listing(self) -> dict[str, object]:
        """The credential as a listing shows it: the token reduced to its last characters."""
        return {
            "host": self.host,
            "username": self.username,
            "token_hint": "…" + self.token[-self.CREDENTIAL_HINT_CHARS:],
            "updated_at": self.updated_at,
        }

    def as_secret(self) -> dict[str, object]:
        """The credential whole, for a rook about to fetch from its host."""
        return {"host": self.host, "username": self.username, "token": self.token}


class GitCredentialStore:
    """The tokens git hosting services gave the user, by host, kept in the server's database, which only
    the server's user may read: roost uses them to read private repositories' refs, and hands the one for
    a repository's host to a rook installing a skill from it. git reads a token through a helper given on
    its command line, which takes it from git's environment, so it never shows in a process listing."""

    CREDENTIAL_HOST_PATTERN = re.compile(r"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:\d{1,5})?$")
    CREDENTIAL_TOKEN_MAX_CHARS = 4096
    CREDENTIAL_USERNAME_MAX_CHARS = 200
    CREDENTIAL_GITHUB_HOST = "github.com"
    CREDENTIAL_GITHUB_USERNAME = "x-access-token"
    CREDENTIAL_OTHER_USERNAME = "oauth2"
    CREDENTIAL_SCHEMES = ("https", "http")
    CREDENTIAL_USERNAME_ENV = "ROOST_GIT_USERNAME"
    CREDENTIAL_PASSWORD_ENV = "ROOST_GIT_PASSWORD"

    def __init__(self, database: Database) -> None:
        self._database = database

    def list_all(self) -> list[GitCredential]:
        """Every credential, by host."""
        with self._database.reading() as connection:
            list_rows = connection.execute("SELECT * FROM git_credentials ORDER BY host").fetchall()
        return [self._credential_of(row) for row in list_rows]

    def put(self, host: str, username: str, token: str) -> GitCredential:
        """Register the token for a host, or replace the one it has.

        Args:
            host: the host, as `github.com` or `git.example.com:8443`
            username: the user name git gives with the token, or empty for the host's usual one
            token: the token

        Returns:
            the credential as stored

        Raises:
            ValidationError: if the host, the user name or the token is unusable
        """
        host = self.normal_host(host)
        token = token.strip()
        if not token or len(token) > self.CREDENTIAL_TOKEN_MAX_CHARS or any(char.isspace() for char in token):
            raise ValidationError("a token is one word of at most 4096 characters")
        username = username.strip() or self.usual_username(host)
        if len(username) > self.CREDENTIAL_USERNAME_MAX_CHARS or any(char.isspace() for char in username):
            raise ValidationError("a user name is one word of at most 200 characters")
        at = ResourceStore.now_timestamp()
        with self._database.transaction() as connection:
            connection.execute(
                """
                INSERT INTO git_credentials (host, username, token, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (host) DO UPDATE SET username = excluded.username, token = excluded.token,
                    updated_at = excluded.updated_at
                """,
                (host, username, token, at, at),
            )
        return GitCredential(host=host, username=username, token=token, updated_at=at)

    def remove(self, host: str) -> None:
        """Forget the token for a host.

        Raises:
            NotFoundError: if the host has none
        """
        host = self.normal_host(host)
        with self._database.transaction() as connection:
            cursor = connection.execute("DELETE FROM git_credentials WHERE host = ?", (host,))
        if cursor.rowcount == 0:
            raise NotFoundError(f"no token is registered for {host}")

    def for_repo(self, repo_url: str) -> GitCredential | None:
        """The credential for a repository's host, for one reached over https; None for none, and for one
        reached over ssh, which brings its own keys."""
        parts = urlsplit(repo_url)
        if parts.scheme not in self.CREDENTIAL_SCHEMES or not parts.hostname:
            return None
        host = parts.hostname.lower() + (f":{parts.port}" if parts.port else "")
        with self._database.reading() as connection:
            row = connection.execute("SELECT * FROM git_credentials WHERE host = ?", (host,)).fetchone()
        return self._credential_of(row) if row else None

    @classmethod
    def git_options(cls) -> list[str]:
        """What git is told on its command line to take a credential from its environment, in place of
        any helper it is set up with."""
        return [
            "-c",
            "credential.helper=",
            "-c",
            f"credential.helper=!f() {{ echo username=${cls.CREDENTIAL_USERNAME_ENV}; echo password=${cls.CREDENTIAL_PASSWORD_ENV}; }}; f",
        ]

    @classmethod
    def git_environment(cls, credential: GitCredential) -> dict[str, str]:
        """The environment that hands git a credential through `git_options`."""
        return {cls.CREDENTIAL_USERNAME_ENV: credential.username, cls.CREDENTIAL_PASSWORD_ENV: credential.token}

    @classmethod
    def normal_host(cls, host: str) -> str:
        """A host as the store keys it, lower case, its scheme and path taken off.

        Raises:
            ValidationError: if it is not a host name, with a port or without
        """
        trimmed = host.strip().lower()
        if "://" in trimmed:
            parts = urlsplit(trimmed)
            trimmed = (parts.hostname or "") + (f":{parts.port}" if parts.port else "")
        trimmed = trimmed.split("/")[0]
        if not cls.CREDENTIAL_HOST_PATTERN.match(trimmed):
            raise ValidationError(f"unusable host: {host!r} (expected a host name, as github.com)")
        return trimmed

    @classmethod
    def usual_username(cls, host: str) -> str:
        """The user name a host takes with a token when none is given: GitHub's for an app token, else
        GitLab's and most others' for a personal one."""
        return cls.CREDENTIAL_GITHUB_USERNAME if host == cls.CREDENTIAL_GITHUB_HOST else cls.CREDENTIAL_OTHER_USERNAME

    @staticmethod
    def _credential_of(row: object) -> GitCredential:
        return GitCredential(
            host=row["host"],
            username=row["username"],
            token=row["token"],
            updated_at=row["updated_at"],
        )
