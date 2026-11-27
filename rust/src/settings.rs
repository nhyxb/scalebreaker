use godot::classes::{ConfigFile, DirAccess};
use godot::global::Error;
use godot::prelude::*;

use crate::rules::{
    GIANT_DEFAULT_MAX_HEIGHT, GIANT_START_HEIGHT, GROWTH_REFERENCE_HEIGHT, HUMAN_HEIGHT, Mode,
};

const DEFAULT_MAP_SIDE: i32 = 1418;
const DEFAULT_SFX_VOLUME: f32 = 0.85;
const DEFAULT_AMBIENCE_VOLUME: f32 = 0.60;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum TimeOfDay {
    Auto,
    #[default]
    Day,
    Dusk,
    Night,
}

impl TimeOfDay {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Day => "day",
            Self::Dusk => "dusk",
            Self::Night => "night",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "auto" => Some(Self::Auto),
            "day" => Some(Self::Day),
            "dusk" => Some(Self::Dusk),
            "night" => Some(Self::Night),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AudioSettings {
    pub sfx_volume: f32,
    pub ambience_volume: f32,
    pub muted: bool,
}

impl Default for AudioSettings {
    fn default() -> Self {
        Self {
            sfx_volume: DEFAULT_SFX_VOLUME,
            ambience_volume: DEFAULT_AMBIENCE_VOLUME,
            muted: false,
        }
    }
}

impl AudioSettings {
    pub fn from_dictionary(values: &VarDictionary) -> (Self, Option<&'static str>) {
        let default = Self::default();
        let mut invalid = None;
        let mut read_volume = |key: &'static str, fallback: f32| {
            let Some(value) = values.get(key) else {
                return fallback;
            };
            settings_number(&value)
                .filter(|&value| nonnegative(value))
                .map(|value| value as f32)
                .unwrap_or_else(|| {
                    invalid.get_or_insert(key);
                    fallback
                })
        };
        let muted = values
            .get("audio_muted")
            .and_then(|value| value.try_to::<bool>().ok())
            .unwrap_or(default.muted);
        let settings = Self {
            sfx_volume: read_volume("sfx_volume", default.sfx_volume),
            ambience_volume: read_volume("ambience_volume", default.ambience_volume),
            muted,
        };
        (settings, invalid)
    }

    pub fn dictionary(self) -> VarDictionary {
        let mut values = VarDictionary::new();
        values.set("sfx_volume", setting_value(self.sfx_volume));
        values.set("ambience_volume", setting_value(self.ambience_volume));
        values.set("audio_muted", self.muted);
        values
    }

    pub fn load(path: &GString) -> Self {
        let mut file = ConfigFile::new_gd();
        if file.load(path) != Error::OK {
            return Self::default();
        }
        file.get_value_ex("audio", "settings")
            .default(&VarDictionary::new().to_variant())
            .done()
            .try_to::<VarDictionary>()
            .map(|values| Self::from_dictionary(&values).0)
            .unwrap_or_default()
    }
}

#[derive(Clone, Copy, PartialEq)]
pub struct GrowthSettings {
    pub random_start: bool,
    pub building_respawn: bool,
    pub building_respawn_delay: f32,
    pub height_bands: bool,
    pub band_start: u32,
    pub band_step: u32,
    pub coin_count: usize,
    pub coin_interval: f32,
    pub coin_growth_rate: f32,
    pub building_growth_rate: f32,
    pub base_health: f32,
    pub base_attack: f32,
    pub attack_height: f32,
    pub respawn_delay: f32,
}

impl Default for GrowthSettings {
    fn default() -> Self {
        Self {
            random_start: false,
            building_respawn: false,
            building_respawn_delay: 60.0,
            height_bands: true,
            band_start: 100,
            band_step: 50,
            coin_count: 200,
            coin_interval: 60.0,
            coin_growth_rate: 0.10,
            building_growth_rate: 0.10,
            base_health: 100.0,
            base_attack: 10.0,
            attack_height: 3.0,
            respawn_delay: 5.0,
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
pub struct BrawlSettings {
    pub start_min_height: f32,
    pub start_max_height: f32,
    pub respawn_max_height: f32,
    pub coin_height: f32,
    pub coin_reward_rate: f32,
}

impl Default for BrawlSettings {
    fn default() -> Self {
        Self {
            start_min_height: GROWTH_REFERENCE_HEIGHT,
            start_max_height: 30.0,
            respawn_max_height: 30.0,
            coin_height: 50.0,
            coin_reward_rate: 0.01,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SitSettings {
    /// Giants sit down on small crowds automatically when this is on.
    pub crush_enabled: bool,
    /// Sit-crush needs targets at most `attacker / crush_ratio` tall (1/5 by default).
    pub crush_ratio: f32,
    /// How many small targets must stand inside the seated footprint.
    pub crush_targets: u32,
    /// Seconds spent seated before the giant pushes itself back up.
    pub hold_base: f32,
    /// Extra seated seconds for every extra body-size multiple (bigger sits longer).
    pub hold_per_scale: f32,
    /// Max-size giants may sit down and idle when nothing is in sight.
    pub idle_enabled: bool,
    /// Chance per second to drop into that idle sit while nothing is around.
    pub idle_chance: f32,
    /// Auto stand-up timeout for the idle sit.
    pub idle_timeout: f32,
    /// A seated giant pins victims at most `attacker / pin_ratio` tall.
    pub pin_ratio: f32,
    /// Seconds between pinned-victim damage ticks.
    pub pin_interval: f32,
}

impl Default for SitSettings {
    fn default() -> Self {
        Self {
            crush_enabled: true,
            crush_ratio: 5.0,
            crush_targets: 2,
            hold_base: 1.2,
            hold_per_scale: 1.0,
            idle_enabled: true,
            idle_chance: 0.35,
            idle_timeout: 60.0,
            pin_ratio: 5.0,
            pin_interval: 0.5,
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
pub struct GameSettings {
    pub map_side: i32,
    /// Multiplier applied to every human walk and sprint speed.
    pub human_speed: f32,
    pub giant_speed: f32,
    /// Giants ignore each other once the height ratio reaches this value.
    pub rival_ignore_ratio: f32,
    /// Giants ignore smaller humans and pedestrians once the height ratio reaches this value.
    pub human_ignore_ratio: f32,
    pub giant_height: f32,
    pub giant_max_height: f32,
    pub giant_count: usize,
    pub npc_initial: usize,
    pub npc_respawn: bool,
    pub npc_interval: f32,
    pub view_distance: f32,
    pub shake_strength: f32,
    pub own_camera_shake: bool,
    pub time_of_day: TimeOfDay,
    /// First person: turning the view also turns the giant's shoulders (bounded by the
    /// ±75° head cone). Off keeps the head free while the body only turns to walk.
    pub first_person_steer: bool,
    /// Periodic tabletop desk hazards (e.g. Yumeka's foreground single-finger poke) in
    /// Sandbox, Growth and Brawl modes. Human Evacuation mode never triggers hazards.
    pub desk_hazards: bool,
    pub growth: GrowthSettings,
    pub brawl: BrawlSettings,
    pub sit: SitSettings,
}

impl Default for GameSettings {
    fn default() -> Self {
        Self {
            map_side: DEFAULT_MAP_SIDE,
            human_speed: 1.0,
            giant_speed: 1.0,
            rival_ignore_ratio: 10.0,
            human_ignore_ratio: 30.0,
            giant_height: GIANT_START_HEIGHT,
            giant_max_height: GIANT_DEFAULT_MAX_HEIGHT,
            giant_count: 1,
            npc_initial: 6,
            npc_respawn: true,
            npc_interval: 8.0,
            view_distance: if cfg!(target_os = "android") {
                200.0
            } else {
                300.0
            },
            shake_strength: 1.0,
            own_camera_shake: true,
            time_of_day: TimeOfDay::default(),
            first_person_steer: true,
            desk_hazards: true,
            growth: GrowthSettings::default(),
            brawl: BrawlSettings::default(),
            sit: SitSettings::default(),
        }
    }
}

impl GameSettings {
    pub fn for_mode(mode: Mode) -> Self {
        if mode.has_growth() {
            Self {
                giant_speed: 4.0,
                giant_height: if mode == Mode::Growth {
                    HUMAN_HEIGHT
                } else {
                    GIANT_START_HEIGHT
                },
                giant_count: 2,
                growth: GrowthSettings {
                    height_bands: mode == Mode::Growth,
                    ..GrowthSettings::default()
                },
                ..Self::default()
            }
        } else {
            Self::default()
        }
    }

    pub fn from_dictionary(values: &VarDictionary, mode: Mode) -> (Self, Option<&'static str>) {
        let default = Self::for_mode(mode);
        let growth = default.growth;
        let brawl = default.brawl;
        let sit = default.sit;
        let legacy_growth_rate = values
            .get("growth_rate")
            .and_then(|value| settings_number(&value))
            .map(|value| value as f32)
            .filter(|value| value.is_finite() && *value >= 0.0);
        let flag = |key: &str, fallback| {
            values
                .get(key)
                .and_then(|value| value.try_to::<bool>().ok())
                .unwrap_or(fallback)
        };
        let mut invalid = None;
        let time_of_day = match values.get("time_of_day") {
            None => default.time_of_day,
            Some(value) => value
                .try_to::<GString>()
                .ok()
                .and_then(|raw| TimeOfDay::parse(&raw.to_string()))
                .unwrap_or_else(|| {
                    invalid.get_or_insert("time_of_day");
                    default.time_of_day
                }),
        };
        let mut read = |key: &'static str, fallback: f64, valid: fn(f64) -> bool| {
            let Some(value) = values.get(key) else {
                return fallback;
            };
            settings_number(&value)
                .filter(|&value| valid(value))
                .unwrap_or_else(|| {
                    invalid.get_or_insert(key);
                    fallback
                })
        };

        let settings = Self {
            map_side: read("map_side", default.map_side.into(), map_side) as i32,
            human_speed: read("human_speed", default.human_speed.into(), positive) as f32,
            giant_speed: read("giant_speed", default.giant_speed.into(), positive) as f32,
            rival_ignore_ratio: read(
                "rival_ignore_ratio",
                default.rival_ignore_ratio.into(),
                nonnegative,
            ) as f32,
            human_ignore_ratio: read(
                "human_ignore_ratio",
                default.human_ignore_ratio.into(),
                nonnegative,
            ) as f32,
            giant_height: read("giant_height", default.giant_height.into(), positive) as f32,
            giant_max_height: read(
                "giant_max_height",
                default.giant_max_height.into(),
                positive,
            ) as f32,
            giant_count: read("giant_count", default.giant_count as f64, nonzero_count).round()
                as usize,
            npc_initial: read("npc_initial", default.npc_initial as f64, count).round() as usize,
            npc_respawn: flag("npc_respawn", default.npc_respawn),
            npc_interval: read("npc_interval", default.npc_interval.into(), nonnegative) as f32,
            view_distance: read("view_distance", default.view_distance.into(), nonnegative) as f32,
            shake_strength: read("shake_strength", default.shake_strength.into(), nonnegative)
                as f32,
            own_camera_shake: flag("own_camera_shake", default.own_camera_shake),
            time_of_day,
            first_person_steer: flag("first_person_steer", default.first_person_steer),
            desk_hazards: flag("desk_hazards", default.desk_hazards),
            growth: GrowthSettings {
                random_start: mode.has_growth() && flag("random_start", growth.random_start),
                building_respawn: flag("building_respawn", growth.building_respawn),
                building_respawn_delay: read(
                    "building_respawn_delay",
                    growth.building_respawn_delay.into(),
                    nonnegative,
                ) as f32,
                height_bands: mode == Mode::Growth && flag("height_bands", growth.height_bands),
                band_start: read("band_start", growth.band_start.into(), nonzero_count).round()
                    as u32,
                band_step: read("band_step", growth.band_step.into(), nonzero_count).round() as u32,
                coin_count: read("coin_count", growth.coin_count as f64, count).round() as usize,
                coin_interval: read("coin_interval", growth.coin_interval.into(), nonnegative)
                    as f32,
                coin_growth_rate: read(
                    "coin_growth_rate",
                    legacy_growth_rate.unwrap_or(growth.coin_growth_rate).into(),
                    nonnegative,
                ) as f32,
                building_growth_rate: read(
                    "building_growth_rate",
                    legacy_growth_rate
                        .unwrap_or(growth.building_growth_rate)
                        .into(),
                    nonnegative,
                ) as f32,
                base_health: read("base_health", growth.base_health.into(), positive) as f32,
                base_attack: read("base_attack", growth.base_attack.into(), nonnegative) as f32,
                attack_height: read("attack_height", growth.attack_height.into(), nonnegative)
                    as f32,
                respawn_delay: read("respawn_delay", growth.respawn_delay.into(), nonnegative)
                    as f32,
            },
            brawl: BrawlSettings {
                start_min_height: read("start_min_height", brawl.start_min_height.into(), finite)
                    as f32,
                start_max_height: read("start_max_height", brawl.start_max_height.into(), finite)
                    as f32,
                respawn_max_height: read(
                    "respawn_max_height",
                    brawl.respawn_max_height.into(),
                    finite,
                ) as f32,
                coin_height: read("coin_height", brawl.coin_height.into(), finite) as f32,
                coin_reward_rate: read("coin_reward_rate", brawl.coin_reward_rate.into(), finite)
                    as f32,
            },
            sit: SitSettings {
                crush_enabled: flag("sit_crush_enabled", sit.crush_enabled),
                crush_ratio: read("sit_crush_ratio", sit.crush_ratio.into(), positive) as f32,
                crush_targets: read(
                    "sit_crush_targets",
                    f64::from(sit.crush_targets),
                    nonzero_count,
                )
                .round() as u32,
                hold_base: read("sit_hold_base", sit.hold_base.into(), nonnegative) as f32,
                hold_per_scale: read("sit_hold_per_scale", sit.hold_per_scale.into(), nonnegative)
                    as f32,
                idle_enabled: flag("sit_idle_enabled", sit.idle_enabled),
                idle_chance: read("sit_idle_chance", sit.idle_chance.into(), nonnegative) as f32,
                idle_timeout: read("sit_idle_timeout", sit.idle_timeout.into(), nonnegative) as f32,
                pin_ratio: read("sit_pin_ratio", sit.pin_ratio.into(), positive) as f32,
                pin_interval: read("sit_pin_interval", sit.pin_interval.into(), positive) as f32,
            },
        };
        (settings, invalid)
    }

    pub fn dictionary(self, mode: Mode) -> VarDictionary {
        let mut values = VarDictionary::new();
        values.set("map_side", self.map_side);
        values.set("human_speed", setting_value(self.human_speed));
        values.set("giant_speed", setting_value(self.giant_speed));
        values.set("rival_ignore_ratio", setting_value(self.rival_ignore_ratio));
        values.set("human_ignore_ratio", setting_value(self.human_ignore_ratio));
        values.set("giant_height", setting_value(self.giant_height));
        values.set("giant_max_height", setting_value(self.giant_max_height));
        values.set("giant_count", self.giant_count as i32);
        if mode != Mode::Brawl {
            values.set("npc_initial", self.npc_initial as i32);
            values.set("npc_respawn", self.npc_respawn);
            values.set("npc_interval", setting_value(self.npc_interval));
        }
        values.set("view_distance", setting_value(self.view_distance));
        values.set("shake_strength", setting_value(self.shake_strength));
        // Display options are set once and mirrored into every mode profile.
        values.set("own_camera_shake", self.own_camera_shake);
        values.set("time_of_day", self.time_of_day.as_str());
        values.set("first_person_steer", self.first_person_steer);
        if mode != Mode::Human {
            values.set("desk_hazards", self.desk_hazards);
        }
        if mode.has_growth() {
            values.set("random_start", self.growth.random_start);
            values.set("building_respawn", self.growth.building_respawn);
            values.set(
                "building_respawn_delay",
                setting_value(self.growth.building_respawn_delay),
            );
            values.set("base_health", setting_value(self.growth.base_health));
            values.set("base_attack", setting_value(self.growth.base_attack));
            values.set("respawn_delay", setting_value(self.growth.respawn_delay));
        }
        if mode == Mode::Growth {
            values.set("height_bands", self.growth.height_bands);
            values.set("band_start", self.growth.band_start);
            values.set("band_step", self.growth.band_step);
            values.set("coin_count", self.growth.coin_count as i32);
            values.set("coin_interval", setting_value(self.growth.coin_interval));
            values.set(
                "coin_growth_rate",
                setting_value(self.growth.coin_growth_rate),
            );
            values.set(
                "building_growth_rate",
                setting_value(self.growth.building_growth_rate),
            );
            values.set("attack_height", setting_value(self.growth.attack_height));
        }
        if mode == Mode::Brawl {
            values.set(
                "start_min_height",
                setting_value(self.brawl.start_min_height),
            );
            values.set(
                "start_max_height",
                setting_value(self.brawl.start_max_height),
            );
            values.set(
                "respawn_max_height",
                setting_value(self.brawl.respawn_max_height),
            );
            values.set("coin_height", setting_value(self.brawl.coin_height));
            values.set(
                "coin_reward_rate",
                setting_value(self.brawl.coin_reward_rate),
            );
        }
        values.set("sit_crush_enabled", self.sit.crush_enabled);
        values.set("sit_crush_ratio", setting_value(self.sit.crush_ratio));
        values.set("sit_crush_targets", self.sit.crush_targets as i32);
        values.set("sit_hold_base", setting_value(self.sit.hold_base));
        values.set("sit_hold_per_scale", setting_value(self.sit.hold_per_scale));
        values.set("sit_idle_enabled", self.sit.idle_enabled);
        values.set("sit_idle_chance", setting_value(self.sit.idle_chance));
        values.set("sit_idle_timeout", setting_value(self.sit.idle_timeout));
        values.set("sit_pin_ratio", setting_value(self.sit.pin_ratio));
        values.set("sit_pin_interval", setting_value(self.sit.pin_interval));
        values
    }

    pub fn load(path: &GString) -> [Self; Mode::ALL.len()] {
        let mut file = ConfigFile::new_gd();
        if file.load(path) != Error::OK {
            return Mode::ALL.map(Self::for_mode);
        }
        Mode::ALL.map(|mode| {
            file.get_value_ex("settings", mode.key())
                .default(&VarDictionary::new().to_variant())
                .done()
                .try_to::<VarDictionary>()
                .map(|values| Self::from_dictionary(&values, mode).0)
                .unwrap_or_else(|_| Self::for_mode(mode))
        })
    }

    pub fn save(path: &GString, settings: [Self; Mode::ALL.len()], audio: AudioSettings) -> bool {
        let mut file = ConfigFile::new_gd();
        for (mode, values) in Mode::ALL.into_iter().zip(settings) {
            file.set_value(
                "settings",
                mode.key(),
                &values.dictionary(mode).to_variant(),
            );
        }
        file.set_value("audio", "settings", &audio.dictionary().to_variant());
        let temp = GString::from(&format!("{path}.tmp"));
        file.save(&temp) == Error::OK && DirAccess::rename_absolute(&temp, path) == Error::OK
    }
}

// Widen the shortest round-trippable decimal so SpinBox does not show f32 padding.
fn setting_value(value: f32) -> f64 {
    value.to_string().parse().unwrap_or_else(|_| value.into())
}

fn settings_number(value: &Variant) -> Option<f64> {
    value
        .try_to::<f64>()
        .ok()
        .or_else(|| value.try_to::<i64>().ok().map(|value| value as f64))
}

fn finite(value: f64) -> bool {
    (value as f32).is_finite()
}

fn nonnegative(value: f64) -> bool {
    value >= 0.0 && finite(value)
}

fn positive(value: f64) -> bool {
    nonnegative(value) && value as f32 >= f32::MIN_POSITIVE
}

fn count(value: f64) -> bool {
    value >= 0.0 && value.round() <= f64::from(i32::MAX)
}

fn nonzero_count(value: f64) -> bool {
    count(value) && value.round() >= 1.0
}

fn map_side(value: f64) -> bool {
    nonzero_count(value) && value.fract() == 0.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn growth_defaults_use_mapwide_coins_and_split_growth_rates() {
        let growth = GrowthSettings::default();
        assert_eq!(growth.coin_count, 200);
        assert_eq!(growth.coin_interval, 60.0);
        assert_eq!(growth.coin_growth_rate, 0.10);
        assert_eq!(growth.building_growth_rate, 0.10);
        let mode = GameSettings::for_mode(Mode::Growth);
        assert_eq!(mode.giant_height, HUMAN_HEIGHT);
        assert_eq!(mode.growth.coin_count, 200);
        assert_eq!(mode.growth.coin_interval, 60.0);
    }

    #[test]
    fn human_speed_and_two_ignore_ratios_have_independent_defaults() {
        let defaults = GameSettings::default();
        assert_eq!(defaults.human_speed, 1.0);
        assert_eq!(defaults.rival_ignore_ratio, 10.0);
        assert_eq!(defaults.human_ignore_ratio, 30.0);
        let growth = GameSettings::for_mode(Mode::Growth);
        assert_eq!(growth.human_speed, 1.0);
        assert_eq!(growth.rival_ignore_ratio, 10.0);
        assert_eq!(growth.human_ignore_ratio, 30.0);
        assert!(positive(1.0) && !positive(0.0));
        assert!(nonnegative(0.0) && !nonnegative(-0.01));
    }

    #[test]
    fn sit_settings_defaults_and_validators() {
        let sit = SitSettings::default();
        assert!(sit.crush_enabled);
        assert_eq!(sit.crush_ratio, 5.0);
        assert_eq!(sit.crush_targets, 2);
        assert_eq!(sit.hold_base, 1.2);
        assert_eq!(sit.hold_per_scale, 1.0);
        assert!(sit.idle_enabled);
        assert_eq!(sit.idle_timeout, 60.0);
        assert_eq!(sit.pin_ratio, 5.0);
        assert_eq!(sit.pin_interval, 0.5);

        // The dictionary readers rely on these validators; a bad ratio must be rejected.
        assert!(positive(5.0) && !positive(0.0) && !positive(-2.0));
        assert!(nonzero_count(2.0) && !nonzero_count(0.0));
        assert!(nonnegative(0.35) && nonnegative(60.0));

        let growth = GameSettings::for_mode(Mode::Growth);
        let brawl = GameSettings::for_mode(Mode::Brawl);
        assert_eq!(growth.sit, brawl.sit);
        assert_eq!(growth.sit, GameSettings::default().sit);
    }

    #[test]
    fn first_person_steer_defaults_on_in_every_mode() {
        // Steering is a camera-facing rule, so it ships on and stays off the growth profile:
        // every mode starts from the same default until the player turns it off.
        assert!(GameSettings::default().first_person_steer);
        assert!(GrowthSettings::default() == GameSettings::default().growth);
        for mode in Mode::ALL {
            assert!(GameSettings::for_mode(mode).first_person_steer);
        }
    }

    #[test]
    fn audio_defaults_and_valid_gain() {
        let audio = AudioSettings::default();
        assert_eq!(audio.sfx_volume, 0.85);
        assert_eq!(audio.ambience_volume, 0.60);
        assert!(!audio.muted);
        assert!(nonnegative(0.0));
        assert!(nonnegative(1.5));
        assert!(!nonnegative(-0.01));
        assert!(!nonnegative(f64::NAN));
    }

    #[test]
    fn time_of_day_defaults_and_parser() {
        assert_eq!(GameSettings::default().time_of_day, TimeOfDay::Day);
        for mode in Mode::ALL {
            assert_eq!(GameSettings::for_mode(mode).time_of_day, TimeOfDay::Day);
        }
        assert_eq!(TimeOfDay::parse("auto"), Some(TimeOfDay::Auto));
        assert_eq!(TimeOfDay::parse("DAY"), Some(TimeOfDay::Day));
        assert_eq!(TimeOfDay::parse(" dusk "), Some(TimeOfDay::Dusk));
        assert_eq!(TimeOfDay::parse("night"), Some(TimeOfDay::Night));
        assert_eq!(TimeOfDay::parse("midnight"), None);
        assert_eq!(TimeOfDay::parse(""), None);
        assert_eq!(TimeOfDay::Auto.as_str(), "auto");
        assert_eq!(TimeOfDay::Day.as_str(), "day");
        assert_eq!(TimeOfDay::Dusk.as_str(), "dusk");
        assert_eq!(TimeOfDay::Night.as_str(), "night");
    }

    #[test]
    fn desk_hazards_defaults_on_across_modes() {
        assert!(GameSettings::default().desk_hazards);
        for mode in Mode::ALL {
            assert!(GameSettings::for_mode(mode).desk_hazards);
        }
    }
}
