"""Private, bounded checkpoints for expensive classification batches."""
import hashlib
import json
import os
import time

from database import DATA_DIR

CHECKPOINT_DIR = DATA_DIR / "taxonomy-checkpoints"
MAX_AGE = 7 * 24 * 60 * 60
MAX_FILES = 3


class ClassificationCheckpoint:
    def __init__(self, inputs):
        fingerprint = hashlib.sha256(json.dumps(inputs, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        CHECKPOINT_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path = CHECKPOINT_DIR / f"{fingerprint}.json"
        self.responses = {}
        files = sorted((p for p in CHECKPOINT_DIR.glob("*.json") if p != self.path), key=lambda p: p.stat().st_mtime, reverse=True)
        for index, path in enumerate(files):
            if index >= MAX_FILES - 1 or time.time() - path.stat().st_mtime > MAX_AGE:
                path.unlink(missing_ok=True)
        try:
            if time.time() - self.path.stat().st_mtime > MAX_AGE:
                self.path.unlink()
            if self.path.stat().st_size <= 4_000_000:
                data = json.loads(self.path.read_text())
                if isinstance(data, dict):
                    self.responses = {key: value for key, value in data.items()
                                      if isinstance(value, dict) and all(isinstance(v, str) for v in value.values())}
        except (OSError, ValueError):
            pass

    def save(self, offset: int, payload: dict):
        self.responses[str(offset)] = payload
        temporary = self.path.with_suffix(".tmp")
        try:
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as output:
                json.dump(self.responses, output, ensure_ascii=False)
            os.replace(temporary, self.path)
        finally:
            temporary.unlink(missing_ok=True)
