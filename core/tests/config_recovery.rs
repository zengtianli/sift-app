use sift_core::{config::Config,engine::Engine};
use std::{fs,path::PathBuf,time::{SystemTime,UNIX_EPOCH}};

#[test]
fn invalid_scope_preserves_last_good_and_never_falls_back_to_disk_root() {
    let support = std::env::temp_dir().join(format!("sift-config-recovery-{}-{}",std::process::id(),SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));
    let root = support.join("allowed");fs::create_dir_all(&root).unwrap();
    let valid = Config{root:root.clone(),ignore_paths:vec![],include_paths:vec![],support_dir:support.clone()}.validated().unwrap();
    valid.save().unwrap();
    let mut invalid = valid.clone();invalid.root = PathBuf::from("relative");assert!(invalid.validated().is_err());
    let mut invalid = valid.clone();invalid.ignore_paths.push(PathBuf::from("bad"));assert!(invalid.validated().is_err());
    fs::write(support.join("config.json"),"broken").unwrap();
    assert!(Config::load(&support).is_err());
    assert_eq!(Config::recover(&support).root,root);
    assert_eq!(fs::read_to_string(support.join("config.json")).unwrap(),"broken");
    fs::remove_file(support.join("config-last-good.json")).unwrap();
    let recovered = Config::recover(&support);
    assert_eq!(recovered.root,support.join("configuration-needs-repair"));
    assert_eq!(fs::read_dir(&recovered.root).unwrap().count(),0);
    fs::write(support.join("runtime.json"),"bad").unwrap();
    let engine = Engine::start(recovered);
    assert!(engine.policy().paused);assert!(!engine.status.runtime_error.lock().unwrap().is_empty());
    engine.edit_policy(|p|p.auto_repair = true).unwrap();
    assert!(engine.status.runtime_error.lock().unwrap().is_empty());
    engine.shutdown();fs::remove_dir_all(support).unwrap();
}
