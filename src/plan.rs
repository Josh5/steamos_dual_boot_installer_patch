use crate::discovery::{DiskRecord, FreeRegion};

pub const ESP_SIZE_MIB: u64 = 256;
pub const EFI_SIZE_MIB: u64 = 64;
pub const ROOT_SIZE_MIB: u64 = 11 * 1024;
pub const VAR_SIZE_MIB: u64 = 1024;
pub const STEAMOS_PARTITION_COUNT: usize = 8;

#[derive(Clone, Copy)]
pub struct PlanOptions {
    pub dry_run: bool,
}

#[derive(Clone)]
pub struct InstallPlan {
    pub target_disk: String,
    pub free_start_mib: u64,
    pub free_end_mib: u64,
    pub free_size_mib: u64,
    pub first_new_partition: u32,
    pub dry_run: bool,
}

pub fn build_plan(
    disk: &DiskRecord,
    region: &FreeRegion,
    options: PlanOptions,
) -> Result<InstallPlan, String> {
    if !region_is_large_enough(region) {
        return Err(String::from("Selected free-space region is too small for the SteamOS layout."));
    }

    let first_new_partition = disk.highest_partition + 1;

    Ok(InstallPlan {
        target_disk: disk.path.clone(),
        free_start_mib: region.start_mib,
        free_end_mib: region.end_mib,
        free_size_mib: region.size_mib,
        first_new_partition,
        dry_run: options.dry_run,
    })
}

pub fn region_is_large_enough(region: &FreeRegion) -> bool {
    region.size_mib > required_fixed_space_mib()
}

pub fn required_fixed_space_mib() -> u64 {
    ESP_SIZE_MIB + (EFI_SIZE_MIB * 2) + (ROOT_SIZE_MIB * 2) + (VAR_SIZE_MIB * 2)
}

pub fn human_mib(value: u64) -> String {
    if value >= 1024 {
        format!("{:.1} GiB", value as f64 / 1024.0)
    } else {
        format!("{value} MiB")
    }
}

impl InstallPlan {
    pub fn review_selected_free_space(&self) -> String {
        format!(
            "{} MiB to {} MiB ({} available)",
            self.free_start_mib,
            self.free_end_mib,
            human_mib(self.free_size_mib)
        )
    }

    pub fn review_summary_text(&self) -> String {
        format!(
            "The installer will create {} SteamOS partitions, including the final home partition that uses the remaining selected space.\n\nThe first new SteamOS partition will be created as partition {}.",
            STEAMOS_PARTITION_COUNT,
            self.first_new_partition
        )
    }
}
