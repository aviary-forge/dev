#![allow(unused)]

use std::{collections::BTreeMap, str::FromStr};

use anyhow::anyhow;
use serde::{de::Visitor, Deserialize, Serialize};
use serde_enum_str::Deserialize_enum_str;

#[derive(Debug, Deserialize_enum_str)]
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

#[derive(Debug, Deserialize_enum_str)]
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

#[derive(Debug, Deserialize)]
pub struct BuildWebhook {
    event: BuildEvent,
    build: Build,
    pipeline: Pipeline,
}

#[derive(Debug, Deserialize)]
pub struct JobWebhook {
    event: JobEvent,
    job: Job,
    build: Build,
    pipeline: Pipeline,
}

#[derive(Debug, Deserialize)]
pub enum BuildkiteWebhookEvent {
    Build(BuildWebhook),
    Job(JobWebhook),
}

#[derive(Debug, Deserialize)]
pub struct Agent {
    pub id: uuid::Uuid,
    pub url: url::Url,
    pub web_url: url::Url,
    pub name: String,
    pub connection_state: String,
    pub user_agent: String,
    pub hostname: String,
}

#[derive(Debug, Deserialize)]
pub struct Job {
    pub id: uuid::Uuid,
    pub name: String,
    pub step_key: Option<String>,

    pub state: String,

    pub web_url: url::Url,
    pub build_url: url::Url,
    pub log_url: url::Url,
    pub raw_log_url: url::Url,
    pub artifacts_url: url::Url,

    pub command: String,
    pub soft_failed: bool,
    pub exit_status: Option<u8>,
    pub artifact_paths: Option<Vec<String>>,

    pub created_at: Option<chrono::DateTime<chrono::Utc>>,
    pub scheduled_at: Option<chrono::DateTime<chrono::Utc>>,
    pub runnable_at: Option<chrono::DateTime<chrono::Utc>>,
    pub started_at: Option<chrono::DateTime<chrono::Utc>>,
    pub finished_at: Option<chrono::DateTime<chrono::Utc>>,
    pub expired_at: Option<chrono::DateTime<chrono::Utc>>,

    pub retried: bool,
    pub retried_in_job_id: Option<uuid::Uuid>,
    pub retries_count: Option<u8>,

    pub agent: Agent,
}

#[derive(Debug, Deserialize)]
pub struct BuildSource {
    id: uuid::Uuid,
    number: u32,
    url: url::Url,
}

#[derive(Debug, Deserialize)]
pub struct Build {
    pub id: uuid::Uuid,
    pub url: url::Url,
    pub web_url: url::Url,

    pub number: u32,
    pub state: String,
    pub cancel_reason: Option<String>,
    pub blocked: bool,
    pub blocked_state: Option<String>,

    pub message: String,
    pub commit: String,
    pub branch: Option<String>,
    pub tag: Option<String>,

    // TODO: resolve author/creator
    pub created_at: Option<chrono::DateTime<chrono::Utc>>,
    pub scheduled_at: Option<chrono::DateTime<chrono::Utc>>,
    pub started_at: Option<chrono::DateTime<chrono::Utc>>,
    pub finished_at: Option<chrono::DateTime<chrono::Utc>>,

    pub meta_data: BTreeMap<String, String>,
    // TODO: unsure of pull_request format
    pub pull_request: Option<u32>,
    pub rebuilt_from: Option<BuildSource>,
}

#[derive(Debug, Deserialize)]
pub struct Pipeline {
    pub id: uuid::Uuid,
    pub url: url::Url,
    pub web_url: url::Url,
}

#[derive(Debug, Deserialize)]
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
