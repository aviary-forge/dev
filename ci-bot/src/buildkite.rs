use std::{fmt, str::FromStr};

use anyhow::anyhow;
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

#[derive(Deserialize)]
pub struct JobWebhook {
    event: JobEvent,
    job: Job,
    build: Build,
    pipeline: Pipeline,
}

#[derive(Deserialize)]
pub enum BuildkiteWebhookEvent {
    Build(BuildWebhook),
    Job(JobWebhook),
}

#[derive(Deserialize)]
pub struct RawWebhook {
    event: String,

    job: Option<Job>,
    pipeline: Option<Pipeline>,
    build: Option<Build>,
}

impl RawWebhook {
    pub fn into_webhook(self) -> Result<Option<BuildkiteWebhookEvent>, anyhow::Error> {
        let event_prefix = self.event.split_once(".");
        match (event_prefix, self.event.as_str()) {
            (Some(("build", _)), e) => {
                let event = BuildEvent::from_str(e).unwrap();
                let webhook = BuildWebhook {
                    event,
                    build: self.build.unwrap(),
                    pipeline: self.pipeline.unwrap(),
                };
                Ok(Some(BuildkiteWebhookEvent::Build(webhook)))
            }
            (Some(("job", _)), e) => {
                let event = JobEvent::from_str(e).unwrap();
                let webhook = JobWebhook {
                    event,
                    job: self.job.unwrap(),
                    build: self.build.unwrap(),
                    pipeline: self.pipeline.unwrap(),
                };
                Ok(Some(BuildkiteWebhookEvent::Job(webhook)))
            }
            (None, "ping") | (Some(("agent", _)), _) | (Some(("cluster_token", _)), _) => Ok(None),
            _ => Err(anyhow!("unsupported event: {}", self.event)),
        }
    }
}
