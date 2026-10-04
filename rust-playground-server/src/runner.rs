#![allow(dead_code)]

use anyhow::{Context, Result, bail};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::fs;
use tokio::process::Command;
use uuid::Uuid;

pub(crate) fn find_repo_root() -> Result<PathBuf> {
    if let Ok(env_root) = std::env::var("REPO_ROOT") {
        let p = PathBuf::from(env_root);
        if p.join("assets/firecracker").exists() {
            return Ok(p);
        }
    }

    let cwd = std::env::current_dir().context("failed to get current dir")?;
    if cwd.join("assets/firecracker").exists() {
        return Ok(cwd);
    }

    if let Some(parent) = cwd.parent()
        && parent.join("assets/firecracker").exists()
    {
        return Ok(parent.to_path_buf());
    }

    bail!("could not locate repository root containing assets/firecracker")
}

pub(crate) fn extract_playground_output(raw: &str) -> String {
    const START_MARKER: &str = "=== PLAYGROUND_EXEC_START ===";
    const END_MARKER: &str = "=== PLAYGROUND_EXEC_END ===";

    if let Some(start_idx) = raw.find(START_MARKER) {
        let after_start = &raw[start_idx + START_MARKER.len()..];
        if let Some(end_idx) = after_start.find(END_MARKER) {
            return after_start[..end_idx].trim().to_string();
        }
    }
    raw.trim().to_string()
}

pub(crate) async fn run(repo_root: &Path, workspace_ext4: &Path, run_id: &Uuid) -> Result<String> {
    let run_dir = crate::workspace::workspace_dir(run_id);
    let config_path = run_dir.join("vm_config.json");

    let workspace_ext4_str = workspace_ext4
        .to_str()
        .context("workspace ext4 path is not valid UTF-8")?;

    let vm_config = serde_json::json!({
        "boot-source": {
            "kernel_image_path": "assets/vmlinux",
            "boot_args": "console=ttyS0 reboot=k panic=1 init=/init"
        },
        "drives": [
            {
                "drive_id": "rootfs",
                "path_on_host": "assets/rust-toolchain.ext4",
                "is_root_device": true,
                "is_read_only": true
            },
            {
                "drive_id": "workspace",
                "path_on_host": workspace_ext4_str,
                "is_root_device": false,
                "is_read_only": false
            }
        ],
        "machine-config": {
            "vcpu_count": 2,
            "mem_size_mib": 512
        }
    });

    let config_json =
        serde_json::to_string_pretty(&vm_config).context("failed to serialize vm_config.json")?;
    fs::write(&config_path, config_json)
        .await
        .context("failed to write vm_config.json")?;

    let fc_bin = repo_root.join("assets/firecracker");
    let child = Command::new(&fc_bin)
        .args([
            "--no-api",
            "--config-file",
            config_path
                .to_str()
                .context("config path is not valid UTF-8")?,
        ])
        .current_dir(repo_root)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .context("failed to spawn firecracker process")?;

    let output = child
        .wait_with_output()
        .await
        .context("failed waiting on firecracker process")?;

    let stdout_str = String::from_utf8_lossy(&output.stdout);
    Ok(extract_playground_output(&stdout_str))
}

pub(crate) async fn run_with_timeout(
    repo_root: &Path,
    workspace_ext4: &Path,
    run_id: &Uuid,
    timeout_duration: Duration,
) -> Result<String> {
    tokio::time::timeout(timeout_duration, run(repo_root, workspace_ext4, run_id))
        .await
        .map_err(|_| anyhow::anyhow!("Execution timed out"))?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_playground_output_with_markers() {
        let raw = "kernel boot logs\n=== PLAYGROUND_EXEC_START ===\nHello, world!\n=== PLAYGROUND_EXEC_END ===\nshutdown logs";
        let extracted = extract_playground_output(raw);
        assert_eq!(extracted, "Hello, world!");
    }

    #[test]
    fn test_extract_playground_output_without_markers() {
        let raw = "kernel panic!";
        let extracted = extract_playground_output(raw);
        assert_eq!(extracted, "kernel panic!");
    }

    #[tokio::test]
    async fn test_end_to_end_firecracker_run() {
        let repo_root = find_repo_root().expect("should find repo root");
        let run_id = Uuid::new_v4();
        let code = r#"fn main() { println!("firecracker-ok"); }"#;

        let workspace_ext4 = crate::workspace::create(code, &run_id)
            .await
            .expect("workspace should be created");

        let output = run_with_timeout(
            &repo_root,
            &workspace_ext4,
            &run_id,
            Duration::from_secs(30),
        )
        .await
        .expect("microVM run should succeed");

        crate::workspace::cleanup(&run_id)
            .await
            .expect("workspace cleanup should succeed");

        assert!(
            output.contains("firecracker-ok"),
            "output should contain 'firecracker-ok', got: {}",
            output
        );
    }
}
