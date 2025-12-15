use std::collections::HashSet;
use std::ffi::OsString;
use std::io;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};

use clap::Parser;
use git2::Repository;

use crate::cli::Args;

mod cli;

#[derive(Debug, thiserror::Error)]
enum RuntimeError {
    #[error("Error opening repo: {0}")]
    OpeningRepo(git2::Error),
    #[error("Getting HEAD failed (maybe we are in a detached HEAD state?) {0}")]
    NoHead(git2::Error),
    #[error("Could not peel HEAD to a commit: {0}")]
    PeelingToCommit(git2::Error),
    #[error("Failed to prepare GCRoot: {0}")]
    CheckingGCRoot(io::Error),
    #[error("Failed to cleanup old pointer for current GCRoot: {0}")]
    CleaingStaleGCRec(io::Error),
    #[error("Creating new symlink: {0}")]
    CreatingLink(io::Error),
    #[error("Failed to cleanup pointers to old GCRoots: {0}")]
    CleaningOutdatedGCRec(io::Error),

    #[error("Refusing to use a GCRoot directory outside of the nix store: {0} given")]
    GCRootDirOutsideNixStore(PathBuf),
    #[error("Refusing to point to an artifact outside of the nix store: {0} given")]
    DestinationOutsideNixStore(PathBuf),
}

fn main() {
    if let Err(e) = real_main() {
        eprintln!("Error: {e}");
        std::process::exit(1);
    }
}

enum SymlinkState {
    Current,
    Stale,
    Empty,
}

fn check_dest(path: &Path, exp_dest: &Path) -> std::io::Result<SymlinkState> {
    if !path.exists() {
        return Ok(SymlinkState::Empty);
    }

    let stat = path.symlink_metadata()?;
    if !stat.is_symlink() {
        return Ok(SymlinkState::Stale);
    }
    let act_dest = std::fs::read_link(path)?;
    Ok(if act_dest == exp_dest {
        SymlinkState::Current
    } else {
        SymlinkState::Stale
    })
}

fn real_main() -> Result<(), RuntimeError> {
    env_logger::init();
    let args = Args::parse();

    if !args.gcroot_dir.starts_with("/nix/var/nix/gcroots/") {
        return Err(RuntimeError::GCRootDirOutsideNixStore(args.gcroot_dir));
    }

    if !args.artifact.starts_with("/nix/store/") {
        return Err(RuntimeError::DestinationOutsideNixStore(args.artifact));
    }

    log::trace!("opening repo {:#?}", args.repository_dir);
    let repo = args
        .repository_dir
        .as_ref()
        .map(Repository::open)
        .unwrap_or_else(Repository::open_from_env)
        .map_err(RuntimeError::OpeningRepo)?;

    let head = repo.head().map_err(RuntimeError::NoHead)?;
    let commit = head
        .peel_to_commit()
        .map_err(RuntimeError::PeelingToCommit)?;
    log::trace!("operating at commit {:#?}", commit);
    let parents: Vec<_> = commit
        .parents()
        .take(args.commits_to_keep as usize - 1)
        .map(|c| (c.id().to_string(), c))
        .collect();

    let parent_hashes = parents.iter().map(|(hash, _)| hash.to_string());
    let hashes: HashSet<_> = std::iter::chain([commit.id().to_string()], parent_hashes)
        .map(OsString::from)
        .collect();

    let commit_hash = commit.id().to_string();
    let path = args.gcroot_dir.join(commit_hash);

    let state = check_dest(&path, &args.artifact).map_err(RuntimeError::CheckingGCRoot)?;
    let create = match state {
        SymlinkState::Current => false,
        SymlinkState::Empty => true,
        SymlinkState::Stale => {
            std::fs::remove_dir_all(&path).map_err(RuntimeError::CleaingStaleGCRec)?;
            true
        },
    };

    if create {
        log::debug!("creating symlink of {:#?} -> {:#?}", path, args.artifact);
        symlink(&args.artifact, &path).map_err(RuntimeError::CreatingLink)?;
    }

    let dir_walker =
        std::fs::read_dir(&args.gcroot_dir).map_err(RuntimeError::CleaningOutdatedGCRec)?;

    let entries_to_delete: Vec<_> = dir_walker
        .map(|e| e.expect("failed to walk directory"))
        .filter(|i| !hashes.contains(&i.file_name()))
        .collect();

    for entry in entries_to_delete.into_iter() {
        let meta = entry
            .metadata()
            .map_err(RuntimeError::CleaningOutdatedGCRec)?;
        let path = entry.path();
        log::debug!("deleting: {:#?}", path);
        if meta.is_dir() {
            std::fs::remove_dir_all(path).map_err(RuntimeError::CleaningOutdatedGCRec)?;
        } else {
            std::fs::remove_file(path).map_err(RuntimeError::CleaningOutdatedGCRec)?;
        }
    }

    Ok(())
}
