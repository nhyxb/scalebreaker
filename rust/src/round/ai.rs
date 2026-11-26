//! Utility-AI core shared by the growth/brawl/sandbox actors.
//!
//! Replaces the old single-axis "chase or straight-line flee" brain with:
//! - a 6-dimension random personality per NPC (`Personality`),
//! - a 7-step relative-size engagement matrix with ±10 % boundary hysteresis
//!   (`SizeTier`),
//! - short-term combat memory with TTL-decayed entries (`CombatMemory`),
//! - a 360° multi-ray escape scorer that never strands an actor facing a wall
//!   (`escape_direction`),
//! - the 0–100 utility score helpers behind the five intents (`Intent`).
//!
//! Everything here is pure data + math so it stays unit-testable without a
//! live Godot scene; `round.rs` wires the scores into `pursue()`.

use super::*;

/// Re-evaluation cadence of the utility scorer. Between ticks the actor keeps
/// executing its current intent; the inertia bonus below then damps flicker.
pub(super) const UTILITY_INTERVAL: f32 = 0.25;
/// Bonus added to the score of the intent the actor is already executing.
/// Requirement: +12~15 current-intent inertia.
pub(super) const INTENT_INERTIA: f32 = 13.0;
/// How long a lost enemy stays interesting enough to search for (4–8 s band).
pub(super) const SEEN_TTL: f32 = 6.0;
/// How long the direction of the last received hit stays in memory.
pub(super) const HIT_TTL: f32 = 2.5;
/// How long "this enemy attacked me" resentment boosts the attack score (20–30 s).
pub(super) const GRUDGE_TTL: f32 = 25.0;
/// How long a failed escape heading stays blacklisted (3–5 s band).
pub(super) const FAILED_ESCAPE_TTL: f32 = 4.0;
/// How long a recent stomp/sit/combat location stays a danger zone (12–15 s).
pub(super) const DANGER_TTL: f32 = 13.0;
/// Candidate rays for the 360° escape scorer (every 22.5°).
const ESCAPE_RAYS: usize = 16;

/// Six random 0–100 traits that shape every utility score. Rolled once per
/// NPC and preserved across respawns so a fighter keeps its character.
#[derive(Clone, Copy, Debug)]
pub(super) struct Personality {
    /// How eagerly the NPC opens and keeps a fight (chase range, engage threshold).
    pub aggression: f32,
    /// Boldness for risky plays: stealing guarded coins, ambushing up a size tier.
    pub risk_appetite: f32,
    /// How strongly it wants to stay alive (retreat health line, kept distance).
    pub survival_drive: f32,
    /// Development vs fighting: coins and buildings over picking a brawl.
    pub growth_drive: f32,
    /// How much a recent hit biases targeting back at the attacker.
    pub vengeance: f32,
    /// Idle demolition frequency and preference for tall buildings.
    pub destructiveness: f32,
}

impl Personality {
    /// Six uniform 0–100 draws from the shared gameplay RNG stream so a
    /// seeded test run reproduces a whole round's cast exactly.
    pub fn roll() -> Self {
        Self {
            aggression: random_range(0.0, 100.0),
            risk_appetite: random_range(0.0, 100.0),
            survival_drive: random_range(0.0, 100.0),
            growth_drive: random_range(0.0, 100.0),
            vengeance: random_range(0.0, 100.0),
            destructiveness: random_range(0.0, 100.0),
        }
    }

    fn normalized(value: f32) -> f32 {
        (value / 100.0).clamp(0.0, 1.0)
    }

    pub fn aggression01(self) -> f32 {
        Self::normalized(self.aggression)
    }
    pub fn risk01(self) -> f32 {
        Self::normalized(self.risk_appetite)
    }
    pub fn survival01(self) -> f32 {
        Self::normalized(self.survival_drive)
    }
    pub fn growth01(self) -> f32 {
        Self::normalized(self.growth_drive)
    }
    pub fn vengeance01(self) -> f32 {
        Self::normalized(self.vengeance)
    }
    pub fn destructiveness01(self) -> f32 {
        Self::normalized(self.destructiveness)
    }
}

/// One of the seven relative-size engagement tiers. The ratio is
/// `enemy_height / own_height`; the existing `rival_ignore_ratio` /
/// `human_ignore_ratio` settings stay hard gates in front of this matrix.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(super) enum SizeTier {
    /// `< 0.1×` — incidental stomp in passing, never a deliberate chase.
    Trivial,
    /// `0.1–0.5×` — actively chased with lead prediction, intercepted via stomp/sit.
    Prey,
    /// `0.5–0.8×` — pressed hard in close combat.
    Pushover,
    /// `0.8–1.2×` — cautious engagement, sidesteps, punishes recovery.
    Peer,
    /// `1.2–2.0×` — ambush by scale×HP comparison or keep away.
    Uphill,
    /// `2.0–5.0×` — avoided outright; develop out of the enemy's range.
    Danger,
    /// `> 5.0×` — flee the enemy's whole quadrant at full speed.
    Overwhelming,
}

impl SizeTier {
    /// Nominal half-open `[lower, upper)` band of the tier.
    fn bounds(self) -> (f32, f32) {
        match self {
            Self::Trivial => (0.0, 0.1),
            Self::Prey => (0.1, 0.5),
            Self::Pushover => (0.5, 0.8),
            Self::Peer => (0.8, 1.2),
            Self::Uphill => (1.2, 2.0),
            Self::Danger => (2.0, 5.0),
            Self::Overwhelming => (5.0, f32::INFINITY),
        }
    }

    pub fn from_ratio(ratio: f32) -> Self {
        [
            Self::Trivial,
            Self::Prey,
            Self::Pushover,
            Self::Peer,
            Self::Uphill,
            Self::Danger,
        ]
        .into_iter()
        .find(|&tier| {
            let (lower, upper) = tier.bounds();
            ratio >= lower && ratio < upper
        })
        .unwrap_or(Self::Overwhelming)
    }

    /// Same classification, but an actor keeps its previous tier while the
    /// ratio stays inside the ±10 % hysteresis band around that tier's edges.
    pub fn from_ratio_with_hysteresis(ratio: f32, previous: Option<Self>) -> Self {
        if let Some(previous) = previous
            && previous != Self::Overwhelming
        {
            let (lower, upper) = previous.bounds();
            if ratio >= lower * 0.9 && ratio < upper * 1.1 {
                return previous;
            }
        }
        Self::from_ratio(ratio)
    }

    /// Whether the matrix wants a deliberate pursuit of this tier at all.
    pub fn chases(self) -> bool {
        !matches!(self, Self::Trivial | Self::Danger | Self::Overwhelming)
    }

    /// Debug/test index of the tier (0 = trivial .. 6 = overwhelming).
    pub fn index(self) -> i32 {
        match self {
            Self::Trivial => 0,
            Self::Prey => 1,
            Self::Pushover => 2,
            Self::Peer => 3,
            Self::Uphill => 4,
            Self::Danger => 5,
            Self::Overwhelming => 6,
        }
    }
}

/// Signed shortest yaw difference, pure math so memory checks stay unit
/// testable without a live Godot engine.
pub(super) fn yaw_difference(from: f32, to: f32) -> f32 {
    let diff = (from - to).rem_euclid(TAU);
    if diff > PI {
        diff - TAU
    } else {
        diff
    }
}

/// TTL-decayed short-term combat memory. Every entry ages out on its own; the
/// per-frame `tick` prunes expired rows so nothing is ever cleared by hand.
#[derive(Default)]
pub(super) struct CombatMemory {
    /// Last place an enemy was actually seen (position, TTL). No wall-hack: the
    /// search intent only walks to this point, sight checks still apply.
    pub last_seen: Option<(Vector3, f32)>,
    /// Where the last received hit came from (attacker position, TTL) so a
    /// backstabbed actor can turn around even before it can see the attacker.
    pub hit_from: Option<(Vector3, f32)>,
    /// Resentment against the enemy that last landed a hit (id, TTL).
    pub grudge: Option<(InstanceId, f32)>,
    /// Escape headings that ran into a wall or made no progress (yaw, TTL).
    pub failed_escapes: Vec<(f32, f32)>,
    /// Recent stomp/sit/combat locations to avoid while foraging
    /// (position, radius, TTL).
    pub danger_zones: Vec<(Vector3, f32, f32)>,
}

impl CombatMemory {
    fn expire(entry: &mut Option<(Vector3, f32)>, dt: f32) {
        if let Some((_, left)) = entry {
            *left -= dt;
            if *left <= 0.0 {
                *entry = None;
            }
        }
    }

    fn expire_id(entry: &mut Option<(InstanceId, f32)>, dt: f32) {
        if let Some((_, left)) = entry {
            *left -= dt;
            if *left <= 0.0 {
                *entry = None;
            }
        }
    }

    pub fn tick(&mut self, dt: f32) {
        Self::expire(&mut self.last_seen, dt);
        Self::expire(&mut self.hit_from, dt);
        Self::expire_id(&mut self.grudge, dt);
        self.failed_escapes
            .retain_mut(|(_, left)| {
                *left -= dt;
                *left > 0.0
            });
        self.danger_zones.retain_mut(|(_, _, left)| {
            *left -= dt;
            *left > 0.0
        });
    }

    pub fn note_seen(&mut self, at: Vector3) {
        self.last_seen = Some((at, SEEN_TTL));
    }

    pub fn note_hit(&mut self, from: Vector3, attacker: InstanceId) {
        self.hit_from = Some((from, HIT_TTL));
        self.grudge = Some((attacker, GRUDGE_TTL));
    }

    pub fn note_failed_escape(&mut self, yaw: f32) {
        self.failed_escapes.retain(|&(bad, _)| bad != yaw);
        self.failed_escapes.push((yaw, FAILED_ESCAPE_TTL));
        if self.failed_escapes.len() > 4 {
            self.failed_escapes.remove(0);
        }
    }

    pub fn note_danger(&mut self, at: Vector3, radius: f32) {
        const MAX_ZONES: usize = 6;
        for (zone, _, left) in &mut self.danger_zones {
            if horizontal(*zone - at).length_squared() < 1.0 {
                *left = DANGER_TTL;
                return;
            }
        }
        self.danger_zones.push((at, radius, DANGER_TTL));
        if self.danger_zones.len() > MAX_ZONES {
            self.danger_zones.remove(0);
        }
    }

    /// Whether an escape heading falls inside a recently failed direction.
    pub fn escape_blocked(&self, yaw: f32) -> bool {
        self.failed_escapes
            .iter()
            .any(|&(bad, _)| yaw_difference(yaw, bad).abs() < 0.55)
    }
}

/// The five scored intents of the utility brain.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(super) enum Intent {
    Evade,
    Attack,
    Forage,
    Search,
    Demolish,
}

impl Default for Intent {
    fn default() -> Self {
        Self::Demolish
    }
}

/// 360° multi-ray escape scorer. Every candidate direction is graded by
///
/// - how much distance it opens from each nearby threat (probe-position based,
///   so tangents that sweep through a strike zone lose to real detours),
/// - a boundary repulsion proportional to how far the probe marches into the
///   sea wall — wall tangents keep their margin and win,
/// - a large penalty on directions blacklisted as recently failed,
/// - mild heading stickiness so equal escapes do not flicker 180°.
///
/// Feasible (unblocked, in-bounds) candidates win; if every ray is blocked the
/// least-bad in-bounds direction is used, and if even that fails the actor
/// heads for the middle of the map. The function never returns a zero vector —
/// the old narrow-cone retreat stranded outmatched AI in corners precisely
/// because it could produce (and stand on) `Vector3::ZERO`.
pub(super) fn escape_direction(
    position: Vector3,
    radius: f32,
    threats: &[(Vector3, f32)],
    world_limit: f32,
    heading_yaw: f32,
    blocked: impl Fn(Vector3) -> bool,
    blacklisted: impl Fn(f32) -> bool,
) -> Vector3 {
    let probe_len = (radius * 2.5 + 6.0).max(8.0);
    let edge_of = |point: Vector3| world_limit - point.x.abs().max(point.z.abs());
    let heading = Vector3::FORWARD.rotated(Vector3::UP, heading_yaw);
    let mut best: Option<(f32, Vector3)> = None;
    let mut fallback: Option<(f32, Vector3)> = None;
    for step in 0..ESCAPE_RAYS {
        let yaw = step as f32 * TAU / ESCAPE_RAYS as f32;
        let dir = Vector3::FORWARD.rotated(Vector3::UP, yaw);
        let probe = position + dir * probe_len;
        let margin = edge_of(probe);
        let outside = margin < radius * 0.5;
        let mut score = 0.0_f32;
        for &(at, reach) in threats {
            // Opening distance from the threat is the goal; closing it is the
            // failure mode the old straight-line retreat died of. The probe
            // delta also catches paths that merely *look* tangential but would
            // sweep straight through the strike zone.
            let window = (reach * 1.5).max(1.0);
            let current = horizontal(at - position).length();
            let probed = horizontal(at - probe).length();
            let weight = ((window - current) / window).clamp(0.0, 1.0);
            score += (probed - current).clamp(-6.0, 6.0) * (0.8 + weight * 2.2);
        }
        // Boundary repulsion: the further a candidate marches into the sea
        // wall, the heavier the penalty. A wall tangent keeps its margin and
        // stays free, which is what unwedges a cornered actor.
        let shrink = (edge_of(position) - margin).max(0.0);
        score -= shrink * 0.25;
        if margin < radius * 1.5 {
            score -= (radius * 1.5 - margin) * 1.5 + 2.0;
        }
        if blacklisted(yaw) {
            score -= 50.0;
        }
        score += 0.35 * dir.dot(heading);
        if !outside && !blocked(probe) && best.is_none_or(|(won, _)| score > won) {
            best = Some((score, dir));
        }
        if !outside && fallback.is_none_or(|(won, _)| score > won) {
            fallback = Some((score, dir));
        }
    }
    if let Some((_, dir)) = best {
        return dir;
    }
    if let Some((_, dir)) = fallback {
        return dir;
    }
    let inward = horizontal(-position);
    if inward.length_squared() > 1e-6 {
        inward.normalized_or_zero()
    } else {
        Vector3::FORWARD
    }
}

/// Evasion utility (0–100) outside immediate warning circles:
/// `size pressure × low-health weight`, damped by the will to survive.
pub(super) fn threat_evasion_score(size_pressure: f32, low_health: f32, survival01: f32) -> f32 {
    let pressure = size_pressure.clamp(0.0, 1.0);
    let wounded = (0.5 + 0.5 * low_health.clamp(0.0, 1.0)).clamp(0.0, 1.0);
    (pressure * wounded * (0.55 + 0.45 * survival01.clamp(0.0, 1.0)) * 100.0).clamp(0.0, 100.0)
}

/// Coin foraging utility (0–100):
/// `value × growth drive ÷ (distance + dwell) − threat × (1 − risk appetite)`.
pub(super) fn coin_forage_score(
    value: f32,
    growth01: f32,
    distance: f32,
    dwell: f32,
    threat: f32,
    risk01: f32,
) -> f32 {
    let value01 = (value / 5.0).clamp(0.0, 1.0);
    let attract = value01 * (0.35 + 0.65 * growth01.clamp(0.0, 1.0));
    let cost = (distance + dwell * 3.0).max(1.0);
    let reach = attract * 100.0 * (60.0 / (60.0 + cost));
    (reach - threat.clamp(0.0, 1.0) * (1.0 - risk01.clamp(0.0, 1.0)) * 60.0).clamp(0.0, 100.0)
}

/// Demolition utility (0–100): `(growth + destruction) × building density`.
pub(super) fn demolition_score(growth01: f32, destructiveness01: f32, density01: f32) -> f32 {
    let drive = (growth01.clamp(0.0, 1.0) + destructiveness01.clamp(0.0, 1.0)) * 0.5;
    (drive * (0.3 + 0.7 * density01.clamp(0.0, 1.0)) * 100.0).clamp(0.0, 100.0)
}
