"""Atomic printer-key updates preserving the tenant's other secrets and permissions."""
import json
import os
import tempfile
import subprocess
from pathlib import Path


def fsync_directory(base):
    descriptor = os.open(base, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def secret_path(base):
    path = base / "app-secrets.json"
    if path.is_symlink() or not path.is_file():
        raise ValueError("Missing or symlinked secret file")
    return path


def read_key(base):
    document = json.loads(secret_path(base).read_text())
    return document.get("PrinterSettings", {}).get("ApiKey", "")


def install_key(base, key):
    path = secret_path(base)
    original = path.stat()
    document = json.loads(path.read_text())
    document.setdefault("PrinterSettings", {})["ApiKey"] = key
    descriptor, temp = tempfile.mkstemp(dir=base, prefix=".printer-secret-")
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(document, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, original.st_mode & 0o777)
        try:
            os.chown(temp, original.st_uid, original.st_gid)
        except PermissionError:
            # Provisioning assigns the backend GID (not one of rumi's groups).
            # Reuse its existing Docker capability and local alpine image, scoped
            # to this temp file. No shell interpolation or new sudo grant.
            subprocess.run(["docker", "run", "--rm", "--network", "none", "--pull", "never",
                "--user", "0", "-v", str(base) + ":/tenant", "alpine:3", "chown",
                str(original.st_uid) + ":" + str(original.st_gid), "/tenant/" + Path(temp).name],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        os.replace(temp, path)
        fsync_directory(base)
    finally:
        Path(temp).unlink(missing_ok=True)


def begin_rotation(base, desired):
    journal = base / ".printer-renewal.json"
    if journal.is_symlink():
        raise ValueError("Symlinked renewal journal")
    if journal.exists():
        data = json.loads(journal.read_text())
        if data["desired"] != desired:
            raise ValueError("Different rotation still needs recovery")
        return data["previous"]
    previous = read_key(base)
    fd, temporary = tempfile.mkstemp(dir=base, prefix=".printer-journal-")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump({"previous": previous, "desired": desired}, handle)
            handle.flush()
            os.fsync(handle.fileno())
        # link is atomic and refuses an existing journal rather than overwriting
        # recovery data; a process death can leave only an unused temp file.
        os.link(temporary, journal)
        fsync_directory(base)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return previous


def finish_rotation(base):
    (base / ".printer-renewal.json").unlink(missing_ok=True)
    fsync_directory(base)
