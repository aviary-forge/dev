use std::path::PathBuf;

use base64::Engine;
use base64::prelude::BASE64_STANDARD;
use chrono::NaiveDate;
use cuimp::CuimpOptions;

use crate::user_agents::{UserAgentConstructionError, get_user_agent};

const URL_PREFIX: &str = "aHR0cHM6Ly93d3cubnl0aW1lcy5jb20vcHV6emxlcy9zcGVsbGluZy1iZWUv";

lazy_static::lazy_static! {
    static ref STR_URL_PREFIX: Vec<u8> = BASE64_STANDARD.decode(URL_PREFIX).unwrap();
}

#[derive(Debug, thiserror::Error)]
pub enum FetchDataError {
    #[error("error building client: {0}")]
    BuildingClient(cuimp::CuimpError),
    #[error("error getting user agent: ({0})")]
    GettingUserAgent(#[from] UserAgentConstructionError),
    #[error("error fetching NYT game page: {0}")]
    GettingData(#[from] cuimp::CuimpError),
    #[error(
        "NYT returned 404 for {0}: the puzzle page endpoint only serves the past two weeks of puzzles"
    )]
    NotFound(NaiveDate),
    #[error("NYT returned unexpected status {0} fetching {1}")]
    UnexpectedStatus(u16, String),
}

pub async fn fetch_for_date(
    date: NaiveDate,
    binary_path: Option<PathBuf>,
) -> Result<String, FetchDataError> {
    let prefix = String::from_utf8_lossy(&STR_URL_PREFIX);
    let date_str = date.format("%Y-%m-%d");
    let url_str = format!("{prefix}{date_str}");
    let user_agent = get_user_agent().await?;
    let curl_args = [
        "--compressed".to_string(),
        "--header".to_string(),
        format!("User-Agent: {user_agent}"),
        "--header".to_string(),
        "Accept: text/html".to_string(),
        "--header".to_string(),
        "Accept-Language: en-US".to_string(),
    ];
    let options = CuimpOptions {
        extra_curl_args: Some(curl_args.into()),
        path: binary_path.map(|p| p.display().to_string()),
        ..Default::default()
    };
    let mut client = cuimp::CuimpHttp::new(options).map_err(FetchDataError::BuildingClient)?;

    let resp = client.get(&url_str).await?;
    if resp.status == 404 {
        return Err(FetchDataError::NotFound(date));
    }
    if !(200..300).contains(&resp.status) {
        return Err(FetchDataError::UnexpectedStatus(resp.status, url_str));
    }
    Ok(resp.data)
}
