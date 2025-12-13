use std::io::{BufRead, BufReader, Error as IoError, Read};

use crate::nix_line::NixLine;
pub struct NixParser<R: Read> {
    reader: BufReader<R>,
    buffer: String,
}

#[derive(Debug, thiserror::Error)]
pub enum ReadError {
    // TODO: flesh out this type?
    #[error("error parsing json: {0}")]
    ParseError(#[from] serde_json::Error),
    #[error("IO Error: {0}")]
    Io(#[from] IoError),
}

impl<R: Read> NixParser<R> {
    pub fn new(reader: R) -> Self {
        let reader = BufReader::new(reader);
        let buffer = String::with_capacity(2048);

        Self { reader, buffer }
    }

    pub fn read_line(&mut self) -> Result<Option<NixLine>, ReadError> {
        let len = loop {
            self.buffer.clear();
            let len = self.reader.read_line(&mut self.buffer)?;
            if len == 0 {
                return Ok(None);
            }

            if !self.buffer.starts_with("@nix ") {
                continue;
            }

            break len;
        };

        let json_str = &self.buffer[5..len];
        let event: NixLine = serde_json::from_str(json_str)?;
        Ok(Some(event))
    }
}
