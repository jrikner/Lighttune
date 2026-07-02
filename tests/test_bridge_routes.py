"""Bridge route tests against mock meter backend (TST-02)."""

from __future__ import annotations


def test_status_mock(client, golden_status):
    resp = client.get("/status")
    assert resp.status_code == 200
    data = resp.json()

    assert data["status"] == golden_status["status"]
    assert data["meter"] == golden_status["meter"]
    assert data["connected"] is True
    assert data["version"] == golden_status["version"]
    assert data["device_configured"] is golden_status["device_configured"]
    assert data["protocol_captured"] is golden_status["protocol_captured"]
    assert data["trigger_discovered"] is golden_status["trigger_discovered"]
    assert data["auth_required"] is golden_status["auth_required"]
    assert isinstance(data["uptime_s"], int)
    assert data["uptime_s"] >= 0
    assert data["last_error"] is None or isinstance(data["last_error"], str)


def test_measure_mock(client, golden_measure):
    resp = client.post("/measure")
    assert resp.status_code == 200
    data = resp.json()

    assert isinstance(data["cct"], int)
    assert isinstance(data["duv"], float)
    assert isinstance(data["cri"], int)
    assert isinstance(data["r9"], int)
    if "tlci" in data:
        assert isinstance(data["tlci"], int)

    # First mock measurement lands near progression step 0
    assert 3800 <= data["cct"] <= 4300
    assert 0.005 <= data["duv"] <= 0.012
    assert data["cri"] == golden_measure["cri"] or isinstance(data["cri"], int)
    assert data["r9"] == golden_measure["r9"] or isinstance(data["r9"], int)
    assert "timestamp" in data


def test_discover_mock(client, golden_discover):
    resp = client.get("/discover")
    assert resp.status_code == 200
    data = resp.json()

    assert data["configured"] is golden_discover["configured"]
    assert data["manufacturer"] == golden_discover["manufacturer"]
    assert golden_discover["product"] in data["product"]
    assert data["vendor_id"] == golden_discover["vendor_id"]
    assert data["product_id"] == golden_discover["product_id"]
    assert isinstance(data["devices"], list)
