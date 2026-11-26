pub const HUMAN_WALK: f32 = 5.8;
pub const HUMAN_SPRINT: f32 = 9.5;
pub const HUMAN_HEIGHT: f32 = 1.8;
pub const HUMAN_RADIUS: f32 = 0.42;
pub const GIANT_WALK: f32 = 7.0;
pub const AI_WALK: f32 = 6.5;
pub const GIANT_RADIUS: f32 = 2.9;
pub const GIANT_START_HEIGHT: f32 = 25.2;
pub const GIANT_DEFAULT_MAX_HEIGHT: f32 = 500.0;
pub const GIANT_GROWTH: f32 = 1.10;
pub const GROWTH_REFERENCE_HEIGHT: f32 = 0.01;
pub const GROWTH_CRUSH_HEIGHT: f32 = 40.0;
// Divisible by every hit count from one through nine, including mixed-size hits.
pub const GROWTH_BUILDING_INTEGRITY: f32 = 2520.0;
pub const ONE_HIT_BUILDING_THRESHOLD: u32 = 3;
pub const TOUCH_CRUSH_BUILDING_THRESHOLD: u32 = 6;
pub const BUILDING_LAYER: u32 = 8;
pub const RUBBLE_LAYER: u32 = 16;
pub const WINDUP: f32 = 0.52;
pub const RECOVERY: f32 = 0.48;
pub const COOLDOWN: f32 = 0.72;
pub const EXIT_RADIUS: f32 = 2.7;

pub fn growth_building_hits(height: f32) -> u32 {
    1 + ((GROWTH_CRUSH_HEIGHT - height - 0.00001).max(0.0) / 5.0).ceil() as u32
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub enum Mode {
    #[default]
    Human,
    Sandbox,
    Growth,
    Brawl,
}

impl Mode {
    pub const ALL: [Self; 4] = [Self::Human, Self::Sandbox, Self::Growth, Self::Brawl];

    pub fn has_growth(self) -> bool {
        matches!(self, Self::Growth | Self::Brawl)
    }

    pub fn key(self) -> &'static str {
        match self {
            Self::Human => "human",
            Self::Sandbox => "giant",
            Self::Growth => "growth",
            Self::Brawl => "brawl",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Active,
    Evacuated,
    Lost,
}

pub struct RoundState {
    pub health: u8,
    pub stamina: f32,
    pub outcome: Outcome,
    exhausted: bool,
}

impl Default for RoundState {
    fn default() -> Self {
        Self {
            health: 3,
            stamina: 1.0,
            outcome: Outcome::Active,
            exhausted: false,
        }
    }
}

impl RoundState {
    pub fn sprint(&mut self, moving: bool, shift: bool, dt: f32) -> bool {
        if !shift {
            self.exhausted = false;
            self.stamina = (self.stamina + dt * 0.25).min(1.0);
            return false;
        }
        if !moving || self.exhausted {
            return false;
        }
        self.stamina = (self.stamina - dt * 0.23).max(0.0);
        self.exhausted = self.stamina == 0.0;
        !self.exhausted
    }

    pub fn is_exhausted(&self) -> bool {
        self.exhausted
    }

    pub fn hurt(&mut self) {
        if self.outcome == Outcome::Active {
            self.health -= 1;
            if self.health == 0 {
                self.outcome = Outcome::Lost;
            }
        }
    }

    pub fn check_exit(&mut self, distance: f32, radius: f32) {
        if self.outcome == Outcome::Active && distance <= radius {
            self.outcome = Outcome::Evacuated;
        }
    }
}

#[derive(Default)]
pub struct GiantProgress {
    pub destroyed: u32,
    pub collected: u32,
    pub growth_count: u32,
}

impl GiantProgress {
    pub fn next_scale(&self, starting_scale: f32, max_scale: f32) -> f32 {
        (starting_scale * GIANT_GROWTH.powf((self.growth_count + 1) as f32)).min(max_scale)
    }

    pub fn one_hit_buildings(&self) -> bool {
        self.destroyed >= ONE_HIT_BUILDING_THRESHOLD
    }

    pub fn touch_crush_buildings(&self) -> bool {
        self.destroyed >= TOUCH_CRUSH_BUILDING_THRESHOLD
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Damage {
    Ignored,
    Cracked,
    Destroyed,
}

pub struct Integrity {
    remaining: f32,
    last_strike: Option<u64>,
}

impl Default for Integrity {
    fn default() -> Self {
        Self::with_health(2.0)
    }
}

impl Integrity {
    pub fn with_health(health: f32) -> Self {
        Self {
            remaining: health,
            last_strike: None,
        }
    }

    pub fn blocks(&self) -> bool {
        self.remaining > 0.0
    }

    pub fn hit(&mut self, strike: u64, amount: f32, destroy_on_hit: bool) -> Damage {
        if !self.blocks() || self.last_strike == Some(strike) {
            return Damage::Ignored;
        }
        self.last_strike = Some(strike);
        self.remaining = if destroy_on_hit {
            0.0
        } else {
            self.remaining - amount
        };
        if self.blocks() {
            Damage::Cracked
        } else {
            Damage::Destroyed
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn growth_demolition_counts_hits_in_five_meter_bands() {
        for (height, hits) in [
            (40.0, 1),
            (39.9, 2),
            (35.0, 2),
            (34.9, 3),
            (30.0, 3),
            (5.0, 8),
            (3.0, 9),
        ] {
            assert_eq!(growth_building_hits(height), hits);
            let mut building = Integrity::with_health(GROWTH_BUILDING_INTEGRITY);
            let damage = GROWTH_BUILDING_INTEGRITY / hits as f32;
            for strike in 1..hits {
                assert_eq!(
                    building.hit(u64::from(strike), damage, false),
                    Damage::Cracked
                );
            }
            assert_eq!(
                building.hit(u64::from(hits), damage, false),
                Damage::Destroyed
            );
        }
    }

    #[test]
    fn two_distinct_impacts_remove_blocking() {
        let mut target = Integrity::default();
        assert!(target.blocks());
        assert_eq!(target.hit(10, 1.0, false), Damage::Cracked);
        assert_eq!(target.hit(10, 1.0, false), Damage::Ignored);
        assert!(target.blocks());
        assert_eq!(target.hit(11, 1.0, false), Damage::Destroyed);
        assert!(!target.blocks());
        assert_eq!(target.hit(12, 1.0, true), Damage::Ignored);
    }

    #[test]
    fn sprint_depletes_and_recharges_only_after_releasing_shift() {
        let mut session = RoundState::default();
        assert!(!session.sprint(false, true, 1.0));
        assert_eq!(session.stamina, 1.0);
        assert!(session.sprint(true, true, 1.0));
        assert!(session.stamina < 1.0);
        assert!(!session.sprint(true, true, 10.0));
        assert!(!session.sprint(true, true, 1.0));
        assert_eq!(session.stamina, 0.0);
        assert!(!session.sprint(true, false, 1.0));
        assert!(session.stamina > 0.0);
        assert!(session.sprint(true, true, 0.1));
    }

    #[test]
    fn evacuation_requires_reaching_exit_and_locks_the_result() {
        let mut session = RoundState::default();
        session.check_exit(EXIT_RADIUS + 0.01, EXIT_RADIUS);
        assert_eq!(session.outcome, Outcome::Active);
        session.check_exit(EXIT_RADIUS, EXIT_RADIUS);
        session.hurt();
        assert_eq!(session.outcome, Outcome::Evacuated);
        assert_eq!(session.health, 3);
    }

    #[test]
    fn exhaustion_of_health_and_round_reset() {
        let mut session = RoundState::default();
        session.sprint(true, true, 2.0);
        for _ in 0..4 {
            session.hurt();
        }
        session.check_exit(0.0, EXIT_RADIUS);
        assert_eq!(session.outcome, Outcome::Lost);
        assert_eq!(session.health, 0);
        session = RoundState::default();
        assert_eq!(session.outcome, Outcome::Active);
        assert_eq!(session.health, 3);
        assert_eq!(session.stamina, 1.0);
    }

    #[test]
    fn building_upgrades_unlock_at_three_and_six_destroyed() {
        let mut session = GiantProgress::default();
        session.destroyed = 2;
        assert!(!session.one_hit_buildings());
        assert!(!session.touch_crush_buildings());
        session.destroyed = 3;
        assert!(session.one_hit_buildings());
        assert!(!session.touch_crush_buildings());
        session.destroyed = 5;
        assert!(!session.touch_crush_buildings());
        session.destroyed = 6;
        assert!(session.one_hit_buildings());
        assert!(session.touch_crush_buildings());
    }

    #[test]
    fn giant_growth_compounds_by_ten_percent_up_to_the_configured_height() {
        let max_scale = GIANT_DEFAULT_MAX_HEIGHT / GIANT_START_HEIGHT;
        let mut progress = GiantProgress::default();
        let mut prev = 1.0;
        for count in 0..31 {
            progress.growth_count = count;
            let cur = progress.next_scale(1.0, max_scale);
            assert!(((cur / prev) - GIANT_GROWTH).abs() < 1e-5);
            prev = cur;
        }
        assert!(prev < max_scale);
        progress.growth_count = 31;
        assert_eq!(progress.next_scale(1.0, max_scale), max_scale);
        assert!(progress.next_scale(1.0, 1000.0 / GIANT_START_HEIGHT) > max_scale);
        progress.growth_count = 0;
        assert_eq!(progress.next_scale(2.0, 2.05), 2.05);
        assert!((progress.next_scale(2.0, max_scale) - 2.2).abs() < 1e-6);
    }
}
