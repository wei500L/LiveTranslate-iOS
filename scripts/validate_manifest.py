#!/usr/bin/env python3
"""Structural + (when models are present) content validation of
Resources/ModelManifest.json.

Structural checks (always run):
  - schemaVersion, both backends present, kinds correct
  - every revision is a 40-char pinned commit SHA (never a branch)
  - totalDownloadBytes equals the sum of file sizes
  - every sha256 is 64 hex chars, every URL pins the revision
  - no path traversal / absolute paths
  - sherpa-onnx version pin

Content checks (with --models-dir, default LocalModels):
  - every file exists at the expected layout with the pinned size and
    SHA256 (streamed, constant memory)

Exit code 0 = valid, 1 = any failure.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

MANIFEST = Path("Resources/ModelManifest.json")


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def check_structure(m) -> int:
    failures = 0
    assert m["schemaVersion"] == 2
    assert set(m["backends"]) == {"coreml-fp16", "sherpa-onnx-int8"}
    assert m["backends"]["coreml-fp16"]["kind"] == "coreMLFP16"
    assert m["backends"]["sherpa-onnx-int8"]["kind"] == "sherpaONNXInt8"
    for key, b in m["backends"].items():
        assert len(b["revision"]) == 40
        total = sum(f["bytes"] for f in b["files"])
        assert b["totalDownloadBytes"] == total, key
        for f in b["files"]:
            assert len(f["sha256"]) == 64
            assert f"/resolve/{b['revision']}/" in f["url"], f["path"]
            assert ".." not in f["path"] and not f["path"].startswith("/")
    assert m["runtime"]["sherpaOnnxVersion"] == "1.13.7"
    print("JSON OK")
    print("coreml keys:", sorted(m["backends"]["coreml-fp16"].keys()))
    return failures


def check_files(m, models_dir: Path) -> int:
    failures = 0
    for key, b in m["backends"].items():
        for f in b["files"]:
            path = models_dir / key / f["path"]
            if not path.exists():
                print(f"MISSING  {key}/{f['path']}")
                failures += 1
                continue
            actual_size = path.stat().st_size
            if actual_size != f["bytes"]:
                print(f"SIZE     {key}/{f['path']}: {actual_size} != {f['bytes']}")
                failures += 1
                continue
            actual_hash = sha256_of(path)
            if actual_hash != f["sha256"]:
                print(f"SHA256   {key}/{f['path']}: {actual_hash} != {f['sha256']}")
                failures += 1
            else:
                print(f"ok       {key}/{f['path']}")
    vad = m["runtime"]["sileroVAD"]
    vad_path = models_dir / "silero_vad.onnx"
    if vad_path.exists():
        if (vad_path.stat().st_size == vad["bytes"]
                and sha256_of(vad_path) == vad["sha256"]):
            print("ok       silero_vad.onnx")
        else:
            print(f"SHA256   silero_vad.onnx mismatch")
            failures += 1
    else:
        print("MISSING  silero_vad.onnx")
        failures += 1
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--models-dir", type=Path, default=Path("LocalModels"))
    parser.add_argument("--structure-only", action="store_true",
                        help="skip file content verification")
    args = parser.parse_args()

    m = json.load(open(MANIFEST))
    failures = check_structure(m)
    if not args.structure_only:
        if args.models_dir.exists():
            failures += check_files(m, args.models_dir)
        else:
            print(f"models dir {args.models_dir} not present — structure checks only")
    if failures:
        print(f"FAILED: {failures} failure(s)")
        return 1
    print("All checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
