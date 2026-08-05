"""Regression tests for the live treadmill client."""

from z1_walkingpad_mcp import client as client_module
from z1_walkingpad_mcp import protocol as p


def telemetry_frame(*, speed_kmh: float, distance_m: int, elapsed_s: int, steps: int) -> bytes:
    """Build the Z1's observed FTMS telemetry vector."""
    speed_raw = round(speed_kmh * 100)
    return bytes([
        0x04,
        0x24,
        speed_raw & 0xFF,
        speed_raw >> 8,
        distance_m & 0xFF,
        (distance_m >> 8) & 0xFF,
        (distance_m >> 16) & 0xFF,
        elapsed_s & 0xFF,
        elapsed_s >> 8,
        steps & 0xFF,
        steps >> 8,
    ])


def test_live_display_and_summary_relay_the_raw_pad_counter(
    monkeypatch, tmp_path
):
    monkeypatch.setattr(client_module, "CALORIE_STATE_FILE", tmp_path / "calorie-state.json")
    treadmill = client_module.Z1Treadmill()
    treadmill._calorie_state_restored = True

    treadmill._on_treadmill_data(
        None,
        telemetry_frame(speed_kmh=3.5, distance_m=10, elapsed_s=10, steps=20),
    )
    treadmill._on_treadmill_data(
        None,
        telemetry_frame(speed_kmh=3.5, distance_m=10, elapsed_s=11, steps=21),
    )

    assert p.parse_treadmill_data(treadmill.status.raw).steps == 21
    assert treadmill.steps_display == 21
    assert treadmill.steps_summary == 21


def test_slow_speed_session_summary_returns_raw_pad_steps(monkeypatch, tmp_path):
    """Regression: the hardware step counter is canonical everywhere. The
    old distance/stride estimator overrode summaries after calibration,
    undercounting this slow-speed case (about 53 estimated vs. 100 raw).
    The summary must report the exact raw hardware count."""
    monkeypatch.setattr(client_module, "CALORIE_STATE_FILE", tmp_path / "calorie-state.json")
    treadmill = client_module.Z1Treadmill()
    treadmill._calorie_state_restored = True

    # slow walking (2.0 km/h): the pad counted 100 steps over 40 m
    treadmill._on_treadmill_data(
        None,
        telemetry_frame(speed_kmh=2.0, distance_m=40, elapsed_s=72, steps=100),
    )

    assert treadmill.steps_summary == 100
    assert treadmill.session_summary()["steps"] == 100
