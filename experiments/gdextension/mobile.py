"""Simulator and attached-device support for the mixed-peer witness."""
import os
import subprocess

BUNDLE = "org.fortress.witness"
PORT = 45872


def options(target, temp):
    if target == "ios":
        return ['application/bundle_identifier="' + BUNDLE + '"', 'application/app_store_team_id="SIMULATOR"',
                "application/export_project_only=true", "application/generate_simulator_library_if_missing=true"]
    # Disposable test key. The Android package is only used for local qualification.
    key = temp / "witness.p12"
    subprocess.run(["keytool", "-genkeypair", "-storetype", "PKCS12", "-keystore", key, "-alias", "witness",
                    "-storepass", "android", "-keypass", "android", "-dname", "CN=Witness", "-keyalg", "RSA",
                    "-validity", "30"], check=True, timeout=30)
    return ['package/unique_name="' + BUNDLE + '"', 'permissions/internet=true',
            'architectures/arm64-v8a=true', 'architectures/x86_64=true',
            f'keystore/release="{key.as_posix()}"', 'keystore/release_user="witness"', 'keystore/release_password="android"']


def libraries(target, native, scratch, stem):
    if target == "android":
        return {"android.arm64": native / f"aarch64-linux-android/release/lib{stem}.so",
                "android.x86_64": native / f"x86_64-linux-android/release/lib{stem}.so"}
    path = scratch / f"{stem}.xcframework"
    subprocess.run(["xcodebuild", "-create-xcframework", "-library",
                    native / f"aarch64-apple-ios/release/lib{stem}.dylib", "-library",
                    native / f"aarch64-apple-ios-sim/release/lib{stem}.dylib", "-output", path], check=True)
    return {"ios": path}


def launch(stack, device, artifact):
    def run(*args):
        subprocess.run(list(args), check=True, timeout=120)

    if device == "android":
        run("adb", "wait-for-device")
        run("adb", "install", "-r", artifact)
        run("adb", "reverse", f"tcp:{PORT}", f"tcp:{PORT}")
        stack.callback(run, "adb", "reverse", "--remove", f"tcp:{PORT}")
        run("adb", "shell", "am", "force-stop", BUNDLE)
        run("adb", "shell", "monkey", "-p", BUNDLE, "1")
        stack.callback(run, "adb", "shell", "am", "force-stop", BUNDLE)
    else:
        udid = os.environ.get("SIMULATOR_UDID", "booted")
        run("xcrun", "simctl", "install", udid, artifact)
        run("xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE)
        # The witness can already have quit after delivering its last report.
        stack.callback(subprocess.run, ["xcrun", "simctl", "terminate", udid, BUNDLE], timeout=15)
