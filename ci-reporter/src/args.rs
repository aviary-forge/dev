use std::path::PathBuf;

use clap::Parser;

#[derive(Parser)]
pub struct Args {
    #[arg(short, long)]
    pub expression: String,

    #[arg(short = 'd', long = "directory")]
    pub working_directory: Option<PathBuf>,
}
