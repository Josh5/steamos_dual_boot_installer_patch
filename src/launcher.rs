use std::env;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::plan::InstallPlan;

const EMBEDDED_RUN_SH: &str = include_str!("../run.sh");

pub struct LaunchSummary {
    pub script_path: PathBuf,
    pub wrapper_path: PathBuf,
    pub command_preview: String,
}

pub fn launch(plan: InstallPlan) -> Result<LaunchSummary, String> {
    let temp_dir = make_temp_dir()?;
    let script_path = temp_dir.join("run.sh");
    let wrapper_path = temp_dir.join("launch-installer.sh");
    fs::write(&script_path, EMBEDDED_RUN_SH).map_err(|error| format!("failed to write temporary script: {error}"))?;
    fs::write(&wrapper_path, build_wrapper_script(&plan, &script_path))
        .map_err(|error| format!("failed to write temporary launcher: {error}"))?;

    mark_executable(&script_path)?;
    mark_executable(&wrapper_path)?;

    let terminal = find_terminal().ok_or_else(|| {
        String::from("no supported terminal emulator was found (tried konsole, x-terminal-emulator, kgx, gnome-terminal)")
    })?;

    let mut command = Command::new(&terminal.binary);
    command.current_dir(&temp_dir);

    terminal.add_args(&mut command, &wrapper_path);

    command
        .spawn()
        .map_err(|error| format!("failed to launch terminal '{}': {error}", terminal.binary))?;

    let command_preview = terminal.preview(&wrapper_path);

    Ok(LaunchSummary {
        script_path,
        wrapper_path,
        command_preview,
    })
}

fn build_wrapper_script(plan: &InstallPlan, script_path: &PathBuf) -> String {
    format!(
        r#"#!/usr/bin/env bash
set -euo pipefail

cd {temp_dir}
exec sudo \
  STEAMOS_SILENT=1 \
  STEAMOS_DRY_RUN={dry_run} \
  TARGET_DISK={target_disk} \
  FREE_REGION_START_MIB={free_start_mib} \
  FREE_REGION_END_MIB={free_end_mib} \
  FIRST_NEW_PARTITION={first_new_partition} \
  ESP_SIZE=256M \
  EFI_SIZE=64M \
  ROOT_SIZE=11G \
  VAR_SIZE=1G \
  bash {script_path}
"#,
        temp_dir = shell_quote(script_path.parent().unwrap()),
        dry_run = if plan.dry_run { "1" } else { "0" },
        target_disk = shell_quote(&plan.target_disk),
        free_start_mib = plan.free_start_mib,
        free_end_mib = plan.free_end_mib,
        first_new_partition = plan.first_new_partition,
        script_path = shell_quote(script_path),
    )
}

fn mark_executable(path: &PathBuf) -> Result<(), String> {
    let mut permissions = fs::metadata(path)
        .map_err(|error| format!("failed to stat '{}': {error}", path.display()))?
        .permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions)
        .map_err(|error| format!("failed to mark '{}' executable: {error}", path.display()))
}

fn shell_quote(path: impl AsRef<std::path::Path>) -> String {
    let value = path.as_ref().to_string_lossy();
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

struct TerminalCommand {
    binary: &'static str,
    mode: TerminalMode,
}

enum TerminalMode {
    Konsole,
    DashDash,
    Exec,
}

impl TerminalCommand {
    fn add_args(&self, command: &mut Command, script_path: &PathBuf) {
        match self.mode {
            TerminalMode::Konsole => {
                command.args(["--noclose", "-e", "bash"]);
                command.arg(script_path);
            }
            TerminalMode::DashDash => {
                command.args(["--", "bash"]);
                command.arg(script_path);
            }
            TerminalMode::Exec => {
                command.args(["-e", "bash"]);
                command.arg(script_path);
            }
        }
    }

    fn preview(&self, script_path: &PathBuf) -> String {
        match self.mode {
            TerminalMode::Konsole => format!("{} --noclose -e bash {}", self.binary, script_path.display()),
            TerminalMode::DashDash => format!("{} -- bash {}", self.binary, script_path.display()),
            TerminalMode::Exec => format!("{} -e bash {}", self.binary, script_path.display()),
        }
    }
}

fn find_terminal() -> Option<TerminalCommand> {
    let candidates = [
        TerminalCommand {
            binary: "konsole",
            mode: TerminalMode::Konsole,
        },
        TerminalCommand {
            binary: "x-terminal-emulator",
            mode: TerminalMode::Exec,
        },
        TerminalCommand {
            binary: "kgx",
            mode: TerminalMode::DashDash,
        },
        TerminalCommand {
            binary: "gnome-terminal",
            mode: TerminalMode::DashDash,
        },
    ];

    candidates
        .into_iter()
        .find(|candidate| command_in_path(candidate.binary))
}

fn command_in_path(binary: &str) -> bool {
    env::var_os("PATH")
        .into_iter()
        .flat_map(|paths| env::split_paths(&paths).collect::<Vec<_>>())
        .map(|path| path.join(binary))
        .any(|candidate| candidate.exists())
}

fn make_temp_dir() -> Result<PathBuf, String> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| format!("failed to read system clock: {error}"))?
        .as_millis();
    let path = env::temp_dir().join(format!("steamos-installer-wizard-{timestamp}"));
    fs::create_dir_all(&path).map_err(|error| format!("failed to create temporary directory: {error}"))?;
    Ok(path)
}
