#!/usr/bin/env bash
set -euo pipefail
tar -czf /tmp/gba_code_latest.tar.gz \
    --ignore-failed-read \
    project.godot export_presets.cfg default_bus_layout.tres \
    README.md PLAN.md MEMORY.md CHANGELOG.md AGENTS.md \
    native/harbor.gdextension \
    rust/Cargo.toml rust/Cargo.lock rust/src \
    scenes tests scripts prototypes
ls -lh /tmp/gba_code_latest.tar.gz
rclone copyto /tmp/gba_code_latest.tar.gz gdrive:gba-sync/gba_code_latest.tar.gz
echo "Synced to Google Drive: gba-sync/gba_code_latest.tar.gz"
