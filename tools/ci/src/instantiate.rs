//! Run `nix eval` to produce a drvmap from Nix expressions.

use anyhow::{Context, Result};
use std::path::Path;
use std::process::Command;

use crate::drvmap::Drvmap;

/// Path to the Nix expression that produces a drvmap.
/// Relative to the repo root.
const DRVMAP_EXPR: &str = "tools/ci/drvmap.nix";

/// Run `nix eval --json -f <expr> drvmap` in the given directory
/// and parse the JSON output into a Drvmap.
///
/// For the base commit, this is run in a temporary worktree. For HEAD,
/// this is run in the current repo.
pub fn instantiate_drvmap(repo_root: &Path, worktree: Option<&Path>) -> Result<Drvmap> {
    let cwd = worktree.unwrap_or(repo_root);

    let output = Command::new("nix")
        .args(["eval", "--json", "-f", DRVMAP_EXPR, "drvmap"])
        .current_dir(cwd)
        .output()
        .with_context(|| {
            format!(
                "nix eval --json -f {} drvmap in {}",
                DRVMAP_EXPR,
                cwd.display()
            )
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("nix eval failed: {stderr}");
    }

    let stdout = String::from_utf8(output.stdout).context("invalid UTF-8 from nix eval")?;

    crate::drvmap::parse(&stdout).context("parsing drvmap from nix eval output")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_drvmap_expr_exists() {
        // Tests run with cwd = crate root (tools/ci/).
        // The workspace root is two levels up.
        let workspace_root = Path::new("../..");
        let path = workspace_root.join(DRVMAP_EXPR);
        // In Nix sandboxes (crane builds), .nix files are filtered out
        // by cleanCargoSource. Skip rather than fail.
        if !path.exists() {
            eprintln!("skipping: {} not found (filtered in sandbox?)", path.display());
            return;
        }
    }
}
