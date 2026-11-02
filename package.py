import sys, zipfile
from pathlib import Path
app, output = map(Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
# Only the ZIP: an openable .app here would be a second copy that Spotlight and "Open With" can find.
with zipfile.ZipFile(output / 'ACdian-macOS.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(app.rglob('*')):
        if path.is_file():
            info = zipfile.ZipInfo(str(Path('ACdian.app') / path.relative_to(app)))
            info.external_attr = (0o100000 | (path.stat().st_mode & 0o777)) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, path.read_bytes())
print(output / 'ACdian-macOS.zip')
