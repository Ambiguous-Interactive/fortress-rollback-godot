use std::{env, path::PathBuf, process::Command};

fn main() {
    // The stamp stays absent so Cargo verifies source bytes even on a cached build.
    let stamp = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo build output")).join("recheck-archive");
    println!("cargo:rerun-if-changed={}", stamp.display());
    let python = if cfg!(windows) { "python" } else { "python3" };
    let status = Command::new(python)
        .arg("verify_source.py")
        .status()
        .expect("start Python to verify the native Fortress source");
    assert!(status.success(), "native Fortress source verification failed");
}
