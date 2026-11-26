"""Video task admission is atomic at the Muse2API storage boundary."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from store import Store  # noqa: E402


with tempfile.TemporaryDirectory(prefix="muse-admission-") as home:
    cfg = SimpleNamespace(
        accounts_file=str(Path(home) / "accounts.json"),
        tasks_file=str(Path(home) / "tasks.json"),
    )
    store = Store(cfg)

    def admit(_):
        return store.create_task_if_capacity("video", "fixture", 8)

    with ThreadPoolExecutor(max_workers=16) as pool:
        results = list(pool.map(admit, range(16)))

    accepted = [task for task in results if task is not None]
    assert len(accepted) == 8, len(accepted)
    assert store.active_generation_count() == 8
    assert store.create_task_if_capacity("video", "overflow", 8) is None

print("PASS: concurrent video admission is capped atomically at 8")
