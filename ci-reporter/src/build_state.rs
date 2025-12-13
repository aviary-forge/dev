use core::iter::{IntoIterator, Iterator};
use std::collections::HashMap;

#[derive(Clone)]
pub enum BuildState {
    NotStarted,
    InProgress,
    Success,
    Failure(Option<String>),
}

pub struct GroupBuildState {
    builds_by_drv_path: HashMap<String, BuildState>,
    needs_update: bool,
}

impl GroupBuildState {
    pub fn new<I: IntoIterator<Item = String>>(derivations: I) -> Self {
        let builds_by_drv_path =
            core::iter::zip(derivations, core::iter::repeat(BuildState::NotStarted)).collect();

        let needs_update = false;
        Self {
            builds_by_drv_path,
            needs_update,
        }
    }

    pub fn set_state(&mut self, drv_path: String, state: BuildState) {
        self.builds_by_drv_path.insert(drv_path, state);
        self.needs_update = true;
    }

    pub fn handle_update(&mut self) {
        self.needs_update = false;
    }
}
