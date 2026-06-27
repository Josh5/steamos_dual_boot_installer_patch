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
    pub command_preview: String,
}

pub fn launch(plan: InstallPlan) -> Result<LaunchSummary, String> {
    let temp_dir = make_temp_dir()?;
    let script_path = temp_dir.join("run.sh");
    fs::write(&script_path, EMBEDDED_RUN_SH).map_err(|error| format!("failed to write temporary script: {error}"))?;

    let mut permissions = fs::metadata(&script_path)
        .map_err(|error| format!("failed to stat temporary script: {error}"))?
        .permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&script_path, permissions)
        .map_err(|error| format!("failed to mark temporary script executable: {error}"))?;

    let terminal = find_terminal().ok_or_else(|| {
        String::from("no supported terminal emulator was found (tried konsole, x-terminal-emulator, kgx, gnome-terminal)")
    })?;

    let mut command = Command::new(&terminal.binary);
    command.current_dir(&temp_dir);
    command.env("STEAMOS_SILENT", "1");
    command.env("STEAMOS_DRY_RUN", if plan.dry_run { "1" } else { "0" });
    command.env("TARGET_DISK", &plan.target_disk);
    command.env("FREE_REGION_START_MIB", plan.free_start_mib.to_string());
    command.env("FREE_REGION_END_MIB", plan.free_end_mib.to_string());
    command.env("FIRST_NEW_PARTITION", plan.first_new_partition.to_string());
    command.env("ESP_SIZE", "256M");
    command.env("EFI_SIZE", "64M");
    command.env("ROOT_SIZE", "11G");
    command.env("VAR_SIZE", "1G");

    terminal.add_args(&mut command, &script_path);

    command
        .spawn()
        .map_err(|error| format!("failed to launch terminal '{}': {error}", terminal.binary))?;

    let command_preview = terminal.preview(&script_path);

    Ok(LaunchSummary {
        script_path,
        command_preview,
    })
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
