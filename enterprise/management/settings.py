import os
from pathlib import Path
from urllib.parse import urlsplit


def database_url():
    return Path(os.environ["YESDESK_DATABASE_URL_FILE"]).read_text(encoding="utf-8").strip()


def https_url(name):
    value = os.environ[name]
    url = urlsplit(value)
    if url.scheme != "https" or not url.hostname or url.username or url.password or url.fragment:
        raise ValueError(f"{name} requires an HTTPS URL")
    return value
