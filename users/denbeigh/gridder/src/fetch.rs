use std::path::PathBuf;
use std::time::Duration;

use base64::Engine;
use base64::prelude::BASE64_STANDARD;
use chrono::NaiveDate;
use cuimp::CuimpOptions;
use rand::Rng;

use crate::parse;
use crate::user_agents::{UserAgentConstructionError, get_user_agents};

const URL_PREFIX: &str = "aHR0cHM6Ly93d3cubnl0aW1lcy5jb20=";
const URL_SUFFIX: &str = "Y3Jvc3N3b3Jkcy9zcGVsbGluZy1iZWUtZm9ydW0uaHRtbA==";

/// How long (in seconds) to pause between captcha responses, before trying
/// the next user agent.
const CAPTCHA_PAUSE_SECS: (f64, f64) = (2.5, 5.0);

lazy_static::lazy_static! {
    static ref STR_URL_PREFIX: Vec<u8> = BASE64_STANDARD.decode(URL_PREFIX).unwrap();
    static ref STR_URL_SUFFIX: Vec<u8> = BASE64_STANDARD.decode(URL_SUFFIX).unwrap();
}

#[derive(Debug, thiserror::Error)]
pub enum FetchDataError {
    #[error("error building client: {0}")]
    BuildingClient(cuimp::CuimpError),
    #[error("error getting user agent: ({0})")]
    GettingUserAgent(#[from] UserAgentConstructionError),
    #[error("error fetching NYT game page: {0}")]
    GettingData(#[from] cuimp::CuimpError),
    #[error("received a captcha response for every user agent tried ({0} total)")]
    AllUserAgentsCaptcha(usize),
}

pub async fn fetch_for_date(
    date: NaiveDate,
    binary_path: Option<PathBuf>,
) -> Result<String, FetchDataError> {
    let prefix = String::from_utf8_lossy(&STR_URL_PREFIX);
    let suffix = String::from_utf8_lossy(&STR_URL_SUFFIX);
    let date_str = date.format("%Y/%m/%d");
    let url_str = format!("{prefix}/{date_str}/{suffix}");

    let user_agents = get_user_agents().await?;
    let mut attempts = 0;
    for user_agent in &user_agents {
        attempts += 1;

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
            path: binary_path.as_ref().map(|p| p.display().to_string()),
            ..Default::default()
        };
        let mut client = cuimp::CuimpHttp::new(options).map_err(FetchDataError::BuildingClient)?;

        let resp = client.get::<String>(&url_str).await?;

        // DataDome block page: pause and rotate to the next user agent. Any
        // other response is handed back; if it's structurally wrong, parsing
        // will fail with a proper error downstream.
        if parse::is_captcha(&resp.data) {
            let (low, high) = CAPTCHA_PAUSE_SECS;
            let pause = rand::rng().random_range(low..high);
            eprintln!("captcha received; pausing {pause:.2}s, then trying the next user agent");
            tokio::time::sleep(Duration::from_secs_f64(pause)).await;
            continue;
        }

        return Ok(resp.data);
    }

    Err(FetchDataError::AllUserAgentsCaptcha(attempts))
}
