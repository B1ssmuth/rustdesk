from pathlib import Path

import psycopg

from settings import database_url


def migrate():
    with psycopg.connect(database_url()) as db:
        db.execute("SELECT pg_advisory_xact_lock(8143020)")
        db.execute(
            "CREATE TABLE IF NOT EXISTS schema_migrations "
            "(name text PRIMARY KEY, installed_at timestamptz NOT NULL DEFAULT now())"
        )
        for path in sorted(Path(__file__).parent.glob("[0-9][0-9][0-9]_*.sql")):
            if db.execute("SELECT 1 FROM schema_migrations WHERE name = %s", (path.name,)).fetchone():
                continue
            db.execute(path.read_text(encoding="utf-8"))
            db.execute("INSERT INTO schema_migrations (name) VALUES (%s)", (path.name,))


if __name__ == "__main__":
    migrate()
