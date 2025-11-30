use axum::extract::Json;
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::Router;

use axum::http::StatusCode;
use buildkite::BuildkiteWebhookEvent;

use crate::buildkite::RawWebhook;

mod buildkite;
mod discord;

async fn handle_health() -> &'static str {
    "OK"
}

async fn handle_discord() -> &'static str {
    unimplemented!()
}

async fn handle_github() -> &'static str {
    unimplemented!()
}

async fn handle_buildkite(Json(payload): Json<RawWebhook>) -> impl IntoResponse {
    match payload.into_webhook() {
        Ok(Some(webhook)) => {
            match webhook {
                BuildkiteWebhookEvent::Build(build) => {
                    eprintln!("received build event: {:?}", build);
                }
                BuildkiteWebhookEvent::Job(job) => {
                    eprintln!("received job event: {:?}", job);
                }
            };
            (StatusCode::OK, "")
        }
        Ok(None) => (StatusCode::OK, ""),
        Err(_) => (StatusCode::BAD_REQUEST, ""),
    }
}

static BIND: &str = "127.0.0.1:1234";

#[tokio::main]
async fn main() -> Result<(), anyhow::Error> {
    let router = Router::new()
        .route("/health", get(handle_health))
        .route("/discord", post(handle_discord))
        .route("/github", post(handle_github))
        .route("/buildkite", post(handle_buildkite));

    let listener = tokio::net::TcpListener::bind(BIND).await?;
    eprintln!("listening on {}", BIND);
    axum::serve(listener, router).await?;

    Ok(())
}
