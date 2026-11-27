use super::*;
use godot::classes::RandomNumberGenerator;
use std::collections::HashSet;

const MAX_PENDING_DEFEATS: usize = 8;
const MAP_COIN_RADIUS: f32 = 0.45;
const COIN_GIANT_CLEARANCE: f32 = 18.0;
const COIN_MIN_SPACING: f32 = 4.0;
const COIN_BUILDING_CLEARANCE: f32 = MAP_COIN_RADIUS + 0.35;
const LOCAL_COIN_SEARCH: f32 = 80.0;
const GIANT_PASS_HEIGHT_RATIO: f32 = 3.0;
/// Fuzzy coin radar: coins closer than this are visible to the naked eye, so
/// the compass sector fades out instead of pointing at them.
const COIN_RADAR_FADE_RANGE: f32 = 110.0;
/// Fuzzy coin radar distance bands (metres): below/near/far pulse speeds.
const COIN_RADAR_NEAR: f32 = 250.0;
const COIN_RADAR_MID: f32 = 550.0;
/// Combat hotspots feed coin grading; each entry is (position, radius, ttl).
const HOTSPOT_TTL: f32 = 12.0;

/// Risk-graded map coin. Higher tiers pay more but force the human stage to
/// stand inside the pickup circle while a collection bar fills.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub(super) enum CoinTier {
    /// Safe/outskirts: 1× value, instant pickup (0 s dwell).
    Normal,
    /// Near a large giant's footfall paths: 2.5× value, ~2.0 s dwell.
    High,
    /// At a giant's feet or inside a multi-way combat hotspot: 5× value,
    /// ~3.5–4.0 s dwell.
    Extreme,
}

impl CoinTier {
    pub fn index(self) -> i32 {
        match self {
            Self::Normal => 0,
            Self::High => 1,
            Self::Extreme => 2,
        }
    }

    /// Reward multiplier of the tier (1× / 2.5× / 5×).
    pub fn value(self) -> f32 {
        match self {
            Self::Normal => 1.0,
            Self::High => 2.5,
            Self::Extreme => 5.0,
        }
    }

    /// Seconds a human-stage actor must stand inside the pickup circle.
    /// Giants of any tier collect instantly — the late game never waits.
    pub fn dwell_seconds(self) -> f32 {
        match self {
            Self::Normal => 0.0,
            Self::High => 2.0,
            Self::Extreme => 3.75,
        }
    }

    /// Fraction of the full collection bar lost per second after leaving the
    /// circle (requirement: ~25–30 %/s, not an instant reset).
    const DECAY_FRACTION: f32 = 0.27;
}

/// One step of the dwell collection bar. `inside` accumulates, leaving decays.
pub(super) fn advance_dwell(progress: f32, tier: CoinTier, inside: bool, dt: f32) -> f32 {
    if inside {
        progress + dt
    } else {
        (progress - CoinTier::DECAY_FRACTION * tier.dwell_seconds() * dt).max(0.0)
    }
}

/// A human-stage actor's live collection bar on one risk-tiered coin. Progress
/// is measured in seconds toward the tier's dwell time and follows the actor,
/// not the coin: leaving the circle decays it instead of resetting it.
#[derive(Clone, Copy)]
pub(super) struct CoinDwell {
    pub coin: InstanceId,
    pub tier: CoinTier,
    pub progress: f32,
}

/// A giant or hotspot that grades map coins.
#[derive(Clone, Copy)]
pub(super) struct CoinThreat {
    pub at: Vector3,
    /// Footfall reach around the giant's feet: inside it coins are `Extreme`.
    pub footfall_reach: f32,
    /// Activity zone radius: inside it coins are at least `High`.
    pub zone: f32,
}

/// Pure grading rule: `Extreme` at a giant's feet or the core of a combat
/// hotspot, `High` inside its activity zone or a hotspot, else `Normal`.
pub(super) fn coin_threat_tier(
    point: Vector3,
    threats: &[CoinThreat],
    hotspots: &[(Vector3, f32)],
) -> CoinTier {
    let mut tier = CoinTier::Normal;
    for threat in threats {
        let distance = horizontal(threat.at - point).length();
        if distance <= threat.footfall_reach {
            return CoinTier::Extreme;
        }
        if distance <= threat.zone {
            tier = tier.max(CoinTier::High);
        }
    }
    for &(at, radius) in hotspots {
        let distance = horizontal(at - point).length();
        if distance <= radius * 0.45 {
            return CoinTier::Extreme;
        }
        if distance <= radius {
            tier = tier.max(CoinTier::High);
        }
    }
    tier
}


const GIANT_NAMES: &[&str] = &[
    "林晓岚",
    "周雨桐",
    "陈远航",
    "许知夏",
    "顾星野",
    "沈嘉禾",
    "江若宁",
    "宋清越",
    "方亦舟",
    "程明溪",
    "温时雨",
    "叶青川",
    "陆向南",
    "白晨曦",
    "唐静秋",
    "夏望舒",
    "贺听澜",
    "赵云帆",
    "孟予安",
    "梁书遥",
    "韩初雪",
    "苏微澄",
    "何景行",
    "谢晚晴",
    "罗子衿",
    "傅以恒",
    "邵文心",
    "高月华",
    "乔言希",
    "秦念慈",
    "杜清和",
    "徐闻笛",
    "钟沐阳",
    "袁思齐",
    "曹舒然",
    "池小满",
    "杨露白",
    "戴千帆",
    "傅青山",
    "金海棠",
];

#[derive(Clone, Copy)]
struct HeightBands {
    start: u32,
    step: u32,
}

impl HeightBands {
    fn new(rules: GrowthSettings) -> Option<Self> {
        rules.height_bands.then_some(Self {
            start: rules.band_start,
            step: rules.band_step,
        })
    }

    fn floor(self, scale: f32) -> Option<u32> {
        let height = scale * GIANT_START_HEIGHT;
        let meters = (height + height * f32::EPSILON).floor() as u32;
        (meters >= self.start).then(|| self.start + (meters - self.start) / self.step * self.step)
    }

    fn growth_limit(self, scale: f32, others: impl Iterator<Item = f32>) -> f32 {
        let band = self.floor(scale);
        others
            .filter_map(|other| self.floor(other))
            .filter(|&occupied| band.is_none_or(|own| occupied > own))
            .min()
            .map_or(f32::INFINITY, Self::below)
    }

    fn spawn_scale(self, mut scale: f32, occupied: &[u32]) -> f32 {
        while let Some(band) = self.floor(scale) {
            if !occupied.contains(&band) {
                break;
            }
            scale = Self::below(band);
        }
        scale
    }

    fn below(band: u32) -> f32 {
        let height = band as f32;
        // The lowest band still needs a positive height below it. At large heights
        // leave enough space for the rounding tolerance in floor().
        (height - (2.0 * f32::EPSILON * height).max(1.0)).max(0.5) / GIANT_START_HEIGHT
    }
}

fn rival_growth(base: f32, attacker: f32, defeated: f32) -> f32 {
    let half = defeated * 0.5;
    if half <= attacker {
        base + half
    } else {
        base.max(defeated)
    }
}

fn random_height_scale(lower: f32, upper: f32) -> f32 {
    (random_range(lower.into(), upper.into()) / GIANT_START_HEIGHT).max(f32::MIN_POSITIVE)
}

fn brawl_height_range(first: f32, second: f32) -> (f32, f32) {
    let upper = first.max(second);
    let lower = first.min(second);
    if upper <= 0.0 {
        return (GROWTH_REFERENCE_HEIGHT, GROWTH_REFERENCE_HEIGHT);
    }
    let lower = if lower > 0.0 {
        lower
    } else {
        GROWTH_REFERENCE_HEIGHT.min(upper)
    };
    (lower, upper)
}

struct Coin {
    node: Gd<Node3D>,
    position: Vector3,
    radius: f32,
    reward: CoinReward,
    tier: CoinTier,
}

#[derive(Clone, Copy)]
enum CoinReward {
    Wave,
    Height(f32),
}

impl Coin {
    fn spawn(root: &mut Gd<Node3D>, position: Vector3, reward: CoinReward, tier: CoinTier) -> Self {
        let node = root
            .call(
                "spawn_coin",
                &[
                    position.to_variant(),
                    MAP_COIN_RADIUS.to_variant(),
                    tier.index().to_variant(),
                ],
            )
            .to::<Gd<Node3D>>();
        Self {
            node,
            position,
            radius: MAP_COIN_RADIUS,
            reward,
            tier,
        }
    }
}

#[derive(Default)]
pub(super) struct CoinField {
    coins: Vec<Coin>,
    refresh_in: f32,
}

pub(super) struct Rival {
    pub index: i32,
    pub body: Gd<CharacterBody3D>,
    pub scale: f32,
    pub health_fraction: f32,
    /// Frame-start pose shared by target scanning and threat avoidance.
    pub position: Vector3,
    pub velocity: Vector3,
    /// Human-stage flag snapshot for cheap stage checks during the actor loop.
    pub human: bool,
    /// The planted area forecast by the current airborne shoe.
    pub footfall: Option<FootfallPreview>,
    /// Sit-crush drop zone (center, radius) while this rival is turning/dropping.
    pub sit_drop: Option<(Vector3, f32)>,
}

impl Rival {
    pub fn from_giant(giant: &Giant) -> Self {
        let body = giant.body.clone();
        Self {
            index: giant.index,
            position: body.get_global_position(),
            velocity: body.get_real_velocity(),
            footfall: giant.footfall.clone(),
            sit_drop: giant.sit_drop_zone(),
            human: giant.human,
            body,
            scale: giant.scale,
            health_fraction: giant.health_fraction,
        }
    }
}

pub(super) struct GiantStrike {
    pub attacker: usize,
    pub area: StrikeArea,
    pub damage: f32,
    pub height: f32,
    pub method: DefeatMethod,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum DefeatMethod {
    Step,
    Bump,
    Punch,
    GrabCrush,
    SitCrush,
    FingerPoke,
}

impl DefeatMethod {
    fn key(self) -> &'static str {
        match self {
            Self::Step => "step",
            Self::Bump => "bump",
            Self::Punch => "punch",
            Self::GrabCrush => "grab_crush",
            Self::SitCrush => "sit_crush",
            Self::FingerPoke => "finger_poke",
        }
    }
}

pub(super) struct GrowthDefeat {
    attacker: Option<usize>,
    victim: usize,
    method: DefeatMethod,
}

fn separation(from: Vector3, to: Vector3) -> f32 {
    let path = to - from;
    let t = (-from.dot(path) / path.length_squared().max(1e-10)).clamp(0.0, 1.0);
    (from + t * path).length()
}

fn overlaps_height(a_floor: f32, a_height: f32, b_floor: f32, b_height: f32) -> bool {
    a_floor <= b_floor + b_height && b_floor <= a_floor + a_height
}

fn coin_pickup_margin(height: f32) -> f32 {
    (height * 0.15).min(0.045)
}

fn coin_grid_layout(count: usize, limit: f32) -> (usize, f32, f32) {
    let side = (count as f32).sqrt().ceil().max(1.0) as usize;
    let cell = (2.0 * limit) / side as f32;
    (side, -limit, cell)
}

fn coin_giant_exclusion(giant_scale: f32, giant_height: f32) -> (f32, f32) {
    let body = GIANT_RADIUS * giant_scale;
    let pickup = (body + MAP_COIN_RADIUS + coin_pickup_margin(giant_height)) * 1.2;
    let preferred = (body + MAP_COIN_RADIUS + COIN_GIANT_CLEARANCE).max(pickup);
    (preferred, pickup)
}

fn nearest_giant_distance_sq(point: Vector3, giants: &[Vector3]) -> f32 {
    giants
        .iter()
        .map(|&giant| horizontal(giant - point).length_squared())
        .reduce(f32::min)
        .unwrap_or(f32::INFINITY)
}

fn most_separated_spawn(
    candidates: impl Iterator<Item = Vector3>,
    giants: &[Vector3],
    can_spawn: impl Fn(Vector3) -> bool,
) -> Option<(Vector3, f32)> {
    let mut best = None;
    let mut best_distance_sq = -1.0;
    for point in candidates {
        let mut distance_sq = f32::INFINITY;
        for &giant in giants {
            distance_sq = distance_sq.min(horizontal(giant - point).length_squared());
            if distance_sq <= best_distance_sq {
                break;
            }
        }
        if distance_sq > best_distance_sq && can_spawn(point) {
            best = Some((point, distance_sq));
            best_distance_sq = distance_sq;
        }
    }
    best
}

fn choose_respawn(
    safe_points: impl Iterator<Item = Vector3>,
    largest: &[Vector3],
    roll: f64,
) -> Option<Vector3> {
    draw_weighted_spawn(
        safe_points,
        |point| {
            if largest.is_empty() {
                1.0
            } else {
                nearest_giant_distance_sq(point, largest)
            }
        },
        roll,
    )
}

fn draw_weighted_spawn(
    safe_points: impl Iterator<Item = Vector3>,
    weight: impl Fn(Vector3) -> f32,
    roll: f64,
) -> Option<Vector3> {
    let mut total = 0.0;
    let candidates: Vec<_> = safe_points
        .map(|point| {
            total += f64::from(weight(point));
            (point, total)
        })
        .collect();
    let index = candidates.partition_point(|&(_, limit)| limit <= roll * total);
    candidates
        .get(index)
        .or_else(|| candidates.last())
        .map(|&(point, _)| point)
}

struct BrawlSpawnRival {
    position: Vector3,
    search_range: f32,
    size_similarity: f32,
}

fn brawl_respawn_weight(point: Vector3, former: Vector3, living: &[BrawlSpawnRival]) -> f32 {
    let mut nearby_match = 0.0_f32;
    let mut search_clearance = 1.0_f32;
    for rival in living {
        let distance = horizontal(point - rival.position).length();
        let beyond_range = (distance - rival.search_range).max(0.0);
        let proximity = 1.0 / (1.0 + (beyond_range / 90.0).powi(3));
        nearby_match = nearby_match.max(rival.size_similarity.powi(2) * proximity);
        search_clearance = search_clearance.min(distance / rival.search_range);
    }
    // Keep every physically safe position in the draw. When the whole map is
    // covered, favor positions that are shallowest inside the other giants' ranges.
    let away_from_defeat = if horizontal(point - former).length_squared() >= 16.0_f32.powi(2) {
        1.0
    } else {
        0.15
    };
    (1.0 + 35.0 * nearby_match) * search_clearance.powi(4) * away_from_defeat
}

pub(super) fn ignores_rival(a: f32, b: f32, ratio: f32) -> bool {
    // Allow the one-ULP rounding introduced when exact metre heights become scales.
    a.max(b) >= (a.min(b) * ratio).next_down()
}

fn slid_into(body: &mut Gd<CharacterBody3D>, other: InstanceId) -> bool {
    (0..body.get_slide_collision_count()).any(|index| {
        body.get_slide_collision(index)
            .and_then(|collision| collision.get_collider())
            .is_some_and(|collider| collider.instance_id() == other)
    })
}

impl HarborRound {
    pub(super) fn assign_giant_names(&mut self) {
        const NAME_CHARACTERS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        let mut names = GIANT_NAMES.to_vec();
        let mut generated = HashSet::new();
        // Keep name sampling independent of the random stream used for gameplay.
        let mut rng = RandomNumberGenerator::new_gd();
        rng.randomize();
        self.giant_names = self
            .giants
            .iter_mut()
            .map(|giant| {
                let name = if names.is_empty() {
                    loop {
                        let label: String = (0..7)
                            .map(|_| {
                                let index = rng.randi_range(0, (NAME_CHARACTERS.len() - 1) as i32);
                                char::from(NAME_CHARACTERS[index as usize])
                            })
                            .collect();
                        if generated.insert(label.clone()) {
                            break GString::from(&label);
                        }
                    }
                } else {
                    let index = rng.randi_range(0, (names.len() - 1) as i32) as usize;
                    GString::from(names.swap_remove(index))
                };
                giant.body.call("set_growth_name", &[name.to_variant()]);
                name
            })
            .collect();
    }

    /// Per-actor state used by the playtests to verify stage changes and AI targeting.
    pub(super) fn actor_debug(&self) -> Array<VarDictionary> {
        let mut entries = Array::new();
        for giant in &self.giants {
            let mut entry = VarDictionary::new();
            entry.set("index", giant.index);
            let name = self
                .giant_names
                .get(giant.index as usize)
                .cloned()
                .unwrap_or_default();
            entry.set("name", &name);
            entry.set("height", giant.height(self.max_height));
            entry.set("human", giant.human);
            entry.set("health", giant.health_fraction);
            entry.set("can_demolish", self.can_demolish(giant));
            entry.set(
                "chase",
                giant.chase_target.map_or(0, InstanceId::to_i64),
            );
            entry.set("footfall_count", giant.footfall_count);
            entry.set("footfall_pending", giant.footfall.is_some());
            if let Some(step) = &giant.footfall {
                step.sole.set_debug(&mut entry, false);
                entry.set("footfall_eta", step.eta);
            }
            if let Some(sole) = &giant.last_footfall {
                sole.set_debug(&mut entry, true);
            }
            entry.set("sit", giant.sit.map_or("", |action| action.phase_key()));
            entry.set("sit_idle", giant.sit.is_some_and(|action| action.idle));
            entry.set("pinned", giant.pinned_by.is_some());
            entry.set("intent", giant.intent_key());
            entry.set(
                "size_tier",
                giant.size_tier.map_or(0, |(_, tier)| tier.index()),
            );
            entry.set("evading", giant.intent == Intent::Evade);
            let dwell = giant.coin_dwell.map_or(0.0, |dwell| {
                (dwell.progress / dwell.tier.dwell_seconds().max(0.001)).clamp(0.0, 1.0)
            });
            entry.set("dwell", dwell);
            entry.set(
                "dwell_tier",
                giant.coin_dwell.map_or(0, |dwell| dwell.tier.index()),
            );
            entries.push(&entry);
        }
        entries
    }

    pub(super) fn rank_growth_giants(&self) -> Array<VarDictionary> {
        let mut entries = Array::new();
        if self.growth_rules.is_none() {
            return entries;
        }
        let mut order: Vec<_> = self.giants.iter().collect();
        order.sort_by(|a, b| {
            let alive = |giant: &Giant| giant.health_fraction > 0.0;
            alive(b)
                .cmp(&alive(a))
                .then_with(|| {
                    if alive(a) {
                        b.scale.total_cmp(&a.scale)
                    } else {
                        std::cmp::Ordering::Equal
                    }
                })
                .then_with(|| a.index.cmp(&b.index))
        });
        for (position, giant) in order.into_iter().enumerate() {
            let mut entry = VarDictionary::new();
            entry.set("name", &self.giant_names[giant.index as usize]);
            entry.set(
                "rank",
                if giant.health_fraction > 0.0 {
                    position as i32 + 1
                } else {
                    0
                },
            );
            entry.set("height", giant.height(self.max_height));
            entry.set(
                "is_player",
                giant.index == 0 && self.player == PlayerRole::Giant,
            );
            entries.push(&entry);
        }
        entries
    }

    pub(super) fn combat_rules(&self) -> GrowthSettings {
        self.growth_rules.unwrap_or_default()
    }

    pub(super) fn advance_giant_growth(&mut self, dt: f32) {
        let former_scale = self.giants[0].scale;
        let bands = self.growth_rules.and_then(HeightBands::new);
        let mut order: Vec<_> = (0..self.giants.len())
            .filter(|&index| {
                let actor = &self.giants[index];
                actor.health_fraction > 0.0 && !actor.grabbed && actor.hand_attack.is_none()
            })
            .collect();
        if bands.is_some() {
            order.sort_by(|&a, &b| self.giants[b].scale.total_cmp(&self.giants[a].scale));
        }
        for index in order {
            let limit = bands.map_or(f32::INFINITY, |bands| {
                bands.growth_limit(
                    self.giants[index].scale,
                    self.giants
                        .iter()
                        .enumerate()
                        .filter(|(i, giant)| *i != index && giant.health_fraction > 0.0)
                        .map(|(_, giant)| giant.scale),
                )
            });
            let actor = &mut self.giants[index];
            actor.growth_limit = limit;
            if actor.scale > limit {
                // A new occupant can claim the band while a follower is within the one-meter gap.
                if actor.growth.is_none() {
                    actor.growth = Some(Growth {
                        from: limit,
                        to: limit,
                        target: actor.scale,
                        elapsed: 0.0,
                        counts_reward: false,
                    });
                }
                actor.resize(limit, self.max_height);
            }
            let was_growing = actor.growth.is_some();
            actor.advance_growth(
                dt,
                self.starting_scale,
                self.max_height,
                self.growth_rules.is_some(),
            );
            let started_growth = !was_growing && actor.growth.is_some();
            let became_giant = self.sync_actor_stage(index);
            if index == 0 && self.player == PlayerRole::Giant {
                if became_giant {
                    if let Some(mut audio) = self.audio() {
                        audio.call("play_transform_giant", &[]);
                    }
                } else if started_growth
                    && let Some(mut audio) = self.audio()
                {
                    audio.call("play_growth_surge", &[]);
                }
            }
        }
        let player = &self.giants[0];
        if self.player == PlayerRole::Giant && player.scale != former_scale {
            self.update_giant_camera_scale(&player.body.clone(), player.scale);
        }
    }

    pub(super) fn initial_growth_spawn(&self) -> Option<(Vector3, f32)> {
        let rules = self.growth_rules.unwrap();
        let random = rules.random_start;
        if self.mode == Mode::Brawl && random {
            return self.random_brawl_start();
        }
        let mut scale = self.open_spawn_scale(if random {
            // Random heights stay between the configured starting height and the height cap.
            let lower = f64::from(self.settings.giant_height);
            let upper = f64::from(self.max_height).max(lower);
            // Sample across orders of magnitude so small starts remain possible.
            (lower * (upper / lower).powf(godot::global::randf()) / f64::from(GIANT_START_HEIGHT)) as f32
        } else {
            self.starting_scale
        });
        if random {
            // Height bands may lower an occupied slot; random heights never leave the range.
            scale = scale.max(self.starting_scale);
        }
        self.growth_spawn_position(scale, None)
            .map(|point| (point, scale))
            .or_else(|| {
                let base = self.open_spawn_scale(self.starting_scale.min(scale));
                if base == scale {
                    return None;
                }
                self.growth_spawn_position(base, None)
                    .map(|point| (point, base))
            })
    }

    fn random_brawl_start(&self) -> Option<(Vector3, f32)> {
        let settings = self.settings.brawl;
        let (lower, upper) = brawl_height_range(settings.start_min_height, settings.start_max_height);
        let minimum = (lower / GIANT_START_HEIGHT).max(f32::MIN_POSITIVE);
        let mut maximum = (upper / GIANT_START_HEIGHT)
            .max(minimum)
            .min(self.world_limit / GIANT_RADIUS);
        let mut minimum_fits = false;
        while minimum <= maximum {
            let scale = random_range(minimum.into(), maximum.into());
            if let Some(point) = self.growth_spawn_position(scale, None) {
                return Some((point, scale));
            }
            if !minimum_fits {
                // If even the smallest body cannot fit, no other height in the range can.
                self.growth_spawn_position(minimum, None)?;
                minimum_fits = true;
            }
            // Larger bodies need at least as much room. Exclude the failed draw and redraw.
            maximum = scale.next_down();
        }
        None
    }

    pub(super) fn update_health_bars(&mut self) {
        let observer = self.observer_position();
        for actor in &mut self.giants {
            let height = actor.height(self.max_height);
            let range = (height * 1.5).clamp(2.0, 45.0);
            let offset = actor.body.get_global_position() - observer;
            let distance_sq = if self.player == PlayerRole::Spectator {
                (offset + Vector3::UP * height).length_squared()
            } else {
                horizontal(offset).length_squared()
            };
            let nearby = (actor.index != 0 || self.player != PlayerRole::Giant)
                && actor.health_fraction > 0.0
                && !actor.grabbed
                && distance_sq <= range * range;
            actor.body.call(
                "show_health",
                &[
                    height.to_variant(),
                    actor.health_fraction.to_variant(),
                    nearby.to_variant(),
                ],
            );
        }
        if self.growth_rules.is_some() {
            let viewer = self.camera.as_ref().unwrap().get_global_position();
            for npc in &mut self.civilians {
                let height = npc.size.height;
                let range = (height * 6.0).clamp(6.0, 24.0);
                let anchor = npc.body.get_global_position() + Vector3::UP * (height * 1.08);
                let nearby = !npc.grabbed
                    && npc.remove_in.is_none()
                    && npc.body.is_visible()
                    && anchor.distance_squared_to(viewer) <= range * range;
                npc.body.call(
                    "show_health",
                    &[
                        height.to_variant(),
                        npc.health_fraction.to_variant(),
                        nearby.to_variant(),
                    ],
                );
            }
        }
    }

    pub(super) fn can_demolish(&self, actor: &Giant) -> bool {
        actor.health_fraction > 0.0 && !self.is_human_stage(actor.scale)
    }

    pub(super) fn reward_building_growth(&self, actor: &mut Giant) {
        if self.mode == Mode::Growth {
            let rate = self.combat_rules().building_growth_rate;
            actor.queue_growth(self.max_height, |base| base * (1.0 + rate));
        }
    }

    fn open_spawn_scale(&self, scale: f32) -> f32 {
        let Some(bands) = self.growth_rules.and_then(HeightBands::new) else {
            return scale;
        };
        let occupied: Vec<_> = self
            .giants
            .iter()
            .filter(|giant| giant.health_fraction > 0.0)
            .filter_map(|giant| bands.floor(giant.scale))
            .collect();
        bands.spawn_scale(scale, &occupied)
    }

    fn giant_spawn_safety(&self, scale: f32) -> impl Fn(Vector3, bool) -> bool + '_ {
        let radius = GIANT_RADIUS * scale;
        let clearance = radius + 0.5;
        let occupied: Vec<_> = self
            .giants
            .iter()
            .filter(|giant| giant.health_fraction > 0.0)
            .map(|giant| {
                let capsule = radius + GIANT_RADIUS * giant.scale + 2.0;
                let footfall =
                    radius + footfall_reach(giant.scale) + 4.0;
                (
                    giant.body.get_global_position(),
                    capsule.max(12.0).powi(2),
                    footfall.max(12.0).powi(2),
                )
            })
            .collect();
        let humans: Vec<_> = self
            .evacuating_human()
            .into_iter()
            .chain(
                self.civilians
                    .iter()
                    .filter(|npc| npc.remove_in.is_none())
                    .map(|npc| &npc.body),
            )
            .map(|body| body.get_global_position())
            .collect();
        move |point, outside_footfall_range| {
            point.x.abs().max(point.z.abs()) + clearance < self.world_limit
                && occupied.iter().all(|&(at, capsule, footfall)| {
                    let min_distance_sq = if outside_footfall_range { footfall } else { capsule };
                    horizontal(at - point).length_squared() >= min_distance_sq
                })
                && humans
                    .iter()
                    .all(|&at| horizontal(at - point).length_squared() > (radius + 5.0).powi(2))
                && self
                    .target_grid
                    .near(point, clearance)
                    .all(|index| !self.targets[index].footprint.touches(point, clearance))
        }
    }

    fn growth_spawn_position(&self, scale: f32, former: Option<Vector3>) -> Option<Vector3> {
        let clear = self.giant_spawn_safety(scale);
        let away_from_former = |point| {
            former.is_none_or(|at| horizontal(at - point).length_squared() >= 16.0_f32.powi(2))
        };
        let living: Vec<_> = self
            .giants
            .iter()
            .filter(|giant| giant.health_fraction > 0.0)
            .map(|giant| giant.body.get_global_position())
            .collect();
        if living.is_empty() {
            let safe = |point| away_from_former(point) && clear(point, true);
            return self
                .find_civilian_spawn(safe)
                .or_else(|| self.find_open_ground(safe));
        }
        let candidates = self
            .spawn_points
            .iter()
            .copied()
            .chain(self.open_ground_points(12.0));
        for outside_footfall_range in [true, false] {
            let safe = |point| away_from_former(point) && clear(point, outside_footfall_range);
            let Some((farthest, distance_sq)) =
                most_separated_spawn(candidates.clone(), &living, safe)
            else {
                continue;
            };
            if former.is_none() {
                return Some(farthest);
            }

            // Keep respawns varied within 95% of the best separation from the nearest giant.
            let distant = candidates
                .clone()
                .filter(|&point| {
                    nearest_giant_distance_sq(point, &living) >= distance_sq * 0.95_f32.powi(2)
                })
                .filter(|&point| safe(point));
            return choose_respawn(
                distant,
                &self.largest_giant_positions(),
                godot::global::randf(),
            );
        }
        None
    }

    fn open_ground_points(
        &self,
        step: f32,
    ) -> impl ExactSizeIterator<Item = Vector3> + Clone + use<> {
        // Spaces between roads can fit large giants when nearby road centers are blocked.
        let extent = (self.world_limit / step).floor() as i32;
        let side = 2 * extent + 1;
        (0..side * side).map(move |index| {
            let x = (index % side - extent) as f32 + 0.5;
            let z = (index / side - extent) as f32 + 0.5;
            Vector3::new(x * step, 0.02, z * step)
        })
    }

    fn find_open_ground(&self, safe: impl Fn(Vector3) -> bool) -> Option<Vector3> {
        let candidates = self.open_ground_points(12.0);
        let start = godot::global::randi_range(0, candidates.len() as i64 - 1) as usize;
        candidates
            .clone()
            .skip(start)
            .chain(candidates.take(start))
            .find(|&point| safe(point))
    }

    fn largest_giant_positions(&self) -> Vec<Vector3> {
        let living = self
            .giants
            .iter()
            .filter(|giant| giant.health_fraction > 0.0);
        let max_scale = living.clone().map(|giant| giant.scale).reduce(f32::max);
        living
            .filter(|giant| Some(giant.scale) == max_scale)
            .map(|giant| giant.body.get_global_position())
            .collect()
    }

    fn giant_respawn_position(&self, former: Vector3, scale: f32) -> Option<Vector3> {
        if self.mode == Mode::Brawl {
            return self.brawl_respawn_position(former, scale);
        }
        if self.growth_rules.is_some()
            && self.giants.iter().any(|giant| giant.health_fraction > 0.0)
        {
            return self.growth_spawn_position(scale, Some(former));
        }
        let clear = self.giant_spawn_safety(scale);
        let safe = |point: Vector3, outside_footfall_range| {
            horizontal(former - point).length_squared() >= 16.0_f32.powi(2)
                && clear(point, outside_footfall_range)
        };
        let largest = self.largest_giant_positions();
        let roll = godot::global::randf();
        let draw = |outside_footfall_range| {
            choose_respawn(
                self.spawn_points
                    .iter()
                    .copied()
                    .filter(|&point| safe(point, outside_footfall_range)),
                &largest,
                roll,
            )
        };
        draw(true)
            .or_else(|| draw(false))
            .or_else(|| self.find_open_ground(|point| safe(point, false)))
    }

    fn brawl_respawn_position(&self, former: Vector3, scale: f32) -> Option<Vector3> {
        let mut living: Vec<_> = self
            .giants
            .iter()
            .filter(|giant| giant.health_fraction > 0.0)
            .map(|giant| BrawlSpawnRival {
                position: giant.body.get_global_position(),
                search_range: sight_range(giant.scale),
                size_similarity: scale.min(giant.scale) / scale.max(giant.scale),
            })
            .collect();
        let closest = living
            .iter()
            .map(|rival| rival.size_similarity)
            .fold(0.0, f32::max);
        if closest > 0.0 {
            for rival in &mut living {
                rival.size_similarity /= closest;
            }
        }

        let clear = self.giant_spawn_safety(scale);
        let in_search_range = |point| {
            living.iter().any(|rival| {
                horizontal(point - rival.position).length_squared() <= rival.search_range.powi(2)
            })
        };
        let candidates = self
            .spawn_points
            .iter()
            .copied()
            .chain(self.open_ground_points(12.0));
        let fine = || self.open_ground_points(4.0);
        let roll = godot::global::randf();
        let weight = |point| brawl_respawn_weight(point, former, &living);
        let safe = |&point: &Vector3| !in_search_range(point) && clear(point, false);
        draw_weighted_spawn(candidates.clone().filter(safe), weight, roll)
            // Search the spaces between the usual candidates before relaxing search clearance.
            .or_else(|| draw_weighted_spawn(fine().filter(safe), weight, roll))
            .or_else(|| {
                [true, false].into_iter().find_map(|outside_footfall_range| {
                    let clear = |&point: &Vector3| clear(point, outside_footfall_range);
                    draw_weighted_spawn(candidates.clone().filter(clear), weight, roll)
                        .or_else(|| draw_weighted_spawn(fine().filter(clear), weight, roll))
                })
            })
    }

    fn respawn_scale(&self) -> f32 {
        if self.mode == Mode::Brawl {
            let (lower, upper) = brawl_height_range(0.0, self.settings.brawl.respawn_max_height);
            random_height_scale(lower, upper)
        } else {
            self.open_spawn_scale(self.starting_scale)
        }
    }

    pub(super) fn update_giant_respawns(&mut self, dt: f32) {
        for index in 0..self.giants.len() {
            let giant = &mut self.giants[index];
            if giant.health_fraction > 0.0 {
                continue;
            }
            giant.respawn_in = (giant.respawn_in - dt).max(0.0);
            if giant.respawn_in > 0.0 {
                continue;
            }
            let former = giant.body.get_global_position();
            let scale = self.respawn_scale();
            let Some(spawn) = self.giant_respawn_position(former, scale) else {
                self.giants[index].respawn_in = 0.25;
                continue;
            };
            self.giants[index].respawn(spawn, scale, self.max_height);
            self.sync_actor_stage(index);
            if index == 0 && self.player == PlayerRole::Giant {
                self.yaw = 0.0;
                self.pitch = self.starting_giant_camera_pitch(scale);
                self.camera_focus_offset = Vector3::ZERO;
                self.reset_camera_shake();
                self.update_giant_camera_scale(&self.giants[0].body.clone(), scale);
                self.follow_camera(0.0);
                self.play_audio_2d("respawn", -3.0, 1.0, 0.02);
            }
        }
    }

    pub(super) fn giant_speed(&self, actor: &Giant, player: bool) -> f32 {
        if actor.human {
            // No sprint, and the giant speed option only applies once the actor is a giant.
            return HUMAN_WALK
                * (actor.height(self.max_height) / HUMAN_HEIGHT)
                * self.settings.human_speed;
        }
        let speed = if player { GIANT_WALK } else { AI_WALK };
        let size = if self.growth_rules.is_some() {
            giant_size_speed_factor(actor.scale)
        } else {
            giant_size_speed_factor(actor.scale.max(1.0))
        };
        speed * size * self.settings.giant_speed
    }

    pub(super) fn growth_stat(&self, actor: &Giant, per_centimeter: f32) -> f32 {
        per_centimeter * (actor.height(self.max_height) / GROWTH_REFERENCE_HEIGHT)
    }

    pub(super) fn building_rebuild_time(&self) -> Option<f64> {
        self.growth_rules
            .filter(|rules| rules.building_respawn)
            .map(|rules| self.building_clock + f64::from(rules.building_respawn_delay))
    }

    pub(super) fn update_building_respawns(&mut self, dt: f64) {
        if self.building_rebuild_time().is_none() {
            return;
        }
        self.building_clock += dt;
        if self.building_respawns.is_empty() {
            return;
        }
        let count_before = self.destroyed_buildings;
        let mut waiting = std::mem::take(&mut self.building_respawns);
        waiting.retain_mut(|(index, deadline)| {
            if self.building_clock < *deadline {
                return true;
            }
            let target = &self.targets[*index];
            let footprint = target.footprint;
            let occupied = self.giants.iter().any(|actor| {
                actor.health_fraction > 0.0
                    && footprint.touches(
                        actor.body.get_global_position(),
                        GIANT_RADIUS * actor.scale + TOUCH_CRUSH_MARGIN,
                    )
            }) || self
                .human
                .iter()
                .any(|body| footprint.touches(body.get_global_position(), HUMAN_RADIUS + 0.1))
                || self.civilians.iter().any(|npc| {
                    footprint.touches(npc.body.get_global_position(), npc.size.radius + 0.1)
                });
            if occupied {
                *deadline = self.building_clock + 1.0;
                return true;
            }
            self.restore_building(*index);
            false
        });
        self.building_respawns = waiting;
        if self.destroyed_buildings != count_before {
            for actor in &mut self.giants {
                actor.replan_in = 0.0;
            }
        }
    }

    fn restore_building(&mut self, index: usize) {
        let target = &mut self.targets[index];
        if let Some(rubble) = target
            .node
            .get_node_or_null("RuinBody")
            .and_then(|node| node.try_cast::<StaticBody3D>().ok())
        {
            for actor in &mut self.giants {
                actor.rubble_passes.retain(|(_, body)| {
                    if *body != rubble {
                        return true;
                    }
                    actor.body.remove_collision_exception_with(body);
                    false
                });
            }
        }
        target.node.call("restore_building", &[]);
        target.integrity = Integrity::with_health(GROWTH_BUILDING_INTEGRITY);
        self.destroyed_buildings -= 1;
        let footprint = target.footprint;
        let mut root = self.base().get_node_as::<Node3D>("Coins");
        self.coins.coins.retain_mut(|coin| {
            if !footprint.touches(coin.node.get_position(), coin.radius) {
                return true;
            }
            root.remove_child(&coin.node);
            coin.node.queue_free();
            false
        });
    }

    /// Giant-stage actors and combat hotspots that grade map coins, snapshotted
    /// once per grading pass. Human-stage actors cannot attack with a footfall and never grade.
    pub(super) fn coin_threats(&self) -> (Vec<CoinThreat>, Vec<(Vector3, f32)>) {
        let threats: Vec<CoinThreat> = self
            .giants
            .iter()
            .filter(|giant| giant.health_fraction > 0.0 && !self.is_human_stage(giant.scale))
            .map(|giant| {
                let height = giant.height(self.max_height);
                let at = giant.body.get_global_position();
                CoinThreat {
                    at,
                    footfall_reach: footfall_reach(giant.scale)
                        + GIANT_RADIUS * giant.scale
                        + (6.0 + height * 0.05),
                    zone: (sight_range(giant.scale) * 1.4).max(height * 2.2),
                }
            })
            .collect();
        let hotspots = self
            .hotspots
            .iter()
            .map(|&(at, radius, _)| (at, radius))
            .collect();
        (threats, hotspots)
    }

    /// Ages combat hotspots and re-grades live coins so a wave that spawned in
    /// a quiet street turns valuable (and slower to grab) once giants move in.
    fn update_hotspots_and_coin_tiers(&mut self, dt: f32) {
        self.coin_regrade_in -= dt;
        if self.coin_regrade_in > 0.0 || self.coins.coins.is_empty() {
            return;
        }
        self.coin_regrade_in = 0.5;
        let (threats, hotspots) = self.coin_threats();
        if threats.is_empty() && hotspots.is_empty() {
            return;
        }
        let mut root = self.base().get_node_as::<Node3D>("Coins");
        let mut restyled: Vec<(Gd<Node3D>, CoinTier)> = Vec::new();
        for coin in &mut self.coins.coins {
            let tier = coin_threat_tier(coin.position, &threats, &hotspots);
            if tier != coin.tier {
                coin.tier = tier;
                restyled.push((coin.node.clone(), tier));
            }
        }
        for (node, tier) in restyled {
            root.call(
                "set_coin_tier",
                &[node.to_variant(), tier.index().to_variant()],
            );
        }
    }

    /// Test/debug rows for the live coin wave.
    pub(super) fn coin_debug_entries(&self) -> Array<VarDictionary> {
        let mut entries = Array::new();
        for coin in &self.coins.coins {
            let mut entry = VarDictionary::new();
            entry.set("tier", coin.tier.index());
            entry.set("dwell", coin.tier.dwell_seconds());
            entry.set("position", coin.position);
            entries.push(&entry);
        }
        entries
    }

    /// Records a combat hotspot (footfalls, demolition, kill) that
    /// grades nearby coins up and keeps foragers away for ~12–15 s.
    pub(super) fn note_hotspot(&mut self, at: Vector3, radius: f32) {
        const MAX_HOTSPOTS: usize = 24;
        let merge_radius_sq = (radius * 0.5).powi(2);
        for (existing, _, left) in &mut self.hotspots {
            if horizontal(*existing - at).length_squared() <= merge_radius_sq {
                *left = HOTSPOT_TTL;
                return;
            }
        }
        self.hotspots.push((at, radius, HOTSPOT_TTL));
        if self.hotspots.len() > MAX_HOTSPOTS {
            self.hotspots.remove(0);
        }
    }

    pub(super) fn update_coin_wave(&mut self, dt: f32) {
        let rules = self.growth_rules.unwrap();
        if rules.coin_count == 0 {
            return;
        }
        let has_eligible = self.giants.iter().any(|giant| {
            giant.health_fraction > 0.0 && !giant.grabbed && !self.can_demolish(giant)
        });
        self.coins.refresh_in = (self.coins.refresh_in - dt).max(0.0);
        if !has_eligible {
            self.coins.refresh_in = 0.0;
        }
        if (!has_eligible && self.coins.coins.is_empty())
            || (has_eligible && self.coins.refresh_in > 0.0)
        {
            for coin in &mut self.coins.coins {
                coin.position = coin.node.get_position();
            }
            self.update_hotspots_and_coin_tiers(dt);
            return;
        }

        let mut root = self.base().get_node_as::<Node3D>("Coins");
        for mut coin in self.coins.coins.drain(..) {
            root.remove_child(&coin.node);
            coin.node.queue_free();
        }
        if !has_eligible {
            return;
        }
        self.coins.refresh_in = rules.coin_interval;
        let (coin_threats, coin_hotspots) = self.coin_threats();
        let giant_exclusions: Vec<_> = self
            .giants
            .iter()
            .filter(|giant| giant.health_fraction > 0.0)
            .map(|giant| {
                let (preferred, pickup) =
                    coin_giant_exclusion(giant.scale, giant.height(self.max_height));
                (
                    giant.body.get_global_position(),
                    preferred * preferred,
                    pickup * pickup,
                )
            })
            .collect();
        let limit = (self.world_limit - MAP_COIN_RADIUS - 0.5).max(1.0);
        let (side, origin, cell) = coin_grid_layout(rules.coin_count, limit);
        let mut cells: Vec<usize> = (0..side * side).collect();
        let strict_spacing_sq = COIN_MIN_SPACING * COIN_MIN_SPACING;
        let fallback_spacing_sq = (2.0 * MAP_COIN_RADIUS * 1.05).powi(2);
        let clear_of_buildings = |point: Vector3| {
            point.x.abs().max(point.z.abs()) <= limit
                && self
                    .target_grid
                    .near(point, COIN_BUILDING_CLEARANCE)
                    .all(|index| {
                        let target = &self.targets[index];
                        !target.integrity.blocks()
                            || !target.footprint.touches(point, COIN_BUILDING_CLEARANCE)
                    })
        };
        let clear_of_giants = |point: Vector3, strict: bool| {
            giant_exclusions
                .iter()
                .all(|&(at, preferred_sq, pickup_sq)| {
                    let dx = at.x - point.x;
                    let dz = at.z - point.z;
                    dx * dx + dz * dz >= if strict { preferred_sq } else { pickup_sq }
                })
        };
        let spaced_from_coins = |coins: &[Coin], point: Vector3, min_dist_sq: f32| {
            coins.iter().all(|coin| {
                let dx = coin.position.x - point.x;
                let dz = coin.position.z - point.z;
                dx * dx + dz * dz >= min_dist_sq
            })
        };

        let mut space = root
            .get_world_3d()
            .and_then(|world| world.get_direct_space_state());
        for _ in 0..rules.coin_count {
            let pick = godot::global::randi_range(0, (cells.len() - 1) as i64) as usize;
            let cell_index = cells.swap_remove(pick);
            let min_x = origin + (cell_index % side) as f32 * cell;
            let max_x = min_x + cell;
            let min_z = origin + (cell_index / side) as f32 * cell;
            let max_z = min_z + cell;
            let sample_cell = || {
                Vector3::new(
                    random_range(f64::from(min_x), f64::from(max_x)),
                    0.0,
                    random_range(f64::from(min_z), f64::from(max_z)),
                )
            };
            let sample_map = || {
                Vector3::new(
                    random_range(f64::from(-limit), f64::from(limit)),
                    0.0,
                    random_range(f64::from(-limit), f64::from(limit)),
                )
            };
            let candidate = (0..24)
                .map(|_| sample_cell())
                .chain((0..24).map(|_| sample_map()))
                .find(|&point| {
                    clear_of_buildings(point)
                        && clear_of_giants(point, true)
                        && spaced_from_coins(&self.coins.coins, point, strict_spacing_sq)
                })
                .or_else(|| {
                    (0..24).map(|_| sample_map()).find(|&point| {
                        clear_of_buildings(point)
                            && clear_of_giants(point, false)
                            && spaced_from_coins(&self.coins.coins, point, fallback_spacing_sq)
                    })
                });
            let Some(mut point) = candidate else { continue };
            let query = PhysicsRayQueryParameters3D::create_ex(
                point + Vector3::UP * 4.0,
                Vector3::new(point.x, -0.3, point.z),
            )
            .collision_mask(1 | RUBBLE_LAYER)
            .done()
            .unwrap();
            point.y = space
                .as_mut()
                .and_then(|space| space.intersect_ray(&query).get("position"))
                .map_or(0.0, |position| position.to::<Vector3>().y);
            self.coins.coins.push(Coin::spawn(
                &mut root,
                point,
                CoinReward::Wave,
                coin_threat_tier(point, &coin_threats, &coin_hotspots),
            ));
        }
        let attack_scale = rules.attack_height / GIANT_START_HEIGHT;
        for giant in &mut self.giants {
            if giant.scale < attack_scale {
                giant.clear_path();
                giant.replan_in = 0.03 * (giant.index % 16) as f32;
            }
        }
    }

    pub(super) fn clear_ground_path(
        &self,
        from: Vector3,
        to: Vector3,
        radius: f32,
        crush_buildings: bool,
    ) -> bool {
        let offset = to - from;
        self.target_grid
            .near(from + offset * 0.5, offset.length() * 0.5 + radius)
            .all(|index| {
                let target = &self.targets[index];
                if !target.integrity.blocks() || (crush_buildings && target.footprint.building) {
                    return true;
                }
                let footprint = target.footprint;
                let inverse = footprint.transform.affine_inverse();
                let from = inverse * from;
                let to = inverse * to;
                let half = footprint.size * 0.5 + Vector3::splat(radius);
                let mut entry: f32 = 0.0;
                let mut exit: f32 = 1.0;
                for (start, delta, bound) in [
                    (from.x, to.x - from.x, half.x),
                    (from.z, to.z - from.z, half.z),
                ] {
                    if delta.abs() < 1e-6 {
                        if start.abs() > bound {
                            return true;
                        }
                        continue;
                    }
                    let a = (-bound - start) / delta;
                    let b = (bound - start) / delta;
                    entry = entry.max(a.min(b));
                    exit = exit.min(a.max(b));
                }
                entry > exit
            })
    }

    /// Growth-mode giants that already demolished their way past the human stage
    /// sweep coins instantly so the late game never waits on a collection bar;
    /// the dwell requirement below only applies to the human stage.
    fn can_collect_coins(&self, actor: &Giant) -> bool {
        actor.health_fraction > 0.0
            && if self.mode == Mode::Brawl {
                actor.scale < self.settings.brawl.coin_height / GIANT_START_HEIGHT
            } else {
                self.growth_rules.is_some()
            }
    }

    pub(super) fn has_nearby_brawl_coin(&self, actor: &Giant, position: Vector3) -> bool {
        self.can_collect_coins(actor)
            && self.coins.coins.iter().any(|coin| {
                let offset = coin.position - position;
                offset.y.abs() <= 3.0
                    && horizontal(offset).length_squared() <= LOCAL_COIN_SEARCH.powi(2)
            })
    }

    /// Removes and banks one coin: progress count, tier-scaled growth reward,
    /// scene cleanup and the pickup sound.
    fn collect_coin_at(&mut self, actor: &mut Giant, index: usize) {
        let wave_rate = self.combat_rules().coin_growth_rate;
        let max_height = self.max_height;
        let (mut node, point, reward, tier) = {
            let coin = &self.coins.coins[index];
            (coin.node.clone(), coin.position, coin.reward, coin.tier)
        };
        actor.progress.collected += 1;
        actor.queue_growth(max_height, |base| match reward {
            CoinReward::Wave => base * (1.0 + wave_rate * tier.value()),
            CoinReward::Height(meters) => base + meters / GIANT_START_HEIGHT,
        });
        let mut root = self.base().get_node_as::<Node3D>("Coins");
        root.remove_child(&node);
        node.queue_free();
        self.coins.coins.remove(index);
        if let Some(mut audio) = self.audio() {
            let is_player = actor.index == 0 && self.player == PlayerRole::Giant;
            audio.call(
                "play_coin_pickup",
                &[is_player.to_variant(), point.to_variant()],
            );
        }
    }

    pub(super) fn check_growth_contacts(&mut self, actor: &mut Giant, start: Vector3, dt: f32) {
        if self.coins.coins.is_empty() || !self.can_collect_coins(actor) {
            actor.coin_dwell = None;
            return;
        }
        let end = actor.body.get_global_position();
        let height = actor.height(self.max_height);
        let radius = self.actor_radius(actor);
        let mut instant: Vec<usize> = Vec::new();
        // The dwell candidate is tracked by node id, not index: sweeping the
        // instant coins out first would shift every later index.
        let mut dwell_id: Option<InstanceId> = None;
        let mut dwell_distance = f32::INFINITY;
        for (index, coin) in self.coins.coins.iter().enumerate() {
            let point = coin.position;
            let in_reach = (point.y - end.y).abs() <= 0.16_f32.max(height * 0.65)
                && separation(horizontal(start - point), horizontal(end - point))
                    <= radius + coin.radius + coin_pickup_margin(height);
            if !in_reach {
                continue;
            }
            if !actor.human || coin.tier.dwell_seconds() <= 0.0 {
                // Normal coins — and every giant-stage actor sweeping the field —
                // keep the instant pickup so the late game never waits.
                instant.push(index);
            } else {
                let distance = horizontal(point - end).length();
                if distance < dwell_distance {
                    dwell_distance = distance;
                    dwell_id = Some(coin.node.instance_id());
                }
            }
        }
        for index in instant.into_iter().rev() {
            self.collect_coin_at(actor, index);
        }
        if actor.coin_dwell.is_some_and(|dwell| {
            !self
                .coins
                .coins
                .iter()
                .any(|coin| coin.node.instance_id() == dwell.coin)
        }) {
            actor.coin_dwell = None;
        }
        let dwell_at = dwell_id
            .and_then(|id| self.coins.coins.iter().position(|coin| coin.node.instance_id() == id));
        // Dwell bar: standing inside the circle fills it, leaving decays it at
        // ~27 %/s (never an instant reset), so a dodge can resume the steal.
        let mut dwell_show: Option<(Vector3, f32, CoinTier)> = None;
        if let Some(index) = dwell_at {
            let (coin_id, tier, position) = {
                let coin = &self.coins.coins[index];
                (coin.node.instance_id(), coin.tier, coin.position)
            };
            let progress = match actor.coin_dwell {
                Some(dwell) if dwell.coin == coin_id => {
                    advance_dwell(dwell.progress, tier, true, dt)
                }
                _ => advance_dwell(0.0, tier, true, dt),
            };
            if progress >= tier.dwell_seconds() {
                self.collect_coin_at(actor, index);
                actor.coin_dwell = None;
            } else {
                actor.coin_dwell = Some(CoinDwell {
                    coin: coin_id,
                    tier,
                    progress,
                });
                dwell_show = Some((position, progress / tier.dwell_seconds(), tier));
            }
        } else if let Some(dwell) = actor.coin_dwell {
            let progress = advance_dwell(dwell.progress, dwell.tier, false, dt);
            if progress <= 0.0 {
                actor.coin_dwell = None;
            } else {
                actor.coin_dwell = Some(CoinDwell {
                    coin: dwell.coin,
                    tier: dwell.tier,
                    progress,
                });
                if let Some(coin) = self
                    .coins
                    .coins
                    .iter()
                    .find(|coin| coin.node.instance_id() == dwell.coin)
                {
                    dwell_show = Some((
                        coin.position,
                        progress / dwell.tier.dwell_seconds(),
                        dwell.tier,
                    ));
                }
            }
        }
        self.update_player_dwell_feedback(actor, dwell_show, dt);
    }

    /// Ground progress ring + rising audio tick for the player's current dwell
    /// bar. AI humans obey the same timing rules but get no per-frame visuals.
    fn update_player_dwell_feedback(
        &mut self,
        actor: &Giant,
        dwell_show: Option<(Vector3, f32, CoinTier)>,
        dt: f32,
    ) {
        let mut root = self.base().get_node_as::<Node3D>("Coins");
        if actor.index == 0 && self.player == PlayerRole::Giant {
            if let Some((position, fraction, tier)) = dwell_show {
                root.call(
                    "show_dwell",
                    &[
                        position.to_variant(),
                        fraction.to_variant(),
                        tier.index().to_variant(),
                    ],
                );
                self.dwell_ring_visible = true;
                self.dwell_tick_in -= dt;
                if self.dwell_tick_in <= 0.0 {
                    self.dwell_tick_in = 0.16;
                    if let Some(mut audio) = self.audio() {
                        audio.call("play_coin_dwell_tick", &[fraction.to_variant()]);
                    }
                }
            } else if self.dwell_ring_visible {
                root.call("hide_dwell", &[]);
                self.dwell_ring_visible = false;
            }
        } else if actor.coin_dwell.is_none() && self.dwell_ring_visible {
            root.call("hide_dwell", &[]);
            self.dwell_ring_visible = false;
        }
    }

    fn drop_brawl_coin(&mut self, attacker: &Giant) {
        let rules = self.settings.brawl;
        if attacker.scale < rules.coin_height / GIANT_START_HEIGHT {
            return;
        }
        let position = attacker.body.get_global_position();
        let height = attacker.height(self.max_height);
        let reward = CoinReward::Height(height * rules.coin_reward_rate);
        let mut root = self.base().get_node_as::<Node3D>("Coins");
        // Brawl giants collect instantly at any tier, so kills always drop the
        // baseline coin; the risk-tier system only grades growth-mode waves.
        self.coins.coins.push(Coin::spawn(
            &mut root,
            position,
            reward,
            CoinTier::Normal,
        ));
        if let Some(mut audio) = self.audio() {
            audio.call(
                "play_coin_drop",
                &[position.to_variant(), height.to_variant()],
            );
        }
    }

    pub(super) fn hurt_giant(&mut self, actor: &mut Giant, damage: f32) -> bool {
        let max_health = self.growth_stat(actor, self.combat_rules().base_health);
        actor.health_fraction = (actor.health_fraction - damage / max_health).max(0.0);
        if actor.health_fraction > 0.0 {
            if let Some(rival) = self
                .rivals
                .iter_mut()
                .find(|rival| rival.index == actor.index)
            {
                rival.health_fraction = actor.health_fraction;
            }
            return false;
        }
        actor.body.set_collision_layer(0);
        actor.body.set_collision_mask(0);
        actor.body.call("show_defeat", &[]);
        actor.sit = None;
        actor.pinned_by = None;
        actor.pin_tick = 0.0;
        actor.footfall = None;
        actor.respawn_in = self.settings.growth.respawn_delay;
        self.effects
            .as_mut()
            .unwrap()
            .call("sit_warn_end", &[actor.index.to_variant()]);
        self.rivals.retain(|rival| rival.index != actor.index);
        true
    }

    pub(super) fn apply_giant_strikes(&mut self, giants: &mut [Giant]) {
        let strikes = std::mem::take(&mut self.giant_strikes);
        for strike in strikes {
            let (earlier, combatants) = giants.split_at_mut(strike.attacker);
            let (attacker, later) = combatants.split_first_mut().unwrap();
            for rival in earlier.iter_mut().chain(later) {
                let target_height = rival.height(self.max_height);
                if rival.health_fraction == 0.0 || rival.grabbed {
                    continue;
                }
                let point = rival.body.get_global_position();
                let tolerance = (0.04 * strike.height).clamp(0.003, 0.25);
                let center = strike.area.center();
                let vertical_reach = if strike.method == DefeatMethod::Step { 0.0 } else { strike.height };
                if strike.area.reaches(point, self.actor_radius(rival))
                    && overlaps_height(
                        point.y,
                        target_height,
                        center.y - tolerance,
                        vertical_reach + tolerance * 2.0,
                    )
                {
                    self.damage_rival(attacker, rival, strike.damage, strike.method);
                    if strike.method == DefeatMethod::SitCrush
                        && rival.health_fraction > 0.0
                        && strike.height >= target_height * self.settings.sit.pin_ratio
                    {
                        rival.pinned_by = Some(attacker.index);
                        rival.pin_tick = 0.0;
                    }
                }
            }
        }
    }

    pub(super) fn damage_rival(
        &mut self,
        attacker: &mut Giant,
        rival: &mut Giant,
        damage: f32,
        method: DefeatMethod,
    ) {
        rival.body.call("show_hit", &[]);
        let is_player_attacker = attacker.index == 0 && self.player == PlayerRole::Giant;
        let is_player_victim = rival.index == 0 && self.player == PlayerRole::Giant;
        let victim_pos = rival.body.get_global_position();
        let victim_height = rival.height(self.max_height);
        if is_player_attacker {
            self.player_giant_hits += 1;
        }
        // Every landed hit marks the spot as a combat hotspot: nearby coins grade
        // up to High/Extreme and foraging AI remembers to keep away.
        self.note_hotspot(
            victim_pos,
            (attacker.height(self.max_height) * 1.2).max(24.0),
        );
        // The victim remembers where the hit came from and holds a grudge
        // against the attacker for 20–30 s (turn-around + attack boost).
        rival.memory.note_hit(
            attacker.body.get_global_position(),
            attacker.body.instance_id(),
        );
        if let Some(mut audio) = self.audio() {
            audio.call(
                "play_combat_hit",
                &[
                    is_player_attacker.to_variant(),
                    is_player_victim.to_variant(),
                    victim_pos.to_variant(),
                    victim_height.to_variant(),
                ],
            );
        }
        if self.hurt_giant(rival, damage) {
            // The kill resolves the hunt: stop searching for a corpse and let
            // the utility brain move on (demolish/roam) immediately.
            attacker.memory.last_seen = None;
            attacker.memory.hit_from = None;
            attacker.memory.grudge = None;
            if let Some(mut audio) = self.audio() {
                audio.call(
                    "play_defeat",
                    &[
                        is_player_attacker.to_variant(),
                        is_player_victim.to_variant(),
                        victim_pos.to_variant(),
                        victim_height.to_variant(),
                    ],
                );
            }
            attacker.match_kills += 1;
            if self.growth_rules.is_some() {
                self.record_growth_defeat(Some(attacker.index), rival.index, method);
                let attacker_scale = attacker.scale;
                attacker.queue_growth(self.max_height, |base| {
                    rival_growth(base, attacker_scale, rival.scale)
                });
                if self.mode == Mode::Brawl {
                    self.drop_brawl_coin(attacker);
                }
            }
        }
    }

    pub(super) fn record_growth_defeat(
        &mut self,
        attacker: Option<i32>,
        victim: i32,
        method: DefeatMethod,
    ) {
        if self.growth_defeats.len() == MAX_PENDING_DEFEATS {
            self.growth_defeats.pop_front();
        }
        self.growth_defeats.push_back(GrowthDefeat {
            attacker: attacker.map(|index| index as usize),
            victim: victim as usize,
            method,
        });
    }

    pub(crate) fn take_growth_defeats(&mut self) -> Option<Array<VarDictionary>> {
        if self.growth_defeats.is_empty() {
            return None;
        }
        let mut messages = Array::new();
        let playing_giant = self.player == PlayerRole::Giant;
        for defeat in self.growth_defeats.drain(..) {
            let mut message = VarDictionary::new();
            if let Some(attacker) = defeat.attacker {
                message.set("attacker", &self.giant_names[attacker]);
            }
            message.set("victim", &self.giant_names[defeat.victim]);
            message.set("method", defeat.method.key());
            message.set("player_defeated", playing_giant && defeat.victim == 0);
            message.set("player_attack", playing_giant && defeat.attacker == Some(0));
            messages.push(&message);
        }
        Some(messages)
    }

    pub(super) fn update_giant_collision_passes(&mut self, frames: &[PairFrame]) {
        if self.giant_collision_passes.is_empty() && frames.iter().all(|frame| frame.human) {
            return;
        }
        let pass_ratio = self
            .settings
            .rival_ignore_ratio
            .min(GIANT_PASS_HEIGHT_RATIO);
        for (index, frame) in frames.iter().enumerate() {
            for (other_index, other) in frames.iter().enumerate().skip(index + 1) {
                let pair = (index, other_index);
                let had_pass = self.giant_collision_passes.contains(&pair);
                let available = frame.health > 0.0
                    && other.health > 0.0
                    && !frame.grabbed
                    && !other.grabbed;
                let fits_ratio = available
                    && !(frame.human && other.human)
                    && frame.scale != other.scale
                    && ignores_rival(frame.scale, other.scale, pass_ratio);
                if !fits_ratio && !had_pass {
                    continue;
                }
                let distance_sq = horizontal(frame.start - other.start).length_squared();
                let body_span = frame.radius + other.radius;
                let travel = frame.travel + other.travel;
                let pass = available
                    && ((fits_ratio && distance_sq <= (body_span + travel + 2.0).powi(2))
                        // Wait until their bodies are clear before restoring a solid collision.
                        || (had_pass && distance_sq <= (body_span + 0.05).powi(2)));
                if pass == had_pass {
                    continue;
                }
                let mut body = self.giants[index].body.clone();
                let mut other_body = self.giants[other_index].body.clone();
                if pass {
                    body.add_collision_exception_with(&other_body);
                    other_body.add_collision_exception_with(&body);
                    self.giant_collision_passes.insert(pair);
                } else {
                    body.remove_collision_exception_with(&other_body);
                    other_body.remove_collision_exception_with(&body);
                    self.giant_collision_passes.remove(&pair);
                }
            }
        }
    }

    pub(super) fn apply_human_bumps(
        &mut self,
        giants: &mut [Giant],
        frames: &[PairFrame],
    ) {
        let Some(rules) = self.growth_rules else {
            return;
        };
        for index in 0..giants.len() {
            let (giant, others) = giants[index..].split_first_mut().unwrap();
            for (offset, other) in others.iter_mut().enumerate() {
                let other_index = index + 1 + offset;
                let pair = (index, other_index);
                let tracked = self.bump_contacts.contains(&pair);
                let a = frames[index];
                let b = frames[other_index];
                let eligible = giant.human && other.human
                    && giant.health_fraction > 0.0 && other.health_fraction > 0.0
                    && !giant.grabbed && !other.grabbed
                    && a.height.max(b.height) + 0.0001 >= a.height.min(b.height) * 2.0;
                if !eligible {
                    self.bump_contacts.remove(&pair);
                    continue;
                }
                let max_travel = a.travel + b.travel;
                if !tracked && horizontal(a.end - b.end).length()
                    > a.radius + b.radius + a.safe_margin + b.safe_margin + max_travel
                {
                    continue;
                }
                let offset = a.end - b.end;
                let a_radius = a.radius;
                let b_radius = b.radius;
                let clearance = a_radius + b_radius + a.safe_margin + b.safe_margin;
                // The relative vertical offset lies in this interval when the capsule axes overlap.
                let axis_min = a_radius + b_radius - a.height;
                let axis_max = b.height - a_radius - b_radius;
                let gap = offset.y - offset.y.clamp(axis_min, axis_max);
                let distance_sq = horizontal(offset).length_squared() + gap.powi(2);
                // A slide can still report the old collider position during the respawn frame.
                let collided = distance_sq <= (clearance + max_travel).powi(2)
                    && (slid_into(&mut giant.body, other.body.instance_id())
                        || slid_into(&mut other.body, giant.body.instance_id()));
                if tracked {
                    // Sliding may omit touching bodies on a frame with no movement into them.
                    if !collided && distance_sq > clearance.powi(2) {
                        self.bump_contacts.remove(&pair);
                    }
                } else if collided {
                    self.bump_contacts.insert(pair);
                    let (larger, smaller) = if giant.scale > other.scale {
                        (&mut *giant, other)
                    } else {
                        (other, &mut *giant)
                    };
                    let damage = self.growth_stat(larger, rules.base_attack);
                    self.damage_rival(larger, smaller, damage, DefeatMethod::Bump);
                }
            }
        }
    }

    pub(super) fn forage(&mut self, actor: &mut Giant, speed: f32, dt: f32) -> Vector3 {
        let position = actor.body.get_global_position();
        let height = actor.height(self.max_height);
        let radius = self.actor_radius(actor);
        let crush_buildings = self.mode == Mode::Brawl && self.can_crush_buildings(actor);
        let personality = actor.personality;
        let mut threats = Vec::new();
        // Other humans only hurt this actor when they are at least twice as tall; any giant is
        // dangerous because it can step on or pick the human up.
        threats.extend(self.rivals.iter().filter(|rival| rival.index != actor.index).filter_map(
            |rival| {
                let rival_height = rival.scale * GIANT_START_HEIGHT;
                let reach = if self.is_human_stage(rival.scale) {
                    if rival_height + 0.0001 < height * 2.0 {
                        return None;
                    }
                    HUMAN_RADIUS * rival_height / HUMAN_HEIGHT
                } else {
                    footfall_reach(rival.scale)
                };
                Some((rival.position, rival.velocity, reach, 0.6))
            },
        ));
        // Projected landings and sit-crush drop zones are threats even before the
        // striking giant's body reach arrives; memory danger zones linger for
        // 12–15 s after the fight moved on.
        for rival in &self.rivals {
            if rival.index == actor.index {
                continue;
            }
            if let Some(step) = &rival.footfall {
                threats.push((step.sole.center, Vector3::ZERO, step.sole.bounds() + radius, 1.2));
            }
            if let Some((center, sit_radius)) = rival.sit_drop {
                threats.push((center, Vector3::ZERO, sit_radius + radius + 1.0, 1.0));
            }
        }
        for &(at, zone_radius, _) in &actor.memory.danger_zones {
            threats.push((at, Vector3::ZERO, zone_radius, 0.6));
        }
        threats.retain(|(at, _, reach, _)| horizontal(*at - position).length() < reach + 7.0);
        let contact_weight = 40.0 / speed.max(0.02);
        // Bold NPCs discount danger; cautious ones amplify it.
        let risk_weight = 1.5 - personality.risk01();
        let risk = |direction: Vector3, travel: f32| -> f32 {
            threats
                .iter()
                .map(|&(at, velocity, reach, buffer)| {
                    let before = horizontal(at - position);
                    let after = before + horizontal(velocity) * travel - direction * speed * travel;
                    let distance = separation(before, after);
                    let clearance = radius + reach + buffer;
                    let closest = (clearance - distance).max(0.0);
                    let ends_close = (clearance + 0.8 - after.length()).max(0.0);
                    // A short stride must still avoid a predicted collision before chasing a coin.
                    let contact = (radius + reach + 0.03 - distance).max(0.0);
                    (contact * contact_weight + closest * 12.0 + ends_close * 3.0) * risk_weight
                })
                .sum()
        };
        // Threat proximity (0–1) of a map point, used by the coin utility score.
        let threat_at = |point: Vector3| -> f32 {
            threats
                .iter()
                .map(|&(at, _, reach, _)| {
                    let window = (reach * 1.5).max(1.0);
                    ((window - horizontal(at - point).length()) / window).max(0.0)
                })
                .fold(0.0_f32, f32::max)
        };

        let local_limit_sq = LOCAL_COIN_SEARCH * LOCAL_COIN_SEARCH;
        let mut nearest_coin: Option<(f32, Vector3)> = None;
        let mut local_coins: Vec<(f32, Vector3, CoinTier)> = Vec::with_capacity(8);
        for coin in &self.coins.coins {
            let point = coin.position;
            if (point.y - position.y).abs() > 3.0 {
                continue;
            }
            let dx = point.x - position.x;
            let dz = point.z - position.z;
            let dist_sq = dx * dx + dz * dz;
            // Value-weighted utility: rare guarded coins attract growth-hungry,
            // risk-tolerant foragers instead of only the nearest coin winning.
            let utility = coin_forage_score(
                coin.tier.value(),
                personality.growth01(),
                dist_sq.sqrt(),
                coin.tier.dwell_seconds(),
                threat_at(point),
                personality.risk01(),
            );
            if nearest_coin.is_none_or(|(best, _)| utility > best) {
                nearest_coin = Some((utility, point));
            }
            if dist_sq <= local_limit_sq {
                let tier = coin.tier;
                if local_coins.len() < 8 {
                    local_coins.push((dist_sq, point, tier));
                } else if let Some((slot, &(worst, _, _))) = local_coins
                    .iter()
                    .enumerate()
                    .max_by(|a, b| a.1 .0.total_cmp(&b.1 .0))
                    && dist_sq < worst
                {
                    local_coins[slot] = (dist_sq, point, tier);
                }
            }
        }

        let direct = local_coins
            .into_iter()
            .filter_map(|(dist_sq, point, tier)| {
                if !self.clear_ground_path(position, point, radius, crush_buildings) {
                    return None;
                }
                let distance = dist_sq.sqrt();
                let direction = horizontal(point - position).normalized_or_zero();
                let utility = coin_forage_score(
                    tier.value(),
                    personality.growth01(),
                    distance,
                    tier.dwell_seconds(),
                    threat_at(point),
                    personality.risk01(),
                );
                Some((direction, utility, distance))
            })
            .filter(|(_, utility, _)| *utility > 4.0)
            .max_by(|a, b| {
                a.1.total_cmp(&b.1)
                    .then_with(|| b.2.total_cmp(&a.2))
            })
            .map(|(dir, _, _)| dir);

        let seek = if let Some(dir) = direct {
            actor.clear_path();
            dir
        } else if let Some((_, goal)) = nearest_coin {
            if self.clear_ground_path(position, goal, radius, crush_buildings) {
                actor.clear_path();
                horizontal(goal - position).normalized_or_zero()
            } else {
                actor.replan_in -= dt;
                let stale_goal = actor
                    .path
                    .first()
                    .is_some_and(|&end| horizontal(end - goal).length_squared() > 36.0);
                if actor.replan_in <= 0.0 || stale_goal {
                    actor.replan_in = 0.55 + 0.02 * (actor.index % 8) as f32;
                    self.request_route(actor, position, goal, radius, crush_buildings);
                }
                while actor.path.len() > 1
                    && actor
                        .path
                        .last()
                        .is_some_and(|point| horizontal(*point - position).length() < 2.2)
                {
                    actor.path.pop();
                }
                if actor
                    .path
                    .last()
                    .is_some_and(|point| horizontal(*point - position).length() < 0.65)
                {
                    actor.path.pop();
                }
                let next = match actor.path.as_slice() {
                    [.., prev, last] => *last * 0.65 + *prev * 0.35,
                    [.., last] => *last,
                    [] => goal,
                };
                let offset = horizontal(next - position);
                if offset.length_squared() > 0.0001 {
                    offset.normalized_or_zero()
                } else {
                    horizontal(self.wander_goal(actor, position, radius, speed) - position)
                        .normalized_or_zero()
                }
            }
        } else {
            actor.clear_path();
            horizontal(self.wander_goal(actor, position, radius, speed) - position)
                .normalized_or_zero()
        };
        [
            0.0,
            0.52,
            -0.52,
            1.05,
            -1.05,
            1.57,
            -1.57,
            std::f32::consts::PI,
        ]
        .into_iter()
        .map(|angle| {
            let forward = if seek == Vector3::ZERO {
                Vector3::FORWARD.rotated(Vector3::UP, actor.body.get_rotation().y)
            } else {
                seek
            };
            forward.rotated(Vector3::UP, angle)
        })
        .chain([Vector3::ZERO])
        .filter(|&direction| {
            let next = position + direction * speed * 0.35;
            next.x.abs().max(next.z.abs()) < self.world_limit
                && (direction == Vector3::ZERO
                    || self.clear_ground_path(position, next, radius, crush_buildings))
        })
        .min_by(|&a, &b| {
            let score = |direction: Vector3| {
                risk(direction, 0.72) - seek.dot(direction) + direction.length_squared() * 0.06
            };
            score(a).total_cmp(&score(b))
        })
        .unwrap_or(Vector3::ZERO)
    }

    pub(super) fn snapshot_growth(&self, actor: &Giant, snapshot: &mut VarDictionary) {
        let Some(rules) = self.growth_rules else {
            return;
        };
        let health = self.growth_stat(actor, rules.base_health);
        snapshot.set("giant_health", health * actor.health_fraction);
        snapshot.set("giant_max_health", health);
        snapshot.set("giant_attack", self.growth_stat(actor, rules.base_attack));
        snapshot.set(
            "growth_band_locked",
            actor.growth_limit.is_finite() && actor.scale >= actor.growth_limit,
        );
        snapshot.set("giant_kills", actor.match_kills);
        snapshot.set("giant_hits", self.player_giant_hits);
        snapshot.set(
            "giants_alive",
            self.giants
                .iter()
                .filter(|giant| giant.health_fraction > 0.0)
                .count() as i32,
        );
        snapshot.set("coins_collected", actor.progress.collected);
        let can_demolish = self.can_demolish(actor);
        snapshot.set("human_stage", actor.human);
        snapshot.set("can_attack", can_demolish);
        snapshot.set("can_demolish", can_demolish);
        snapshot.set("can_crush_buildings", self.can_crush_buildings(actor));
        snapshot.set(
            "building_hits",
            growth_building_hits(actor.height(self.max_height)),
        );
        snapshot.set("attack_height", rules.attack_height);
        if self.mode == Mode::Growth {
            snapshot.set("coin_refresh_in", self.coins.refresh_in.max(0.0));
        }
        let player_position = actor.body.get_global_position();
        if self.mode == Mode::Brawl && self.can_collect_coins(actor) {
            // Brawl keeps the precise nearest-coin compass (giants hunt kill drops).
            if let Some(coin) = self
                .coins
                .coins
                .iter()
                .map(|coin| horizontal(coin.position - player_position))
                .min_by(|a, b| a.length_squared().total_cmp(&b.length_squared()))
            {
                let view = coin.rotated(Vector3::UP, -self.yaw);
                snapshot.set("coin_angle", view.x.atan2(-view.z));
                snapshot.set("coin_distance", coin.length());
            }
        } else if self.mode == Mode::Growth && actor.human {
            // Fuzzy coin radar, growth human stage only: a ~40° direction sector
            // toward the best-value coin beyond naked-eye range. No exact metres
            // ever leave this snapshot — only tier colour and a 3-band pulse.
            let mut best: Option<(CoinTier, f32, Vector3)> = None;
            for coin in &self.coins.coins {
                let offset = horizontal(coin.position - player_position);
                let distance = offset.length();
                if distance <= COIN_RADAR_FADE_RANGE {
                    continue;
                }
                let better = best.is_none_or(|(tier, best_distance, _)| {
                    coin.tier > tier || (coin.tier == tier && distance < best_distance)
                });
                if better {
                    best = Some((coin.tier, distance, offset));
                }
            }
            if let Some((tier, distance, offset)) = best {
                let view = offset.rotated(Vector3::UP, -self.yaw);
                let proximity = if distance < COIN_RADAR_NEAR {
                    2
                } else if distance < COIN_RADAR_MID {
                    1
                } else {
                    0
                };
                let mut radar = VarDictionary::new();
                radar.set("angle", view.x.atan2(-view.z));
                radar.set("span", 40.0_f32.to_radians());
                radar.set("tier", tier.index());
                radar.set("proximity", proximity);
                snapshot.set("coin_radar", &radar);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spread_spawn_maximizes_distance_to_the_nearest_giant() {
        let occupied = [Vector3::ZERO, Vector3::new(100.0, 0.0, 0.0)];
        let close_to_second = Vector3::new(95.0, 0.0, 0.0);
        let middle = Vector3::new(50.0, 0.0, 0.0);
        let alternative = Vector3::new(40.0, 0.0, 0.0);
        let candidates = [close_to_second, alternative, middle];
        assert_eq!(
            most_separated_spawn(candidates.into_iter(), &occupied, |_| true),
            Some((middle, 2500.0))
        );
        assert_eq!(
            most_separated_spawn(candidates.into_iter(), &occupied, |point| point != middle),
            Some((alternative, 1600.0))
        );
    }

    #[test]
    fn growth_bands_hold_at_the_meter_below_the_next_occupied_slot() {
        let bands = HeightBands::new(GrowthSettings::default()).unwrap();
        let scale = |height: f32| height / GIANT_START_HEIGHT;
        let limit = |height, others: &[f32]| {
            bands.growth_limit(scale(height), others.iter().copied().map(scale))
        };
        assert_eq!(limit(120.0, &[150.0]), scale(149.0));
        assert_eq!(limit(95.0, &[150.0, 120.0]), scale(99.0));
        assert_eq!(limit(149.0, &[200.0, 99.0]), scale(199.0));
        assert_eq!(limit(149.0, &[99.0]), f32::INFINITY);
        for height in [299.0, 249.0, 199.0, 149.0, 99.0] {
            assert_eq!(limit(height, &[height + 1.0]), scale(height));
        }
        assert_eq!(limit(199.0, &[300.0, 299.0, 149.0]), scale(249.0));
        let mut leader = 350.0;
        for height in [299.0, 249.0, 199.0, 149.0, 99.0] {
            assert!(limit(height, &[leader]) >= scale(height + 1.0));
            leader = height + 1.0;
        }
    }

    #[test]
    fn rival_reward_includes_the_equal_half_boundary_and_inherits_larger_size() {
        assert_eq!(rival_growth(60.0, 60.0, 80.0), 100.0);
        assert_eq!(rival_growth(60.0, 60.0, 120.0), 120.0);
        assert_eq!(rival_growth(60.0, 60.0, 140.0), 140.0);
        assert_eq!(rival_growth(72.0, 60.0, 80.0), 112.0);
    }

    #[test]
    fn weighted_respawn_gives_near_and_far_roads_proportional_chances() {
        let near = Vector3::new(10.0, 0.0, 0.0);
        let far = Vector3::new(20.0, 0.0, 0.0);
        let draw =
            |largest: &[Vector3], roll| choose_respawn([near, far].into_iter(), largest, roll);
        // Squared distances of 100 and 400 give the near road 20% of the probability.
        assert_eq!(draw(&[Vector3::ZERO], 0.19), Some(near));
        assert_eq!(draw(&[Vector3::ZERO], 0.21), Some(far));
        // With tied giants, the second road is close to one of them.
        assert_eq!(
            draw(&[Vector3::ZERO, Vector3::new(25.0, 0.0, 0.0)], 0.5),
            Some(near)
        );
        assert_eq!(draw(&[], 0.49), Some(near));
        assert_eq!(draw(&[], 0.51), Some(far));
        assert_eq!(choose_respawn(std::iter::empty(), &[], 0.5), None);
    }

    #[test]
    fn brawl_respawn_favors_similar_giants_but_can_draw_other_safe_points() {
        let similar = Vector3::new(-400.0, 0.0, 0.0);
        let larger = Vector3::new(400.0, 0.0, 0.0);
        let living = [
            BrawlSpawnRival {
                position: similar,
                search_range: 150.0,
                size_similarity: 1.0,
            },
            BrawlSpawnRival {
                position: larger,
                search_range: 150.0,
                size_similarity: 0.25,
            },
        ];
        let near_similar = similar + Vector3::BACK * 160.0;
        let near_larger = larger + Vector3::BACK * 160.0;
        let far = Vector3::new(0.0, 0.0, 500.0);
        let points = [near_similar, near_larger, far];
        let weight = |point| brawl_respawn_weight(point, Vector3::ZERO, &living);
        let mut picks = [0; 3];
        for sample in 0..1000 {
            let roll = (f64::from(sample) + 0.5) / 1000.0;
            let point = draw_weighted_spawn(points.into_iter(), weight, roll).unwrap();
            let index = points
                .iter()
                .position(|&candidate| candidate == point)
                .unwrap();
            picks[index] += 1;
        }
        assert!(picks[0] > 5 * picks[1] && picks[1] > picks[2] && picks[2] > 0);
    }

    #[test]
    fn rival_gap_is_symmetric_and_includes_the_configured_threshold() {
        assert!(ignores_rival(1.0, 10.0, 10.0));
        assert!(ignores_rival(10.0, 1.0, 10.0));
        assert!(ignores_rival(1.0, 3.0_f32.next_down(), 3.0));
        assert!(!ignores_rival(1.0, 2.999, 3.0));
        assert!(!ignores_rival(1.0, 9.9, 10.0));
        assert!(!ignores_rival(1.0, 10.0, 12.0));
    }

    #[test]
    fn mapwide_coin_grid_covers_the_full_playable_span() {
        let limit = 703.0;
        for count in [1, 4, 200, 1000] {
            let (side, origin, cell) = coin_grid_layout(count, limit);
            assert!(side * side >= count);
            assert_eq!(origin, -limit);
            assert!((origin + side as f32 * cell - limit).abs() < 1e-3);
        }
    }

    #[test]
    fn coin_giant_exclusion_stays_outside_pickup_reach_and_clearance() {
        for height in [0.01, 1.0, 25.2, 200.0] {
            let scale = height / GIANT_START_HEIGHT;
            let (preferred, pickup) = coin_giant_exclusion(scale, height);
            let body = GIANT_RADIUS * scale;
            assert!(pickup > body + MAP_COIN_RADIUS + coin_pickup_margin(height));
            assert!(preferred >= body + MAP_COIN_RADIUS + COIN_GIANT_CLEARANCE - 1e-4);
            assert!(preferred > pickup);
        }
    }

    #[test]
    fn coins_grade_by_giant_feet_activity_zones_and_hotspots() {
        let threats = [CoinThreat {
            at: Vector3::ZERO,
            footfall_reach: 25.0,
            zone: 120.0,
        }];
        // At the giant's feet: Extreme.
        assert_eq!(
            coin_threat_tier(Vector3::new(10.0, 0.0, 10.0), &threats, &[]),
            CoinTier::Extreme
        );
        // Inside its activity zone: at least High.
        assert_eq!(
            coin_threat_tier(Vector3::new(80.0, 0.0, 0.0), &threats, &[]),
            CoinTier::High
        );
        // Safe outskirts: Normal.
        assert_eq!(
            coin_threat_tier(Vector3::new(400.0, 0.0, 0.0), &threats, &[]),
            CoinTier::Normal
        );
        // Multi-way combat hotspots grade like a giant: core Extreme, rim High.
        let hotspots = [(Vector3::new(500.0, 0.0, 0.0), 60.0)];
        assert_eq!(
            coin_threat_tier(Vector3::new(525.0, 0.0, 0.0), &threats, &hotspots),
            CoinTier::Extreme
        );
        assert_eq!(
            coin_threat_tier(Vector3::new(550.0, 0.0, 0.0), &threats, &hotspots),
            CoinTier::High
        );
        assert_eq!(
            coin_threat_tier(Vector3::new(900.0, 0.0, 0.0), &threats, &hotspots),
            CoinTier::Normal
        );
    }

    #[test]
    fn dwell_bars_fill_by_tier_and_decay_slowly_instead_of_resetting() {
        // Normal coins and the giant stage stay instant.
        assert_eq!(CoinTier::Normal.dwell_seconds(), 0.0);
        assert!((CoinTier::High.dwell_seconds() - 2.0).abs() < 1e-6);
        // Extreme tier sits inside the required 3.5–4.0 s band.
        assert!(CoinTier::Extreme.dwell_seconds() >= 3.5);
        assert!(CoinTier::Extreme.dwell_seconds() <= 4.0);
        // Standing inside fills the bar frame by frame.
        assert!((advance_dwell(0.0, CoinTier::High, true, 0.25) - 0.25).abs() < 1e-6);
        let mut filled = 0.0;
        for _ in 0..40 {
            filled = advance_dwell(filled, CoinTier::Extreme, true, 0.1);
        }
        assert!(filled >= CoinTier::Extreme.dwell_seconds() && filled <= 4.5);
        // Leaving decays the full bar at ~27 %/s: never an instant reset.
        let half = CoinTier::High.dwell_seconds() * 0.5;
        let after = advance_dwell(half, CoinTier::High, false, 1.0);
        let lost = half - after;
        assert!(lost > 0.2 * CoinTier::High.dwell_seconds());
        assert!(lost < 0.35 * CoinTier::High.dwell_seconds());
        assert!(after > 0.0);
        // A long absence drains to exactly zero, never below.
        assert_eq!(advance_dwell(0.01, CoinTier::High, false, 10.0), 0.0);
    }

    #[test]
    fn coin_reward_multipliers_and_tier_ordering() {
        assert_eq!(CoinTier::Normal.value(), 1.0);
        assert_eq!(CoinTier::High.value(), 2.5);
        assert_eq!(CoinTier::Extreme.value(), 5.0);
        assert!(CoinTier::Normal < CoinTier::High);
        assert!(CoinTier::High < CoinTier::Extreme);
    }

    #[test]
    fn guarded_coins_attract_bold_foragers_and_scare_cautious_ones() {
        let bold = coin_forage_score(5.0, 0.5, 30.0, 3.75, 0.8, 0.9);
        let timid = coin_forage_score(5.0, 0.5, 30.0, 3.75, 0.8, 0.1);
        assert!(bold > timid, "risk appetite must raise guarded-coin utility");
        assert_eq!(timid, 0.0, "a cautious forager skips a guarded jackpot");
        for score in [bold, timid] {
            assert!((0.0..=100.0).contains(&score));
        }
        // Unthreatened coins scale with tier value, and threat always lowers
        // the score even for a bold collector.
        let extreme = coin_forage_score(5.0, 0.5, 30.0, 3.75, 0.0, 0.5);
        let normal = coin_forage_score(1.0, 0.5, 30.0, 0.0, 0.0, 0.5);
        assert!(extreme > normal);
        assert!(
            normal > coin_forage_score(1.0, 0.5, 30.0, 0.0, 0.8, 0.1),
            "threat lowers the utility of the same coin"
        );
        // Growth-hungry foragers prefer the same coin more than lazy ones.
        assert!(
            coin_forage_score(2.5, 0.9, 20.0, 2.0, 0.0, 0.5)
                > coin_forage_score(2.5, 0.1, 20.0, 2.0, 0.0, 0.5)
        );
    }

    #[test]
    fn evasion_and_demolition_utilities_stay_bounded_and_directional() {
        // Evasion rises with the size gap and a wounded body.
        assert!(
            threat_evasion_score(0.9, 0.8, 0.5) > threat_evasion_score(0.4, 0.2, 0.5)
        );
        // The will to survive dampens it.
        assert!(
            threat_evasion_score(0.9, 0.5, 1.0) >= threat_evasion_score(0.9, 0.5, 0.0)
        );
        for score in [
            threat_evasion_score(1.5, 1.5, 1.5),
            threat_evasion_score(-1.0, -1.0, -1.0),
        ] {
            assert!((0.0..=100.0).contains(&score));
        }
        // Demolition follows growth/destruction drive and building density.
        assert!(
            demolition_score(0.9, 0.9, 0.8) > demolition_score(0.2, 0.1, 0.1)
        );
        assert!((0.0..=100.0).contains(&demolition_score(1.0, 1.0, 1.0)));
    }
}
