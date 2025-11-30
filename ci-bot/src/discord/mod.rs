use std::num::ParseIntError;
use std::str::FromStr;

use bb8::{Pool, RunError};
use bb8_postgres::PostgresConnectionManager;
use bytes::BytesMut;
use tokio_postgres::{
    types::{FromSql, ToSql, Type},
    Connection, Error as PostgresError, NoTls,
};

use serenity::model::id::MessageId;

#[derive(Debug)]
struct DbMessageId(MessageId);

impl<'a> FromSql<'a> for DbMessageId {
    fn from_sql(
        ty: &tokio_postgres::types::Type,
        raw: &'a [u8],
    ) -> Result<Self, Box<dyn std::error::Error + Sync + Send>> {
        match String::from_sql(ty, raw) {
            Ok(v) => {
                let parsed = MessageId::from_str(&v)?;
                Ok(DbMessageId(parsed))
            }
            Err(e) => Err(e),
        }
    }

    fn accepts(ty: &tokio_postgres::types::Type) -> bool {
        <String as tokio_postgres::types::FromSql>::accepts(ty)
    }
}

impl ToSql for DbMessageId {
    fn to_sql(
        &self,
        ty: &Type,
        out: &mut BytesMut,
    ) -> Result<tokio_postgres::types::IsNull, Box<dyn std::error::Error + Sync + Send>>
    where
        Self: Sized,
    {
        let str_id = self.0.to_string();
        str_id.to_sql(ty, out)
    }

    fn accepts(ty: &Type) -> bool
    where
        Self: Sized,
    {
        <String as tokio_postgres::types::ToSql>::accepts(ty)
    }

    fn to_sql_checked(
        &self,
        ty: &Type,
        out: &mut BytesMut,
    ) -> Result<tokio_postgres::types::IsNull, Box<dyn std::error::Error + Sync + Send>> {
        let str_id = self.0.to_string();
        str_id.to_sql_checked(ty, out)
    }
}

pub struct MessageStore {
    pool: Pool<PostgresConnectionManager<NoTls>>,
}

static FETCH_MESSAGE_FOR_BUILD: &str = r#"
SELECT message_id
FROM build_messages
WHERE build_id = $1
LIMIT 1;
"#;

static INSERT_MESSAGE_FOR_BUILD: &str = r#"
INSERT INTO build_messages (build_id, message_id)
VALUES ($1, $2)
ON CONFLICT DO NOTHING;
"#;

#[derive(Debug, thiserror::Error)]
pub enum MessageStoreError {
    #[error("connection pool exhausted")]
    ConnectionPoolExhausted,
    #[error("error fetching connection: {0}")]
    ConnectionError(PostgresError),
    #[error("error querying db: {0}")]
    QueryError(#[from] PostgresError),
}

#[derive(Debug, thiserror::Error)]
pub enum MessageStorePutError {
    #[error("error interacting with database: {0}")]
    DbError(#[from] MessageStoreError),
    #[error("A message for build {0} already exists")]
    KeyExists(uuid::Uuid),
}

impl From<PostgresError> for MessageStorePutError {
    fn from(value: PostgresError) -> Self {
        Self::DbError(MessageStoreError::from(value))
    }
}

impl From<RunError<PostgresError>> for MessageStorePutError {
    fn from(value: RunError<PostgresError>) -> Self {
        Self::DbError(MessageStoreError::from(value))
    }
}

#[derive(Debug, thiserror::Error)]
pub enum MessageStoreGetError {
    #[error("error interacting with database: {0}")]
    DbError(#[from] MessageStoreError),
    #[error("stored discord ID was not a valid u64: {0}")]
    InvalidMessageId(#[from] ParseIntError),
}

impl From<PostgresError> for MessageStoreGetError {
    fn from(value: PostgresError) -> Self {
        Self::DbError(MessageStoreError::from(value))
    }
}

impl From<RunError<PostgresError>> for MessageStoreGetError {
    fn from(value: RunError<PostgresError>) -> Self {
        Self::DbError(MessageStoreError::from(value))
    }
}

impl From<RunError<PostgresError>> for MessageStoreError {
    fn from(value: RunError<PostgresError>) -> Self {
        match value {
            RunError::TimedOut => Self::ConnectionPoolExhausted,
            RunError::User(e) => Self::ConnectionError(e),
        }
    }
}

impl MessageStore {
    pub async fn get_message(
        &self,
        build_id: &uuid::Uuid,
    ) -> Result<Option<MessageId>, MessageStoreGetError> {
        let res: Option<String> = self
            .pool
            .get()
            .await?
            .query_one(FETCH_MESSAGE_FOR_BUILD, &[build_id])
            .await?
            .try_get(0)
            .ok();

        // TODO: this feels kinda clunky
        match res {
            Some(id_str) => {
                let id = u64::from_str(&id_str)?;
                Ok(Some(MessageId::from(id)))
            }
            None => Ok(None),
        }
    }

    pub async fn put_message(
        &self,
        build_id: &uuid::Uuid,
        message_id: &MessageId,
    ) -> Result<(), MessageStorePutError> {
        let wrapped_msg_id = DbMessageId(*message_id);
        let res = self
            .pool
            .get()
            .await?
            .execute(INSERT_MESSAGE_FOR_BUILD, &[build_id, &wrapped_msg_id])
            .await?;

        if res == 0 {
            Err(MessageStorePutError::KeyExists(*build_id))
        } else {
            Ok(())
        }
    }
}
