use base64::Engine;
use base64::prelude::BASE64_STANDARD;
use rand::seq::SliceRandom;

const BROWSER_UA_SRC_URL: &str = "aHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL21pY3JvbGlua2hxL3RvcC11c2VyLWFnZW50cy9yZWZzL2hlYWRzL21hc3Rlci9zcmMvZGVza3RvcC5qc29u";
lazy_static::lazy_static! {
    static ref BROWSER_UA_SRC_BYTES: Vec<u8> = BASE64_STANDARD.decode(BROWSER_UA_SRC_URL).unwrap();
    static ref BROWSER_UA_SRC_STR: String = String::from_utf8(BROWSER_UA_SRC_BYTES.to_vec()).unwrap();
}

#[derive(thiserror::Error, Debug)]
pub enum DataFetchError {
    #[error("error fetching release info: {0}")]
    MakingRequest(reqwest::Error),
    #[error("error reading response body: {0}")]
    ReadingBody(reqwest::Error),
    #[error("error decoding response into JSON: {0}")]
    DecodingBrowserInfo(#[from] serde_json::Error),
}

async fn fetch_user_agents() -> Result<Vec<String>, DataFetchError> {
    let resp = reqwest::get(BROWSER_UA_SRC_STR.to_string())
        .await
        .map_err(DataFetchError::MakingRequest)?;
    let body = resp.bytes().await.map_err(DataFetchError::ReadingBody)?;

    let data = serde_json::from_slice(&body)?;
    Ok(data)
}

#[derive(thiserror::Error, Debug)]
pub enum UserAgentConstructionError {
    #[error("error fetching chromium releases: {0}")]
    FetchingData(#[from] DataFetchError),
    #[error("empty list was returned from user-agent source")]
    EmptyListReturned,
}

/// Returns a shuffled list of user agents, so each request pattern looks a
/// little different.
pub async fn get_user_agents() -> Result<Vec<String>, UserAgentConstructionError> {
    let mut agents = fetch_user_agents().await?;
    if agents.is_empty() {
        return Err(UserAgentConstructionError::EmptyListReturned);
    }
    agents.shuffle(&mut rand::rng());
    Ok(agents)
}
