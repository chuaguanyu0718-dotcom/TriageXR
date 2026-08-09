#!/usr/bin/env python3
"""CI-safe structural checks for TriageXR's bundled spatial and audio assets."""

from __future__ import annotations

import struct
import wave
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODEL_NAMES = ["CasualtyAlex", "CasualtyJordan", "CasualtySam", "CollisionVehicle"]
AUDIO_NAMES = ["SurveyConfirm", "SurveyComplete", "HazardAlert"]


def data_offset(archive: Path, info: zipfile.ZipInfo) -> int:
    with archive.open("rb") as source:
        source.seek(info.header_offset)
        header = source.read(30)
    if len(header) != 30 or header[:4] != b"PK\x03\x04":
        raise AssertionError(f"{archive.name}: invalid local ZIP header")
    name_length, extra_length = struct.unpack("<HH", header[26:30])
    return info.header_offset + 30 + name_length + extra_length


def validate_usdz(name: str) -> None:
    archive = ROOT / "Models" / f"{name}.usdz"
    assert archive.exists() and archive.stat().st_size > 4_096, f"Missing model: {archive}"
    with zipfile.ZipFile(archive) as bundle:
        entries = bundle.infolist()
        assert entries, f"{archive.name}: empty archive"
        roots = [entry for entry in entries if "/" not in entry.filename and entry.filename.endswith((".usd", ".usda", ".usdc"))]
        assert len(roots) == 1, f"{archive.name}: expected one root USD layer"
        assert entries[0].filename == roots[0].filename, f"{archive.name}: root layer must be first"
        assert all(entry.compress_type == zipfile.ZIP_STORED for entry in entries), f"{archive.name}: USDZ entries must be uncompressed"
        assert all(data_offset(archive, entry) % 64 == 0 for entry in entries), f"{archive.name}: entry alignment is not 64-byte safe"
        assert all(not entry.filename.lower().endswith(".exr") for entry in entries), f"{archive.name}: unsupported EXR remained in bundle"
        assert all(".." not in Path(entry.filename).parts for entry in entries), f"{archive.name}: unsafe archive path"


def validate_audio(name: str) -> None:
    path = ROOT / "Resources" / f"{name}.wav"
    with wave.open(str(path), "rb") as audio:
        assert audio.getnchannels() == 1, f"{path.name}: expected mono"
        assert audio.getsampwidth() == 2, f"{path.name}: expected 16-bit PCM"
        assert audio.getframerate() == 44_100, f"{path.name}: unexpected sample rate"
        duration = audio.getnframes() / audio.getframerate()
        assert 0.1 <= duration <= 1.0, f"{path.name}: cue duration out of range"


def main() -> None:
    for model in MODEL_NAMES:
        validate_usdz(model)
    for cue in AUDIO_NAMES:
        validate_audio(cue)
    panorama = ROOT / "Resources" / "RoadsidePanorama.png"
    assert panorama.exists() and panorama.stat().st_size > 10_000, "Roadside panorama is missing or empty"
    print(f"Validated {len(MODEL_NAMES)} USDZ models, {len(AUDIO_NAMES)} audio cues, and the panorama.")


if __name__ == "__main__":
    main()
