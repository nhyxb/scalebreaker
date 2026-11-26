use godot::classes::{
    Camera3D, DirectionalLight3D, Input, InputEvent, Node, PackedScene, WorldEnvironment,
    environment::FogMode, input::MouseMode, notify::Node3DNotification,
};
use godot::prelude::*;
use std::time::Instant;

use crate::round::{HarborRound, PlayerRole};
use crate::rules::Mode;
use crate::settings::{AudioSettings, GameSettings};

const OVERVIEW_DRAW_DISTANCE: f32 = if cfg!(target_os = "android") {
    280.0
} else {
    460.0
};
const FOG_BEGIN_RATIO: f32 = 0.50;
const FOG_END_RATIO: f32 = 0.92;
/// Shipped (desktop / Android) view distance. At or above it the sea haze is pushed out to
/// the island rim instead of the old 252-435 m band, so every district stays readable.
const DEFAULT_VIEW_DISTANCE: f32 = if cfg!(target_os = "android") {
    200.0
} else {
    300.0
};
/// Fraction of `map_side` where the haze starts and fully resolves. On the 1,418 m harbour,
/// 0.52 / 1.12 push the haze past the island core (~737 m / ~1,588 m) so the city stays crisp
/// while the outer sea blends gently into the warm bedroom skybox.
const FOG_MAP_BEGIN: f32 = 0.52;
const FOG_MAP_END: f32 = 1.12;
/// Extra horizontal slack per metre of camera altitude at or above the shipped view distance,
/// preventing 500 m giants overlooking the whole island from being veiled by near fog.
const FOG_ALTITUDE_BEGIN_SLACK: f32 = 0.45;
const FOG_ALTITUDE_END_SLACK: f32 = 0.85;

fn view_fog_bounds(draw_distance: f32, camera_height: f32, map_side: f32) -> (f32, f32) {
    let distance = draw_distance.max(1.0);
    let height = camera_height.max(0.0);
    let mut begin = distance * FOG_BEGIN_RATIO;
    let mut end = distance * FOG_END_RATIO;
    if draw_distance >= DEFAULT_VIEW_DISTANCE && map_side > 0.0 {
        // Everything is batched and always visible now; the fog, not a draw-distance cut,
        // softens the far sea rim without obscuring high-altitude overviews.
        begin = begin.max(map_side * FOG_MAP_BEGIN + height * FOG_ALTITUDE_BEGIN_SLACK);
        end = end.max(map_side * FOG_MAP_END + height * FOG_ALTITUDE_END_SLACK);
    }
    let end = end.hypot(height);
    let begin = begin
        .hypot(height)
        .min((end - 1.0).max(0.0));
    (begin, end)
}

#[derive(GodotClass)]
#[class(base=Node3D, init)]
pub struct HarborGame {
    base: Base<Node3D>,
    #[export]
    round_scene: Option<Gd<PackedScene>>,
    #[export]
    district_scene: Option<Gd<PackedScene>>,
    #[export]
    #[init(val = GString::from("user://gameplay.cfg"))]
    settings_path: GString,
    settings: [GameSettings; Mode::ALL.len()],
    audio_settings: AudioSettings,
    invalid_setting: GString,
    round: Option<Gd<HarborRound>>,
    paused: bool,
    #[init(val = "menu")]
    screen: &'static str,
    #[init(val = -1.0)]
    fog_draw_distance: f32,
    #[init(val = -1.0)]
    fog_camera_height: f32,
    #[init(val = -1.0)]
    fog_map_side: f32,
}

#[godot_api]
impl INode3D for HarborGame {
    fn ready(&mut self) {
        self.settings = GameSettings::load(&self.settings_path);
        self.audio_settings = AudioSettings::load(&self.settings_path);
        self.apply_audio_settings();
        if cfg!(target_os = "android") {
            self.base()
                .get_node_as::<DirectionalLight3D>("Sun")
                .set_param(godot::classes::light_3d::Param::SHADOW_MAX_DISTANCE, 95.0);
            let mut overview = self.base().get_node_as::<Camera3D>("Overview");
            overview.set_meta("district_draw_distance", &280.0_f32.to_variant());
            overview.set_far(590.0);
        }
        self.present("menu");
    }

    fn on_notification(&mut self, what: Node3DNotification) {
        match what {
            Node3DNotification::WM_GO_BACK_REQUEST => {
                if !self.handle_interface_back() {
                    self.pause();
                }
            }
            Node3DNotification::APPLICATION_PAUSED => self.pause(),
            Node3DNotification::APPLICATION_FOCUS_OUT if cfg!(target_os = "android") => {
                self.pause();
            }
            _ => (),
        }
    }

    fn input(&mut self, event: Gd<InputEvent>) {
        if !event.is_action_pressed("pause_game") {
            return;
        }
        if self.handle_interface_back() {
            self.base().get_viewport().unwrap().set_input_as_handled();
        } else if matches!(self.screen, "playing" | "paused") {
            self.base().get_viewport().unwrap().set_input_as_handled();
            if self.paused {
                self.resume();
            } else {
                self.pause();
            }
        }
    }

    fn process(&mut self, _delta: f64) {
        if self.screen != "playing" {
            return;
        }
        self.sync_view_fog();
        let (outcome, snapshot, defeats) = {
            let mut round = self.round.as_mut().unwrap().bind_mut();
            (
                round.outcome_name(),
                round.snapshot(),
                round.take_growth_defeats(),
            )
        };
        let mut view = self.view();
        view.call("update_hud", &[snapshot.to_variant()]);
        if let Some(defeats) = defeats {
            view.call("announce_growth_defeats", &[defeats.to_variant()]);
        }
        if outcome != "playing" {
            self.present(outcome);
        }
    }
}

#[godot_api]
impl HarborGame {
    #[func]
    fn start_mode(&mut self, giant: bool) {
        if giant {
            self.start_round(Mode::Sandbox, PlayerRole::Giant);
        } else {
            self.start_round(Mode::Human, PlayerRole::Evacuee);
        }
    }

    #[func]
    fn start_growth(&mut self) {
        self.start_round(Mode::Growth, PlayerRole::Giant);
    }

    #[func]
    fn start_growth_spectator(&mut self) {
        self.start_round(Mode::Growth, PlayerRole::Spectator);
    }

    #[func]
    fn start_growth_human(&mut self) {
        self.start_round(Mode::Growth, PlayerRole::HumanObserver);
    }

    #[func]
    fn start_brawl(&mut self) {
        self.start_round(Mode::Brawl, PlayerRole::Giant);
    }

    fn start_round(&mut self, mode: Mode, player: PlayerRole) {
        let start = Instant::now();
        self.unpause_tree();
        self.stop_gameplay_sfx();
        self.clear_map();
        let mut round = self
            .round_scene
            .as_ref()
            .unwrap()
            .instantiate_as::<HarborRound>();
        let settings = self.settings[mode as usize];
        {
            let mut session = round.bind_mut();
            session.mode = mode;
            session.player = player;
            session.settings = settings;
        }
        let mut district = round.get_node_as::<Node3D>("District");
        district.set("map_side", &settings.map_side.to_variant());
        district.set("micro_ground", &mode.has_growth().to_variant());
        self.base()
            .get_node_as::<Node3D>("MapSlot")
            .add_child(&round);
        self.round = Some(round);
        self.present("playing");
        if cfg!(target_os = "android") {
            godot_print!(
                "[Harbor] round_ready mode={} ms={:.1}",
                mode.key(),
                start.elapsed().as_secs_f64() * 1000.0
            );
        }
    }

    #[func]
    fn restart(&mut self) {
        let selection = self.round.as_ref().map(|round| {
            let round = round.bind();
            (round.mode, round.player)
        });
        if let Some((mode, player)) = selection {
            self.start_round(mode, player);
        }
    }

    #[func]
    fn pause(&mut self) {
        if self.screen == "playing" {
            self.paused = true;
            self.base().get_tree().set_pause(true);
            self.present("paused");
        }
    }

    #[func]
    fn resume(&mut self) {
        if self.paused {
            self.unpause_tree();
            self.present("playing");
        }
    }

    #[func]
    fn show_menu(&mut self) {
        self.unpause_tree();
        self.stop_gameplay_sfx();
        self.clear_map();
        let preview = self.district_scene.as_ref().unwrap().instantiate().unwrap();
        self.base()
            .get_node_as::<Node3D>("MapSlot")
            .add_child(&preview);
        self.base()
            .get_node_as::<Camera3D>("Overview")
            .make_current();
        self.present("menu");
    }

    #[func]
    fn get_screen(&self) -> GString {
        self.screen.into()
    }

    #[func]
    fn get_settings(&self, giant: bool) -> VarDictionary {
        self.get_mode_settings(i32::from(giant))
    }

    #[func]
    fn default_settings(&self) -> VarDictionary {
        self.default_mode_settings(0)
    }

    #[func]
    fn save_settings(&mut self, human: VarDictionary, giant: VarDictionary) -> bool {
        self.save_mode_settings(human, giant, self.get_mode_settings(Mode::Growth as i32))
    }

    #[func]
    fn get_mode_settings(&self, index: i32) -> VarDictionary {
        let mode = Mode::ALL.get(index as usize).copied().unwrap_or_default();
        self.settings[mode as usize].dictionary(mode)
    }

    #[func]
    fn default_mode_settings(&self, index: i32) -> VarDictionary {
        let mode = Mode::ALL.get(index as usize).copied().unwrap_or_default();
        GameSettings::for_mode(mode).dictionary(mode)
    }

    #[func]
    fn invalid_setting(&self) -> GString {
        self.invalid_setting.clone()
    }

    #[func]
    fn save_mode_settings(
        &mut self,
        human: VarDictionary,
        giant: VarDictionary,
        growth: VarDictionary,
    ) -> bool {
        self.save_all_mode_settings(
            human,
            giant,
            growth,
            self.get_mode_settings(Mode::Brawl as i32),
        )
    }

    #[func]
    fn get_audio_settings(&self) -> VarDictionary {
        self.audio_settings.dictionary()
    }

    #[func]
    fn default_audio_settings(&self) -> VarDictionary {
        AudioSettings::default().dictionary()
    }

    #[func]
    fn save_audio_settings(&mut self, audio: VarDictionary) -> bool {
        self.invalid_setting = GString::new();
        let (decoded, invalid) = AudioSettings::from_dictionary(&audio);
        if let Some(key) = invalid {
            self.invalid_setting = key.into();
            return false;
        }
        if !GameSettings::save(&self.settings_path, self.settings, decoded) {
            return false;
        }
        self.audio_settings = decoded;
        self.apply_audio_settings();
        true
    }

    #[func]
    fn save_all_mode_settings(
        &mut self,
        human: VarDictionary,
        giant: VarDictionary,
        growth: VarDictionary,
        brawl: VarDictionary,
    ) -> bool {
        self.save_all_settings(human, giant, growth, brawl, self.audio_settings.dictionary())
    }

    #[func]
    fn save_all_settings(
        &mut self,
        human: VarDictionary,
        giant: VarDictionary,
        growth: VarDictionary,
        brawl: VarDictionary,
        audio: VarDictionary,
    ) -> bool {
        self.invalid_setting = GString::new();
        let values = [human, giant, growth, brawl];
        let mut settings = self.settings;
        for (mode, values) in Mode::ALL.into_iter().zip(&values) {
            let (decoded, invalid) = GameSettings::from_dictionary(values, mode);
            if let Some(key) = invalid {
                self.invalid_setting = key.into();
                return false;
            }
            settings[mode as usize] = decoded;
        }
        let (decoded_audio, invalid_audio) = AudioSettings::from_dictionary(&audio);
        if let Some(key) = invalid_audio {
            self.invalid_setting = key.into();
            return false;
        }
        if !GameSettings::save(&self.settings_path, settings, decoded_audio) {
            return false;
        }
        self.settings = settings;
        self.audio_settings = decoded_audio;
        self.apply_audio_settings();
        if let Some(round) = &mut self.round {
            let mut round = round.bind_mut();
            let options = settings[round.mode as usize];
            round.apply_settings(options);
        }
        self.sync_view_fog();
        true
    }

    fn audio_manager(&self) -> Option<Gd<Node>> {
        self.base()
            .get_tree()
            .get_root()
            .get_node_or_null("HarborAudio")
    }

    fn apply_audio_settings(&self) {
        if let Some(mut audio) = self.audio_manager() {
            audio.call(
                "apply_audio_settings",
                &[
                    self.audio_settings.sfx_volume.to_variant(),
                    self.audio_settings.ambience_volume.to_variant(),
                    self.audio_settings.muted.to_variant(),
                ],
            );
        }
    }

    fn stop_gameplay_sfx(&self) {
        if let Some(mut audio) = self.audio_manager() {
            audio.call("stop_gameplay_sfx", &[]);
        }
    }

    fn unpause_tree(&mut self) {
        self.paused = false;
        self.base().get_tree().set_pause(false);
    }

    fn clear_map(&mut self) {
        self.round = None;
        let mut slot = self.base().get_node_as::<Node3D>("MapSlot");
        for mut child in slot.get_children().iter_shared() {
            slot.remove_child(&child);
            child.queue_free();
        }
    }

    fn present(&mut self, screen: &'static str) {
        self.screen = screen;
        let (mode, player) =
            self.round
                .as_mut()
                .map_or((Mode::Human, PlayerRole::Evacuee), |round| {
                    let mut round = round.bind_mut();
                    round.clear_touch();
                    (round.mode, round.player)
                });
        Input::singleton().set_mouse_mode(if screen == "playing" && !cfg!(target_os = "android") {
            MouseMode::CAPTURED
        } else {
            MouseMode::VISIBLE
        });
        let mut view = self.view();
        view.call(
            "show_screen",
            &[
                GString::from(screen).to_variant(),
                (mode as i32).to_variant(),
                self.round.to_variant(),
                (player as i32).to_variant(),
            ],
        );
        if screen == "playing" {
            let snapshot = self.round.as_ref().unwrap().bind().snapshot();
            view.call("update_hud", &[snapshot.to_variant()]);
        }
        self.sync_view_fog();
        if cfg!(target_os = "android") {
            godot_print!("[Harbor] screen={screen} mode={}", mode.key());
        }
    }

    fn sync_view_fog(&mut self) {
        let Some(viewport) = self.base().get_viewport() else {
            return;
        };
        let Some(camera) = viewport.get_camera_3d() else {
            return;
        };
        let draw_distance = if camera.has_meta("district_draw_distance") {
            camera
                .get_meta("district_draw_distance")
                .try_to::<f32>()
                .unwrap_or(OVERVIEW_DRAW_DISTANCE)
        } else {
            OVERVIEW_DRAW_DISTANCE
        };
        let camera_height = camera.get_global_position().y.max(0.0);
        if (draw_distance - self.fog_draw_distance).abs() < 0.05
            && (camera_height - self.fog_camera_height).abs() < 0.25
            && self.fog_map_side > 0.0
        {
            return;
        }
        let map_side = self
            .base()
            .get_node_or_null("MapSlot/Round/District")
            .map(|node| node.get("map_side"))
            .and_then(|value| {
                value
                    .try_to::<f32>()
                    .ok()
                    .or_else(|| value.try_to::<i64>().ok().map(|raw| raw as f32))
            })
            .unwrap_or(0.0);
        self.fog_draw_distance = draw_distance;
        self.fog_camera_height = camera_height;
        self.fog_map_side = map_side;
        let (begin, end) = view_fog_bounds(draw_distance, camera_height, map_side);
        if let Some(mut env) = self
            .base()
            .get_node_as::<WorldEnvironment>("Atmosphere")
            .get_environment()
        {
            env.set_fog_enabled(true);
            env.set_fog_mode(FogMode::DEPTH);
            env.set_fog_depth_begin(begin);
            env.set_fog_depth_end(end);
        }
    }

    fn handle_interface_back(&self) -> bool {
        self.view().call("handle_back", &[]).to::<bool>()
    }

    fn view(&self) -> Gd<Node> {
        self.base().get_node_as::<Node>("Interface")
    }
}

#[cfg(test)]
mod tests {
    use super::view_fog_bounds;

    #[test]
    fn view_fog_veils_the_draw_boundary_while_keeping_feet_clear_at_altitude() {
        for draw in [40.0, 200.0] {
            let (begin, end) = view_fog_bounds(draw, 1.5, 1418.0);
            assert!(begin > 0.0 && begin < end);
            assert!(end < draw, "under the shipped view distance fog still matches it");
        }
        let (high_begin, high_end) = view_fog_bounds(300.0, 450.0, 0.0);
        assert!(high_begin > 450.0, "ground straight under a 500 m giant stays clear");
        assert!(high_end < 300.0_f32.hypot(450.0));
        let (extreme_begin, extreme_end) = view_fog_bounds(40.0, 1000.0, 0.0);
        assert!(extreme_end - extreme_begin >= 0.99);
    }

    #[test]
    fn view_fog_is_pushed_to_the_island_rim_on_big_maps() {
        // The shipped 1,418 m harbour: haze starts past the city core, not at the old 252 m.
        let (begin, end) = view_fog_bounds(300.0, 1.5, 1418.0);
        assert!(begin > 400.0 && begin < end);
        assert!(end > 700.0);
        // A bigger island scales with it, and everything stays inside the far plane.
        let (far_begin, far_end) = view_fog_bounds(460.0, 1.5, 1900.0);
        assert!(far_end > end && far_begin > begin);
        assert!(far_end < 2500.0);
        // The 460 m overview keeps its own 0.92 of the draw distance when the map is small.
        let (small_begin, small_end) = view_fog_bounds(460.0, 1.5, 300.0);
        assert!(small_begin < 400.0 && small_end < 460.0);
        // A 500 m giant overlooking the whole 1,418 m map (camera ~560 m high) sees clear city
        // well past 1,000 m with full fog pushed beyond 1,900 m.
        let (giant500_begin, giant500_end) = view_fog_bounds(300.0, 560.0, 1418.0);
        assert!(giant500_begin > 1000.0 && giant500_end > 1900.0);
    }
}
