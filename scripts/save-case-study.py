#!/usr/bin/env python3
"""Save a case study Markdown file into ACdian's "Case Study" module.

Usage: save-case-study.py [file.md]   (reads stdin when no file is given)
Vault root: $ACDIAN_VAULT, else the app's pagesPath setting, else ACdian's iCloud folder.
"""
import json, os, re, subprocess, sys
from pathlib import Path

MODULE = os.environ.get("ACDIAN_CASE_MODULE", "Case Study")


def vault_root():
    if os.environ.get("ACDIAN_VAULT"):
        return Path(os.environ["ACDIAN_VAULT"]).expanduser()
    try:
        path = subprocess.run(["defaults", "read", "com.acdian.reader", "pagesPath"],
                              capture_output=True, text=True, check=True).stdout.strip()
        if path:
            return Path(path)
    except (OSError, subprocess.CalledProcessError):
        pass
    return Path.home() / "Library/Mobile Documents/iCloud~com~acdian~reader/Documents"


def norm(s):
    return re.sub(r"[\s_-]", "", s).lower()


def module_folder(root):
    want = norm(MODULE)
    try:
        modules = json.loads((root / ".acdian-modules.json").read_text())["modules"]
        for m in modules:
            if want in (norm(m.get("name", "")), norm(m.get("folder", ""))):
                return root / m["folder"]
    except (OSError, ValueError, KeyError):
        pass
    for d in root.iterdir():
        if d.is_dir() and norm(d.name) == want:
            return d
    sys.exit(f"在 {root} 里没有找到「{MODULE}」模块")


def file_name(text):
    m = re.search(r"^#\s*(?:【Case】)?\s*(.+?)\s*(?:\(\d{4}\.\d{2}\.\d{2}\))?\s*$", text, re.M)
    name = m.group(1) if m else "Case Study"
    return re.sub(r'[/\\:*?"<>|]', "-", name).strip() or "Case Study"


def main():
    text = Path(sys.argv[1]).read_text() if len(sys.argv) > 1 else sys.stdin.read()
    if not text.strip():
        sys.exit("内容为空")
    root = vault_root()
    if not root.is_dir():
        sys.exit(f"找不到 ACdian 页面库：{root}")
    folder = module_folder(root)
    base = file_name(text)
    target, n = folder / f"{base}.md", 2
    while target.exists():
        target, n = folder / f"{base} {n}.md", n + 1
    tmp = target.with_name(f".{target.name}.tmp")
    tmp.write_text(text if text.endswith("\n") else text + "\n")
    tmp.replace(target)
    print(target)


if __name__ == "__main__":
    main()
