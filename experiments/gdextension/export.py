"""Install a binary addon in a fresh project and run an actual release export."""
import argparse
import json
import platform
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

import mobile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CACHE = ROOT / ".cache/reference"
HOST = {"Darwin": "macos", "Windows": "windows", "Linux": "linux"}[platform.system()]
ARCH = {"aarch64": "arm64", "arm64": "arm64", "amd64": "x86_64", "x86_64": "x86_64"}[platform.machine().lower()]
STEM = "fortress_gdextension_experiment"
LIB = {"macos": f"lib{STEM}.dylib", "windows": f"{STEM}.dll", "linux": f"lib{STEM}.so"}[HOST]


def install_package(project, archive_path, target):
    addon = project / "addons/fortress_native"
    pin = json.loads((ROOT / "docs/reference/pins.json").read_text())["sources"]["fortress"]
    shutil.copy(CACHE / pin["root"] / "LICENSE-MIT", addon / "Fortress-LICENSE-MIT.txt")
    manifest = addon / "fortress.template"
    native = CACHE / "target/gdextension"
    libraries = {f"{HOST}.{ARCH}": native / "release" / LIB}
    if target == "macos":
        fat = project.parent / LIB
        subprocess.run(["lipo", "-create", native / "release" / LIB,
                        native / f"x86_64-apple-darwin/release/{LIB}", "-output", fat], check=True, timeout=30)
        libraries = {"macos": fat}
    if target == "windows" and HOST != "windows":
        libraries["windows.x86_64"] = native / f"x86_64-pc-windows-gnu/release/{STEM}.dll"
    if target == "web":
        libraries["web.wasm32"] = native / f"wasm32-unknown-emscripten/release/{STEM}.wasm"
    if target in ("ios", "android"):
        libraries.update(mobile.libraries(target, native, project.parent, STEM))
    entries = []
    for tag, source in libraries.items():
        folder = addon / tag if target == "android" and tag.startswith("android.") else addon
        folder.mkdir(exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, folder / source.name)
        else:
            shutil.copy(source, folder)
        resource = (folder / source.name).relative_to(project).as_posix()
        entries.append(f'{tag} = "res://{resource}"')
    (addon / "fortress.gdextension").write_text(manifest.read_text() + "\n".join(entries) + "\n")
    manifest.unlink()
    with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(addon.rglob("*")):
            archive.write(file, file.relative_to(project))
    shutil.rmtree(addon)
    with zipfile.ZipFile(archive_path) as archive:
        archive.extractall(project)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", choices=("4.3", "4.7.2"))
    parser.add_argument("target", choices=sorted({HOST, "windows", "web", "android", "ios"}))
    parser.add_argument("--editor", type=Path)
    args = parser.parse_args()
    version = args.version
    scratch = ROOT / ".cache/native-experiment"
    scratch.mkdir(exist_ok=True)
    output = scratch / version / args.target
    output.mkdir(parents=True, exist_ok=True)
    for previous in ("qualification.json", "benchmark.json"):
        (output / previous).unlink(missing_ok=True)
    arch = "x86_64" if args.target == "windows" and HOST != "windows" else ARCH
    names = {"linux": ("Linux", f"linux_release.{ARCH}", "witness"),
             "macos": ("macOS", "macos.zip", "witness.app"),
             "windows": ("Windows Desktop", f"windows_release_{arch}.exe", "witness.exe"),
             "android": ("Android", "android_release.apk", "witness.apk"),
             "ios": ("iOS", "ios.zip", "witness.xcodeproj"),
             "web": ("Web", "web_dlink_nothreads_release.zip", "index.html")}
    name, template, artifact = names[args.target]
    with tempfile.TemporaryDirectory(dir=scratch) as tmp:
        parent = Path(tmp)
        staged = parent / "export"
        staged.mkdir()
        project = parent / "game"
        shutil.copytree(HERE / "project", project)
        shutil.copy(ROOT / "tests/oracle/reference_game.gd", project)
        install_package(project, staged / "addon.zip", args.target)
        custom = parent / template
        with zipfile.ZipFile(CACHE / f"downloads/Godot_v{version}-stable_export_templates.tpz") as templates:
            custom.write_bytes(templates.read("templates/" + template))
        options = [f'custom_template/{mode}="{custom.as_posix()}"' for mode in ("debug", "release")]
        export_arch = "universal" if args.target == "macos" else arch
        options.append(f'binary_format/architecture="{export_arch}"')
        if args.target == "windows":
            options.append("application/modify_resources=false")
        if args.target == "web":
            options += ["variant/extensions_support=true", "variant/thread_support=false"]
        if args.target in ("ios", "android"):
            options.extend(mobile.options(args.target, parent))
        if args.target == "macos":
            options += ['application/bundle_identifier="org.fortress.witness"', 'codesign/codesign=1']
        (project / "export_presets.cfg").write_text(
            f'[preset.0]\nname="{name}"\nplatform="{name}"\nrunnable=true\nexport_filter="all_resources"\n'
            'include_filter=""\nexclude_filter=""\n[preset.0.options]\n' + '\n'.join(options) + '\n')
        editor = args.editor or CACHE / f"editors/{version}/Godot_v{version}-stable_linux.{ARCH}"
        base = [editor, "--headless", "--path", project]
        actual = subprocess.check_output([editor, "--version"], text=True).strip()
        if not actual.startswith(version + ".stable."):
            raise ValueError(f"unexpected editor {actual}")
        # Early registration avoids first-scan script compilation and shutdown bugs on headless editors.
        (project / ".godot").mkdir()
        (project / ".godot/extension_list.cfg").write_text("res://addons/fortress_native/fortress.gdextension\n")
        probe = project / "package_probe.gd"
        probe.write_text('extends SceneTree\nfunc _initialize():\n\tquit(0 if ClassDB.class_exists("FortressNativeSession") else 23)\n')
        binary = project / "addons/fortress_native" / LIB
        missing = parent / LIB
        binary.rename(missing)
        probe_command = base + ["--script", "res://package_probe.gd"]
        red = subprocess.run(probe_command, capture_output=True, text=True, timeout=60)
        red_output = red.stdout + red.stderr
        missing_diagnostic = LIB in red_output or (
            "ERR_FILE_NOT_FOUND" in red_output and "res://addons/fortress_native/fortress.gdextension" in red_output
        )
        if red.returncode != 23 or not missing_diagnostic:
            raise RuntimeError("missing-library control failed: " + red.stdout + red.stderr)
        missing.rename(binary)
        green = subprocess.run(probe_command + ["--verbose"], capture_output=True, text=True, timeout=60)
        if green.returncode:
            raise RuntimeError("installed library did not register:\n" + green.stdout + green.stderr)
        probe.unlink()
        for command in (["--import"], ["--export-release", name, staged / artifact]):
            proc = subprocess.run(base + command, capture_output=True, text=True, timeout=180)
            errors = [line for line in (proc.stdout + proc.stderr).splitlines() if "ERROR:" in line]
            if HOST == "windows":
                # Godot 4.3 reports optional PDB copy failures when loading an editor DLL.
                errors = [line for line in errors if not (
                    line.startswith("ERROR: File '") and line.endswith(f"/{STEM}.pdb' does not exist.")
                )]
            if proc.returncode or errors:
                raise RuntimeError(proc.stdout + proc.stderr)
        if args.target == "ios":
            subprocess.run(["xcodebuild", "-project", staged / artifact, "-scheme", "witness",
                            "-configuration", "Release", "-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator",
                            "-derivedDataPath", staged / "build", "CODE_SIGNING_ALLOWED=NO", "build"], check=True, timeout=900)
        if not (staged / artifact).exists():
            raise RuntimeError("export command completed without producing the requested artifact")
        for item in staged.iterdir():
            destination = output / item.name
            if destination.is_dir():
                shutil.rmtree(destination)
            item.replace(destination)
        print(f"{actual} exported {output / artifact}, missing-library control exited 23")


if __name__ == "__main__":
    main()
