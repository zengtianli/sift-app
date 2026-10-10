//! Sift engine: Cardinal's file-name index behind a C ABI (for the Swift app),
//! a local socket (for the CLI) and an offline reader.

mod alloc;
pub mod config;
pub mod engine;
pub mod ffi;
pub mod ipc;
pub mod offline;
pub mod query;
mod recovery;
pub mod service;


#[global_allocator]
static GLOBAL: alloc::SiftAlloc = alloc::SiftAlloc;
