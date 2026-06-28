mod discovery;
mod launcher;
mod plan;

use std::cell::RefCell;
use std::process;
use std::rc::{Rc, Weak};

use discovery::{DiskRecord, FreeRegion};
use launcher::LaunchSummary;
use plan::{InstallPlan, PlanOptions};
use slint::{Model, ModelRc, VecModel};

slint::include_modules!();

const DRY_RUN_FORCED: bool = cfg!(feature = "dry-run-forced");
const RUN_SH_VERSION: &str = env!("RUN_SH_VERSION");

struct AppState {
    current_stage: i32,
    disks: Vec<DiskRecord>,
    disk_rows: Rc<VecModel<DiskCardData>>,
    region_rows: Rc<VecModel<RegionCardData>>,
    selected_disk: Option<usize>,
    selected_region: Option<usize>,
    plan: Option<InstallPlan>,
    dry_run: bool,
    execution_text: String,
    execution_title: String,
    error_text: String,
}

impl AppState {
    fn new() -> Self {
        let (disks, error_text) = match discovery::discover_disks() {
            Ok(disks) => (disks, String::new()),
            Err(error) => (Vec::new(), format!("Disk discovery failed: {error}")),
        };

        Self {
            current_stage: 0,
            disks,
            disk_rows: Rc::new(VecModel::from(Vec::<DiskCardData>::new())),
            region_rows: Rc::new(VecModel::from(Vec::<RegionCardData>::new())),
            selected_disk: None,
            selected_region: None,
            plan: None,
            dry_run: DRY_RUN_FORCED,
            execution_text: String::new(),
            execution_title: String::from("Waiting to launch installer"),
            error_text,
        }
    }

    fn selected_disk_record(&self) -> Option<&DiskRecord> {
        self.selected_disk.and_then(|idx| self.disks.get(idx))
    }

    fn selected_region_record(&self) -> Option<&FreeRegion> {
        self.selected_disk_record()
            .and_then(|disk| self.selected_region.and_then(|idx| disk.free_regions.get(idx)))
    }

    fn rebuild_plan(&mut self) {
        self.plan = match (self.selected_disk_record(), self.selected_region_record()) {
            (Some(disk), Some(region)) => plan::build_plan(
                disk,
                region,
                PlanOptions {
                    dry_run: self.dry_run,
                },
            )
            .ok(),
            _ => None,
        };
    }

    fn can_next(&self) -> bool {
        match self.current_stage {
            0 => true,
            1 => self.selected_disk.is_some(),
            2 => self.selected_region.is_some() && self.plan.is_some(),
            _ => false,
        }
    }

    fn can_run(&self) -> bool {
        self.current_stage == 3 && self.plan.is_some()
    }

    fn can_close(&self) -> bool {
        self.current_stage < 4 || !self.execution_text.is_empty()
    }

    fn next(&mut self) {
        if !self.can_next() {
            return;
        }
        if self.current_stage < 3 {
            self.current_stage += 1;
        }
    }

    fn back(&mut self) {
        if self.current_stage > 0 && self.current_stage < 4 {
            self.current_stage -= 1;
        }
    }

    fn select_disk(&mut self, index: usize) {
        if index >= self.disks.len() {
            return;
        }
        self.selected_disk = Some(index);
        self.selected_region = None;
        self.plan = None;
        self.error_text.clear();
    }

    fn select_region(&mut self, index: usize) {
        if let Some(disk) = self.selected_disk_record() {
            if index >= disk.free_regions.len() {
                return;
            }
        } else {
            return;
        }
        self.selected_region = Some(index);
        self.rebuild_plan();
    }

    fn launch(&mut self) -> bool {
        let Some(plan) = self.plan.clone() else {
            self.error_text = String::from("Install plan is not ready.");
            return false;
        };

        match launcher::launch(plan) {
            Ok(summary) => {
                self.execution_title = String::from("Installer terminal launched");
                self.execution_text = render_launch_summary(&summary, self.dry_run);
                self.error_text.clear();
                true
            }
            Err(error) => {
                self.current_stage = 4;
                self.execution_title = String::from("Failed to launch installer");
                self.execution_text = format!(
                    "The backend terminal could not be launched.\n\n{}\n\nNo disk changes were started.",
                    error
                );
                self.error_text = self.execution_text.clone();
                false
            }
        }
    }
}

fn main() -> Result<(), slint::PlatformError> {
    let app = AppWindow::new()?;
    let state = Rc::new(RefCell::new(AppState::new()));

    {
        let state_ref = state.borrow();
        app.set_disks(ModelRc::from(state_ref.disk_rows.clone()));
        app.set_regions(ModelRc::from(state_ref.region_rows.clone()));
    }

    sync_ui(&app, &state);

    wire_callbacks(&app, Rc::downgrade(&state));

    app.run()
}

fn wire_callbacks(app: &AppWindow, state: Weak<RefCell<AppState>>) {
    let state_select_disk = state.clone();
    let weak = app.as_weak();
    app.on_select_disk(move |index| {
        if let Some(state) = state_select_disk.upgrade() {
            state.borrow_mut().select_disk(index as usize);
            if let Some(app) = weak.upgrade() {
                sync_ui(&app, &state);
            }
        }
    });

    let state_select_region = state.clone();
    let weak = app.as_weak();
    app.on_select_region(move |index| {
        if let Some(state) = state_select_region.upgrade() {
            state.borrow_mut().select_region(index as usize);
            if let Some(app) = weak.upgrade() {
                sync_ui(&app, &state);
            }
        }
    });

    let state_next = state.clone();
    let weak = app.as_weak();
    app.on_next(move || {
        if let Some(state) = state_next.upgrade() {
            state.borrow_mut().next();
            if let Some(app) = weak.upgrade() {
                sync_ui(&app, &state);
            }
        }
    });

    let state_back = state.clone();
    let weak = app.as_weak();
    app.on_back(move || {
        if let Some(state) = state_back.upgrade() {
            state.borrow_mut().back();
            if let Some(app) = weak.upgrade() {
                sync_ui(&app, &state);
            }
        }
    });

    let state_run = state.clone();
    let weak = app.as_weak();
    app.on_run_installer(move || {
        if let Some(state) = state_run.upgrade() {
            let launched = state.borrow_mut().launch();
            if let Some(app) = weak.upgrade() {
                sync_ui(&app, &state);
            }
            if launched {
                process::exit(0);
            }
        }
    });

    app.on_close_app(move || {
        process::exit(0);
    });
}

fn sync_ui(app: &AppWindow, state: &Rc<RefCell<AppState>>) {
    let state_ref = state.borrow_mut();

    app.set_current_stage(state_ref.current_stage);
    app.set_dry_run(state_ref.dry_run);
    app.set_can_next(state_ref.can_next());
    app.set_can_run(state_ref.can_run());
    app.set_can_close(state_ref.can_close());
    app.set_execution_title(state_ref.execution_title.clone().into());
    app.set_execution_text(state_ref.execution_text.clone().into());
    app.set_error_text(state_ref.error_text.clone().into());
    app.set_selected_disk_summary(selected_disk_summary(&state_ref).into());
    app.set_selected_region_summary(selected_region_summary(&state_ref).into());
    app.set_stage_subtitle(stage_subtitle(&state_ref).into());
    app.set_wizard_version(format!("Version {RUN_SH_VERSION}").into());
    app.set_review_target_disk(review_target_disk(&state_ref).into());
    app.set_review_detected_model(review_detected_model(&state_ref).into());
    app.set_review_selected_free_space(review_selected_free_space(&state_ref).into());
    app.set_review_summary_text(review_summary_text(&state_ref).into());

    let disk_rows = state_ref
        .disks
        .iter()
        .enumerate()
        .map(|(index, disk)| {
            let usable = disk
                .free_regions
                .iter()
                .any(|region| plan::region_is_large_enough(region));

            DiskCardData {
                title: disk.path.clone().into(),
                subtitle: format!(
                    "{} | {}",
                    disk.display_name(),
                    disk.human_size()
                )
                .into(),
                details: format!(
                    "Free regions: {} | Largest: {}\nPartitions: {} | {}",
                    disk.free_regions.len(),
                    disk.partitions.len(),
                    disk.largest_free_region_human(),
                    disk.partition_summary()
                )
                .into(),
                status: if usable {
                    "USABLE".into()
                } else if disk.free_regions.is_empty() {
                    "NO FREE SPACE".into()
                } else {
                    "TOO SMALL".into()
                },
                is_selected: state_ref.selected_disk == Some(index),
                is_valid: usable,
            }
        })
        .collect::<Vec<_>>();
    replace_rows(&state_ref.disk_rows, disk_rows);

    let region_rows = state_ref
        .selected_disk_record()
        .map(|disk| {
            disk.free_regions
                .iter()
                .enumerate()
                .map(|(index, region)| RegionCardData {
                    title: format!("Region {}", index + 1).into(),
                    subtitle: format!(
                        "{} free",
                        plan::human_mib(region.size_mib)
                    )
                    .into(),
                    details: format!(
                        "Start: {} MiB | End: {} MiB\n{}",
                        region.start_mib,
                        region.end_mib,
                        if plan::region_is_large_enough(region) {
                            "Valid for SteamOS"
                        } else {
                            "Too small for current layout"
                        }
                    )
                    .into(),
                    status: if plan::region_is_large_enough(region) {
                        "VALID".into()
                    } else {
                        "TOO SMALL".into()
                    },
                    is_selected: state_ref.selected_region == Some(index),
                    is_valid: plan::region_is_large_enough(region),
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    replace_rows(&state_ref.region_rows, region_rows);
}

fn stage_subtitle(state: &AppState) -> String {
    match state.current_stage {
        0 => String::from("Prepare and validate the install flow before any backend execution starts."),
        1 => String::from("Choose the physical disk that contains the prepared unallocated space."),
        2 => String::from("Choose the exact unallocated region that will hold the SteamOS partition set."),
        3 => String::from("Review the selected disk and free-space plan before opening the backend installer in a terminal."),
        4 => String::from("The terminal could not be launched. Review the error and retry."),
        _ => String::new(),
    }
}

fn selected_disk_summary(state: &AppState) -> String {
    match state.selected_disk_record() {
        Some(disk) => format!(
            "Selected disk: {}\nDetected model: {}\nCapacity: {}\nDetected free regions: {}",
            disk.path,
            disk.display_name(),
            disk.human_size(),
            disk.free_regions.len()
        ),
        None => String::from("No disk selected."),
    }
}

fn selected_region_summary(state: &AppState) -> String {
    match state.selected_region_record() {
        Some(region) => format!(
            "Selected region: {} MiB -> {} MiB\nSize: {}",
            region.start_mib,
            region.end_mib,
            plan::human_mib(region.size_mib)
        ),
        None => String::from("No unallocated region selected."),
    }
}

fn review_target_disk(state: &AppState) -> String {
    state.selected_disk_record()
        .map(|disk| disk.path.clone())
        .unwrap_or_else(|| String::from("Not selected"))
}

fn review_detected_model(state: &AppState) -> String {
    state.selected_disk_record()
        .map(|disk| disk.display_name())
        .unwrap_or_else(|| String::from("Not selected"))
}

fn review_selected_free_space(state: &AppState) -> String {
    match &state.plan {
        Some(plan) => plan.review_selected_free_space(),
        None => String::from("Not selected"),
    }
}

fn review_summary_text(state: &AppState) -> String {
    match &state.plan {
        Some(plan) => plan.review_summary_text(),
        None => String::from("Select a disk and a valid unallocated region to build the install plan."),
    }
}

fn render_launch_summary(summary: &LaunchSummary, dry_run: bool) -> String {
    format!(
        "Temporary script written:\n  {}\n\nTemporary launcher written:\n  {}\n\nTerminal command:\n  {}\n\nMode:\n  {}\n\nThe launched terminal will prompt for sudo before backend execution starts.",
        summary.script_path.display(),
        summary.wrapper_path.display(),
        summary.command_preview,
        if dry_run { "DRY RUN" } else { "LIVE" }
    )
}

fn replace_rows<T: Clone + 'static>(model: &Rc<VecModel<T>>, new_rows: Vec<T>) {
    let current = model.row_count();
    let target = new_rows.len();

    for (index, row) in new_rows.into_iter().enumerate() {
        if index < current {
            model.set_row_data(index, row);
        } else {
            model.push(row);
        }
    }

    while model.row_count() > target {
        let last = model.row_count() - 1;
        model.remove(last);
    }
}
