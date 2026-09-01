pub mod db;
pub mod ffi;
pub mod knowledge;
pub mod models;

pub use db::Db;

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("database error: {0}")]
    Db(#[from] rusqlite::Error),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error(
        "Hark database is older than this hark-mcp (schema v{found}, need v{required}) — \
         open the Hark app once to migrate it"
    )]
    SchemaOutOfDate { found: i64, required: usize },
}

pub type Result<T> = std::result::Result<T, Error>;
