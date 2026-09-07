use std::collections::HashMap;

use serde::Deserialize;

use crate::{LengthInfo, PairInfo};

// We scrape the inline `window.gameData = {...}` script by needle rather than
// parsing HTML: less robust to page format changes, so go back to `scraper` if
// the page markup changes out from under us.
const SCRIPT_NEEDLE: &str = "window.gameData = ";
const SCRIPT_CLOSE: &str = "</script>";

#[derive(Debug, Deserialize)]
struct GameData {
    today: Today,
}

#[derive(Debug, Deserialize)]
struct Today {
    answers: Vec<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum SiteParseError {
    #[error(
        "gameData script not found; response was likely a captcha/interstitial page ({len} bytes)"
    )]
    MissingGameData { len: usize },
    #[error("gameData script is not terminated by `{SCRIPT_CLOSE}`")]
    UnterminatedScript,
    #[error("failed to deserialize gameData: {0}")]
    Deserializing(#[from] serde_json::Error),
}

pub fn parse_content(body: &str) -> Result<(PairInfo, LengthInfo), SiteParseError> {
    let (_, rest) = body
        .split_once(SCRIPT_NEEDLE)
        .ok_or(SiteParseError::MissingGameData { len: body.len() })?;

    let script = rest
        .split_once(SCRIPT_CLOSE)
        .ok_or(SiteParseError::UnterminatedScript)?
        .0;

    let data: GameData = serde_json::from_str(script)?;

    let mut pairs: PairInfo = HashMap::default();
    let mut lengths: LengthInfo = HashMap::default();
    for answer in &data.today.answers {
        let mut chars = answer.chars();
        let first = chars.next().unwrap();
        let second = chars.next().unwrap();
        *pairs.entry((first, second)).or_default() += 1;
        *lengths.entry((first, answer.chars().count())).or_default() += 1;
    }

    Ok((pairs, lengths))
}
