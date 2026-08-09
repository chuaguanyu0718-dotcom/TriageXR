#!/usr/bin/env python3
"""Generate short, original PCM earcons used by TriageXR."""

from __future__ import annotations

import math
import struct
import wave
from pathlib import Path


SAMPLE_RATE = 44_100
OUTPUT_DIR = Path(__file__).resolve().parents[1] / "Resources"


def envelope(index: int, sample_count: int) -> float:
    attack = max(1, int(SAMPLE_RATE * 0.012))
    release = max(1, int(SAMPLE_RATE * 0.08))
    if index < attack:
        return index / attack
    if index > sample_count - release:
        return max(0.0, (sample_count - index) / release)
    return 1.0


def write_tones(filename: str, tones: list[tuple[float, float]], volume: float = 0.32) -> None:
    samples: list[int] = []
    for frequency, duration in tones:
        sample_count = int(SAMPLE_RATE * duration)
        for index in range(sample_count):
            phase = 2 * math.pi * frequency * index / SAMPLE_RATE
            value = math.sin(phase) + 0.18 * math.sin(phase * 2)
            samples.append(int(32767 * volume * envelope(index, sample_count) * value / 1.18))
        samples.extend([0] * int(SAMPLE_RATE * 0.035))

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUTPUT_DIR / filename), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(b"".join(struct.pack("<h", value) for value in samples))


def main() -> None:
    write_tones("SurveyConfirm.wav", [(620, 0.10), (780, 0.12)], 0.24)
    write_tones("SurveyComplete.wav", [(520, 0.10), (700, 0.10), (920, 0.18)], 0.27)
    write_tones("HazardAlert.wav", [(310, 0.15), (245, 0.18)], 0.25)


if __name__ == "__main__":
    main()
