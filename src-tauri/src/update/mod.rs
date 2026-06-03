//! In-place self-update for the standalone server / Docker runtime.
//!
//! Desktop (Tauri) builds never drive this — they update through
//! `tauri-plugin-updater`. Here the running worker downloads the signed
//! release bundle for its platform, verifies it, swaps `codeg-server` +
//! `codeg-mcp` + `web/` on disk (keeping `.bak`), and then restarts:
//!
//! - **Supervised** (our `--supervise` parent, PID 1 in Docker): the worker
//!   exits with [`runtime::EXIT_RESTART`] and the supervisor relaunches it
//!   after `CODEG_RESTART_DELAY_MS`.
//! - **Standalone** (no supervisor): the worker re-execs itself.

pub mod install;
pub mod runtime;
pub mod verify;
pub mod version;

use std::time::Duration;

pub use install::{InstallOutcome, UpdatePhase};
pub use runtime::{capability, restart_delay_ms, runtime_label, UpdateCapability};

/// Schedule a restart that fires *after* the current HTTP response has had
/// time to flush, so the frontend receives its acknowledgement before the
/// socket drops. Returns immediately.
pub fn schedule_restart() {
    tokio::spawn(async {
        // Give axum a moment to write the response body to the client.
        tokio::time::sleep(Duration::from_millis(400)).await;
        restart_now();
    });
}

fn restart_now() -> ! {
    match runtime::capability() {
        UpdateCapability::Supervised => {
            eprintln!("[update] exiting for supervisor relaunch");
            std::process::exit(runtime::EXIT_RESTART);
        }
        UpdateCapability::Reexec => reexec(),
    }
}

#[cfg(unix)]
fn reexec() -> ! {
    use std::os::unix::process::CommandExt;
    let exe = runtime::self_exe();
    let args: Vec<String> = std::env::args().skip(1).collect();
    eprintln!("[update] re-exec {} {:?}", exe.display(), args);
    // `exec` only returns on failure (it replaces the process image). The
    // listening socket is marked CLOEXEC at bind time, so it closes here and
    // the new image rebinds cleanly.
    let err = std::process::Command::new(&exe).args(&args).exec();
    eprintln!("[update] re-exec failed: {err}; exiting");
    std::process::exit(runtime::EXIT_RESTART);
}

#[cfg(windows)]
fn reexec() -> ! {
    let exe = runtime::self_exe();
    let args: Vec<String> = std::env::args().skip(1).collect();
    eprintln!("[update] re-spawn {} {:?}", exe.display(), args);
    match std::process::Command::new(&exe).args(&args).spawn() {
        Ok(_) => std::process::exit(0),
        Err(e) => {
            eprintln!("[update] re-spawn failed: {e}");
            std::process::exit(runtime::EXIT_RESTART);
        }
    }
}
