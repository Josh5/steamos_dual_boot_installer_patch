use std::process::Command;

use serde::Deserialize;

#[derive(Clone, Debug, Default)]
pub struct DiskRecord {
    pub path: String,
    pub name: String,
    pub size_bytes: u64,
    pub model: String,
    pub vendor: String,
    pub transport: String,
    pub partitions: Vec<PartitionRecord>,
    pub free_regions: Vec<FreeRegion>,
    pub highest_partition: u32,
}

#[derive(Clone, Debug, Default)]
pub struct PartitionRecord {
    pub number: u32,
    pub name: String,
    pub path: String,
    pub fs_type: String,
    pub label: String,
    pub part_label: String,
}

#[derive(Clone, Debug, Default)]
pub struct FreeRegion {
    pub start_mib: u64,
    pub end_mib: u64,
    pub size_mib: u64,
}

impl DiskRecord {
    pub fn display_name(&self) -> String {
        let mut parts = Vec::new();
        if !self.vendor.is_empty() {
            parts.push(self.vendor.clone());
        }
        if !self.model.is_empty() {
            parts.push(self.model.clone());
        }
        if parts.is_empty() {
            if !self.name.is_empty() {
                self.name.clone()
            } else {
                String::from("Unknown model")
            }
        } else {
            parts.join(" ")
        }
    }

    pub fn human_size(&self) -> String {
        human_bytes(self.size_bytes)
    }

    pub fn largest_free_region_human(&self) -> String {
        self.free_regions
            .iter()
            .map(|region| region.size_mib)
            .max()
            .map(human_mib)
            .unwrap_or_else(|| String::from("None"))
    }

    pub fn partition_summary(&self) -> String {
        if self.partitions.is_empty() {
            return String::from("No partitions detected");
        }

        let mut rows = self
            .partitions
            .iter()
            .take(3)
            .map(PartitionRecord::summary_line)
            .collect::<Vec<_>>();

        if self.partitions.len() > 3 {
            rows.push(format!("+{} more partitions", self.partitions.len() - 3));
        }

        rows.join(" | ")
    }
}

impl PartitionRecord {
    pub fn summary_line(&self) -> String {
        let mut parts = vec![format!("p{}", self.number)];

        if !self.part_label.is_empty() {
            parts.push(self.part_label.clone());
        } else if !self.label.is_empty() {
            parts.push(self.label.clone());
        } else if !self.name.is_empty() {
            parts.push(self.name.clone());
        } else {
            parts.push(self.path.clone());
        }

        if !self.fs_type.is_empty() {
            parts.push(self.fs_type.clone());
        }

        parts.join(" ")
    }
}

pub fn discover_disks() -> Result<Vec<DiskRecord>, String> {
    let lsblk = Command::new("lsblk")
        .args([
            "-J",
            "-b",
            "-o",
            "NAME,PATH,SIZE,TYPE,MODEL,VENDOR,TRAN,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS",
        ])
        .output()
        .map_err(|error| format!("failed to run lsblk: {error}"))?;

    if !lsblk.status.success() {
        return Err(String::from_utf8_lossy(&lsblk.stderr).trim().to_string());
    }

    let document: LsblkDocument = serde_json::from_slice(&lsblk.stdout)
        .map_err(|error| format!("failed to parse lsblk output: {error}"))?;

    let mut disks = Vec::new();
    for device in document.blockdevices {
        if device.device_type != "disk" {
            continue;
        }
        if device.name.starts_with("loop")
            || device.name.starts_with("ram")
            || device.name.starts_with("zram")
        {
            continue;
        }

        let mut disk = DiskRecord {
            path: device.path.clone(),
            name: device.name,
            size_bytes: device.size,
            model: device.model.unwrap_or_default().trim().to_string(),
            vendor: device.vendor.unwrap_or_default().trim().to_string(),
            transport: device.transport.unwrap_or_default().trim().to_string(),
            partitions: Vec::new(),
            free_regions: Vec::new(),
            highest_partition: 0,
        };

        for child in device.children.unwrap_or_default() {
            if child.device_type != "part" {
                continue;
            }
            let number = partition_number(&child.path);
            if number > disk.highest_partition {
                disk.highest_partition = number;
            }
            disk.partitions.push(PartitionRecord {
                number,
                name: child.name,
                path: child.path,
                fs_type: child.fs_type.unwrap_or_default(),
                label: child.label.unwrap_or_default(),
                part_label: child.part_label.unwrap_or_default(),
            });
        }

        disk.free_regions = discover_free_regions(&disk.path)?;
        disks.push(disk);
    }

    Ok(disks)
}

fn discover_free_regions(disk_path: &str) -> Result<Vec<FreeRegion>, String> {
    let parted = Command::new("parted")
        .args(["-m", "-s", disk_path, "unit", "MiB", "print", "free"])
        .output()
        .map_err(|error| format!("failed to run parted: {error}"))?;

    if !parted.status.success() {
        return Err(String::from_utf8_lossy(&parted.stderr).trim().to_string());
    }

    parse_parted_free(&String::from_utf8_lossy(&parted.stdout))
}

fn parse_parted_free(raw: &str) -> Result<Vec<FreeRegion>, String> {
    let mut regions = Vec::new();

    for line in raw.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with("BYT;") || line.starts_with("/dev/") {
            continue;
        }

        let fields: Vec<&str> = line.split(':').collect();
        if fields.len() < 5 {
            continue;
        }

        if fields[4].trim_end_matches(';') != "free" {
            continue;
        }

        let start = parse_mib(fields[1])?;
        let end = parse_mib(fields[2])?;
        let size = parse_mib(fields[3])?;
        if size < 1 {
            continue;
        }

        regions.push(FreeRegion {
            start_mib: start,
            end_mib: end,
            size_mib: size,
        });
    }

    Ok(regions)
}

fn parse_mib(value: &str) -> Result<u64, String> {
    let trimmed = value.trim().trim_end_matches("MiB");
    let parsed = trimmed
        .parse::<f64>()
        .map_err(|error| format!("failed to parse MiB value '{trimmed}': {error}"))?;
    Ok(parsed.floor() as u64)
}

fn partition_number(path: &str) -> u32 {
    let digits = path
        .chars()
        .rev()
        .take_while(|ch| ch.is_ascii_digit())
        .collect::<String>()
        .chars()
        .rev()
        .collect::<String>();
    digits.parse::<u32>().unwrap_or(0)
}

fn human_bytes(value: u64) -> String {
    const GIB: f64 = 1024.0 * 1024.0 * 1024.0;
    const TIB: f64 = GIB * 1024.0;
    let value = value as f64;
    if value >= TIB {
        format!("{:.1} TiB", value / TIB)
    } else {
        format!("{:.1} GiB", value / GIB)
    }
}

fn human_mib(value: u64) -> String {
    if value >= 1024 {
        format!("{:.1} GiB", value as f64 / 1024.0)
    } else {
        format!("{value} MiB")
    }
}

#[derive(Deserialize)]
struct LsblkDocument {
    blockdevices: Vec<LsblkDevice>,
}

#[derive(Deserialize)]
struct LsblkDevice {
    name: String,
    path: String,
    size: u64,
    #[serde(rename = "type")]
    device_type: String,
    #[serde(rename = "model")]
    model: Option<String>,
    #[serde(rename = "vendor")]
    vendor: Option<String>,
    #[serde(rename = "tran")]
    transport: Option<String>,
    #[serde(rename = "fstype")]
    fs_type: Option<String>,
    #[serde(rename = "label")]
    label: Option<String>,
    #[serde(rename = "partlabel")]
    part_label: Option<String>,
    children: Option<Vec<LsblkDevice>>,
}
