use axum::extract::Json;
use axum::routing::get;
use axum::Router;

mod buildkite;

async fn handle_health() -> &'static str {
    "OK"
}

async fn handle_discord() -> &'static str {
    unimplemented!()
}

async fn handle_github() -> &'static str {
    unimplemented!()
}

async fn handle_buildkite(Json(payload): Json<crate::buildkite::RawWebhook>) -> &'static str {
    unimplemented!()
}

static BIND: &str = "127.0.0.1:1234";

#[tokio::main]
async fn main() -> Result<(), anyhow::Error> {
    let router = Router::new().route("/health", get(handle_health));

    let listener = tokio::net::TcpListener::bind(BIND).await?;
    eprintln!("listening on {}", BIND);
    axum::serve(listener, router).await?;

    Ok(())
}
