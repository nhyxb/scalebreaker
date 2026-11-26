#!/usr/bin/env python3
"""Fetch the Kenney 3D kits used by the harbor districts.

Only `Models/GLB format/*.glb` and the per-kit `Textures/colormap.png` atlas are
extracted. OBJ/FBX/Previews folders are never copied, and every kit lands in its
own `assets/kenney/<pack>/` directory so the six different `colormap.png`
atlases cannot overwrite each other.

Usage:
    python3 scripts/fetch_kenney_assets.py            # download missing zips, then extract
    python3 scripts/fetch_kenney_assets.py --no-download

The zip cache lives in `build/tmp/kenney/` (see MEMORY.md: /tmp does not survive
between shell commands on this machine).
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "build", "tmp", "kenney")
ASSET_ROOT = os.path.join(ROOT, "assets", "kenney")
REMOTE = "gdrive:Kenney 3D Assets"

# pack -> (zip name, [model stems without .glb])
PACKS: dict[str, tuple[str, list[str]]] = {
    "commercial": (
        "kenney_city-kit-commercial.zip",
        [
            # Midtown towers & old-harbor mid-rise blocks
            "building-a", "building-b", "building-c", "building-d", "building-e",
            "building-f", "building-g", "building-h", "building-i", "building-j",
            "building-k", "building-l", "building-m", "building-n",
            "building-skyscraper-a", "building-skyscraper-b", "building-skyscraper-c",
            "building-skyscraper-d", "building-skyscraper-e",
            # 86-200 face proxies for the far building MultiMesh (district_batches.gd)
            "low-detail-building-a", "low-detail-building-b", "low-detail-building-c",
            "low-detail-building-d", "low-detail-building-e", "low-detail-building-f",
            "low-detail-building-g", "low-detail-building-h", "low-detail-building-i",
            "low-detail-building-j",
            # Street dressing for the old harbor core and plazas
            "detail-awning", "detail-awning-wide",
            "detail-parasol-a", "detail-parasol-b",
        ],
    ),
    "industrial": (
        "kenney_city-kit-industrial.zip",
        [
            # Container terminal warehouses
            "building-h", "building-i", "building-j", "building-k", "building-p", "building-s",
            # Refinery halls, tank farm and stacks
            "building-a", "building-b", "building-e", "building-f", "building-m",
            "detail-tank", "detail-tank-large",
            "chimney-large", "chimney-medium", "chimney-basic",
            "water-tower",
            # Shipyard assembly halls
            "building-c", "building-l", "building-q", "building-r", "building-t",
        ],
    ),
    "roads": (
        "kenney_city-kit-roads.zip",
        ["light-curved", "light-square"],
    ),
    "suburban": (
        "kenney_city-kit-suburban.zip",
        [
            "building-type-a", "building-type-b", "building-type-c", "building-type-d",
            "building-type-e", "building-type-f", "building-type-g", "building-type-h",
            "building-type-i", "building-type-j",
            "tree-large", "tree-small", "planter",
        ],
    ),
    "watercraft": (
        "kenney_watercraft-kit.zip",
        [
            "cargo-container-a", "cargo-container-b", "cargo-container-c",
            "cargo-pile-a", "cargo-pile-b",
            "boat-tug-a", "boat-tug-b", "boat-tow-a", "boat-tow-b",
            "ship-cargo-a", "ship-cargo-b", "ship-cargo-c",
            "ship-ocean-liner", "ship-ocean-liner-small",
            "boat-fishing-small", "buoy",
        ],
    ),
    "car": (
        "kenney_car-kit.zip",
        [
            "sedan", "suv", "taxi", "van", "delivery", "truck",
            "police", "firetruck", "ambulance",
        ],
    ),
    "furniture": (
        "kenney_furniture-kit.zip",
        [
            "desk", "chairDesk",
            "computerScreen", "computerKeyboard", "computerMouse",
            "lampRoundTable", "books", "bear", "plantSmall1", "speakerSmall",
            "bedDouble", "pillow", "pillowLong", "cabinetBedDrawer",
            "bookcaseOpen", "bookcaseClosedDoors", "rugRounded", "pottedPlant",
            "lampSquareCeiling", "trashcan", "coatRackStanding",
        ],
    ),
}


def download(pack: str, zip_name: str) -> str:
    os.makedirs(CACHE, exist_ok=True)
    target = os.path.join(CACHE, zip_name)
    if os.path.exists(target) and os.path.getsize(target) > 0:
        return target
    print(f"rclone copyto {REMOTE}/{zip_name}")
    subprocess.run(
        ["rclone", "copyto", f"{REMOTE}/{zip_name}", target],
        check=True,
    )
    return target


def extract(pack: str, zip_path: str, stems: list[str]) -> int:
    out_dir = os.path.join(ASSET_ROOT, pack)
    os.makedirs(out_dir, exist_ok=True)
    written = 0
    with zipfile.ZipFile(zip_path) as archive:
        names = set(archive.namelist())
        model_dir = (
            "Models/GLB format"
            if any(n.startswith("Models/GLB format/") for n in names)
            else "Models/GLTF format"
        )
        for stem in stems:
            member = f"{model_dir}/{stem}.glb"
            if member not in names:
                raise SystemExit(f"{zip_path}: missing {member}")
            with archive.open(member) as src:
                data = src.read()
            with open(os.path.join(out_dir, f"{stem}.glb"), "wb") as dst:
                dst.write(data)
            written += 1
        atlas = f"{model_dir}/Textures/colormap.png"
        if atlas in names:
            tex_dir = os.path.join(out_dir, "Textures")
            os.makedirs(tex_dir, exist_ok=True)
            with archive.open(atlas) as src:
                data = src.read()
            with open(os.path.join(tex_dir, "colormap.png"), "wb") as dst:
                dst.write(data)
    return written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-download", action="store_true",
                        help="use the zips already cached in build/tmp/kenney")
    args = parser.parse_args()

    total = 0
    for pack, (zip_name, stems) in PACKS.items():
        zip_path = os.path.join(CACHE, zip_name)
        if args.no_download:
            if not os.path.exists(zip_path):
                raise SystemExit(f"missing cached zip: {zip_path}")
        else:
            zip_path = download(pack, zip_name)
        count = extract(pack, zip_path, stems)
        total += count
        print(f"{pack:<12} {count:>2} glb -> assets/kenney/{pack}/")

    # Guard rails: nothing but GLB models plus the per-kit atlas may land here.
    for root, _dirs, files in os.walk(ASSET_ROOT):
        for name in files:
            if name.endswith((".obj", ".fbx", ".mtl", ".bin")):
                raise SystemExit(f"forbidden source asset copied: {os.path.join(root, name)}")
    print(f"done: {total} glb across {len(PACKS)} kits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
