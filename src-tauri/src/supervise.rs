//! `codeg-server --supervise` — a minimal process supervisor that owns the
//! lifecycle of the real worker so an in-place upgrade can swap the binary
//! and have the *new* version relaunched deterministically.
//!
//! In Docker this process is PID 1, so it also has to behave like an init:
//! forward `SIGTERM`/`SIGINT` to the worker for graceful container stop, and
//! reap reparented orphan children so they don't pile up as zombies.
//!
//! Relaunch contract: the worker performs the file swap and then exits with
//! [`crate::update::runtime::EXIT_RESTART`]. We wait `CODEG_RESTART_DELAY_MS`
//! and respawn from the (now replaced) executable path. Any *other* exit is
//! propagated as-is — a fatal config error or a bad upgrade should stop the
//! process (and, under a container restart policy, fall back to the image)
//! rather than hot-loop.

use crate::update::runtime;

/// Build the worker argv: our own args minus the `--supervise` flag.
fn worker_args() -> Vec<String> {
    std::env::args()
        .skip(1)
        .filter(|a| a != "--supervise")
        .collect()
}

#[cfg(unix)]
pub fn run() -> ! {
    use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};

    static WORKER_PID: AtomicI32 = AtomicI32::new(0);
    static TERMINATING: AtomicBool = AtomicBool::new(false);

    extern "C" fn forward_signal(sig: libc::c_int) {
        TERMINATING.store(true, Ordering::SeqCst);
        let pid = WORKER_PID.load(Ordering::SeqCst);
        if pid > 0 {
            // SAFETY: `kill` is async-signal-safe.
            unsafe {
                libc::kill(pid, sig);
            }
        }
    }

    // SAFETY: installing handlers before spawning any child. `signal` is fine
    // for our forward-and-flag use; we deliberately keep the handler trivial.
    unsafe {
        libc::signal(libc::SIGTERM, forward_signal as *const () as libc::sighandler_t);
        libc::signal(libc::SIGINT, forward_signal as *const () as libc::sighandler_t);
    }

    let exe = runtime::self_exe();
    let args = worker_args();
    let delay = runtime::restart_delay_ms();

    let spawn_worker = || -> std::process::Child {
        std::process::Command::new(&exe)
            .args(&args)
            .env(runtime::ENV_SUPERVISED, "1")
            .env(runtime::ENV_RESTART_DELAY_MS, delay.to_string())
            .spawn()
            .unwrap_or_else(|e| {
                eprintln!("[supervise][FATAL] failed to spawn worker: {e}");
                std::process::exit(1);
            })
    };

    let mut child = spawn_worker();
    WORKER_PID.store(child.id() as i32, Ordering::SeqCst);
    eprintln!("[supervise] worker started (pid {})", child.id());

    loop {
        let worker_pid = WORKER_PID.load(Ordering::SeqCst);
        let mut status: libc::c_int = 0;
        // Block until *any* child changes state. As PID 1 we reap every
        // reparented orphan here; only the worker's exit drives decisions.
        let pid = unsafe { libc::waitpid(-1, &mut status, 0) };

        if pid == -1 {
            let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
            if errno == libc::EINTR {
                continue; // interrupted by a forwarded signal; retry
            }
            if errno == libc::ECHILD {
                // No children left — nothing more to supervise.
                std::process::exit(if TERMINATING.load(Ordering::SeqCst) {
                    0
                } else {
                    1
                });
            }
            eprintln!("[supervise][FATAL] waitpid failed (errno {errno})");
            std::process::exit(1);
        }

        if pid != worker_pid {
            // Reaped an orphan zombie; ignore and keep going.
            continue;
        }

        // The worker exited. Decode how.
        let _ = child.try_wait(); // let std reap its own bookkeeping (no-op)
        // Clear the pid immediately: during the relaunch delay below a
        // forwarded signal must not `kill()` a PID the OS may have recycled.
        WORKER_PID.store(0, Ordering::SeqCst);
        if TERMINATING.load(Ordering::SeqCst) {
            eprintln!("[supervise] worker stopped during shutdown; exiting");
            std::process::exit(0);
        }

        if libc::WIFEXITED(status) {
            let code = libc::WEXITSTATUS(status);
            if code == runtime::EXIT_RESTART {
                eprintln!("[supervise] upgrade restart requested; relaunching in {delay}ms");
                std::thread::sleep(std::time::Duration::from_millis(delay));
                if TERMINATING.load(Ordering::SeqCst) {
                    std::process::exit(0);
                }
                child = spawn_worker();
                WORKER_PID.store(child.id() as i32, Ordering::SeqCst);
                eprintln!("[supervise] worker relaunched (pid {})", child.id());
                continue;
            }
            eprintln!("[supervise] worker exited with code {code}; propagating");
            std::process::exit(code);
        }

        if libc::WIFSIGNALED(status) {
            let sig = libc::WTERMSIG(status);
            eprintln!("[supervise] worker killed by signal {sig}; exiting");
            // Mirror the conventional 128+signal exit code.
            std::process::exit(128 + sig);
        }

        // Stopped/continued or otherwise non-terminal — keep waiting.
    }
}

#[cfg(windows)]
pub fn run() -> ! {
    // Windows has no PID 1 / zombie semantics. A straightforward
    // spawn → wait → relaunch loop is enough; standalone Windows servers
    // typically also sit under a service manager.
    let exe = runtime::self_exe();
    let args = worker_args();
    let delay = runtime::restart_delay_ms();

    loop {
        let mut child = std::process::Command::new(&exe)
            .args(&args)
            .env(runtime::ENV_SUPERVISED, "1")
            .env(runtime::ENV_RESTART_DELAY_MS, delay.to_string())
            .spawn()
            .unwrap_or_else(|e| {
                eprintln!("[supervise][FATAL] failed to spawn worker: {e}");
                std::process::exit(1);
            });

        let status = child.wait().unwrap_or_else(|e| {
            eprintln!("[supervise][FATAL] wait failed: {e}");
            std::process::exit(1);
        });

        match status.code() {
            Some(code) if code == runtime::EXIT_RESTART => {
                eprintln!("[supervise] upgrade restart requested; relaunching in {delay}ms");
                std::thread::sleep(std::time::Duration::from_millis(delay));
            }
            Some(code) => std::process::exit(code),
            None => std::process::exit(1),
        }
    }
}
