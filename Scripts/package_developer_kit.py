#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build deterministic kit archives in a caller-chosen, new output directory."""
import argparse
import json
from pathlib import Path
import zipfile
from validate_developer_kit import KIT_VERSION, NAME, PLUGIN, SKILL, files, require, safe_name, sha, validate_plugin


def archive(path, payload):
    require(not path.exists(), "refusing to replace an existing archive")
    records = [{"path": p, "bytes": len(b), "sha256": sha(b)} for p, b in sorted(payload.items())]
    manifest = {"schema_version": 1, "self_excluded": True, "files": records}
    payload = {**payload, NAME + "/MANIFEST.json": (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode()}
    with zipfile.ZipFile(path, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
        for name, data in sorted(payload.items()):
            safe_name(name)
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            output.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    require(path.stat().st_size < 1_048_576, "an archive exceeds one MiB")
    return {"name": path.name, "bytes": path.stat().st_size, "sha256": sha(path.read_bytes())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    validate_plugin()
    require(not args.output.exists(), "choose a new output directory")
    args.output.mkdir(parents=True)
    result = []
    for kind, source in (("plugin", PLUGIN), ("skill", SKILL)):
        name = "%s-%s-%s.zip" % (NAME, kind, KIT_VERSION)
        result.append(archive(args.output / name, {NAME + "/" + p: b for p, b in files(source).items()}))
    (args.output / "ASSETS.json").write_text(json.dumps({"kit_version": KIT_VERSION, "files": result}, sort_keys=True, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
