#!/usr/bin/python3
"""Keeps the backup folder an exact copy of the iCloud pages folder, deletions included.

    scripts/backup-sync.py            sync now
    scripts/backup-sync.py --dry-run  only say what would change

Files the backup no longer needs (deleted from iCloud, or about to be
overwritten by a newer version) are moved to a dated holding folder beside the
backup and purged after 7 days. A run stops without touching anything if the
iCloud folder looks empty or not mounted, if a page is still only in iCloud
after asking for it, or if more than 5% of the backup would be deleted.
"""
import datetime, os, shutil, subprocess, sys, time

HOME = os.path.expanduser("~")
SOURCE = os.path.join(HOME, "Library/Mobile Documents/iCloud~com~acdian~reader/Documents")
BACKUP = os.path.join(HOME, "Developer/acdian/Backup")
HOLDING = os.path.join(HOME, "Developer/acdian/Backup-deleted")
KEEP_DAYS, MAX_DELETE, MIN_FILES = 7, 0.05, 1000
SKIP = (".DS_Store",)
DATALESS = 0x40000000  # SF_DATALESS: the file's content is still only in iCloud


def log(message):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), message, flush=True)


def skipped(name):
    return name in SKIP or (name.startswith(".") and name.endswith(".icloud"))


def listing(root):
    """Relative paths of every file and folder under root, and the dataless files."""
    files, folders, dataless = set(), set(), []
    for parent, dirs, names in os.walk(root):
        relative = os.path.relpath(parent, root)
        for name in dirs:
            folders.add(os.path.normpath(os.path.join(relative, name)))
        for name in names:
            if skipped(name):
                continue
            path = os.path.normpath(os.path.join(relative, name))
            files.add(path)
            if os.lstat(os.path.join(parent, name)).st_flags & DATALESS:
                dataless.append(path)
    return files, folders, dataless


def download(paths):
    """Asks iCloud for pages not on this Mac and waits up to ten minutes for them."""
    for path in paths:
        subprocess.run(["brctl", "download", os.path.join(SOURCE, path)], capture_output=True)
    deadline = time.time() + 600
    while time.time() < deadline:
        left = [p for p in paths if os.lstat(os.path.join(SOURCE, p)).st_flags & DATALESS]
        if not left:
            return []
        time.sleep(10)
    return left


def purge_old():
    if not os.path.isdir(HOLDING):
        return
    limit = datetime.date.today() - datetime.timedelta(days=KEEP_DAYS)
    for name in sorted(os.listdir(HOLDING)):
        try:
            day = datetime.date.fromisoformat(name)
        except ValueError:
            continue
        if day < limit:
            shutil.rmtree(os.path.join(HOLDING, name), ignore_errors=True)
            log(f"purged holding folder {name}")


def main():
    dry = "--dry-run" in sys.argv
    source_files, source_folders, dataless = listing(SOURCE) if os.path.isdir(SOURCE) else (set(), set(), [])
    if len(source_files) < MIN_FILES:
        log(f"stopped: the iCloud folder has only {len(source_files)} files; it may not be mounted")
        return 1
    if dataless:
        log(f"{len(dataless)} pages are only in iCloud; downloading them first")
        left = [] if dry else download(dataless)
        if left:
            log(f"stopped: {len(left)} pages did not download, e.g. {left[0]}")
            return 1
    os.makedirs(BACKUP, exist_ok=True)
    backup_files, backup_folders, _ = listing(BACKUP)
    gone_files = sorted(backup_files - source_files)
    gone_folders = sorted(backup_folders - source_folders)
    if backup_files and len(gone_files) > MAX_DELETE * len(backup_files):
        log(f"stopped: {len(gone_files)} of {len(backup_files)} backup files would be deleted (over {MAX_DELETE:.0%})")
        return 1
    log(f"{len(source_files - backup_files)} new, {len(gone_files)} to delete, {len(gone_folders)} folders to delete")
    if dry:
        for path in gone_files[:20]:
            log(f"  would delete {path}")
        return 0
    hold = os.path.join(HOLDING, datetime.date.today().isoformat())
    for path in gone_files:
        target = os.path.join(hold, path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if os.path.exists(target):
            os.remove(target)
        shutil.move(os.path.join(BACKUP, path), target)
    # Deepest first, so a folder is empty by the time it is removed.
    for path in sorted(gone_folders, key=lambda p: p.count(os.sep), reverse=True):
        full = os.path.join(BACKUP, path)
        if os.path.isdir(full) and not [n for n in os.listdir(full) if not skipped(n)]:
            shutil.rmtree(full, ignore_errors=True)
    # New and changed files; overwritten versions go to the holding folder too.
    result = subprocess.run(["/usr/bin/rsync", "-a", "--backup", f"--backup-dir={hold}",
                             "--exclude=.DS_Store", "--exclude=*.icloud", SOURCE + "/", BACKUP + "/"],
                            capture_output=True, text=True)
    if result.returncode != 0:
        log(f"rsync failed: {result.stderr.strip()[:300]}")
        return 1
    after, _, _ = listing(BACKUP)
    if after != source_files:
        log(f"warning: backup differs from iCloud by {len(after ^ source_files)} files")
        return 1
    purge_old()
    log(f"done: {len(after)} files in the backup, same as iCloud; removed files are in {hold} for {KEEP_DAYS} days")
    return 0


if __name__ == "__main__":
    sys.exit(main())
