//! hark-mcp — stdio MCP server over the Hark knowledge base (Phase 4).
//!
//! Default command serves MCP over stdio against the app's SQLite database,
//! opened strictly read-only (safe alongside a running Hark app: WAL +
//! busy_timeout). `install` registers this binary with Claude Code,
//! OpenCode, and/or Codex.
//!
//! stdout carries the newline-delimited JSON-RPC transport — all logging
//! goes to stderr.

mod install;
mod server;

use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, Subcommand};
use rmcp::{transport::stdio, ServiceExt};

use server::{HarkService, EMBEDDING_CACHE_DIR};

#[derive(Debug, Parser)]
#[command(
    name = "hark-mcp",
    version,
    about = "Hark MCP server: search and read your local meeting transcripts and dictations \
             from Claude Code, OpenCode, or Codex"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    #[command(flatten)]
    serve_args: ServeArgs,
}

#[derive(Debug, Clone, clap::Args)]
struct ServeArgs {
    /// Path to the Hark SQLite database
    /// (default: ~/Library/Application Support/Hark/hark.sqlite)
    #[arg(long, global = true)]
    db: Option<PathBuf>,

    /// Directory of the cached embedding model used for hybrid search
    /// (default: ~/Library/Application Support/Hark/models). If the model
    /// isn't cached there, search degrades to keyword-only — it never
    /// downloads anything.
    #[arg(long, global = true)]
    models: Option<PathBuf>,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Serve MCP over stdio (the default when no command is given)
    Serve,
    /// Register this binary as an MCP server with AI coding tools
    Install {
        /// Which client to configure
        #[arg(long, value_enum)]
        client: install::Client,
        /// Where the config lives: the current directory or the home directory
        #[arg(long, value_enum, default_value = "project")]
        scope: install::Scope,
    },
}

fn hark_support_dir() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
        .join("Library/Application Support/Hark")
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Some(Command::Install { client, scope }) => install::run(client, scope),
        Some(Command::Serve) | None => serve(cli.serve_args).await,
    }
}

async fn serve(args: ServeArgs) -> Result<()> {
    let db_path = args
        .db
        .unwrap_or_else(|| hark_support_dir().join("hark.sqlite"));
    let models_dir = args.models.unwrap_or_else(|| hark_support_dir().join("models"));

    let (service, hybrid) = HarkService::new(db_path.clone(), models_dir.clone());
    eprintln!("hark-mcp: serving over stdio, db = {}", db_path.display());
    if hybrid {
        eprintln!(
            "hark-mcp: hybrid search enabled (embedding model cached at {})",
            models_dir.join(EMBEDDING_CACHE_DIR).display()
        );
    } else {
        eprintln!(
            "hark-mcp: embedding model not found under {} — search runs keyword-only \
             (open the Hark app once to download the model)",
            models_dir.display()
        );
    }
    if !db_path.exists() {
        eprintln!(
            "hark-mcp: warning: no database at {} — tools will error until the Hark app has run once",
            db_path.display()
        );
    }

    let running = service
        .serve(stdio())
        .await
        .inspect_err(|e| eprintln!("hark-mcp: failed to start: {e}"))?;
    running.waiting().await?;
    Ok(())
}
