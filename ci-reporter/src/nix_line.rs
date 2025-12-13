#![allow(dead_code)]

use std::fmt;

use serde::de::{Deserializer, Error as DeError, IgnoredAny, MapAccess, Visitor};
use serde::Deserialize;

pub type MsgId = u64;
pub type EventType = u8;

#[derive(Debug)]
pub enum ResultFields {
    FileLinked {
        files: i64,
        bytes: i64,
    }, // type 100: [int, int]

    BuildLogLine(String), // type 101: [string]

    UntrustedPath(String), // type 102: [string]

    CorruptedPath(String), // type 103: [string]

    SetPhase(String), // type 104: [string]

    Progress {
        done: i64,
        expected: i64,
        running: i64,
        failed: i64,
    }, // type 105: [int, int, int, int]

    SetExpected {
        activity_type: EventType,
        count: i64,
    }, // type 106: [int, int]

    PostBuildLogLine(String), // type 107: [string]

    FetchStatus(String), // type 108: [string]
}

#[derive(Debug)]
pub enum Activity {
    Build {
        derivation: String,
        host: String,
    }, // type 105: [string, string, ?, ?]

    CopyPath {
        path: String,
        from: String,
        to: String,
    }, // type 100: [string, string, string]

    FileTransfer {
        url: String,
    }, // type 101: [string]

    Builds, // type 104: no fields

    Unknown {
        type_id: EventType,
        text: String,
    }, // fallback for unhandled types
}

#[derive(Debug)]
pub struct StartEvent {
    pub id: MsgId,
    pub level: u8,
    pub text: String,
    pub activity: Activity,
}

#[derive(Debug)]
pub struct ResultEvent {
    pub id: MsgId,
    pub fields: ResultFields,
}

#[derive(Deserialize, Debug)]
pub struct MsgEvent {
    pub level: u8,
    pub msg: String,
}

#[derive(Deserialize, Debug)]
pub struct StopEvent {
    pub id: MsgId,
}

#[derive(Deserialize, Debug)]
#[serde(tag = "action", rename_all = "lowercase")]
pub enum NixLine {
    Start(StartEvent),
    Result(ResultEvent),
    Msg(MsgEvent),
    Stop(StopEvent),
}

// Custom deserializer for ResultEvent
impl<'de> Deserialize<'de> for ResultEvent {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct ResultEventVisitor;

        impl<'de> Visitor<'de> for ResultEventVisitor {
            type Value = ResultEvent;

            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("struct ResultEvent")
            }

            fn visit_map<A>(self, mut map: A) -> Result<Self::Value, A::Error>
            where
                A: MapAccess<'de>,
            {
                let mut id = None;
                let mut type_field = None;
                let mut fields_raw = None;

                // Phase 1: Read all fields from JSON
                while let Some(key) = map.next_key::<String>()? {
                    match key.as_str() {
                        "id" => id = Some(map.next_value()?),
                        "type" => type_field = Some(map.next_value()?),
                        "fields" => {
                            // Buffer as raw JSON value
                            fields_raw = Some(map.next_value::<serde_json::Value>()?);
                        },
                        _ => {
                            let _ = map.next_value::<IgnoredAny>()?;
                        },
                    }
                }

                // Phase 2: Validate required fields
                let id = id.ok_or_else(|| A::Error::missing_field("id"))?;
                let type_field = type_field.ok_or_else(|| A::Error::missing_field("type"))?;
                let fields_raw = fields_raw.ok_or_else(|| A::Error::missing_field("fields"))?;

                // Phase 3: Deserialize fields based on type
                let fields =
                    deserialize_result_fields(type_field, fields_raw).map_err(A::Error::custom)?;

                Ok(ResultEvent { id, fields })
            }
        }

        deserializer.deserialize_map(ResultEventVisitor)
    }
}

// Helper function for type-dependent deserialization of result fields
fn deserialize_result_fields(
    type_field: EventType,
    fields_raw: serde_json::Value,
) -> Result<ResultFields, String> {
    let array = fields_raw
        .as_array()
        .ok_or_else(|| "fields must be an array".to_string())?;

    match type_field {
        100 => {
            // FileLinked: [int, int]
            let files = array
                .first()
                .and_then(|v| v.as_i64())
                .ok_or("expected i64 at fields[0]")?;
            let bytes = array
                .get(1)
                .and_then(|v| v.as_i64())
                .ok_or("expected i64 at fields[1]")?;
            Ok(ResultFields::FileLinked { files, bytes })
        },

        101 => {
            // BuildLogLine: [string]
            let line = array
                .first()
                .and_then(|v| v.as_str())
                .ok_or("expected string at fields[0]")?;
            Ok(ResultFields::BuildLogLine(line.to_string()))
        },

        102 => {
            // UntrustedPath: [string]
            let path = array
                .first()
                .and_then(|v| v.as_str())
                .ok_or("expected string at fields[0]")?;
            Ok(ResultFields::UntrustedPath(path.to_string()))
        },

        103 => {
            // CorruptedPath: [string]
            let path = array
                .first()
                .and_then(|v| v.as_str())
                .ok_or("expected string at fields[0]")?;
            Ok(ResultFields::CorruptedPath(path.to_string()))
        },

        104 => {
            // SetPhase: [string]
            let phase = array
                .first()
                .and_then(|v| v.as_str())
                .ok_or("expected string at fields[0]")?;
            Ok(ResultFields::SetPhase(phase.to_string()))
        },

        105 => {
            // Progress: [int, int, int, int]
            let done = array
                .first()
                .and_then(|v| v.as_i64())
                .ok_or("expected i64 at fields[0]")?;
            let expected = array
                .get(1)
                .and_then(|v| v.as_i64())
                .ok_or("expected i64 at fields[1]")?;
            let running = array
                .get(2)
                .and_then(|v| v.as_i64())
                .ok_or("expected i64 at fields[2]")?;
            let failed = array
                .get(3)
                .and_then(|v| v.as_i64())
                .ok_or("expected i64 at fields[3]")?;
            Ok(ResultFields::Progress {
                done,
                expected,
                running,
                failed,
            })
        },

        106 => {
            // SetExpected: [int, int]
            let activity_type = array
                .first()
                .and_then(|v| v.as_u64())
                .map(|v| v as EventType)
                .ok_or("expected u8 at fields[0]")?;
            let count = array
                .get(1)
                .and_then(|v| v.as_i64())
                .ok_or("expected i64 at fields[1]")?;
            Ok(ResultFields::SetExpected {
                activity_type,
                count,
            })
        },

        107 => {
            // PostBuildLogLine: [string]
            let line = array
                .first()
                .and_then(|v| v.as_str())
                .ok_or("expected string at fields[0]")?;
            Ok(ResultFields::PostBuildLogLine(line.to_string()))
        },

        108 => {
            // FetchStatus: [string]
            let status = array
                .first()
                .and_then(|v| v.as_str())
                .ok_or("expected string at fields[0]")?;
            Ok(ResultFields::FetchStatus(status.to_string()))
        },

        _ => Err(format!("unknown result type: {}", type_field)),
    }
}

// Custom deserializer for StartEvent
impl<'de> Deserialize<'de> for StartEvent {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct StartEventVisitor;

        impl<'de> Visitor<'de> for StartEventVisitor {
            type Value = StartEvent;

            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("struct StartEvent")
            }

            fn visit_map<A>(self, mut map: A) -> Result<Self::Value, A::Error>
            where
                A: MapAccess<'de>,
            {
                let mut id = None;
                let mut level = None;
                let mut text: Option<String> = None;
                let mut type_field = None;
                let mut fields_raw = None;

                while let Some(key) = map.next_key::<String>()? {
                    match key.as_str() {
                        "id" => id = Some(map.next_value()?),
                        "level" => level = Some(map.next_value()?),
                        "text" => text = Some(map.next_value::<String>()?),
                        "type" => type_field = Some(map.next_value()?),
                        "fields" => {
                            fields_raw = Some(map.next_value::<serde_json::Value>()?);
                        },
                        _ => {
                            let _ = map.next_value::<IgnoredAny>()?;
                        },
                    }
                }

                let id = id.ok_or_else(|| A::Error::missing_field("id"))?;
                let level = level.ok_or_else(|| A::Error::missing_field("level"))?;
                let text_val = text.ok_or_else(|| A::Error::missing_field("text"))?;
                let type_field = type_field.ok_or_else(|| A::Error::missing_field("type"))?;

                let activity = deserialize_activity(type_field, fields_raw, &text_val)
                    .map_err(A::Error::custom)?;

                Ok(StartEvent {
                    id,
                    level,
                    text: text_val,
                    activity,
                })
            }
        }

        deserializer.deserialize_map(StartEventVisitor)
    }
}

// Helper function for activity deserialization
fn deserialize_activity(
    type_field: EventType,
    fields_raw: Option<serde_json::Value>,
    text: &str,
) -> Result<Activity, String> {
    match type_field {
        105 => {
            // Build: [string/int, string/int, ?, ?]
            let array = fields_raw
                .as_ref()
                .and_then(|v| v.as_array())
                .ok_or_else(|| "Build activity requires fields array".to_string())?;

            // Handle mixed string/int types - prefer string, fallback to empty string
            let derivation = array
                .first()
                .and_then(|v| v.as_str().or(Some("")))
                .ok_or("expected derivation at fields[0]")?
                .to_string();

            let host = array
                .get(1)
                .and_then(|v| v.as_str().or(Some("")))
                .ok_or("expected host at fields[1]")?
                .to_string();

            Ok(Activity::Build { derivation, host })
        },

        100 => {
            // CopyPath: [string, string, string]
            let array = fields_raw
                .as_ref()
                .and_then(|v| v.as_array())
                .ok_or_else(|| "CopyPath activity requires fields array".to_string())?;

            let path = array
                .first()
                .and_then(|v| v.as_str())
                .ok_or("expected path at fields[0]")?
                .to_string();

            let from = array
                .get(1)
                .and_then(|v| v.as_str())
                .ok_or("expected from at fields[1]")?
                .to_string();

            let to = array
                .get(2)
                .and_then(|v| v.as_str())
                .ok_or("expected to at fields[2]")?
                .to_string();

            Ok(Activity::CopyPath { path, from, to })
        },

        101 => {
            // FileTransfer: [string]
            let array = fields_raw
                .as_ref()
                .and_then(|v| v.as_array())
                .ok_or_else(|| "FileTransfer activity requires fields array".to_string())?;

            let url = array
                .first()
                .and_then(|v| v.as_str())
                .ok_or("expected url at fields[0]")?
                .to_string();

            Ok(Activity::FileTransfer { url })
        },

        104 => {
            // Builds: no fields
            Ok(Activity::Builds)
        },

        _ => {
            // Unknown activity type
            Ok(Activity::Unknown {
                type_id: type_field,
                text: text.to_string(),
            })
        },
    }
}
