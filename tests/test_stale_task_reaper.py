"""Regression checks for stale async task cancellation and durable cleanup state."""
from types import SimpleNamespace
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import app


def test_stale_processing_task_is_reclaimed_and_signals_worker():
    original_store, original_cfg = app.store, app.CFG
    task_id = "task_stale_fixture"

    class FakeStore:
        def __init__(self):
            self.tasks = {
                task_id: {
                    "id": task_id,
                    "kind": "video",
                    "status": "processing",
                    "created_at": 100,
                    "updated_at": 100,
                    "started_at": 100,
                }
            }

        def get_task(self, tid):
            return self.tasks.get(tid)

        def update_task(self, tid, **changes):
            task = self.tasks.get(tid)
            if task:
                task.update(changes)
            return task

    fake_store = FakeStore()
    app.store = fake_store
    app.CFG = SimpleNamespace(stale_task_timeout=900)
    runtime = app._register_task_runtime(task_id, "video")
    try:
        assert app._reclaim_stale_tasks(now=1100) == 1
        task = fake_store.get_task(task_id)
        assert task["status"] == "failed"
        assert task["reclaimed_at"] == 1100
        assert runtime["reclaimed"] is True
        assert runtime["stop_event"].is_set()
    finally:
        app._unregister_task_runtime(task_id)
        app.store, app.CFG = original_store, original_cfg


if __name__ == "__main__":
    test_stale_processing_task_is_reclaimed_and_signals_worker()
    print("PASS: stale task reaper cancellation and persisted failure")
