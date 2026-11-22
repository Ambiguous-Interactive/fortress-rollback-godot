"""Build, export, and run the mixed-peer matrix on the target runner."""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

from export import ARCH, CACHE, HERE, HOST, MACOS_CROSS_TARGET, ROOT, SCRATCH, editor_archive, prepared_editor

sys.path.insert(0, str(ROOT / "scripts/reference"))
from fetch import digest, fetch, load_manifest, prepare_zip, sources

# SHA512-SUMS.txt from the matching official Godot releases.
EDITOR_SHA512 = {
    ("4.3", "macos"): "8a556637aa6b83a60473decdb43a448b214f31fd13318b6f7ba2ebc4cca4e40d1f7a933330ce40afa8d72273ef6a6f3a0e3b0f0abf8e1be3fe4f03119cae62c2",
    ("4.3", "windows"): "ad09b7e19949327700dfbe64e35880a2a08091c0751277f5cc21b915e5df9b4fe93fb43c50d6bdfb9d16b46168592491aa698e0d2dbe9f92132e163dd77b97e1",
    ("4.7.2", "macos"): "38aa16e5bba2083941fc5b3e54be0089bd4cc35e32415f5b9fd9a8a6a7b9818255d44532ea8ef94b5aef56c4b407c2d634fa4f657e4ebe681ebbf59b7bac69ca",
    ("4.7.2", "windows"): "83decd58fdf67b9d657958a1ae6bf1929c20785315a81effe245874cdc57acb709bf868e00778a96984338c1b29dafdb453c6847747694621c6ecf5da2259993",
}


def editor(data, version):
    name = editor_archive(version)
    pin = data["artifacts"].get(name)
    if pin is None:
        pin = dict(url=f"https://github.com/godotengine/godot/releases/download/{version}-stable/{name}",
                   digest=EDITOR_SHA512[version, HOST], algorithm="sha512")
    archive = fetch(pin, name)
    dest = SCRATCH / "editors" / version
    if HOST == "macos":
        subprocess.run(["ditto", "-x", "-k", archive, dest], check=True)
    else:
        prepare_zip(archive, dest, executable_members=(name.removesuffix(".zip"),))
    return prepared_editor(version)


def qualify_driver(binary, addon):
    with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
        project = Path(directory)
        for relative in ("addons/fortress_rollback", "examples/offline"):
            shutil.copytree(ROOT / relative, project / relative)
        with zipfile.ZipFile(addon) as package:
            package.extractall(project)
        (project / "project.godot").write_text('config_version=5\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
        (project / ".godot").mkdir()
        (project / ".godot/extension_list.cfg").write_text("res://addons/fortress_native/fortress.gdextension\n")
        script = "qualify_native_driver.gd"
        shutil.copyfile(ROOT / "scripts" / script, project / script)
        command = [str(binary), "--headless", "--path", str(project)]
        subprocess.run(command + ["--editor", "--import", "--quit"], check=True, timeout=120)
        command += ["--script", script]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        print(result.stdout, end="")
        if result.returncode != 0:
            raise RuntimeError(result.stderr)
        control = subprocess.run(command + ["--", "--wrong-sample"], capture_output=True, text=True, timeout=60)
        if control.returncode != 1 or "incorrect confirmed input at frame 12" not in control.stderr:
            raise RuntimeError(f"native driver's wrong-sample control did not fail as expected: {control.stdout}\n{control.stderr}")
        diagnostic = "incorrect confirmed input at frame 12"
        print(f"Native driver control rejected: {diagnostic}")
        return {"layouts": [line for line in result.stdout.splitlines() if line.startswith("Native driver slots=")], "negative_control": diagnostic}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", choices=["4.3", "4.7.2"])
    parser.add_argument("target", choices=[HOST, "android", "ios", "web"])
    args = parser.parse_args()
    target, version = args.target, args.version
    directory = ROOT / ".cache/native-experiment" / version / target
    for previous in ("qualification.json", "benchmark.json", "prediction-stall.json"):
        (directory / previous).unlink(missing_ok=True)
    data = load_manifest()
    sources(dict(data, sources={"fortress": data["sources"]["fortress"]}))
    templates = f"Godot_v{version}-stable_export_templates.tpz"
    fetch(data["artifacts"][templates], templates)
    binary = editor(data, version)
    native = CACHE / "target/gdextension"
    env = dict(os.environ, CARGO_TARGET_DIR=str(native))
    cargo = ["cargo", "build", "--manifest-path", HERE / "Cargo.toml", "--locked", "--release"]
    subprocess.run(cargo + ["--lib"], env=env, check=True)
    # Both feature sets can emit a cdylib with the same filename, particularly on Windows.
    peer_target = native / "reference"
    subprocess.run(cargo + ["--no-default-features", "--features", "peer", "--bins", "--target-dir", peer_target], env=env, check=True)
    if target == "web":
        subprocess.run(["bash", HERE / "build_web.sh"], env=dict(env, RUSTUP_TOOLCHAIN="nightly-2026-02-01"), check=True)
    if target == "android":
        sdk = Path(env["ANDROID_HOME"])
        ndk = Path(env["ANDROID_NDK_HOME"]) / "toolchains/llvm/prebuilt/linux-x86_64/bin"
        env["XDG_CONFIG_HOME"] = str(ROOT / ".cache/native-android-config")
        config = Path(env["XDG_CONFIG_HOME"]) / "godot"
        config.mkdir(parents=True, exist_ok=True)
        minor = ".".join(version.split(".")[:2])
        (config / f"editor_settings-{minor}.tres").write_text(
            '[gd_resource type="EditorSettings" format=3]\n[resource]\n'
            f'export/android/android_sdk_path="{sdk.as_posix()}"\nexport/android/java_sdk_path="{Path(env["JAVA_HOME"]).as_posix()}"\n')
        for abi in ("aarch64-linux-android", "x86_64-linux-android"):
            env["CARGO_TARGET_" + abi.replace("-", "_").upper() + "_LINKER"] = str(ndk / f"{abi}24-clang")
            subprocess.run(cargo + ["--target", abi, "--lib"], check=True, env=env)
    if target == "macos":
        subprocess.run(cargo + ["--target", MACOS_CROSS_TARGET, "--lib"], check=True, env=env)
    if target == "ios":
        for abi in ("aarch64-apple-ios", "aarch64-apple-ios-sim"):
            subprocess.run(cargo + ["--target", abi, "--lib"], check=True, env=env)
    subprocess.run([sys.executable, HERE / "export.py", version, target, "--editor", binary], check=True, env=env)
    outputs = {"linux": "witness", "windows": "witness.exe", "macos": "witness.app", "android": "witness.apk",
               "web": "index.html", "ios": "build/Build/Products/Release-iphonesimulator/witness.app"}
    opts = ["--device", target] if target in ("android", "ios") else []
    peer = peer_target / "release" / ("reference-peer.exe" if HOST == "windows" else "reference-peer")
    variants = [(engine, ["--engine", engine, "--browser", "default"]) for engine in ("chromium", "firefox", "webkit")] if target == "web" else [(target, opts)]
    receipts = {}
    for label, extra in variants:
        result = subprocess.check_output([sys.executable, HERE / "matrix.py", "--", "--export", directory / outputs[target],
                                          "--peer", peer, *extra], text=True, env=env)
        receipts[label] = json.loads(result)
    receipt = {"version": version, "host": HOST, "architecture": ARCH, "target": target,
               "fortress_revision": data["sources"]["fortress"]["revision"],
               "addon_sha256": digest(directory / "addon.zip"), "runs": receipts}
    if target == "linux":
        receipt["driver"] = qualify_driver(binary, directory / "addon.zip")
        stall = subprocess.check_output([sys.executable, HERE / "qualify.py", "--export", directory / outputs[target],
                                         "--peer", peer, "--stall"], text=True, env=env)
        (directory / "prediction-stall.json").write_text(json.dumps(json.loads(stall.splitlines()[-1]), indent=2) + "\n")
        measurements = subprocess.check_output([sys.executable, HERE / "benchmark.py", version, "--editor", binary, "--rust-peer-dir", peer.parent], text=True, env=env)
        (directory / "benchmark.json").write_text(json.dumps([json.loads(line) for line in measurements.splitlines()], indent=2) + "\n")
    partial = directory / "qualification.tmp"
    partial.write_text(json.dumps(receipt, indent=2) + "\n")
    partial.replace(directory / "qualification.json")
    print(json.dumps(receipts))


if __name__ == "__main__":
    main()
