//! `hark-mcp install` — registers this binary as an MCP server with Claude
//! Code, OpenCode, and/or Codex by parse-merge-writing their config files.
//! Unrelated config content is preserved; the original file is backed up to
//! `<file>.bak` once (never overwriting an existing backup).

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use clap::ValueEnum;
use serde_json::{json, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Client {
    Claude,
    Opencode,
    Codex,
    All,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Scope {
    /// Config in the current directory (per-repo).
    Project,
    /// Config in the user's home directory (all repos).
    User,
}

pub fn run(client: Client, scope: Scope) -> Result<()> {
    let exe = std::env::current_exe()
        .context("could not determine this binary's path")?
        .canonicalize()
        .context("could not canonicalize this binary's path")?;
    let exe_str = exe.to_string_lossy().into_owned();

    match client {
        Client::Claude => install_claude(&exe_str, scope)?,
        Client::Opencode => install_opencode(&exe_str, scope)?,
        Client::Codex => install_codex(&exe_str, scope)?,
        Client::All => {
            install_claude(&exe_str, scope)?;
            install_opencode(&exe_str, scope)?;
            install_codex(&exe_str, scope)?;
        }
    }
    Ok(())
}

fn home_dir() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME is not set")
}

/// Copies `path` to `<path>.bak` the first time it is modified; an existing
/// backup is never overwritten.
fn backup_once(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let bak = PathBuf::from(format!("{}.bak", path.display()));
    if bak.exists() {
        return Ok(());
    }
    fs::copy(path, &bak).with_context(|| format!("could not back up {}", path.display()))?;
    println!("  backed up original to {}", bak.display());
    Ok(())
}

/// Reads `path` as a JSON object (empty object when absent), refusing to
/// touch a file that doesn't parse — never clobber what we can't merge.
fn read_json_object(path: &Path) -> Result<serde_json::Map<String, Value>> {
    if !path.exists() {
        return Ok(serde_json::Map::new());
    }
    let raw = fs::read_to_string(path)
        .with_context(|| format!("could not read {}", path.display()))?;
    if raw.trim().is_empty() {
        return Ok(serde_json::Map::new());
    }
    let value: Value = serde_json::from_str(&raw).with_context(|| {
        format!(
            "{} exists but is not valid JSON — fix or remove it, then re-run install",
            path.display()
        )
    })?;
    match value {
        Value::Object(map) => Ok(map),
        _ => bail!(
            "{} exists but its top level is not a JSON object — refusing to modify it",
            path.display()
        ),
    }
}

fn write_json_object(path: &Path, map: serde_json::Map<String, Value>) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("could not create {}", parent.display()))?;
    }
    let mut out = serde_json::to_string_pretty(&Value::Object(map))?;
    out.push('\n');
    fs::write(path, out).with_context(|| format!("could not write {}", path.display()))?;
    Ok(())
}

/// Claude Code. Project scope: merge into ./.mcp.json. User scope: Claude
/// stores user-scope servers in its own config, managed by the CLI — print
/// the exact command instead of poking at internals.
fn install_claude(exe: &str, scope: Scope) -> Result<()> {
    match scope {
        Scope::Project => {
            let path = PathBuf::from(".mcp.json");
            let mut root = read_json_object(&path)?;
            backup_once(&path)?;
            let servers = root
                .entry("mcpServers")
                .or_insert_with(|| json!({}));
            let Value::Object(servers) = servers else {
                bail!(".mcp.json has a non-object \"mcpServers\" key — refusing to modify it");
            };
            servers.insert(
                "hark".into(),
                json!({ "command": exe, "args": ["serve"] }),
            );
            write_json_object(&path, root)?;
            println!(
                "Claude Code (project): wrote server \"hark\" ({exe} serve) to {}",
                fs::canonicalize(&path).unwrap_or(path).display()
            );
        }
        Scope::User => {
            println!("Claude Code (user): user-scope servers are managed by the claude CLI. Run:");
            println!("  claude mcp add --scope user hark -- {exe} serve");
        }
    }
    Ok(())
}

/// OpenCode: `opencode.json` — project scope in the current directory, user
/// scope in ~/.config/opencode/.
fn install_opencode(exe: &str, scope: Scope) -> Result<()> {
    let path = match scope {
        Scope::Project => PathBuf::from("opencode.json"),
        Scope::User => home_dir()?.join(".config/opencode/opencode.json"),
    };
    let mut root = read_json_object(&path)?;
    let existed = path.exists();
    backup_once(&path)?;
    if !existed {
        root.entry("$schema")
            .or_insert_with(|| json!("https://opencode.ai/config.json"));
    }
    let mcp = root.entry("mcp").or_insert_with(|| json!({}));
    let Value::Object(mcp) = mcp else {
        bail!(
            "{} has a non-object \"mcp\" key — refusing to modify it",
            path.display()
        );
    };
    mcp.insert(
        "hark".into(),
        json!({ "type": "local", "command": [exe, "serve"], "enabled": true }),
    );
    write_json_object(&path, root)?;
    println!(
        "OpenCode ({scope:?} scope): wrote mcp server \"hark\" ({exe} serve) to {}",
        fs::canonicalize(&path).unwrap_or(path).display()
    );
    Ok(())
}

/// Codex: ~/.codex/config.toml, `[mcp_servers.hark]`. Codex has no per-project
/// MCP config, so scope is ignored (with a note). toml_edit preserves the
/// file's existing comments, formatting, and unrelated tables.
fn install_codex(exe: &str, scope: Scope) -> Result<()> {
    if scope == Scope::Project {
        println!("Codex: MCP servers are configured globally (~/.codex/config.toml); the project scope does not apply.");
    }
    let path = home_dir()?.join(".codex/config.toml");
    let mut doc: toml_edit::DocumentMut = if path.exists() {
        fs::read_to_string(&path)
            .with_context(|| format!("could not read {}", path.display()))?
            .parse()
            .with_context(|| {
                format!(
                    "{} exists but is not valid TOML — fix or remove it, then re-run install",
                    path.display()
                )
            })?
    } else {
        toml_edit::DocumentMut::new()
    };
    backup_once(&path)?;

    let servers = doc
        .entry("mcp_servers")
        .or_insert(toml_edit::Item::Table(toml_edit::Table::new()));
    let Some(servers) = servers.as_table_mut() else {
        bail!(
            "{} has a non-table `mcp_servers` key — refusing to modify it",
            path.display()
        );
    };
    // Keep `[mcp_servers]` implicit so only `[mcp_servers.hark]` is emitted.
    servers.set_implicit(true);

    let mut hark = toml_edit::Table::new();
    hark["command"] = toml_edit::value(exe);
    let mut args = toml_edit::Array::new();
    args.push("serve");
    hark["args"] = toml_edit::value(args);
    servers.insert("hark", toml_edit::Item::Table(hark));

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("could not create {}", parent.display()))?;
    }
    fs::write(&path, doc.to_string())
        .with_context(|| format!("could not write {}", path.display()))?;
    println!(
        "Codex: wrote [mcp_servers.hark] (command = {exe}, args = [\"serve\"]) to {}",
        path.display()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_reader_refuses_invalid_and_non_object() {
        let dir = std::env::temp_dir().join(format!("hark-install-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let bad = dir.join("bad.json");
        fs::write(&bad, "{ not json").unwrap();
        assert!(read_json_object(&bad).is_err());
        let arr = dir.join("arr.json");
        fs::write(&arr, "[1,2]").unwrap();
        assert!(read_json_object(&arr).is_err());
        let missing = dir.join("missing.json");
        assert!(read_json_object(&missing).unwrap().is_empty());
    }
}
