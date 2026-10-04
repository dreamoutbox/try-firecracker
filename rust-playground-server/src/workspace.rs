#![allow(dead_code)]

use anyhow::{Context, Result, bail};
use std::path::PathBuf;
use tokio::fs;
use tokio::process::Command;
use uuid::Uuid;

const CARGO_TEMPLATE: &str = include_str!("../template/Cargo.toml");
const WORKSPACE_SIZE_MIB: u32 = 64;

pub(crate) fn workspace_dir(run_id: &Uuid) -> PathBuf {
    PathBuf::from(format!("/tmp/run-{}", run_id))
}

pub(crate) async fn create(code: &str, run_id: &Uuid) -> Result<PathBuf> {
    let base_dir = workspace_dir(run_id);
    let staging_dir = base_dir.join("staging");
    let src_dir = staging_dir.join("src");

    fs::create_dir_all(&src_dir).await.with_context(|| {
        format!(
            "failed to create staging directory at {}",
            src_dir.display()
        )
    })?;

    fs::write(staging_dir.join("Cargo.toml"), CARGO_TEMPLATE)
        .await
        .context("failed to write workspace Cargo.toml")?;

    fs::write(src_dir.join("main.rs"), code)
        .await
        .context("failed to write workspace src/main.rs")?;

    let ext4_path = base_dir.join("code.ext4");
    let staging_str = staging_dir
        .to_str()
        .context("staging path is not valid UTF-8")?;
    let ext4_str = ext4_path.to_str().context("ext4 path is not valid UTF-8")?;
    let size_arg = format!("{}M", WORKSPACE_SIZE_MIB);

    let status = Command::new("mkfs.ext4")
        .args(["-q", "-F", "-d", staging_str, ext4_str, &size_arg])
        .status()
        .await
        .context("failed to execute mkfs.ext4")?;

    if !status.success() {
        bail!("mkfs.ext4 exited with non-zero status: {}", status);
    }

    Ok(ext4_path)
}

pub(crate) async fn cleanup(run_id: &Uuid) -> Result<()> {
    let base_dir = workspace_dir(run_id);
    if fs::try_exists(&base_dir).await.unwrap_or(false) {
        fs::remove_dir_all(&base_dir).await.with_context(|| {
            format!(
                "failed to remove workspace directory {}",
                base_dir.display()
            )
        })?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_create_and_cleanup_workspace() {
        let run_id = Uuid::new_v4();
        let code = r#"fn main() { println!("hi"); }"#;

        let ext4_path = create(code, &run_id)
            .await
            .expect("workspace creation should succeed");

        assert!(ext4_path.exists(), "ext4 image should exist on disk");
        let metadata = fs::metadata(&ext4_path)
            .await
            .expect("metadata should be readable");
        assert!(metadata.len() > 0, "ext4 image should not be empty");

        cleanup(&run_id)
            .await
            .expect("workspace cleanup should succeed");

        assert!(
            !workspace_dir(&run_id).exists(),
            "workspace directory should be removed after cleanup"
        );
    }
}
