mod runner;
mod workspace;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use axum::extract::State;
use axum::response::{Html, IntoResponse, Json};
use axum::routing::{get, post};
use axum::Router;
use serde::{Deserialize, Serialize};
use tokio::sync::Semaphore;
use tracing::{error, info, warn};
use uuid::Uuid;

const INDEX_HTML: &str = include_str!("../static/index.html");
const DEFAULT_TIMEOUT_SECS: u64 = 30;
const MAX_CONCURRENT_RUNS: usize = 4;

#[derive(Clone)]
struct AppState {
    repo_root: Arc<PathBuf>,
    semaphore: Arc<Semaphore>,
    timeout_duration: Duration,
}

#[derive(Deserialize)]
struct RunRequest {
    code: String,
}

#[derive(Serialize)]
struct RunResponse {
    #[serde(skip_serializing_if = "Option::is_none")]
    stdout: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    elapsed_ms: u128,
}

async fn index_handler() -> impl IntoResponse {
    Html(INDEX_HTML)
}

async fn run_handler(
    State(state): State<AppState>,
    Json(payload): Json<RunRequest>,
) -> impl IntoResponse {
    let start_time = Instant::now();
    let run_id = Uuid::new_v4();

    info!(?run_id, "received playground run request");

    let _permit = match state.semaphore.acquire().await {
        Ok(permit) => permit,
        Err(err) => {
            error!(?run_id, %err, "semaphore acquire failed");
            return Json(RunResponse {
                stdout: None,
                error: Some("Server concurrency limit reached".to_string()),
                elapsed_ms: start_time.elapsed().as_millis(),
            });
        }
    };

    let workspace_ext4 = match workspace::create(&payload.code, &run_id).await {
        Ok(path) => path,
        Err(err) => {
            error!(?run_id, %err, "workspace creation failed");
            return Json(RunResponse {
                stdout: None,
                error: Some(format!("Workspace initialization error: {err}")),
                elapsed_ms: start_time.elapsed().as_millis(),
            });
        }
    };

    let result = runner::run_with_timeout(
        &state.repo_root,
        &workspace_ext4,
        &run_id,
        state.timeout_duration,
    )
    .await;

    // Cleanup workspace directory; log warning on failure instead of masking response
    if let Err(cleanup_err) = workspace::cleanup(&run_id).await {
        warn!(?run_id, %cleanup_err, "failed to clean up workspace");
    }

    match result {
        Ok(stdout) => {
            info!(?run_id, elapsed_ms = start_time.elapsed().as_millis(), "run completed successfully");
            Json(RunResponse {
                stdout: Some(stdout),
                error: None,
                elapsed_ms: start_time.elapsed().as_millis(),
            })
        }
        Err(err) => {
            warn!(?run_id, %err, elapsed_ms = start_time.elapsed().as_millis(), "run failed or timed out");
            Json(RunResponse {
                stdout: None,
                error: Some(err.to_string()),
                elapsed_ms: start_time.elapsed().as_millis(),
            })
        }
    }
}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM signal handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
    info!("shutdown signal received, commencing graceful shutdown");
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let repo_root = runner::find_repo_root().context("failed to locate repo root")?;
    info!(repo_root = %repo_root.display(), "located repository root");

    let timeout_secs: u64 = std::env::var("TIMEOUT_SECS")
        .ok()
        .and_then(|t| t.parse().ok())
        .unwrap_or(DEFAULT_TIMEOUT_SECS);

    let state = AppState {
        repo_root: Arc::new(repo_root),
        semaphore: Arc::new(Semaphore::new(MAX_CONCURRENT_RUNS)),
        timeout_duration: Duration::from_secs(timeout_secs),
    };

    let app = Router::new()
        .route("/", get(index_handler))
        .route("/run", post(run_handler))
        .with_state(state);

    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(3000);

    let addr = format!("0.0.0.0:{}", port);
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .with_context(|| format!("failed to bind listener on {addr}"))?;

    info!("rust-playground-server running on http://{}", addr);

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("server encountered fatal error")?;

    info!("rust-playground-server shutdown complete");
    Ok(())
}
