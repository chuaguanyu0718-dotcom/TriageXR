#!/usr/bin/env python3
"""Remove the broken embedded dome light from TriageXR's generated USDZ assets."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path


def run(*arguments: str, working_directory: Path | None = None) -> None:
    subprocess.run(
        arguments,
        cwd=working_directory,
        check=True,
        text=True,
    )


def remove_environment_light(source: str) -> str:
    marker = 'def DomeLight "env_light"'
    marker_index = source.find(marker)
    if marker_index < 0:
        if "color_0C0C0C.exr" in source:
            raise ValueError("broken EXR remains without an env_light prim")
        return source

    line_start = source.rfind("\n", 0, marker_index) + 1
    opening_brace = source.find("{", marker_index)
    if opening_brace < 0:
        raise ValueError("env_light opening brace was not found")

    depth = 0
    closing_brace = None
    for index in range(opening_brace, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                closing_brace = index + 1
                break

    if closing_brace is None:
        raise ValueError("env_light closing brace was not found")

    if closing_brace < len(source) and source[closing_brace] == "\n":
        closing_brace += 1
    repaired = source[:line_start] + source[closing_brace:]
    if "color_0C0C0C.exr" in repaired:
        raise ValueError("broken EXR reference remains after repair")
    return repaired


def repair(asset: Path) -> None:
    asset = asset.resolve()
    with tempfile.TemporaryDirectory(prefix="triagexr-usdz-") as temporary:
        work = Path(temporary)
        package = work / "package"
        package.mkdir()
        with zipfile.ZipFile(asset) as archive:
            archive.extractall(package)
        source_layer = work / f"{asset.stem}.usda"
        compiled_layer = package / f"{asset.stem}.usdc"
        repaired_package = work / asset.name

        run("usdcat", str(asset), "-o", str(source_layer))
        source = source_layer.read_text(encoding="utf-8")
        source_layer.write_text(remove_environment_light(source), encoding="utf-8")
        run("usdcat", str(source_layer), "-o", str(compiled_layer))
        broken_texture = package / "textures" / "color_0C0C0C.exr"
        if broken_texture.exists():
            broken_texture.unlink()

        package_inputs = [compiled_layer.name]
        textures = package / "textures"
        if textures.exists() and any(textures.iterdir()):
            package_inputs.append("textures")
        run(
            "usdzip",
            "-r",
            str(repaired_package),
            *package_inputs,
            working_directory=package,
        )
        run("usdchecker", "--arkit", str(repaired_package))
        shutil.copyfile(repaired_package, asset)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("assets", nargs="+", type=Path)
    arguments = parser.parse_args()
    for asset in arguments.assets:
        repair(asset)
        print(f"Repaired {asset}")


if __name__ == "__main__":
    main()
