use anyhow::Result;
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
enum GuestStatus {
    Online,
    Offline,
}

#[derive(Debug, Serialize, Deserialize)]
struct NetworkReport {
    target: String,
    status: GuestStatus,
    message: String,
}

fn main() -> Result<()> {
    let report = NetworkReport {
        target: String::from("crates.io"),
        status: GuestStatus::Online,
        message: String::from(
            "Cargo successfully resolved and compiled external dependencies inside Firecracker microVM",
        ),
    };

    let serialized = serde_json::to_string_pretty(&report)?;
    println!("{serialized}");

    Ok(())
}
