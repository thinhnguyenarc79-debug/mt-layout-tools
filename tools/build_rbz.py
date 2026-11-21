#!/usr/bin/env python3
"""Đóng gói src/ thành dist/mt_layout_tools.rbz và ghi version.json (kèm SHA-256).

Cách dùng:  python3 tools/build_rbz.py "Ghi chú bản phát hành"
Phiên bản lấy từ src/mt_layout_tools/version.rb.
"""
import hashlib, json, re, sys, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
DIST = ROOT / "dist"
REPO = "thinhnguyenarc79-debug/mt-layout-tools"

version = re.search(r"VERSION\s*=\s*'([^']+)'", (SRC / "mt_layout_tools/version.rb").read_text("utf-8")).group(1)
notes = sys.argv[1] if len(sys.argv) > 1 else ""

DIST.mkdir(exist_ok=True)
rbz = DIST / "mt_layout_tools.rbz"
with zipfile.ZipFile(rbz, "w", zipfile.ZIP_DEFLATED) as z:
    for p in sorted(SRC.rglob("*")):
        if p.is_file():
            info = zipfile.ZipInfo(p.relative_to(SRC).as_posix(), date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, p.read_bytes())

sha = hashlib.sha256(rbz.read_bytes()).hexdigest()
manifest = {
    "version": version,
    "rbz_url": f"https://raw.githubusercontent.com/{REPO}/main/dist/mt_layout_tools.rbz",
    "sha256": sha,
    "notes": notes,
}
(ROOT / "version.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", "utf-8")
print(f"Built {rbz.name} v{version} sha256={sha}")
