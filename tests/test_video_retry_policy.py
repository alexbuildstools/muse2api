"""Video retries should switch accounts only for account-scoped failures."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


with tempfile.TemporaryDirectory(prefix="muse-video-retry-policy-") as home:
    os.environ.update(MUSE2API_HOME=home, MUSE2API_PROFILE_ROOT=home,
                      MUSE2API_KEY="test-only")
    spec = importlib.util.spec_from_file_location(
        "video_retry_policy_candidate", ROOT / "app.py")
    app = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = app
    spec.loader.exec_module(app)

    first = app.store.add_account({"hatch_sess": "one", "hatch_vml": "one",
                                   "hatch_native_auth_device": "one"}, "one")
    second = app.store.add_account({"hatch_sess": "two", "hatch_vml": "two",
                                    "hatch_native_auth_device": "two"}, "two")

    assert not app._is_account_retryable_failure(
        app.MuseGenerationError("等待生成超时，未出现新的生成结果"))
    assert app._is_account_retryable_failure(app.MuseAuthError("fixture 401"))
    assert app._is_account_retryable_failure(app.MuseProxyError("fixture proxy"))
    assert app._is_account_retryable_failure(app.MuseGenerationError("账号额度不足"))

    calls = []

    def generic_failure(cookies, prompt, **kwargs):
        calls.append(cookies["hatch_sess"])
        raise app.MuseGenerationError("等待生成超时，未出现新的生成结果")

    with patch.object(app, "_renew_and_persist",
                      side_effect=lambda ident, **_: app.store.get_account(ident)), \
         patch.object(app.engine, "start"), \
         patch.object(app.engine, "generate", side_effect=generic_failure), \
         patch.object(app.engine, "reset_thread"), \
         patch.object(app.engine, "close_current_page"):
        try:
            app._run_generation_locked(
                "video", "video", 30, account_id=first["id"],
                deadline=app.time.monotonic() + 30, account_retry_only=True)
        except app.MuseGenerationError as exc:
            assert "等待生成超时" in str(exc)
        else:
            raise AssertionError("generic video failure was not propagated")
    assert calls == ["one"], calls

    calls.clear()

    def auth_then_success(cookies, prompt, **kwargs):
        calls.append(cookies["hatch_sess"])
        if len(calls) == 1:
            raise app.MuseAuthError("fixture session expired")
        return {"filename": "fixture.mp4", "size": 4, "kind": "video"}

    with patch.object(app, "_renew_and_persist",
                      side_effect=lambda ident, **_: app.store.get_account(ident)), \
         patch.object(app, "_sync_cookies", return_value={}), \
         patch.object(app.engine, "start"), \
         patch.object(app.engine, "generate", side_effect=auth_then_success), \
         patch.object(app.engine, "reset_thread"), \
         patch.object(app.engine, "close_current_page"):
        result, account_id = app._run_generation_locked(
            "video", "video", 30, account_id=first["id"],
            deadline=app.time.monotonic() + 30, account_retry_only=True)
    assert calls == ["one", "two"], calls
    assert account_id == second["id"]
    assert result["kind"] == "video"

print("PASS: generic video failures stop; account-scoped failures rotate once")
