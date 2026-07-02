"""Setup route smoke tests in mock mode (MTR-07, optional beyond CI trio)."""

from __future__ import annotations


def test_discover_mock_configured(client):
    resp = client.get("/discover")
    assert resp.status_code == 200
    data = resp.json()
    assert data["configured"] is True
    assert data["manufacturer"] == "Sekonic"


def test_capture_mock_protocol(client):
    resp = client.post("/capture")
    assert resp.status_code == 200
    data = resp.json()
    assert data["success"] is True
    assert data["protocol_captured"] is True
    assert isinstance(data["cct"], int)


def test_learn_trigger_mock(client):
    resp = client.post("/learn_trigger")
    assert resp.status_code == 200
    data = resp.json()
    assert data["success"] is True
    assert data["trigger_cmd_hex"]
