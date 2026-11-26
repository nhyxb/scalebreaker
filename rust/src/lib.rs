use godot::prelude::*;

mod game;
mod round;
mod route;
mod rules;
mod settings;

struct HarborExtension;

#[gdextension]
unsafe impl ExtensionLibrary for HarborExtension {}
