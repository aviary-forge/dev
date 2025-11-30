use std::fmt;

pub use buildkite::types::{Build, Job, Pipeline};
use serde::{de::Visitor, Deserialize, Serialize};
use serde_enum_str::Deserialize_enum_str;

#[derive(Deserialize_enum_str)]
pub enum BuildEvent {
    #[serde(rename = "build.scheduled")]
    Scheduled,
    #[serde(rename = "build.running")]
    Running,
    #[serde(rename = "build.failing")]
    Failing,
    #[serde(rename = "build.finished")]
    Finished,
    #[serde(rename = "build.skipped")]
    Skipped,
}

#[derive(Deserialize_enum_str)]
pub enum JobEvent {
    #[serde(rename = "job.scheduled")]
    Scheduled,
    #[serde(rename = "job.started")]
    Started,
    #[serde(rename = "job.finished")]
    Finished,
    #[serde(rename = "job.activated")]
    Activated,
}

#[derive(Deserialize)]
pub struct BuildWebhook {
    event: BuildEvent,
    build: Build,
    pipeline: Pipeline,
}
