fn main() {
    println!("cargo:rerun-if-changed=run.sh");
    let run_sh = std::fs::read_to_string("run.sh").expect("failed to read run.sh");
    let version = run_sh
        .lines()
        .find_map(|line| line.strip_prefix("# Version: "))
        .expect("run.sh is missing a '# Version: ...' header");
    println!("cargo:rustc-env=RUN_SH_VERSION={version}");
    slint_build::compile("ui/app.slint").expect("failed to compile Slint UI");
}
