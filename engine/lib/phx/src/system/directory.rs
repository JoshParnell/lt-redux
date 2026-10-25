use std::io::ErrorKind;
use std::path::PathBuf;
use std::sync::OnceLock;
use std::{env, fs};

use directories::ProjectDirs;
use tracing::error;

static PREF_PATH_OVERRIDE: OnceLock<String> = OnceLock::new();

#[repr(C)]
pub struct Directory {
    pub iterator: fs::ReadDir,
}

impl Directory {
    /// Make `get_pref_path` return `path` for the rest of the run.
    pub fn override_pref_path(path: &str) {
        let _ = PREF_PATH_OVERRIDE.set(path.into());
    }
}

#[luajit_ffi_gen::luajit_ffi]
impl Directory {
    pub fn open(path: &str) -> Option<Self> {
        match fs::read_dir(path) {
            Ok(dir) => Some(Self { iterator: dir }),
            Err(err) => {
                error!("Cannot open directory: {path}. Error: {err}");

                None
            }
        }
    }

    pub fn get_next(&mut self) -> Option<String> {
        match self.iterator.next() {
            Some(Ok(dir)) => dir.file_name().to_str().map(|s| s.to_string()),
            Some(Err(err)) => {
                error!("Cannot get next item in the folder. Error: {err}");
                None
            }
            None => None,
        }
    }

    pub fn change(cwd: &str) -> bool {
        if let Err(err) = env::set_current_dir(cwd) {
            error!("Cannot change current directory. Error: {err}");
            return false;
        }
        true
    }

    pub fn create(path: &str) -> bool {
        if let Err(err) = fs::create_dir(path) {
            if err.kind() != ErrorKind::AlreadyExists {
                error!("Failed to create directory. Error: {err}");
                return false;
            }
        }
        true
    }

    pub fn get_current() -> Option<String> {
        match env::current_dir() {
            Ok(path) => path.to_str().map(|path_str| path_str.into()),
            Err(err) => {
                error!("Cannot get current directory. Error: {err}");
                None
            }
        }
    }

    pub fn get_pref_path(org: &str, app: &str) -> Option<String> {
        let path = match PREF_PATH_OVERRIDE.get() {
            Some(path) => PathBuf::from(path),
            None => match ProjectDirs::from("", org, app) {
                Some(proj_dirs) => proj_dirs.data_dir().to_path_buf(),
                None => {
                    error!("Cannot get project directory.");
                    return None;
                }
            },
        };

        if let Err(err) = std::fs::create_dir_all(&path) {
            error!("Cannot create project dir: {path:?}. Error: {err}");
            None
        } else if let Some(path_str) = path.to_str() {
            Some(format!("{path_str}/"))
        } else {
            error!("Path is not valid UTF-8: {path:?}");
            None
        }
    }

    pub fn remove(path: &str) -> bool {
        if let Err(err) = fs::remove_dir(path) {
            error!("Cannot remove directory. Error: {err}");
            return false;
        }
        true
    }
}
