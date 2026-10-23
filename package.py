import os, sys, shutil, zipfile
from pathlib import Path
app, output = map(Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output / 'ACdian-macOS.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(app.rglob('*')):
        if path.is_file():
            info = zipfile.ZipInfo(str(Path('ACdian.app') / path.relative_to(app)))
            info.external_attr = (0o100000 | (path.stat().st_mode & 0o777)) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, path.read_bytes())
# A directly openable copy as well as the ZIP; no cloud-storage metadata copied.
destination = output / 'ACdian.app'
for root, dirs, files in os.walk(app):
    target = destination / Path(root).relative_to(app)
    target.mkdir(parents=True, exist_ok=True)
    for name in files:
        src = Path(root) / name
        shutil.copyfile(src, target / name)
        os.chmod(target / name, src.stat().st_mode & 0o777)
print(output / 'ACdian-macOS.zip')
