use std::env::current_dir;

use clap::Parser;

use crate::args::Args;
use crate::monitor::Monitor;

mod args;
mod build_state;
mod monitor;
mod nix_line;
mod parser;

fn main() {
    let args = Args::parse();
    let wd = args
        .working_directory
        .unwrap_or_else(|| current_dir().unwrap());

    let mut monitor = Monitor::new(wd, &[&args.expression]);
    monitor.build();
}
