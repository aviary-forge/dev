use core::convert::From;
use core::default::Default;
use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::PathBuf;
use std::process::{exit, Command, Stdio};
use std::sync::OnceLock;

use regex::Regex;

use crate::nix_line::{Activity, NixLine};
use crate::parser::NixParser;

fn exit_code_failure_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r"builder for '([^']+)' failed with exit code \d+")
            .expect("Failed to compile exit code failure regex")
    })
}

fn hash_mismatch_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r"hash mismatch in fixed-output derivation '([^']+)':")
            .expect("Failed to compile hash mismatch regex")
    })
}

pub struct Monitor {
    working_directory: PathBuf,
    expressions: Vec<String>,
}

impl Monitor {
    pub fn new(directory: impl Into<PathBuf>, expressions: &[&str]) -> Self {
        Self {
            working_directory: directory.into(),
            expressions: expressions.iter().map(|s| s.to_string()).collect(),
        }
    }

    pub fn build(&mut self) {
        let mut instantiate_cmd = Command::new("nix-instantiate");
        instantiate_cmd.current_dir(&self.working_directory);
        for expr in self.expressions.iter() {
            instantiate_cmd.arg("-A").arg(expr);
        }

        let instantiate_output = match instantiate_cmd.output() {
            Ok(p) => p,
            Err(e) => {
                eprintln!("error running nix-instantiate: {}", e);
                exit(1);
            },
        };

        let deriv_path = match instantiate_output.status.code() {
            Some(0) => String::from_utf8(instantiate_output.stdout)
                .expect("nix-instantiate produced invalid string")
                .trim()
                .to_string(),
            Some(n) => {
                eprintln!("process exited with status {n}");
                std::io::stdout()
                    .write_all(&instantiate_output.stderr)
                    .expect("failed to write stderr");
                exit(1);
            },
            None => {
                eprintln!("process terminated by signal");
                exit(1);
            },
        };

        eprintln!("realising derivation: {deriv_path}");

        // TODO: consolidate into a two-way map?
        let mut active_tasks: HashMap<u64, String> = Default::default();
        let mut reverse_task_map: HashMap<String, u64> = Default::default();
        let mut completed_derivs: HashSet<String> = Default::default();
        let mut failed_derivs: HashSet<String> = Default::default();

        let build_handle_result = Command::new("nix-store")
            .current_dir(&self.working_directory)
            .arg("--log-format")
            .arg("internal-json")
            .arg("--realise")
            .stderr(Stdio::piped())
            .stdout(Stdio::null())
            .arg(&deriv_path)
            .spawn();
        let mut build_handle = match build_handle_result {
            Ok(handle) => handle,
            Err(e) => {
                eprintln!("failed to spawn nix-build process: {e}");
                exit(1);
            },
        };
        let monitored_derivs = HashSet::from([deriv_path]);
        let mut reader = NixParser::new(build_handle.stderr.as_mut().unwrap());
        loop {
            let item = match reader.read_line() {
                Err(e) => {
                    eprintln!("error reading line: {}", e);
                    exit(1);
                },
                Ok(Some(item)) => item,
                Ok(None) => break,
            };

            match item {
                NixLine::Start(event) => {
                    if let Activity::Build {
                        derivation,
                        host: _,
                    } = event.activity
                    {
                        if monitored_derivs.contains(&derivation) {
                            eprintln!("started building {derivation}");
                            reverse_task_map.insert(derivation.clone(), event.id);
                            active_tasks.insert(event.id, derivation);
                        }
                    }
                },
                NixLine::Stop(event) => {
                    if let Some(derivation) = active_tasks.remove(&event.id) {
                        eprintln!("finished building {derivation}");
                        reverse_task_map.remove(&derivation);
                        completed_derivs.insert(derivation);
                    }
                },
                NixLine::Msg(event) => {
                    if event.level <= 3 {
                        eprintln!("{}", event.msg);
                    }

                    // Check for build failures using regex
                    if event.level == 0 {
                        let derivation = exit_code_failure_regex()
                            .captures(&event.msg)
                            .or_else(|| hash_mismatch_regex().captures(&event.msg))
                            .and_then(|caps| caps.get(1))
                            .map(|m| m.as_str());

                        if let Some(drv_path) = derivation {
                            // Only track failures for builds we're monitoring
                            if let Some(id) = reverse_task_map.remove(drv_path) {
                                eprintln!("errored while building {}", drv_path);
                                active_tasks.remove(&id);
                                failed_derivs.insert(drv_path.to_string());
                            }
                        }
                    }
                },
                NixLine::Result(_result_event) => (),
            }
        }

        match build_handle.wait() {
            Ok(status) => match status.code() {
                Some(0) => {},
                Some(n) => {
                    eprintln!("nix-build exited with status {n}");
                    exit(n);
                },
                None => {
                    eprintln!("nix-build was killed by signal");
                    exit(1);
                },
            },
            Err(e) => {
                eprintln!("failed to wait for child: {e}");
                exit(1);
            },
        }
    }
}
