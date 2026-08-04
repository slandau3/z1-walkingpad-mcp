"""Regression tests for the live treadmill client."""

from z1_walkingpad_mcp import client as client_module
from z1_walkingpad_mcp import protocol as p
from z1_walkingpad_mcp.stride import StrideLearner


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


def test_calibrated_live_display_keeps_step_delta_when_distance_does_not_tick(
    monkeypatch, tmp_path
):
    monkeypatch.setattr(client_module, "CALORIE_STATE_FILE", tmp_path / "calorie-state.json")
    treadmill = client_module.Z1Treadmill()
    treadmill.stride = StrideLearner(state_file=tmp_path / "stride.json")
    treadmill.stride.learn(distance_m=120, steps=160, speed_kmh=3.5)
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
