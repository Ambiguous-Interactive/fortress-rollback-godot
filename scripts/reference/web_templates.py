"""Restore the byte-verified Web subset of a pinned Godot export template archive."""
import os
from pathlib import Path
import tempfile
import zipfile

from fetch import digest

# Parent TPZ digests from pins.json and SHA-256 of their deterministic Web-only ZIP.
SUBSETS = {
    ("sha512", "476366caf0fd45a8f24136cf9cf1dc0bc2b96f7c82d53e5f82200b55aefd07b286d283fd6f1ce29e0de70648c5a51d3b12f96c6d4fafd4e8c4878ecda6406d6a"):
        "1cc4cd5550ee096eaa32f5f5927cab7728ef444e52a15dbb33d1e9694459cfd5",
    ("sha256", "f298490b8d44d934be425a5a65a51bf15f422428b229a06a6e11d9ffea248011"):
        "fbf75425ce188b8a740c296973d327f8ac935ca06a708896cec01a56e799a3fa",
}


def write_subset(parent, output):
    # The members are already compressed ZIPs. Fixed metadata, order and stored bytes give one cross-platform digest.
    with zipfile.ZipFile(parent) as original, zipfile.ZipFile(output, "w") as subset:
        for name in sorted(n for n in original.namelist() if Path(n).name.startswith("web_")):
            entry = zipfile.ZipInfo(name)
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            subset.writestr(entry, original.read(name))


def web_template_archive(pin, name, offline, cache, fetch_archive):
    expected = SUBSETS.get((pin.get("algorithm"), pin.get("digest")))
    if expected is None:
        return fetch_archive(pin, name, offline)
    directory = cache / "web-template-archives"
    if directory.is_symlink() or Path(name).name != name:
        raise ValueError("unsafe Web template cache path")
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / Path(name).with_suffix(".zip")
    if not archive.is_symlink() and archive.is_file() and digest(archive) == expected:
        return archive
    parent = fetch_archive(pin, name, offline)
    with tempfile.NamedTemporaryFile(dir=directory, delete=False) as output:
        temporary = Path(output.name)
        try:
            write_subset(parent, output)
            output.close()
            if digest(temporary) != expected:
                raise ValueError("Web template subset differs from pinned members")
            os.replace(temporary, archive)
        finally:
            temporary.unlink(missing_ok=True)
    return archive
