use crate::discovery::{DiskRecord, FreeRegion};

pub const ESP_SIZE_MIB: u64 = 256;
pub const EFI_SIZE_MIB: u64 = 64;
pub const ROOT_SIZE_MIB: u64 = 11 * 1024;
pub const VAR_SIZE_MIB: u64 = 1024;

#[derive(Clone, Copy)]
pub struct PlanOptions {
    pub dry_run: bool,
}

#[derive(Clone)]
pub struct InstallPlan {
    pub target_disk: String,
    pub disk_model: String,
    pub free_start_mib: u64,
    pub free_end_mib: u64,
    pub free_size_mib: u64,
    pub first_new_partition: u32,
    pub dry_run: bool,
    pub rows: Vec<PartitionPlanRow>,
}

#[derive(Clone)]
pub struct PartitionPlanRow {
    pub order: usize,
    pub partition_number: u32,
    pub name: &'static str,
    pub purpose: &'static str,
    pub size_mib: Option<u64>,
    pub note: &'static str,
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
    let rows = vec![
        row(1, first_new_partition, "esp", "EFI system", Some(ESP_SIZE_MIB), "Created first"),
        row(2, first_new_partition + 1, "efi-A", "SteamOS EFI A", Some(EFI_SIZE_MIB), "Formatted by backend"),
        row(3, first_new_partition + 2, "efi-B", "SteamOS EFI B", Some(EFI_SIZE_MIB), "Formatted by backend"),
        row(4, first_new_partition + 3, "rootfs-A", "Root filesystem A", Some(ROOT_SIZE_MIB), "Fixed size"),
        row(5, first_new_partition + 4, "rootfs-B", "Root filesystem B", Some(ROOT_SIZE_MIB), "Fixed size"),
        row(6, first_new_partition + 5, "var-A", "Var partition A", Some(VAR_SIZE_MIB), "Fixed size"),
        row(7, first_new_partition + 6, "var-B", "Var partition B", Some(VAR_SIZE_MIB), "Fixed size"),
        row(8, first_new_partition + 7, "home", "Home partition", None, "Uses remaining free space"),
    ];

    Ok(InstallPlan {
        target_disk: disk.path.clone(),
        disk_model: disk.display_name(),
        free_start_mib: region.start_mib,
        free_end_mib: region.end_mib,
        free_size_mib: region.size_mib,
        first_new_partition,
        dry_run: options.dry_run,
        rows,
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
    pub fn review_text(&self) -> String {
        let lines = vec![
            String::from("The installer will target the selected disk and create the standard SteamOS partition layout inside the chosen unallocated region."),
            String::new(),
            String::from("Target disk:"),
            format!("    {}", self.target_disk),
            String::from("Detected model:"),
            format!("    {}", self.disk_model),
            String::from("Selected free space:"),
            format!(
                "    {} MiB to {} MiB ({} available)",
                self.free_start_mib, self.free_end_mib, human_mib(self.free_size_mib)
            ),
            String::from("The first new SteamOS partition will be created as:"),
            format!("    partition {}", self.first_new_partition),
            String::new(),
            format!(
                "The installer will create {} SteamOS partitions, including the final home partition that uses the remaining selected space.",
                self.rows.len()
            ),
        ];

        lines.join("\n")
    }

    pub fn advanced_text(&self) -> String {
        let mut lines = vec![
            String::from("#  Part  Name       Purpose              Size       Notes"),
        ];

        for row in &self.rows {
            let size = row
                .size_mib
                .map(human_mib)
                .unwrap_or_else(|| String::from("Remaining"));
            lines.push(format!(
                "{:<2} p{:<4} {:<10} {:<20} {:<10} {}",
                row.order, row.partition_number, row.name, row.purpose, size, row.note
            ));
        }

        lines.join("\n")
    }
}

fn row(
    order: usize,
    partition_number: u32,
    name: &'static str,
    purpose: &'static str,
    size_mib: Option<u64>,
    note: &'static str,
) -> PartitionPlanRow {
    PartitionPlanRow {
        order,
        partition_number,
        name,
        purpose,
        size_mib,
        note,
    }
}
