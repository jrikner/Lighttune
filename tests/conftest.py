"""Pytest fixtures for sekonic-bridge route tests (mock meter, no USB)."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest
from starlette.testclient import TestClient

REPO_ROOT = Path(__file__).resolve().parent.parent
BRIDGE_DIR = REPO_ROOT / "sekonic-bridge"
FIXTURES_DIR = REPO_ROOT / "tests" / "fixtures"

sys.path.insert(0, str(BRIDGE_DIR))

import server as bridge_server  # noqa: E402


@pytest.fixture(scope="session")
def golden_status() -> dict:
    import json

    return json.loads((FIXTURES_DIR / "bridge_status_ok.json").read_text())


@pytest.fixture(scope="session")
def golden_measure() -> dict:
    import json

    return json.loads((FIXTURES_DIR / "bridge_measure_ok.json").read_text())


@pytest.fixture(scope="session")
def golden_discover() -> dict:
    import json

    return json.loads((FIXTURES_DIR / "bridge_discover_mock.json").read_text())


@pytest.fixture
def client():
    bridge_server._use_mock_global = True
    with TestClient(bridge_server.app) as test_client:
        yield test_client
