import sqlite3
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path


class Database:
    """The server's SQLite database: the resources, the relations between them, and the event log.

    One connection serves every request thread, behind one lock: the server's load is a few agents and a
    few desktops, and a single writer keeps every change and the event that announces it in one order.
    """

    DATABASE_FILE_NAME = "rookd.db"
    DATABASE_FILE_MODE = 0o600
    DATABASE_DIR_MODE = 0o700
    DATABASE_BUSY_TIMEOUT_SECONDS = 10
    DATABASE_SCHEMA = (
        """
        CREATE TABLE IF NOT EXISTS resources (
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            name TEXT NOT NULL,
            attributes TEXT NOT NULL,
            origin_kind TEXT,
            origin_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            last_used_at TEXT NOT NULL,
            PRIMARY KEY (kind, id)
        )
        """,
        "CREATE INDEX IF NOT EXISTS resources_by_use ON resources (kind, last_used_at)",
        """
        CREATE TABLE IF NOT EXISTS relations (
            source_kind TEXT NOT NULL,
            source_id TEXT NOT NULL,
            verb TEXT NOT NULL,
            target_kind TEXT NOT NULL,
            target_id TEXT NOT NULL,
            first_at TEXT NOT NULL,
            last_at TEXT NOT NULL,
            count INTEGER NOT NULL,
            PRIMARY KEY (source_kind, source_id, verb, target_kind, target_id)
        )
        """,
        "CREATE INDEX IF NOT EXISTS relations_by_target ON relations (target_kind, target_id)",
        """
        CREATE TABLE IF NOT EXISTS events (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            at TEXT NOT NULL,
            actor_kind TEXT NOT NULL,
            actor_id TEXT NOT NULL,
            verb TEXT NOT NULL,
            object_kind TEXT,
            object_id TEXT,
            detail TEXT NOT NULL
        )
        """,
    )

    def __init__(self, data_root: Path) -> None:
        self._path = data_root / self.DATABASE_FILE_NAME
        data_root.mkdir(parents=True, exist_ok=True)
        data_root.chmod(self.DATABASE_DIR_MODE)
        self._lock = threading.RLock()
        self._connection = sqlite3.connect(
            self._path,
            timeout=self.DATABASE_BUSY_TIMEOUT_SECONDS,
            check_same_thread=False,
            isolation_level=None,
        )
        self._connection.row_factory = sqlite3.Row
        self._path.chmod(self.DATABASE_FILE_MODE)
        self._connection.execute("PRAGMA journal_mode=WAL")
        with self.transaction() as connection:
            for statement in self.DATABASE_SCHEMA:
                connection.execute(statement)

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        """Hold the database for a block of statements that succeed or fail together.

        Yields:
            the connection, inside a transaction that commits when the block ends and rolls back if it
            raises
        """
        with self._lock:
            self._connection.execute("BEGIN IMMEDIATE")
            try:
                yield self._connection
            except BaseException:
                self._connection.execute("ROLLBACK")
                raise
            self._connection.execute("COMMIT")

    @contextmanager
    def reading(self) -> Iterator[sqlite3.Connection]:
        """Hold the database for reads that must see one consistent state.

        Yields:
            the connection
        """
        with self._lock:
            yield self._connection

    def close(self) -> None:
        """Close the connection; the database is unusable afterwards."""
        with self._lock:
            self._connection.close()
