"""Bridge API key auth tests (MTR-08)."""

from __future__ import annotations

AUTH_HEADER = {"X-Bridge-Key": "test-secret"}


def test_status_requires_key_when_configured(auth_client):
    resp = auth_client.get("/status")
    assert resp.status_code == 401

    resp = auth_client.get("/status", headers=AUTH_HEADER)
    assert resp.status_code == 200
    data = resp.json()
    assert data["auth_required"] is True


def test_measure_requires_key_when_configured(auth_client):
    resp = auth_client.post("/measure")
    assert resp.status_code == 401

    resp = auth_client.post("/measure", headers=AUTH_HEADER)
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data["cct"], int)


def test_discover_requires_key_when_configured(auth_client):
    resp = auth_client.get("/discover")
    assert resp.status_code == 401

    resp = auth_client.get("/discover", headers=AUTH_HEADER)
    assert resp.status_code == 200
    data = resp.json()
    assert data["configured"] is True
