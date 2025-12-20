use std::path::PathBuf;

use clap::{Parser, Subcommand};

#[derive(Subcommand, Debug, Clone)]
pub enum Command {
    Evaluate(EvaluateArgs),
    ReadJob,
}

#[derive(Parser, Debug, Clone)]
pub struct EvaluateArgs {
    data_file_path: PathBuf,
}

#[derive(Parser)]
pub struct Args {
    #[arg(short, long)]
    pub expression: String,

    #[arg(short = 'd', long = "directory")]
    pub working_directory: Option<PathBuf>,

    #[command(subcommand)]
    pub command: Command,
}
