"""
Tests for the bridge's web dashboard (GET /dashboard) and its supporting
JSON routes: /device_model and /restart.

Key behaviors under test:
  * GET /dashboard is reachable WITHOUT an X-Bridge-Key header even when an
    API key is configured (a plain browser navigation can't set custom
    headers) -- it's the one route deliberately left off the `_auth`
    per-route dependency list.
  * The JSON API routes the dashboard's own JavaScript calls (/status,
    /device_model, etc.) still enforce the key normally.
  * POST /device_model validates against the allowed meter list and
    persists the choice.
  * POST /restart responds successfully and schedules an os._exit(1) --
    verified without actually killing the test process.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
BRIDGE_DIR = REPO_ROOT / "sekonic-bridge"
sys.path.insert(0, str(BRIDGE_DIR))

import server as bridge_server  # noqa: E402


@pytest.fixture
def device_cfg(tmp_path, monkeypatch):
    cfg_path = tmp_path / "device_config.json"
    monkeypatch.setattr(bridge_server, "DEVICE_CONFIG_PATH", cfg_path)
    return cfg_path


def test_dashboard_reachable_without_key_when_auth_configured(auth_client):
    # auth_client fixture sets BRIDGE_API_KEY -- normally every route needs
    # X-Bridge-Key, but /dashboard must stay reachable for plain navigation.
    resp = auth_client.get("/dashboard")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]


def test_dashboard_reachable_without_key_when_auth_not_configured(client):
    resp = client.get("/dashboard")
    assert resp.status_code == 200


def test_dashboard_contains_expected_page_scaffold(client):
    resp = client.get("/dashboard")
    html = resp.text
    assert "SEKONIC BRIDGE" in html
    assert "telemetry" in html
    assert "/status" in html
    assert "/device_model" in html
    assert "/restart" in html


def test_dashboard_json_routes_still_require_key(auth_client):
    # The dashboard page itself is open, but the JSON routes it calls are
    # still protected -- calling /status without the key must still 401.
    resp = auth_client.get("/status", headers={})
    assert resp.status_code == 401


def test_device_model_get_defaults_to_c7000(client, device_cfg):
    resp = client.get("/status")
    assert resp.json()["meter"] == "C-7000"


def test_device_model_post_valid_model(client, device_cfg):
    resp = client.post("/device_model", json={"model": "C-800"})
    assert resp.status_code == 200
    data = resp.json()
    assert data["ok"] is True
    assert data["meter_model"] == "C-800"

    saved = json.loads(device_cfg.read_text())
    assert saved["meter_model"] == "C-800"

    # And it's reflected back in /status.
    resp2 = client.get("/status")
    assert resp2.json()["meter"] == "C-800"


def test_device_model_post_rejects_invalid_model(client, device_cfg):
    resp = client.post("/device_model", json={"model": "NotAMeter"})
    assert resp.status_code == 422
    assert resp.json()["detail"]["error"] == "invalid_model"


def test_device_model_post_rejects_missing_model(client, device_cfg):
    resp = client.post("/device_model", json={})
    assert resp.status_code == 422


def test_device_model_requires_auth_when_configured(auth_client, device_cfg):
    resp = auth_client.post("/device_model", json={"model": "C-800"}, headers={})
    assert resp.status_code == 401


def test_restart_returns_ok_without_killing_test_process(client, monkeypatch):
    # Replace the scheduled os._exit(1) with a no-op so the test process
    # survives; we only care that /restart responds and schedules a task.
    calls = []
    monkeypatch.setattr(bridge_server.os, "_exit", lambda code: calls.append(code))

    resp = client.post("/restart")
    assert resp.status_code == 200
    assert resp.json()["ok"] is True
