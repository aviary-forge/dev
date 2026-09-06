use std::collections::HashMap;

use regex::Regex;
use scraper::{ElementRef, Html, Selector};

use crate::{LengthInfo, PairInfo};

lazy_static::lazy_static! {
    static ref TABLE_SELECTOR: Selector = Selector::parse("table.table").unwrap();
    static ref TR_SELECTOR: Selector = Selector::parse("tr.row").unwrap();
    static ref TD_SELECTOR: Selector = Selector::parse("td.cell").unwrap();
    static ref CONTENT_SELECTOR: Selector = Selector::parse("p.content").unwrap();

    static ref TWO_LETTER_REGEX: Regex = Regex::new(r#"\b([a-zA-Z]{2})-(\d+)\b"#).unwrap();
}

#[derive(Debug, thiserror::Error)]
pub enum SiteParseError {
    #[error("no data table found on page")]
    MissingTable,
}

/// Detects the captcha/block interstitial page, so callers can react to being
/// blocked instead of just failing to parse.
///
/// The page is a DataDome challenge; it identifies itself via its
/// `captcha-delivery.com` script hosts, so look for those rather than the
/// (changeable) user-facing message.
pub fn is_captcha(body: &str) -> bool {
    body.contains("captcha-delivery.com")
}

/// Whether the expected data table is present on the page.
pub fn has_table(body: &str) -> bool {
    let page = Html::parse_document(body);
    page.select(&TABLE_SELECTOR).next().is_some()
}

pub fn parse_content(body: &str) -> Result<(PairInfo, LengthInfo), SiteParseError> {
    let page = Html::parse_document(body);

    let table = page
        .select(&TABLE_SELECTOR)
        .next()
        .ok_or(SiteParseError::MissingTable)?;

    let main_node = table.parent().unwrap();
    let main_el = ElementRef::wrap(main_node).unwrap();

    let two_letters_el = main_el.select(&CONTENT_SELECTOR).nth(4).unwrap();

    let pairs = extract_pair_info(two_letters_el);
    let table_info = extract_table_info(table);

    Ok((pairs, table_info))
}

fn extract_pair_info(node: ElementRef) -> PairInfo {
    let text_vec = node.text().collect::<Vec<_>>();
    let text = text_vec.concat();

    let mut pair_counts = HashMap::default();
    for (_, [prefix, count]) in TWO_LETTER_REGEX.captures_iter(&text).map(|c| c.extract()) {
        assert!(prefix.len() == 2);
        let i: usize = count.parse().expect("received negative count");
        let mut chars = prefix.chars();
        let char1 = chars.next().unwrap();
        let char2 = chars.next().unwrap();
        pair_counts.insert((char1, char2), i);
    }

    pair_counts
}

fn extract_table_info(node: ElementRef) -> LengthInfo {
    let mut rows = node.select(&TR_SELECTOR);
    // Expecting 8 rows: 1 header, 6 letters, 1 sum
    let header = rows.next().unwrap();
    let (_, values) = extract_table_row_info(header);

    let mut items = HashMap::default();
    for row in rows {
        let (l, quants) = extract_table_row_info(row);
        let letter = l.unwrap();
        if letter == 'Σ' {
            continue;
        }

        for (i, quantity) in quants.iter().enumerate() {
            items.insert((letter, values[i]), *quantity);
        }
    }

    items
}

fn extract_table_row_info(tr: ElementRef) -> (Option<char>, Vec<usize>) {
    let mut els = tr.select(&TD_SELECTOR);
    let header = els.next().unwrap().text().collect::<Vec<_>>().concat();
    let header_char = header.trim().chars().next();

    let mut items = Vec::new();
    for el in els {
        let text = el.text().collect::<Vec<_>>().concat();
        let num = match text.trim() {
            // This doesn't matter, and will get dropped just below anyway
            "Σ" | "-" => 0,
            v => v.parse().unwrap(),
        };
        items.push(num);
    }

    // drop the "sum" item
    items.truncate(items.len() - 1);
    (header_char, items)
}

#[cfg(test)]
mod tests {
    use super::*;

    const CAPTCHA_BODY: &str = r#"<html lang="en"><head><title>nytimes.com</title></head><body style="margin:0"><p id="cmsg">Please enable JS and disable any ad blocker</p><script data-cfasync="false">var dd={'rt':'c'}</script><script data-cfasync="false" src="https://ct.captcha-delivery.com/c.js"></script></body></html>"#;

    #[test]
    fn detects_captcha_page() {
        assert!(is_captcha(CAPTCHA_BODY));
        assert!(!is_captcha("<html><body>just a page</body></html>"));
    }

    #[test]
    fn detects_missing_table() {
        assert!(!has_table(CAPTCHA_BODY));
        assert!(has_table(
            r#"<html><body><table class="table"><tr class="row"><td class="cell">A</td></tr></table></body></html>"#
        ));
    }

    #[test]
    fn parse_content_errors_without_panic() {
        let err = parse_content(CAPTCHA_BODY).unwrap_err();
        assert!(matches!(err, SiteParseError::MissingTable));
    }
}
