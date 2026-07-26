//! Git operations: worktree creation, merge-base computation, cleanup.

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};
use std::process::Command;

/// Create a temporary git worktree at the given commit and return its path.
///
/// The worktree is created in a temp directory. Callers are responsible
/// for cleanup via [`remove_worktree`].
pub fn create_worktree(repo_root: &Path, commit: &str, prefix: &str) -> Result<PathBuf> {
    let temp_dir = std::env::temp_dir().join(format!("ci-worktree-{}-", prefix));
    let worktree_path = temp_dir.join("worktree");
    std::fs::create_dir_all(&temp_dir)
        .with_context(|| format!("creating temp dir {}", temp_dir.display()))?;

    // If the worktree already exists from a previous run, remove it.
    if worktree_path.exists() {
        remove_worktree(&worktree_path, repo_root)?;
    }

    let output = Command::new("git")
        .args([
            "worktree",
            "add",
            "--detach",
            worktree_path.to_str().unwrap(),
            commit,
        ])
        .current_dir(repo_root)
        .output()
        .with_context(|| format!("git worktree add at {}", commit))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git worktree add failed: {stderr}");
    }

    Ok(worktree_path)
}

/// Remove a git worktree and prune the worktree list.
pub fn remove_worktree(worktree_path: &Path, repo_root: &Path) -> Result<()> {
    // Remove the worktree
    let output = Command::new("git")
        .args([
            "worktree",
            "remove",
            "--force",
            worktree_path.to_str().unwrap(),
        ])
        .current_dir(repo_root)
        .output()
        .with_context(|| format!("git worktree remove {}", worktree_path.display()))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        // It's possible the worktree was already cleaned up
        if !stderr.contains("not a working tree") {
            anyhow::bail!("git worktree remove failed: {stderr}");
        }
    }

    // Clean up the parent temp dir if it's empty now
    if let Some(parent) = worktree_path.parent() {
        let _ = std::fs::remove_dir(parent);
    }

    Ok(())
}

/// Run `git merge-base HEAD <branch>` and return the commit SHA.
pub fn merge_base(repo_root: &Path, branch: &str) -> Result<String> {
    let output = Command::new("git")
        .args(["merge-base", "HEAD", branch])
        .current_dir(repo_root)
        .output()
        .with_context(|| format!("git merge-base HEAD {branch}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git merge-base failed: {stderr}");
    }

    String::from_utf8(output.stdout)
        .context("invalid UTF-8 from git merge-base")?
        .trim()
        .to_string()
        .lines()
        .next()
        .map(|s| s.to_string())
        .ok_or_else(|| anyhow::anyhow!("empty output from git merge-base"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_merge_base_self() {
        // HEAD and HEAD should give HEAD
        let repo = Path::new(".");
        let result = merge_base(repo, "HEAD");
        assert!(result.is_ok());
    }
}
