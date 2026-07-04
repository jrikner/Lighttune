"""Tests for fixture log sync routes and /fixtures page."""

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
def fixture_log_path(tmp_path, monkeypatch):
    path = tmp_path / "fixture_log.json"
    monkeypatch.setattr(bridge_server, "FIXTURE_LOG_PATH", path)
    bridge_server._fixture_log_updated_at = None
    return path


SAMPLE_RECORD = {
    "make": "Martin",
    "model": "MAC Aura XB",
    "kelvin": 5600,
    "date": "2026-07-03",
    "contributor": "local",
    "cct": 5580,
    "duv": -0.0012,
    "cri": 92,
    "r9": 78,
    "best_duv": True,
}


def test_fixtures_page_reachable_without_key(client):
    resp = client.get("/fixtures")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "Fixture Log" in resp.text
    assert "/fixture_log" in resp.text


def test_fixture_log_get_empty(client, fixture_log_path):
    resp = client.get("/fixture_log")
    assert resp.status_code == 200
    data = resp.json()
    assert data["records"] == []
    assert data["count"] == 0


def test_fixture_log_post_and_get(client, fixture_log_path):
    resp = client.post("/fixture_log", json=[SAMPLE_RECORD])
    assert resp.status_code == 200
    data = resp.json()
    assert data["ok"] is True
    assert data["count"] == 1
    assert data["updated_at"] is not None

    saved = json.loads(fixture_log_path.read_text())
    assert saved[0]["make"] == "Martin"

    resp2 = client.get("/fixture_log")
    assert resp2.json()["records"][0]["model"] == "MAC Aura XB"


def test_fixture_log_post_wrapped_records(client, fixture_log_path):
    resp = client.post("/fixture_log", json={"records": [SAMPLE_RECORD, SAMPLE_RECORD]})
    assert resp.status_code == 200
    assert resp.json()["count"] == 2


def test_fixture_log_post_rejects_invalid_record(client):
    resp = client.post("/fixture_log", json=[{"make": "OnlyMake"}])
    assert resp.status_code == 422


def test_fixture_log_requires_auth_when_configured(auth_client, fixture_log_path):
    resp = auth_client.get("/fixture_log", headers={})
    assert resp.status_code == 401

    resp2 = auth_client.post("/fixture_log", json=[SAMPLE_RECORD], headers={})
    assert resp2.status_code == 401
