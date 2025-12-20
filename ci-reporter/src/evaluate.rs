#![allow(dead_code)]

use std::path::PathBuf;

use serde::Deserialize;
use serde_with::base64::Base64;
use serde_with::serde_as;

// TODO
#[serde_as]
#[derive(Debug, Deserialize)]
pub struct Owner {
    #[serde_as(as = "Base64")]
    discord: String,
    github: String,
}

#[derive(Debug, Deserialize)]
pub struct EvaluationResult {
    drv_path: PathBuf,
    output_path: PathBuf,
    owners: Vec<Owner>,
    system: String,
    tree_path: String,
}
