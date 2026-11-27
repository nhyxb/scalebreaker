use std::collections::{HashMap, HashSet, VecDeque};
use std::f32::consts::{FRAC_PI_2, PI, TAU};
use std::time::Instant;

use godot::classes::{
    Camera3D, CapsuleShape3D, CharacterBody3D, CollisionShape3D, Input, InputEvent,
    InputEventMouseButton, InputEventMouseMotion, KinematicCollision3D, PackedScene,
    PhysicsDirectSpaceState3D, PhysicsRayQueryParameters3D, SphereShape3D, SpringArm3D,
    StaticBody3D,
};
use godot::prelude::*;

use crate::route::{self, Footprint};
use crate::rules::*;
use crate::settings::{GameSettings, GrowthSettings};

mod ai;
mod footfalls;
mod growth;
mod hands;
mod sit;
use ai::{
    CombatMemory, Intent, Personality, SizeTier, INTENT_INERTIA, UTILITY_INTERVAL,
    coin_forage_score, demolition_score, escape_direction, threat_evasion_score,
};
use footfalls::{Footfall, FootfallPreview, footfall_reach};
use growth::{CoinDwell, CoinField, DefeatMethod, GiantStrike, GrowthDefeat, Rival, ignores_rival};
use hands::{HandAttack, HandMove};
use sit::SitAction;

/// Third-person arm length and focus height as fractions of the live body height. The old
/// fixed 34 m arm with a 76 m cap and a 46 m focus cap left a 500 m giant's camera buried
/// inside its own legs; both now follow `height`.
const GIANT_CAMERA_LENGTH_RATIO: f32 = 1.30;
const GIANT_CAMERA_FOCUS_RATIO: f32 = 0.55;
const GROWTH_CAMERA_MIN_LENGTH: f32 = 0.12;
/// Mouse wheel zoom, multiplied into the arm length.
const CAMERA_ZOOM_MIN: f32 = 0.45;
const CAMERA_ZOOM_MAX: f32 = 3.0;
const CAMERA_ZOOM_STEP: f32 = 0.16;
const CAMERA_ZOOM_SMOOTHING: f32 = 12.0;
/// Below this fraction of the body height the camera is inside the mesh; the focus climbs
/// toward the chest so the view is never a screen full of thigh.
const CAMERA_NEAR_GUARD_RATIO: f32 = 0.20;
const CAMERA_NEAR_GUARD_FOCUS: f32 = 0.82;
/// Third-person "foot follow": camera out at 45° in front of the left shoe, looking back.
const FOOT_VIEW_YAW_OFFSET: f32 = 0.79;
const FOOT_VIEW_LENGTH_RATIO: f32 = 0.62;
const FOOT_VIEW_FOCUS_FORWARD: f32 = 0.24;
const FOOT_VIEW_FOCUS_LEFT: f32 = 0.16;
const FOOT_VIEW_FOCUS_HEIGHT: f32 = 0.05;
const FOOT_VIEW_PITCH: f32 = -0.22;
const FIRST_PERSON_MAX_SCALE: f32 = 1.0 / GIANT_START_HEIGHT;
/// Fallback eye height (fraction of the actor height) for rigs whose Head bone cannot be
/// read; giant_visual.gd::first_person_eye_position() owns the real placement.
const FIRST_PERSON_EYE_FRACTION: f32 = 0.90;
/// Eye offsets in front of / above the Head joint, mirrored by giant_visual.gd.
const FIRST_PERSON_EYE_FORWARD: f32 = 0.045;
/// First person may only look this far off the giant's shoulders (≈75°), so the back bow
/// and the fox tail can never swing into view behind the head.
const FIRST_PERSON_YAW_LIMIT: f32 = 1.31;
/// Below this the round stops asking the rig to turn at all; the in-place step turn has its
/// own wider 12.6° start deadzone, so the head can glance around without shuffling the feet.
const FIRST_PERSON_STEER_DEADZONE: f32 = 0.05;
/// Looking down in first person walks the eye forward so the view clears the hidden
/// neck instead of staring into the stump; scaled by the giant's height.
const FIRST_PERSON_LOOK_DOWN_PITCH: f32 = -0.35;
const FIRST_PERSON_LOOK_DOWN_LEAN: f32 = 0.105;
/// The evacuee can look up without swinging the spring arm through the street.
const EVAC_ARM_MAX_PITCH: f32 = 0.26;
const MOUSE_LOOK_SENSITIVITY: f32 = 0.0028;
const KEYBOARD_LOOK_SPEED: f32 = FRAC_PI_2;
const GROWTH_DURATION: f32 = 0.60;
const GROWTH_COOLDOWN: f32 = 1.0;
const SIGHT_RANGE: f32 = 150.0;
const TARGET_OCCLUSION_TIME: f32 = 2.0;
const SIGHT_MASK: u32 = 1 | 2 | BUILDING_LAYER | RUBBLE_LAYER;
const TARGET_CELL_SIZE: f32 = 36.0;
const NPC_DRAW_RANGE: f32 = 135.0;
const TOUCH_CRUSH_MARGIN: f32 = 0.14;
const SPECTATOR_MIN_HEIGHT: f32 = 0.04;
const DISTANT_SILHOUETTE_HEIGHT: f32 = 150.0;
const GIANT_MESH_BOUND_RATIO: f32 = 0.72;
/// Route plans allowed in one physics frame. With sixty AI actors the individual replan
/// timers can expire together; the queue spreads those searches over consecutive frames.
const PATH_PLANS_PER_FRAME: usize = 4;
/// Beyond this distance an AI giant updates its procedural skeleton on alternating frames
/// (or every third frame further out). The player and nearby actors keep a full-rate update.
const ANIMATION_FULL_DISTANCE: f32 = 120.0;
const ANIMATION_HALF_DISTANCE: f32 = 240.0;
const PATH_TIME_BUDGET: f32 = 0.0025;
/// How far a giant looks for rivals and people. The 150 m baseline suits small giants; a
/// giant hundreds of metres tall has to look about its own height away to spot a peer.
fn sight_range(scale: f32) -> f32 {
    SIGHT_RANGE.max(GIANT_START_HEIGHT * scale)
}

/// Whether a giant is large enough to ignore a human or pedestrian. Unlike the symmetric
/// rival rule, a taller human is never the ignored side.
fn ignores_human(giant_height: f32, human_height: f32, ratio: f32) -> bool {
    giant_height >= (human_height * ratio).next_down()
}

/// How far an AI giant will reach for a rival. Rival distance is measured between body
/// centres, and the collision capsule keeps two giants at least
/// `GIANT_RADIUS * (scale + rival_scale)` apart. The old flat 75 m cap therefore made any
/// pair taller than roughly 326 m each mutually invisible: they walked into each other
/// without ever fighting. Keep the cap at least one full body span plus the footfall reach.
fn rival_engage_range(reach: f32, speed: f32, scale: f32) -> f32 {
    (reach + speed * 2.5).clamp(10.0, 75.0_f32.max(2.0 * GIANT_RADIUS * scale + reach))
}

#[derive(Clone, Copy)]
struct ImpactArea {
    center: Vector3,
    yaw: f32,
    radii: Vector2,
}

impl ImpactArea {
    fn to_unit_circle(self, point: Vector3) -> Vector2 {
        let local = (point - self.center).rotated(Vector3::UP, -self.yaw);
        Vector2::new(local.x, local.z) / self.radii
    }

    fn contains(self, point: Vector3) -> bool {
        self.to_unit_circle(point).length_squared() <= 1.0
    }

    fn reaches(self, point: Vector3, radius: f32) -> bool {
        Self {
            radii: self.radii + Vector2::splat(radius),
            ..self
        }
        .contains(point)
    }

    fn touches(self, footprint: Footprint) -> bool {
        if footprint.touches(self.center, 0.0) {
            return true;
        }

        // In the ellipse's normalized space, each side of the footprint is a
        // line segment. It overlaps the ellipse when it comes within unit radius.
        let half = footprint.size * 0.5;
        let corners = [
            Vector3::new(-half.x, 0.0, -half.z),
            Vector3::new(half.x, 0.0, -half.z),
            Vector3::new(half.x, 0.0, half.z),
            Vector3::new(-half.x, 0.0, half.z),
        ]
        .map(|corner| self.to_unit_circle(footprint.transform * corner));
        (0..corners.len()).any(|index| {
            let start = corners[index];
            let edge = corners[(index + 1) % corners.len()] - start;
            let t = (-start.dot(edge) / edge.length_squared()).clamp(0.0, 1.0);
            (start + edge * t).length_squared() <= 1.0
        })
    }
}

#[derive(Clone)]
enum StrikeArea {
    Sole(Footfall),
    Ellipse(ImpactArea),
}

impl StrikeArea {
    fn reaches(&self, point: Vector3, radius: f32) -> bool {
        match self {
            Self::Sole(sole) => sole.reaches(point, radius),
            Self::Ellipse(area) => area.reaches(point, radius),
        }
    }

    fn touches(&self, footprint: Footprint) -> bool {
        match self {
            Self::Sole(sole) => sole.touches(footprint),
            Self::Ellipse(area) => area.touches(footprint),
        }
    }

    fn center(&self) -> Vector3 {
        match self {
            Self::Sole(sole) => sole.center,
            Self::Ellipse(area) => area.center,
        }
    }

    fn bounds(&self) -> f32 {
        match self {
            Self::Sole(sole) => sole.bounds(),
            Self::Ellipse(area) => area.radii.x.max(area.radii.y),
        }
    }
}

struct Growth {
    from: f32,
    to: f32,
    target: f32,
    elapsed: f32,
    counts_reward: bool,
}

struct Target {
    node: Gd<Node3D>,
    footprint: Footprint,
    integrity: Integrity,
    grabbed: bool,
}

struct Civilian {
    body: Gd<CharacterBody3D>,
    size: BodySize,
    /// Frame-start position used by the AI target scan.
    position: Vector3,
    direction: Vector3,
    turn_in: f32,
    speed: f32,
    remove_in: Option<f32>,
    grabbed: bool,
    health_fraction: f32,
    /// Three-state escape behavior (see update_civilians).
    state: CivilianState,
    /// How much longer panic keeps running after the last sensed threat.
    panic_left: f32,
    /// Cadence of the (cheap) threat sense, staggered per pedestrian.
    sense_in: f32,
    /// Where the current threat was last sensed (position, radius).
    threat: Option<(Vector3, f32)>,
    /// Cover point the shelter-seeking state walks toward.
    cover_goal: Option<Vector3>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum CivilianState {
    /// Daily stroll along the streets.
    Calm,
    /// Sprinting away from a nearby giant, collapse or warning circle.
    Panic,
    /// Walking to a sheltered corner away from the last threat.
    Cover,
}

impl CivilianState {
    fn key(self) -> &'static str {
        match self {
            Self::Calm => "calm",
            Self::Panic => "panic",
            Self::Cover => "cover",
        }
    }
}

#[derive(Clone, Copy)]
struct BodySize {
    height: f32,
    radius: f32,
}

impl BodySize {
    const STANDARD_HUMAN: Self = Self {
        height: HUMAN_HEIGHT,
        radius: HUMAN_RADIUS,
    };

    fn from_capsule(collision: &Gd<CollisionShape3D>) -> Self {
        let capsule = collision.get_shape().unwrap().cast::<CapsuleShape3D>();
        let scale = collision.get_global_transform().basis.get_scale().abs();
        Self {
            height: (capsule.get_height() * scale.y).max(0.001),
            radius: capsule.get_radius() * scale.x.max(scale.z),
        }
    }
}

impl Civilian {
    fn max_health(&self) -> f32 {
        1000.0 * (self.size.height / HUMAN_HEIGHT)
    }

    fn hurt(&mut self, damage: f32, instant_defeat: bool) {
        self.health_fraction = if instant_defeat {
            0.0
        } else {
            (self.health_fraction - damage / self.max_health()).max(0.0)
        };
        if self.health_fraction <= 0.0 {
            self.remove_in = Some(1.15);
            self.body.call("show_fall", &[]);
        }
    }
}

#[derive(Clone, Copy)]
enum GroundImpact {
    Footfall,
    Sit,
}

impl GroundImpact {
    fn strength_and_reach(self) -> (f32, f32) {
        match self {
            Self::Footfall => (1.20, 133.0),
            Self::Sit => (1.42, 160.0),
        }
    }

    fn shake(self, distance: f32, scale: f32) -> f32 {
        let (strength, reach) = self.strength_and_reach();
        let reach = reach * scale.sqrt().clamp(0.7, 2.2);
        strength * (1.0 - distance / reach).max(0.0).powi(2)
    }

    fn relative_shake(self, distance: f32, source_height: f32, viewer_height: f32) -> f32 {
        if source_height <= viewer_height {
            return 0.0;
        }
        let (strength, legacy_reach) = self.strength_and_reach();
        let reach = (2.5 + 8.0 * source_height).min(220.0) * (legacy_reach / 100.0);
        let height_gap = (source_height / viewer_height).log2();
        strength * (height_gap / (height_gap + 3.0)) * (1.0 - distance / reach).max(0.0).powi(2)
    }
}

struct CameraImpact {
    at: Vector3,
    kind: GroundImpact,
    giant: Option<(i32, f32)>,
}

#[derive(Default)]
struct CameraShake {
    strength: f32,
    elapsed: f32,
}

impl CameraShake {
    fn add_peak(&mut self, peak: f32, cutoff: f32) -> bool {
        if peak > self.strength && peak > cutoff {
            self.strength = peak;
            self.elapsed = 0.0;
            true
        } else {
            false
        }
    }

    fn decay(&mut self, dt: f32, attenuation: f32, cutoff: f32) {
        self.elapsed += dt;
        self.strength *= attenuation;
        if self.strength < cutoff {
            self.strength = 0.0;
        }
    }
}

struct GiantSight {
    space: Gd<PhysicsDirectSpaceState3D>,
    ray: Gd<PhysicsRayQueryParameters3D>,
}

impl GiantSight {
    fn new(giant: &Gd<CharacterBody3D>, scale: f32) -> Option<Self> {
        let space = giant.get_world_3d()?.get_direct_space_state()?;
        let eye = giant.get_global_position() + Vector3::UP * (22.5 * scale);
        let mut ray = PhysicsRayQueryParameters3D::new_gd();
        ray.set_from(eye);
        ray.set_collision_mask(SIGHT_MASK);
        ray.set_hit_from_inside(true);
        Some(Self { space, ray })
    }

    fn sees_at(&mut self, position: Vector3, height: f32) -> bool {
        [0.86, 0.31].into_iter().any(|fraction| {
            self.ray.set_to(position + Vector3::UP * height * fraction);
            self.space.intersect_ray(&self.ray).is_empty()
        })
    }
}

struct CombatTarget {
    body: Gd<CharacterBody3D>,
    /// Frame-start position so scanning every rival does not issue engine calls per pair.
    position: Vector3,
    size: BodySize,
    rival: Option<(f32, f32)>,
}

/// A route request waiting for one of the per-frame planning slots.
#[derive(Clone, Copy)]
struct PathRequest {
    serial: u64,
    from: Vector3,
    goal: Vector3,
    radius: f32,
    crush_buildings: bool,
}

/// One frame's physics-body snapshot shared by both pair passes. Reading positions, safe
/// margins and speeds from Godot once per pair cost thousands of engine calls per frame at
/// sixty actors; the passes now work from this snapshot instead.
#[derive(Clone, Copy)]
struct PairFrame {
    start: Vector3,
    end: Vector3,
    radius: f32,
    height: f32,
    safe_margin: f32,
    travel: f32,
    scale: f32,
    human: bool,
    health: f32,
    grabbed: bool,
}

#[derive(Default)]
struct TargetGrid {
    cells: HashMap<(i32, i32), Vec<usize>>,
    max_radius: f32,
}

impl TargetGrid {
    fn cell(point: Vector3) -> (i32, i32) {
        (
            (point.x / TARGET_CELL_SIZE).floor() as i32,
            (point.z / TARGET_CELL_SIZE).floor() as i32,
        )
    }

    fn insert(&mut self, index: usize, footprint: Footprint) {
        let half = footprint.size * 0.5;
        self.max_radius = self.max_radius.max(half.x.hypot(half.z));
        self.cells
            .entry(Self::cell(footprint.transform.origin))
            .or_default()
            .push(index);
    }

    fn near(&self, point: Vector3, radius: f32) -> impl Iterator<Item = usize> + '_ {
        let pad = Vector3::splat(radius + self.max_radius);
        let (min_x, min_z) = Self::cell(point - pad);
        let (max_x, max_z) = Self::cell(point + pad);
        let count =
            (max_x as i64 - min_x as i64 + 1).saturating_mul(max_z as i64 - min_z as i64 + 1);
        let cells: Box<dyn Iterator<Item = &Vec<usize>>> = if count > self.cells.len() as i64 {
            Box::new(self.cells.iter().filter_map(move |(&(x, z), indices)| {
                ((min_x..=max_x).contains(&x) && (min_z..=max_z).contains(&z)).then_some(indices)
            }))
        } else {
            Box::new(
                (min_x..=max_x).flat_map(move |x| {
                    (min_z..=max_z).filter_map(move |z| self.cells.get(&(x, z)))
                }),
            )
        };
        cells.flatten().copied()
    }
}

struct Giant {
    body: Gd<CharacterBody3D>,
    index: i32,
    model_scale: Vector3,
    scale: f32,
    /// Before the demolition height a growth actor wears the human model and can only bump
    /// smaller humans. Once it reaches the threshold it becomes a giant for the rest of the round.
    human: bool,
    yaw_velocity: f32,
    footfall: Option<FootfallPreview>,
    last_footfall: Option<Footfall>,
    footfall_count: u32,
    hand_attack: Option<HandAttack>,
    pending_hand: Option<HandMove>,
    grabbed: bool,
    progress: GiantProgress,
    growth: Option<Growth>,
    growth_rewards: VecDeque<f32>,
    growth_limit: f32,
    growth_in: f32,
    rubble_passes: Vec<(Footprint, Gd<StaticBody3D>)>,
    chase_target: Option<InstanceId>,
    chase_hidden_for: f32,
    roam_goal: Option<Vector3>,
    path: Vec<Vector3>,
    /// Serial of the route request that is allowed to replace `path` (0 means none).
    pending_path: u64,
    replan_in: f32,
    blocking_target: Option<usize>,
    building_target: Option<usize>,
    standing_pivot_active: bool,
    was_walking: bool,
    health_fraction: f32,
    silhouette_opacity: u8,
    beyond_regular_clip: bool,
    detail_tier: u8,
    respawn_in: f32,
    match_kills: u32,
    fixed_walk_tempo: bool,
    walk_remainder: Vector3,
    /// Active sit-crush / idle-sit action (see round/sit.rs).
    sit: Option<SitAction>,
    /// Cooldown before the next sit-crush trigger.
    sit_in: f32,
    /// Giant index currently sitting on this actor (immobile + damage over time).
    pinned_by: Option<i32>,
    pin_tick: f32,
    /// Frames to skip before the next procedural skeleton update, and the time accumulated
    /// while those frames pass.
    visual_wait: u8,
    visual_dt: f32,
    /// Utility-AI brain (see round/ai.rs): rolled once, kept across respawns.
    personality: Personality,
    /// Intent the utility scorer last picked; re-scored every ~0.25 s.
    intent: Intent,
    intent_in: f32,
    /// Relative-size tier versus the currently tracked enemy, kept with ±10 %
    /// boundary hysteresis so edge ratios do not flicker between behaviors.
    size_tier: Option<(InstanceId, SizeTier)>,
    /// 360° escape bookkeeping: chosen heading, start point and how long it has
    /// made no progress (blacklists the heading when stuck against a wall).
    escape_yaw: Option<f32>,
    escape_origin: Vector3,
    escape_elapsed: f32,
    /// Short-term combat memory with TTL-decayed rows (see round/ai.rs).
    memory: CombatMemory,
    /// Throttle for recording danger zones during prolonged danger exposure.
    danger_note_in: f32,
    /// Human-stage dwell bar for risk-tiered coins (see round/growth.rs).
    coin_dwell: Option<CoinDwell>,
}

enum AnimateStep {
    None,
    HumanFootfall,
    GiantFootfall(Footfall),
}

impl Giant {
    fn new(
        mut body: Gd<CharacterBody3D>,
        index: i32,
        settings: GameSettings,
        scale: f32,
        growth: bool,
    ) -> Self {
        body.set("pace", &settings.giant_speed.to_variant());
        body.set("human_pace", &settings.human_speed.to_variant());
        body.set("size_scaled_walk", &growth.to_variant());
        if growth {
            // Never inherit platform velocity from a giant teleporting on respawn.
            body.set_platform_floor_layers(0);
        }
        let model_scale = body.get_node_as::<Node3D>("Model").get_scale();
        let mut giant = Self::new_life(body, index, model_scale);
        if scale != 1.0 {
            giant.resize(scale, settings.giant_max_height);
        }
        giant
    }

    fn new_life(body: Gd<CharacterBody3D>, index: i32, model_scale: Vector3) -> Self {
        Self {
            body,
            index,
            model_scale,
            scale: 1.0,
            human: false,
            yaw_velocity: 0.0,
            footfall: None,
            last_footfall: None,
            footfall_count: 0,
            hand_attack: None,
            pending_hand: None,
            grabbed: false,
            progress: GiantProgress::default(),
            growth: None,
            growth_rewards: VecDeque::new(),
            growth_limit: f32::INFINITY,
            growth_in: 0.0,
            rubble_passes: Vec::new(),
            chase_target: None,
            chase_hidden_for: 0.0,
            roam_goal: None,
            path: Vec::new(),
            pending_path: 0,
            replan_in: 0.0,
            blocking_target: None,
            building_target: None,
            standing_pivot_active: false,
            was_walking: false,
            health_fraction: 1.0,
            silhouette_opacity: 0,
            beyond_regular_clip: false,
            detail_tier: 0,
            respawn_in: 0.0,
            match_kills: 0,
            fixed_walk_tempo: false,
            walk_remainder: Vector3::ZERO,
            sit: None,
            sit_in: 0.0,
            pinned_by: None,
            pin_tick: 0.0,
            visual_wait: 0,
            visual_dt: 0.0,
            personality: Personality::roll(),
            intent: Intent::default(),
            intent_in: 0.0,
            size_tier: None,
            escape_yaw: None,
            escape_origin: Vector3::ZERO,
            escape_elapsed: 0.0,
            memory: CombatMemory::default(),
            danger_note_in: 0.0,
            coin_dwell: None,
        }
    }

    fn respawn(&mut self, spawn: Vector3, starting_scale: f32, max_height: f32) {
        for (_, rubble) in self.rubble_passes.drain(..) {
            self.body.remove_collision_exception_with(&rubble);
        }
        let mut body = self.body.clone();
        body.set_global_position(spawn);
        body.set_velocity(Vector3::ZERO);
        body.set_rotation(Vector3::ZERO);
        body.set_collision_layer(4);
        body.set_collision_mask(31);
        body.call("show_respawn", &[]);
        let kills = self.match_kills;
        // The personality survives death: the same character keeps its traits.
        let personality = self.personality;
        *self = Self::new_life(body, self.index, self.model_scale);
        self.match_kills = kills;
        self.personality = personality;
        self.resize(starting_scale, max_height);
    }

    fn height(&self, max_height: f32) -> f32 {
        if self.scale == max_height / GIANT_START_HEIGHT {
            max_height
        } else {
            GIANT_START_HEIGHT * self.scale
        }
    }

    /// Debug/test key of the current utility intent.
    fn intent_key(&self) -> &'static str {
        match self.intent {
            Intent::Evade => "evade",
            Intent::Attack => "attack",
            Intent::Forage => "forage",
            Intent::Search => "search",
            Intent::Demolish => "demolish",
        }
    }

    /// Drops the followed route and any request that would rebuild it. Movement that no
    /// longer needs a route calls this so a deferred plan cannot restore a stale path.
    fn clear_path(&mut self) {
        self.path.clear();
        self.pending_path = 0;
    }

    fn resize(&mut self, scale: f32, max_height: f32) {
        self.scale = scale;
        let height = self.height(max_height);
        let mut collision = self.body.get_node_as::<CollisionShape3D>("Collision");
        let mut capsule = collision.get_shape().unwrap().cast::<CapsuleShape3D>();
        if self.human {
            if let Some(mut model) = self
                .body
                .get_node_or_null("HumanModel")
                .and_then(|node| node.try_cast::<Node3D>().ok())
            {
                model.set_scale(Vector3::splat(height / HUMAN_HEIGHT));
            }
            capsule.set_radius(HUMAN_RADIUS * (height / HUMAN_HEIGHT));
            capsule.set_height(height);
        } else {
            let mut model = self.body.get_node_as::<Node3D>("Model");
            model.set_scale(self.model_scale * scale);
            if height >= capsule.get_height() {
                capsule.set_height(height);
                capsule.set_radius(GIANT_RADIUS * scale);
            } else {
                capsule.set_radius(GIANT_RADIUS * scale);
                capsule.set_height(height);
            }
        }
        collision.set_position(Vector3::UP * (height * 0.5));
        self.body
            .set_safe_margin((height * 0.01).clamp(0.00004, 0.001));
        self.body.set_floor_snap_length(0.4 * height.min(1.0));
    }

    /// Switch between the small human stage and the giant stage. A giant never shrinks back into
    /// the human stage during a round; only a respawn or a height-band limit can do that.
    fn set_stage(&mut self, human: bool, max_height: f32) {
        if self.human == human {
            return;
        }
        self.human = human;
        self.footfall = None;
        self.hand_attack = None;
        self.pending_hand = None;
        self.standing_pivot_active = false;
        self.was_walking = false;
        self.sit = None;
        self.pinned_by = None;
        self.pin_tick = 0.0;
        self.detail_tier = 0;
        self.body.call("set_stage", &[human.to_variant()]);
        self.resize(self.scale, max_height);
    }

    fn animate(
        &mut self,
        speed: f32,
        dt: f32,
        stride: u8,
        turn_target: f32,
        allow_standing_turn: bool,
        backward: bool,
        blocked: bool,
    ) -> AnimateStep {
        self.visual_wait = self.visual_wait.saturating_sub(1);
        if stride <= 1 {
            // Coming back into full-detail range should not wait for a pending skip.
            self.visual_wait = 0;
        }
        // The visual script clamps its own delta, so keep the accumulated step inside it.
        self.visual_dt = (self.visual_dt + dt).min(0.05);
        if self.visual_wait > 0 {
            return AnimateStep::None;
        }
        let delta = std::mem::take(&mut self.visual_dt);
        self.visual_wait = stride.max(1) - 1;
        let contact = if self.human {
            self.body.call(
                "show_motion",
                &[speed.to_variant(), (-1.0_f32).to_variant(), delta.to_variant()],
            )
        } else {
            self.body.call(
                "show_motion",
                &[
                    speed.to_variant(),
                    (-1.0_f32).to_variant(),
                    delta.to_variant(),
                    turn_target.to_variant(),
                    allow_standing_turn.to_variant(),
                    backward.to_variant(),
                    blocked.to_variant(),
                ],
            )
        };
        if self.human {
            return if contact.try_to::<bool>().unwrap_or(false) {
                AnimateStep::HumanFootfall
            } else {
                AnimateStep::None
            };
        }
        self.footfall = FootfallPreview::from_script(self.body.call("heavy_step_preview", &[]));
        let landed = contact.try_to::<VarDictionary>().ok()
            .and_then(|contact| Footfall::from_script(&contact));
        if let Some(sole) = landed {
            AnimateStep::GiantFootfall(sole)
        } else {
            AnimateStep::None
        }
    }

    fn advance_growth(&mut self, dt: f32, starting_scale: f32, max_height: f32, growth_mode: bool) {
        self.growth_in = (self.growth_in - dt).max(0.0);
        let max_scale = max_height / GIANT_START_HEIGHT;
        if self.growth.is_none() && self.scale < max_scale && self.growth_in == 0.0 {
            let target = if growth_mode {
                self.growth_rewards.pop_front()
            } else if self.progress.growth_count < self.progress.destroyed {
                Some(self.progress.next_scale(starting_scale, max_scale))
            } else {
                None
            };
            let Some(target) = target else { return };
            self.growth = Some(Growth {
                from: self.scale,
                to: target.min(self.growth_limit),
                target,
                elapsed: 0.0,
                counts_reward: true,
            });
            self.growth_in = if growth_mode { 0.40 } else { GROWTH_COOLDOWN };
            return;
        }
        let Some(growth) = self.growth.as_mut() else {
            return;
        };
        let permitted = growth.target.min(self.growth_limit).max(self.scale);
        if growth.to != permitted {
            growth.from = self.scale;
            growth.to = permitted;
            growth.elapsed = 0.0;
        }
        if growth.from == growth.to {
            return;
        }
        growth.elapsed += dt;
        let duration = if growth_mode { 0.34 } else { GROWTH_DURATION };
        let t = (growth.elapsed / duration).min(1.0);
        let target = growth.to;
        if t == 1.0 {
            if target == growth.target {
                self.progress.growth_count += u32::from(growth.counts_reward);
                self.growth = None;
            } else {
                growth.from = target;
            }
            self.resize(target, max_height);
        } else {
            let eased = t * t * (3.0 - 2.0 * t);
            let scale = growth.from + (target - growth.from) * eased;
            self.resize(scale, max_height);
        }
    }

    fn queue_growth(&mut self, max_height: f32, reward: impl FnOnce(f32) -> f32) {
        let base = self
            .growth_rewards
            .back()
            .copied()
            .or_else(|| self.growth.as_ref().map(|growth| growth.target))
            .unwrap_or(self.scale);
        let target = reward(base).min(max_height / GIANT_START_HEIGHT);
        if target > base {
            self.growth_rewards.push_back(target);
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum PlayerRole {
    Evacuee,
    Giant,
    Spectator,
    HumanObserver,
}

#[derive(GodotClass)]
#[class(base=Node3D)]
pub struct HarborRound {
    base: Base<Node3D>,
    pub mode: Mode,
    pub player: PlayerRole,
    pub settings: GameSettings,
    human: Option<Gd<CharacterBody3D>>,
    giants: Vec<Giant>,
    giant_names: Vec<GString>,
    #[export]
    giant_scene: Option<Gd<PackedScene>>,
    max_height: f32,
    orbit: Option<Gd<Node3D>>,
    camera: Option<Gd<Camera3D>>,
    regular_camera_far: f32,
    effects: Option<Gd<Node3D>>,
    state: RoundState,
    targets: Vec<Target>,
    target_grid: TargetGrid,
    total_buildings: usize,
    destroyed_buildings: u32,
    building_clock: f64,
    building_respawns: Vec<(usize, f64)>,
    world_limit: f32,
    spawn_points: Vec<Vector3>,
    #[export]
    npc_scene: Option<Gd<PackedScene>>,
    civilians: Vec<Civilian>,
    npc_spawn_in: f32,
    npc_limit: usize,
    exit: Vector3,
    exit_radius: f32,
    yaw: f32,
    pitch: f32,
    first_person: bool,
    /// Third of the three view modes: full third person, diagonal foot follow, first person.
    foot_view: bool,
    /// Initial mode chosen by `prefers_first_person()`; `V` cycles from there.
    manual_view: Option<u8>,
    camera_zoom: f32,
    camera_zoom_target: f32,
    /// User yaw parked while the foot-follow view drives the camera.
    foot_view_yaw: Option<f32>,
    touch_axes: Vector2,
    touch_sprint: bool,
    touch_stand: bool,
    touch_sit: bool,
    touch_hand: Option<HandMove>,
    camera_focus_offset: Vector3,
    nearby_shake: CameraShake,
    own_shake: CameraShake,
    camera_impacts: Vec<CameraImpact>,
    starting_scale: f32,
    strike: u64,
    growth_rules: Option<GrowthSettings>,
    coins: CoinField,
    rivals: Vec<Rival>,
    giant_collision_passes: HashSet<(usize, usize)>,
    bump_contacts: HashSet<(usize, usize)>,
    path_requests: Vec<Option<PathRequest>>,
    path_cursor: usize,
    path_serial: u64,
    evacuee_position: Option<Vector3>,
    frame_observer: Vector3,
    giant_strikes: Vec<GiantStrike>,
    growth_defeats: VecDeque<GrowthDefeat>,
    player_giant_hits: u32,
    /// Combat hotspots (position, radius, ttl) fed by footfalls/sits/demolitions;
    /// they grade map coins up and fade after ~12 s.
    hotspots: Vec<(Vector3, f32, f32)>,
    /// Cadence of the live coin re-grading pass.
    coin_regrade_in: f32,
    /// Cooldown of the player's rising dwell audio tick.
    dwell_tick_in: f32,
    /// Whether the ground dwell ring is currently shown (avoids per-frame
    /// GDScript hide calls when nothing changed).
    dwell_ring_visible: bool,
    /// Active tabletop desk-hazard warning circles `(id, center, radius)`
    /// pushed by `scenes/desk_hazards.gd`. Fed into AI evasion and civilian
    /// panic without ever registering hazards as targetable/attackable giants.
    hazard_warnings: Vec<(i32, Vector3, f32)>,
}

#[godot_api]
impl INode3D for HarborRound {
    fn init(base: Base<Node3D>) -> Self {
        Self {
            base,
            mode: Mode::Human,
            player: PlayerRole::Evacuee,
            settings: GameSettings::default(),
            human: None,
            giants: Vec::new(),
            giant_names: Vec::new(),
            giant_scene: None,
            max_height: GIANT_DEFAULT_MAX_HEIGHT,
            orbit: None,
            camera: None,
            regular_camera_far: 0.0,
            effects: None,
            state: RoundState::default(),
            targets: Vec::new(),
            target_grid: TargetGrid::default(),
            total_buildings: 0,
            destroyed_buildings: 0,
            building_clock: 0.0,
            building_respawns: Vec::new(),
            world_limit: 0.0,
            spawn_points: Vec::new(),
            npc_scene: None,
            civilians: Vec::new(),
            npc_spawn_in: 0.0,
            npc_limit: 10,
            exit: Vector3::ZERO,
            exit_radius: EXIT_RADIUS,
            yaw: 0.0,
            pitch: -0.2,
            first_person: false,
            foot_view: false,
            manual_view: None,
            camera_zoom: 1.0,
            camera_zoom_target: 1.0,
            foot_view_yaw: None,
            touch_axes: Vector2::ZERO,
            touch_sprint: false,
            touch_stand: false,
            touch_sit: false,
            touch_hand: None,
            camera_focus_offset: Vector3::ZERO,
            nearby_shake: CameraShake::default(),
            own_shake: CameraShake::default(),
            camera_impacts: Vec::new(),
            starting_scale: 1.0,
            strike: 0,
            growth_rules: None,
            coins: CoinField::default(),
            rivals: Vec::new(),
            giant_collision_passes: HashSet::new(),
            bump_contacts: HashSet::new(),
            path_requests: Vec::new(),
            path_cursor: 0,
            path_serial: 0,
            evacuee_position: None,
            frame_observer: Vector3::ZERO,
            giant_strikes: Vec::new(),
            growth_defeats: VecDeque::new(),
            player_giant_hits: 0,
            hotspots: Vec::new(),
            coin_regrade_in: 0.0,
            dwell_tick_in: 0.0,
            dwell_ring_visible: false,
            hazard_warnings: Vec::new(),
        }
    }

    fn ready(&mut self) {
        self.growth_rules = self.mode.has_growth().then_some(self.settings.growth);
        let mut giant = self.base().get_node_as::<CharacterBody3D>("Giant");
        let mut human = self.base().get_node_as::<CharacterBody3D>("Human");
        if matches!(self.player, PlayerRole::Giant | PlayerRole::Spectator) {
            // The unused scene actor starts at the central crossing until it is freed.
            human.set_collision_layer(0);
            human.queue_free();
        } else {
            human.set("pace", &self.settings.human_speed.to_variant());
        }
        let district = self.base().get_node_as::<Node3D>("District");
        let giant_spawn = self.base().get_node_as::<Node3D>("District/GiantSpawn");
        let exit = self.base().get_node_as::<Node3D>("District/Evacuation");
        let mut arm = self.base().get_node_as::<SpringArm3D>("Orbit/Arm");
        let mut camera = self.base().get_node_as::<Camera3D>("Orbit/Arm/Camera");
        let mut effects = self.base().get_node_as::<Node3D>("Effects");
        self.orbit = Some(self.base().get_node_as::<Node3D>("Orbit"));
        self.exit = exit.get_global_position();
        // On very small maps, preserve space between the central street and the exit.
        let exit_from_center = horizontal(self.exit - district.get_global_position()).length();
        self.exit_radius = EXIT_RADIUS.min(exit_from_center * 0.5);
        self.targets = self
            .base()
            .get_node_as::<Node3D>("District/Targets")
            .get_children()
            .iter_shared()
            .map(|node| {
                let node = node.cast::<Node3D>();
                let footprint = Footprint {
                    transform: node.get_global_transform(),
                    size: node.get("footprint").to::<Vector3>(),
                    building: node.get("kind").to::<GString>() == GString::from("building"),
                };
                Target {
                    node,
                    footprint,
                    grabbed: false,
                    integrity: if self.growth_rules.is_some() {
                        Integrity::with_health(if footprint.building {
                            GROWTH_BUILDING_INTEGRITY
                        } else {
                            6000.0
                        })
                    } else {
                        Integrity::default()
                    },
                }
            })
            .collect();

        for (index, target) in self.targets.iter().enumerate() {
            self.target_grid.insert(index, target.footprint);
            self.total_buildings += usize::from(target.footprint.building);
        }
        self.world_limit = district.get("play_edge").to::<f32>();
        self.spawn_points = district
            .get("spawn_points")
            .to::<PackedVector3Array>()
            .as_slice()
            .iter()
            .map(|point| district.to_global(*point))
            .filter(|point| {
                self.target_grid
                    .near(*point, 1.2)
                    .all(|index| !self.targets[index].footprint.touches(*point, 1.2))
            })
            .collect();
        self.starting_scale = self.settings.giant_height / GIANT_START_HEIGHT;
        self.max_height = self.settings.giant_max_height;
        let nominal = giant_spawn.get_global_position();
        let (giant_start, scale) = if self.growth_rules.is_some() {
            self.initial_growth_spawn()
                .unwrap_or((nominal, self.starting_scale))
        } else {
            (
                self.giant_spawn_position(nominal, 0.0).unwrap_or(nominal),
                self.starting_scale,
            )
        };
        giant.set_global_position(giant_start);
        self.giants.push(Giant::new(
            giant,
            0,
            self.settings,
            scale,
            self.growth_rules.is_some(),
        ));
        self.sync_actor_stage(0);
        if let Some(scene) = self.giant_scene.clone() {
            let mut others = self.base().get_node_as::<Node3D>("OtherGiants");
            for index in 1..self.settings.giant_count {
                let spawn = if self.growth_rules.is_some() {
                    self.initial_growth_spawn()
                } else {
                    let preferred = (self.world_limit * 0.75).min(85.0);
                    let spacing = (2.0 * GIANT_RADIUS * self.starting_scale + 8.0).max(preferred);
                    self.giant_spawn_position(giant_start, spacing)
                        .map(|spawn| (spawn, self.starting_scale))
                };
                let Some((spawn, scale)) = spawn else {
                    break;
                };
                let mut body = scene.instantiate_as::<CharacterBody3D>();
                body.set_name(format!("Giant{}", index + 1).as_str());
                body.set_position(others.to_local(spawn));
                others.add_child(&body);
                self.giants.push(Giant::new(
                    body,
                    index as i32,
                    self.settings,
                    scale,
                    self.growth_rules.is_some(),
                ));
                self.sync_actor_stage(index);
            }
        }
        self.path_requests.resize(self.giants.len(), None);
        if self.player == PlayerRole::Giant {
            self.yaw = 0.0;
            self.pitch = self.starting_giant_camera_pitch(scale);
            let arm_length = self.giant_arm_length(GIANT_START_HEIGHT * scale);
            arm.set_length(arm_length);
            let boundary = self.base().get_node_as::<StaticBody3D>("District/Boundary");
            arm.add_excluded_object(boundary.get_rid());
            camera.set_position(Vector3::BACK * arm_length);
        } else if self.player == PlayerRole::Spectator {
            let mut orbit = self.orbit.as_ref().unwrap().clone();
            let height = GIANT_START_HEIGHT * scale;
            let distance = (height * 1.15).clamp(0.12, 155.0);
            let inward = horizontal(-giant_start)
                .try_normalized()
                .unwrap_or(Vector3::BACK);
            let focus = giant_start + Vector3::UP * height * 0.5;
            orbit.set_global_position(focus + (inward + Vector3::UP * 0.42) * distance);
            self.yaw = inward.x.atan2(inward.z);
            self.pitch = -0.42_f32.atan();
            camera
                .reparent_ex(&orbit)
                .keep_global_transform(false)
                .done();
            camera.set_position(Vector3::ZERO);
            camera.set_near((orbit.get_global_position().y * 0.025).clamp(0.05, 0.09));
        } else {
            let is_observer = self.player == PlayerRole::HumanObserver;
            let safe_spawn = |point: Vector3| {
                self.clear_of_giants(point, 12.0)
                    && (is_observer
                        || horizontal(point - self.exit).length_squared()
                            > (self.exit_radius + 3.0).powi(2))
            };
            let spawn = is_observer
                .then(|| self.human_observer_spawn(giant_start, GIANT_START_HEIGHT * scale))
                .flatten()
                .or_else(|| {
                    self.random_spawn(giant_start, 28.0, f32::INFINITY)
                        .filter(|&point| safe_spawn(point))
                })
                .or_else(|| self.find_civilian_spawn(safe_spawn))
                .unwrap_or_else(|| {
                    district
                        .get_node_as::<Node3D>("HumanSpawn")
                        .get_global_position()
                });
            if is_observer {
                human.set_collision_layer(0);
                human.set_collision_mask(SIGHT_MASK);
                self.yaw = (spawn.x - giant_start.x).atan2(spawn.z - giant_start.z);
            } else {
                self.yaw = -FRAC_PI_2;
                effects.call(
                    "show_exit",
                    &[self.exit.to_variant(), self.exit_radius.to_variant()],
                );
            }
            human.set_global_position(spawn);
            human.set_rotation(Vector3::UP * self.yaw);
            camera.set_h_offset(0.34);
            self.human = Some(human);
        }
        self.effects = Some(effects);
        self.camera = Some(camera.clone());
        if self.growth_rules.is_some() {
            self.assign_giant_names();
            if self.player == PlayerRole::Giant {
                let mut probe = SphereShape3D::new_gd();
                probe.set_radius(0.28);
                arm.set_shape(&probe);
                self.update_giant_camera_scale(&self.giants[0].body.clone(), scale);
            }
        }
        self.apply_camera_distance(scale);
        let human_start = self.human.as_ref().map(|human| human.get_global_position());
        self.npc_limit = (self.settings.npc_initial + 4).max(10);
        // Growth and Brawl populate the map with the named combatants only.
        if self.growth_rules.is_none() {
            for index in 0..self.settings.npc_initial {
                let anchor = if index % 2 == 0 {
                    giant_start
                } else {
                    human_start.unwrap_or(giant_start)
                };
                self.spawn_civilian(anchor, true);
            }
            self.npc_spawn_in = self.next_npc_spawn();
        }
        self.follow_camera(0.0);
        camera.make_current();
        self.update_distant_silhouettes();
    }

    fn process(&mut self, _delta: f64) {
        self.update_distant_silhouettes();
    }

    fn unhandled_input(&mut self, event: Gd<InputEvent>) {
        if self.state.outcome != Outcome::Active {
            return;
        }
        if self.player == PlayerRole::Giant && event.is_action_pressed("toggle_view") {
            self.toggle_view();
            self.base().get_viewport().unwrap().set_input_as_handled();
            return;
        }
        // Mouse wheel pulls the third-person camera in and out (no-op in first person).
        if self.player == PlayerRole::Giant
            && let Ok(button) = event.clone().try_cast::<InputEventMouseButton>()
            && button.is_pressed()
        {
            // 4 / 5 are Godot's wheel up / wheel down button indices.
            match button.get("button_index").try_to::<i64>().unwrap_or(0) {
                4 => self.zoom_by(1.0),
                5 => self.zoom_by(-1.0),
                _ => return,
            }
            self.base().get_viewport().unwrap().set_input_as_handled();
            return;
        }
        if !cfg!(target_os = "android")
            && let Ok(mouse) = event.clone().try_cast::<InputEventMouseMotion>()
            && mouse.get_device() != InputEvent::DEVICE_ID_EMULATION
        {
            self.look(mouse.get_screen_relative());
        }
    }

    fn physics_process(&mut self, delta: f64) {
        let dt = delta as f32;
        let input = Input::singleton();
        let view_axes = input.get_vector("look_left", "look_right", "look_up", "look_down");
        if view_axes != Vector2::ZERO && self.state.outcome == Outcome::Active {
            self.rotate_view(view_axes * (KEYBOARD_LOOK_SPEED * dt));
        }
        let keys = input.get_vector("move_left", "move_right", "move_forward", "move_back");
        let axes = (keys + self.touch_axes).limit_length(Some(1.0));
        let stand_pressed = std::mem::take(&mut self.touch_stand)
            || std::mem::take(&mut self.touch_sit)
            || input.is_action_just_pressed("stand_up");
        let hand_pressed = self.touch_hand.take().or_else(|| {
            if input.is_action_just_pressed("grab_crush") {
                Some(HandMove::GrabCrush)
            } else if input.is_action_just_pressed("punch") {
                Some(HandMove::Punch)
            } else {
                None
            }
        });
        let camera_forward = Vector3::FORWARD.rotated(Vector3::UP, self.yaw);
        let direction = Vector3::new(axes.x, 0.0, axes.y).rotated(Vector3::UP, self.yaw);
        // Pure backpedal (S / rear stick cone) keeps facing forward; diagonal S+A/S+D
        // turns forward along a curved arc like any other off-heading directional input.
        let backward_input = self.player == PlayerRole::Giant
            && direction.length_squared() > 0.0001
            && axes.y > 0.25
            && direction.normalized_or_zero().dot(camera_forward) < -0.84;
        if self.state.outcome == Outcome::Active {
            if self.player == PlayerRole::Spectator {
                self.move_spectator(axes, dt);
            }
            self.update_giant_respawns(dt);
            self.process_path_requests();
            self.update_civilians(dt);
            if self.growth_rules.is_some() {
                self.update_building_respawns(delta);
            }
            if self.mode == Mode::Growth {
                self.update_coin_wave(dt);
            }
            self.advance_giant_growth(dt);
            for giant in &mut self.giants {
                giant.memory.tick(dt);
            }
            self.hotspots.retain_mut(|(_, _, left)| {
                *left -= dt;
                *left > 0.0
            });
            self.rivals.clear();
            self.rivals.extend(
                self.giants
                    .iter()
                    .filter(|giant| giant.health_fraction > 0.0 && !giant.grabbed)
                    .map(Rival::from_giant),
            );
            if let Some(mut human) = self.human.clone() {
                let moving = direction.length_squared() > 0.0001;
                let sprint = self.touch_sprint || input.is_action_pressed("sprint");
                let evacuation = self.player == PlayerRole::Evacuee;
                let was_exhausted = self.state.is_exhausted();
                let sprinting = if evacuation {
                    self.state.sprint(moving, sprint, dt)
                } else {
                    moving && sprint
                };
                if evacuation && !was_exhausted && self.state.is_exhausted() {
                    self.play_audio_2d("stamina_empty", -5.0, 1.0, 0.04);
                }
                let speed = (if sprinting { HUMAN_SPRINT } else { HUMAN_WALK })
                    * self.settings.human_speed;
                drive(&mut human, direction, speed, dt, 13.0);
                let actual_speed = ground_speed(&human);
                let footfall = human
                    .call(
                        "show_motion",
                        &[actual_speed.to_variant(), sprinting.to_variant()],
                    )
                    .try_to::<bool>()
                    .unwrap_or(false);
                if footfall
                    && let Some(mut audio) = self.audio()
                {
                    audio.call(
                        "play_human_step",
                        &[
                            human.get_global_position().to_variant(),
                            sprinting.to_variant(),
                            HUMAN_HEIGHT.to_variant(),
                            true.to_variant(),
                        ],
                    );
                }
                if evacuation {
                    let position = human.get_global_position();
                    self.state
                        .check_exit(horizontal(position - self.exit).length(), self.exit_radius);
                }
            }
            self.evacuee_position = self
                .evacuating_human()
                .map(|body| body.get_global_position());
        }
        self.frame_observer = self.observer_position();
        let mut frames = self.capture_pair_frames(dt);
        self.update_giant_collision_passes(&frames);
        let mut giants = std::mem::take(&mut self.giants);
        for index in 0..giants.len() {
            let actor = &mut giants[index];
            if actor.health_fraction <= 0.0 || actor.grabbed {
                continue;
            }
            if actor.hand_attack.is_some() && self.state.outcome == Outcome::Active {
                let start = actor.body.get_global_position();
                drive_giant(
                    &mut actor.body,
                    &mut actor.yaw_velocity,
                    Vector3::ZERO,
                    Vector3::ZERO,
                    dt,
                    actor.scale,
                    self.settings.giant_speed,
                    actor.human,
                );
                if self.growth_rules.is_some() {
                    self.check_growth_contacts(actor, start, dt);
                }
                continue;
            }
            let player = actor.index == 0 && self.player == PlayerRole::Giant;
            self.update_giant(
                actor,
                player,
                direction,
                player && backward_input,
                hand_pressed,
                stand_pressed,
                dt,
            );
            self.apply_giant_strikes(&mut giants);
        }
        self.update_hand_attacks(&mut giants, dt);
        sync_pair_frames(&mut frames, &giants);
        self.apply_human_bumps(&mut giants, &frames);
        self.giants = giants;
        self.update_pins(dt);
        self.flush_camera_impacts();
        if self.state.outcome == Outcome::Active {
            self.follow_camera(dt);
        }
        self.update_camera_shake(dt);
        self.update_health_bars();
    }
}

#[godot_api]
impl HarborRound {
    #[func]
    fn set_touch_motion(&mut self, axes: Vector2, sprint: bool) {
        self.touch_axes = axes;
        self.touch_sprint = sprint;
    }

    #[func]
    fn tap_stand_up(&mut self) {
        self.touch_stand = true;
    }

    #[func]
    fn tap_sit_down(&mut self) {
        self.touch_sit = true;
    }

    #[func]
    fn tap_grab_crush(&mut self) {
        self.touch_hand = Some(HandMove::GrabCrush);
    }

    #[func]
    fn tap_punch(&mut self) {
        self.touch_hand = Some(HandMove::Punch);
    }

    #[func]
    pub fn clear_touch(&mut self) {
        self.set_touch_motion(Vector2::ZERO, false);
        self.touch_stand = false;
        self.touch_sit = false;
        self.touch_hand = None;
    }

    #[func]
    fn toggle_view(&mut self) {
        if self.state.outcome != Outcome::Active || self.player != PlayerRole::Giant {
            return;
        }
        // 0: third person full body, 1: third person diagonal foot follow, 2: first person.
        let next = (self.view_mode() + 1) % 3;
        self.manual_view = Some(next);
        let giant = &self.giants[0];
        self.update_giant_camera_scale(&giant.body.clone(), giant.scale);
        self.follow_camera(0.0);
        self.play_audio_2d("view_toggle", -5.0, 1.0, 0.03);
    }

    #[func]
    fn look(&mut self, motion: Vector2) {
        if self.state.outcome != Outcome::Active {
            return;
        }
        self.rotate_view(motion * MOUSE_LOOK_SENSITIVITY);
        self.follow_camera(0.0);
    }

    fn rotate_view(&mut self, angles: Vector2) {
        self.yaw = (self.yaw - angles.x).rem_euclid(TAU);
        let (bottom, top) = if self.first_person || self.player == PlayerRole::Spectator {
            (-1.45, 1.45)
        } else if matches!(self.player, PlayerRole::Evacuee | PlayerRole::HumanObserver) {
            (-1.15, 1.45)
        } else {
            (-1.15, 0.26)
        };
        self.pitch = (self.pitch - angles.y).clamp(bottom, top);
        self.clamp_first_person_view();
    }

    /// First person is not a free-look camera: the head turns at most ±75° off the
    /// shoulders, so the back bow and the tail stay out of view however far the mouse goes.
    fn clamp_first_person_view(&mut self) {
        if !self.first_person || self.player != PlayerRole::Giant {
            return;
        }
        let Some(giant) = self.giants.first() else {
            return;
        };
        let body_yaw = giant.body.get_rotation().y;
        let offset = godot::global::angle_difference(body_yaw as f64, self.yaw as f64) as f32;
        let clamped = offset.clamp(-FIRST_PERSON_YAW_LIMIT, FIRST_PERSON_YAW_LIMIT);
        if clamped != offset {
            self.yaw = (body_yaw + clamped).rem_euclid(TAU);
        }
    }

    fn update_giant(
        &mut self,
        actor: &mut Giant,
        player: bool,
        direction: Vector3,
        backward_input: bool,
        hand_pressed: Option<HandMove>,
        stand_pressed: bool,
        dt: f32,
    ) {
        if self.state.outcome != Outcome::Active {
            actor.animate(0.0, dt, 1, f32::NAN, false, false, false);
            actor.footfall = None;
            return;
        }
        let mut giant = actor.body.clone();
        actor.sit_in = (actor.sit_in - dt).max(0.0);
        let can_demolish = self.can_demolish(actor);
        let can_crush = self.can_crush_buildings(actor);
        {
            let current_mask = giant.get_collision_mask();
            // Once touch-crush is unlocked, ignore building colliders completely so footsteps
            // pass straight through instead of snagging on facades.
            let mut new_mask = if can_crush {
                current_mask & !BUILDING_LAYER
            } else {
                current_mask | BUILDING_LAYER
            };
            if self.growth_rules.is_some() {
                new_mask = if can_crush {
                    new_mask & !RUBBLE_LAYER
                } else {
                    new_mask | RUBBLE_LAYER
                };
            }
            if new_mask != current_mask {
                giant.set_collision_mask(new_mask);
            }
        }

        // Sitting (or being sat on) owns the whole body: no input, no AI, no other attack.
        if actor.sit.is_some() || self.maybe_start_sit(actor, player, stand_pressed, dt) {
            actor.was_walking = false;
            actor.standing_pivot_active = false;
            actor.footfall = None;
            actor.pending_hand = None;
            self.drive_sit(actor, dt, player && stand_pressed);
            drive_giant(
                &mut giant,
                &mut actor.yaw_velocity,
                Vector3::ZERO,
                Vector3::ZERO,
                dt,
                actor.scale,
                1.0,
                actor.human,
            );
            return;
        }
        // Pinned by a bigger giant's sit-crush: stay put and eat the damage ticks.
        if actor.pinned_by.is_some() {
            actor.was_walking = false;
            actor.standing_pivot_active = false;
            actor.footfall = None;
            actor.pending_hand = None;
            drive_giant(
                &mut giant,
                &mut actor.yaw_velocity,
                Vector3::ZERO,
                Vector3::ZERO,
                dt,
                actor.scale,
                1.0,
                actor.human,
            );
            actor.animate(0.0, dt, 1, f32::NAN, false, false, false);
            actor.footfall = None;
            return;
        }
        let mut giant_direction = direction;
        let giant_speed = self.giant_speed(actor, player);
        let fixed_walk_tempo = !can_demolish;
        if actor.fixed_walk_tempo != fixed_walk_tempo {
            actor.fixed_walk_tempo = fixed_walk_tempo;
            giant.set("fixed_walk_tempo", &fixed_walk_tempo.to_variant());
        }
        let mut ai_hold_for_scenery: Option<Vector3> = None;
        if !player {
            giant_direction = self.pursue(actor, giant_speed, dt);
            if self.ai_attacks_scenery(actor)
                && !can_crush
                && actor.intent != Intent::Evade
                && actor.chase_target.is_none()
                && let Some(scenery_idx) = actor.blocking_target.or(actor.building_target)
                && self.targets[scenery_idx].footprint.building
                && self.targets[scenery_idx].integrity.blocks()
                && !self.targets[scenery_idx].grabbed
            {
                let pos = giant.get_global_position();
                let height = actor.height(self.max_height);
                let target_fp = self.targets[scenery_idx].footprint;
                let surface = closest_surface_point(target_fp, pos);
                let dist = horizontal(surface - pos).length();
                let to_surface = horizontal(surface - pos).normalized_or_zero();
                let hand_range = if target_fp.size.y * 0.93 >= height * 0.27 {
                    height * 0.34
                } else if height + 0.05 >= 3.0 * target_fp.size.y {
                    height * 0.25
                } else {
                    0.0
                };
                let sit_range = actor.sit_radius() * 1.05;
                let engage_range = hand_range
                    .max(sit_range)
                    .max(GIANT_RADIUS * actor.scale + 0.45 * actor.scale);
                if dist <= engage_range && to_surface.length_squared() > 0.0001 {
                    if self.start_ai_scenery_hand_move(actor, scenery_idx) {
                        actor.standing_pivot_active = false;
                        actor.was_walking = false;
                        return;
                    }
                    let forward = Vector3::FORWARD.rotated(Vector3::UP, giant.get_rotation().y);
                    let aligned_for_hand = forward.dot(to_surface) >= 0.78;
                    if !aligned_for_hand && hand_range > 0.0 && dist <= hand_range && Self::ready_for_hand_move(actor) {
                        ai_hold_for_scenery = Some(to_surface);
                    } else if actor.sit_in <= 0.0
                        && dist <= sit_range
                        && self.maybe_start_ai_building_sit(actor, surface)
                    {
                        actor.standing_pivot_active = false;
                        actor.was_walking = false;
                        actor.footfall = None;
                        actor.pending_hand = None;
                        self.drive_sit(actor, dt, false);
                        return;
                    } else if dist <= GIANT_RADIUS * actor.scale + 0.35 * actor.scale
                        || actor.blocking_target.is_some()
                        || (!Self::ready_for_hand_move(actor) && dist <= hand_range.max(sit_range))
                    {
                        // Stand ready facing the facade while a swing finishes or before punching,
                        // rather than grinding pelvis/legs into an indestructible wall.
                        ai_hold_for_scenery = Some(to_surface);
                    }
                }
            }
        } else if actor.human {
            // Humans have no active attacks; smaller humans can take a body check.
            actor.pending_hand = None;
        } else {
            let floored = giant.is_on_floor();
            actor.pending_hand = hand_pressed.or(actor.pending_hand.filter(|_| floored));
            if let Some(kind) = actor.pending_hand {
                actor.standing_pivot_active = false;
                if Self::ready_for_hand_move(actor) {
                    actor.pending_hand = None;
                    if self.start_player_hand_move(actor, kind) {
                        actor.was_walking = false;
                        return;
                    }
                } else {
                    giant_direction = Vector3::ZERO;
                }
            }
        }

        if actor.hand_attack.is_some() {
            actor.standing_pivot_active = false;
            actor.was_walking = false;
            return;
        }
        // First-person steering: turning the view turns the body. Both stay inside the same
        // ±75° cone, so camera and shoulders never fight over the rotation, and a locked
        // hand action keeps its facing.
        let steer_view = player
            && self.first_person
            && self.settings.first_person_steer
            && !actor.human
            && actor.pending_hand.is_none();
        let input_yaw = if giant_direction.length_squared() > 0.0001 {
            Some((-giant_direction.x).atan2(-giant_direction.z))
        } else {
            None
        };
        // Walking already steers the shoulders through the same ±75° cone as the head.
        let steer_dir = input_yaw.map(|wanted| {
            let offset = godot::global::angle_difference(self.yaw as f64, wanted as f64) as f32;
            let want_yaw = self.yaw + offset.clamp(-FIRST_PERSON_YAW_LIMIT, FIRST_PERSON_YAW_LIMIT);
            Vector3::FORWARD.rotated(Vector3::UP, want_yaw)
        });
        let steer_dir = if steer_view && steer_dir.is_some() {
            steer_dir
        } else {
            None
        };
        // Standing still: the in-place step turn owns the body, so it never slides on planted
        // feet. Small head turns under the deadzone leave the body alone.
        let steer_yaw = if steer_view && input_yaw.is_none() {
            let offset =
                godot::global::angle_difference(giant.get_rotation().y as f64, self.yaw as f64)
                    .abs() as f32;
            if offset > FIRST_PERSON_STEER_DEADZONE {
                Some(self.yaw)
            } else {
                None
            }
        } else {
            None
        };
        let camera_fwd = Vector3::FORWARD.rotated(Vector3::UP, self.yaw);
        let backpedal = player
            && !actor.human
            && backward_input
            && actor.pending_hand.is_none()
            && ai_hold_for_scenery.is_none();
        if ai_hold_for_scenery.is_some() {
            giant_direction = Vector3::ZERO;
        }
        let steer_idle_dir = steer_yaw.map(|yaw| Vector3::FORWARD.rotated(Vector3::UP, yaw));
        let turn_intent = if backpedal {
            camera_fwd
        } else {
            ai_hold_for_scenery
                .or(steer_dir)
                .or(steer_idle_dir)
                .unwrap_or(giant_direction)
        };
        actor.standing_pivot_active = false;
        let move_dir = giant_direction;
        let turn_dir = turn_intent;
        let drive_turn_dir = if !actor.human
            && turn_dir.length_squared() > 0.0001
        {
            let raw_yaw = (-turn_dir.x).atan2(-turn_dir.z);
            let allowed_yaw = giant
                .call("stance_turn_target", &[raw_yaw.to_variant()])
                .try_to::<f32>()
                .unwrap_or(raw_yaw);
            Vector3::FORWARD.rotated(Vector3::UP, allowed_yaw)
        } else {
            turn_dir
        };
        let carry_vel = if !actor.human
            && move_dir.length_squared() <= 0.0001
            && actor.pending_hand.is_none()
        {
            giant
                .call("stop_carry_velocity", &[dt.to_variant()])
                .try_to::<Vector3>()
                .unwrap_or(Vector3::ZERO)
        } else {
            Vector3::ZERO
        };
        let desired_velocity = if move_dir.length_squared() > 0.0001 {
            if !actor.human {
                let body_forward = Vector3::FORWARD.rotated(Vector3::UP, giant.get_rotation().y);
                if backpedal {
                    let back_dir = move_dir.normalized_or_zero();
                    let align = body_forward.dot(-back_dir).clamp(0.0, 1.0);
                    let turn_speed_mult = 0.55 + 0.45 * align;
                    back_dir * (giant_speed * GIANT_BACKWARD_MULT * turn_speed_mult)
                } else {
                    // Always launch immediately along body forward so off-heading inputs curve
                    // smoothly along a car-like arc instead of freezing to spin in place.
                    let align = body_forward.dot(move_dir.normalized_or_zero()).clamp(-1.0, 1.0);
                    let turn_speed_mult = if align >= 0.0 {
                        0.62 + 0.38 * align
                    } else {
                        0.48 + 0.14 * (1.0 + align)
                    };
                    body_forward * (giant_speed * turn_speed_mult)
                }
            } else {
                move_dir * giant_speed
            }
        } else {
            carry_vel
        };
        let giant_position = giant.get_global_position();
        let mut vel_xz = desired_velocity;
        let micro_steps = self.growth_rules.is_some() && giant_speed < 0.05;
        if micro_steps && desired_velocity != Vector3::ZERO {
            // Keep travel below physics/world precision for the next tick instead of losing it.
            let requested = desired_velocity * dt + actor.walk_remainder;
            let step = horizontal((giant_position + requested) - giant_position);
            if step.length_squared() >= 0.00002_f32.powi(2) {
                actor.walk_remainder = requested - step;
                vel_xz = step / dt;
            } else {
                actor.walk_remainder = requested;
                vel_xz = Vector3::ZERO;
            }
        } else {
            actor.walk_remainder = Vector3::ZERO;
        }
        actor.rubble_passes.retain(|(footprint, rubble)| {
            let near = footprint.touches(giant_position, GIANT_RADIUS * actor.scale + 3.0);
            if !near {
                giant.remove_collision_exception_with(rubble);
            }
            near
        });
        let turn_pace = if actor.human {
            // Human turning also ignores the giant speed option.
            1.0
        } else {
            self.settings.giant_speed
        };
        drive_giant(
            &mut giant,
            &mut actor.yaw_velocity,
            vel_xz,
            drive_turn_dir,
            dt,
            actor.scale,
            turn_pace,
            actor.human,
        );
        if micro_steps && vel_xz != Vector3::ZERO {
            // Recover rounding loss from the physics move without accumulating blocked travel.
            let travelled = horizontal(giant.get_global_position() - giant_position);
            let lost = vel_xz * dt - travelled;
            let rounding =
                2.0 * f32::EPSILON * giant_position.x.abs().max(giant_position.z.abs()).max(1.0);
            if !giant.is_on_wall() && lost.length_squared() <= rounding.powi(2) {
                actor.walk_remainder += lost;
            }
        }
        let requested_travel = vel_xz.length() * dt;
        let actual_travel = horizontal(giant.get_global_position() - giant_position).length();
        actor.was_walking = move_dir.length_squared() > 0.0001
            && (requested_travel <= f32::EPSILON || actual_travel > requested_travel * 0.35);
        if can_crush && (move_dir.length_squared() > 0.0001 || actual_travel > 0.002) {
            self.crush_touched_buildings(actor, giant.get_global_position());
        }
        if self.growth_rules.is_some() {
            self.check_growth_contacts(actor, giant_position, dt);
            if actor.health_fraction <= 0.0 {
                return;
            }
        }
        let ai_attacks_scenery = !player && self.ai_attacks_scenery(actor);
        if !player && !ai_attacks_scenery {
            if actor.chase_target.is_none() && giant.is_on_wall() {
                let forward = Vector3::FORWARD.rotated(Vector3::UP, giant.get_rotation().y);
                let heading_into_wall = actor.roam_goal.is_none_or(|goal| {
                    let to_goal = horizontal(goal - giant.get_global_position()).normalized_or_zero();
                    forward.dot(to_goal) > 0.35
                });
                if heading_into_wall {
                    actor.roam_goal = None;
                    actor.clear_path();
                }
            }
        } else if ai_attacks_scenery && actor.blocking_target.is_none() {
            actor.blocking_target = (0..giant.get_slide_collision_count())
                .filter_map(|index| giant.get_slide_collision(index))
                .filter_map(|collision| collision.get_collider())
                .filter_map(|collider| {
                    collider
                        .try_cast::<Node3D>()
                        .ok()?
                        .get_parent()?
                        .try_cast::<Node3D>()
                        .ok()
                })
                .find_map(|parent| {
                    self.target_grid
                        .near(parent.get_global_position(), 0.0)
                        .find(|&index| {
                            let target = &self.targets[index];
                            target.integrity.blocks()
                                && (!can_crush || !target.footprint.building)
                                && target.node.instance_id() == parent.instance_id()
                        })
                });
        }
        // Giant step timing also drives damage and must advance every physics frame.
        let visual_stride = if actor.human { self.animation_stride(actor, giant_position) } else { 1 };
        let actual_ground = ground_speed(&giant);
        let travel_dir = desired_velocity.normalized_or_zero();
        let req_len = desired_velocity.length();
        let actual_vel = horizontal(giant.get_velocity());
        let wall_opposing = giant.is_on_wall()
            && (0..giant.get_slide_collision_count())
                .filter_map(|index| giant.get_slide_collision(index))
                .any(|collision| horizontal(collision.get_normal()).dot(travel_dir) < -0.25);
        let progress = actual_vel.dot(travel_dir);
        let blocked = !actor.human
            && move_dir.length_squared() > 0.0001
            && giant.is_on_wall()
            && (actual_ground < req_len * 0.42
                || progress < req_len * 0.38
                || (wall_opposing && progress < req_len * 0.65));
        let speed = if move_dir.length_squared() > 0.0001 {
            if micro_steps && !giant.is_on_wall() {
                req_len
            } else {
                actual_ground
            }
        } else {
            0.0
        };
        let (turn_target, allow_standing_turn) = if move_dir.length_squared() > 0.0001 {
            ((-turn_intent.x).atan2(-turn_intent.z), false)
        } else if !actor.human
            && carry_vel.length_squared() <= 0.0001
            && actor.pending_hand.is_none()
        {
            if let Some(aim) = ai_hold_for_scenery {
                ((-aim.x).atan2(-aim.z), false)
            } else if let Some(view_yaw) = steer_yaw {
                (view_yaw, false)
            } else {
                (f32::NAN, false)
            }
        } else {
            (f32::NAN, false)
        };
        match actor.animate(
            speed,
            dt,
            visual_stride,
            turn_target,
            allow_standing_turn,
            backpedal,
            blocked,
        ) {
            AnimateStep::GiantFootfall(footfall) => self.resolve_footfall(actor, footfall),
            AnimateStep::HumanFootfall => {
                if let Some(mut audio) = self.audio() {
                    audio.call(
                        "play_human_step",
                        &[
                            actor.body.get_global_position().to_variant(),
                            false.to_variant(),
                            actor.height(self.max_height).to_variant(),
                            player.to_variant(),
                        ],
                    );
                }
            }
            AnimateStep::None => {}
        }
    }

    #[func]
    fn configure(&mut self, giant: bool) {
        (self.mode, self.player) = if giant {
            (Mode::Sandbox, PlayerRole::Giant)
        } else {
            (Mode::Human, PlayerRole::Evacuee)
        };
    }

    pub fn apply_settings(&mut self, settings: GameSettings) {
        let change_spawn = settings.npc_respawn != self.settings.npc_respawn
            || settings.npc_interval != self.settings.npc_interval;
        let change_distance = settings.view_distance != self.settings.view_distance;
        self.settings = settings;
        if change_spawn {
            self.npc_spawn_in = self.next_npc_spawn();
        }
        if change_distance {
            self.apply_camera_distance(self.giants[0].scale);
            self.update_distant_silhouettes();
        }
        for giant in &mut self.giants {
            giant.body.set("pace", &settings.giant_speed.to_variant());
            giant.body.set("human_pace", &settings.human_speed.to_variant());
        }
        if let Some(human) = &mut self.human {
            human.set("pace", &settings.human_speed.to_variant());
        }
        if settings.shake_strength == 0.0 {
            self.reset_camera_shake();
        } else if !settings.own_camera_shake && self.own_shake.strength > 0.0 {
            self.own_shake = CameraShake::default();
            self.apply_camera_shake();
        }
    }

    /// Test-only helper: force a giant's body size so pair-state regressions can be
    /// reproduced without depending on random spawn heights.
    #[func]
    fn debug_resize_giant(&mut self, index: i32, height: f32) {
        let ceiling = (self.max_height / GIANT_START_HEIGHT).max(0.0001);
        let scale = (height / GIANT_START_HEIGHT).clamp(0.0001, ceiling);
        let Some(actor) = self.giants.iter_mut().find(|giant| giant.index == index) else {
            return;
        };
        actor.health_fraction = 1.0;
        actor.growth_limit = ceiling;
        actor.resize(scale, self.max_height);
    }

    #[func]
    fn growth_leaderboard(&self) -> Array<VarDictionary> {
        self.rank_growth_giants()
    }

    #[func]
    fn growth_actors(&self) -> Array<VarDictionary> {
        self.actor_debug()
    }

    /// Test/debug view of the live coin field: tier, dwell requirement and
    /// ground position of every coin in the wave.
    #[func]
    fn coin_debug(&self) -> Array<VarDictionary> {
        self.coin_debug_entries()
    }

    /// Test/debug view of the civilian crowd states (calm/panic/cover).
    #[func]
    fn civilian_debug(&self) -> Array<VarDictionary> {
        let mut entries = Array::new();
        for npc in &self.civilians {
            let mut entry = VarDictionary::new();
            entry.set("state", npc.state.key());
            entry.set("position", npc.body.get_global_position());
            entries.push(&entry);
        }
        entries
    }

    /// Whether periodic/manual tabletop desk hazards are allowed in this round.
    /// Legacy Human Evacuation mode never triggers desk hazards regardless of setting.
    #[func]
    fn desk_hazards_enabled(&self) -> bool {
        self.mode != Mode::Human && self.settings.desk_hazards
    }

    #[func]
    fn mode_key(&self) -> GString {
        self.mode.key().into()
    }

    #[func]
    fn world_play_edge(&self) -> f32 {
        self.world_limit
    }

    /// Register or update a desk-hazard warning circle so Phase 4 AI (human & giant)
    /// and civilians immediately flee outside the strike zone without registering the
    /// hazard as an attackable giant/rival.
    #[func]
    fn set_hazard_warning(&mut self, id: i32, center: Vector3, radius: f32) {
        let clean_center = Vector3::new(center.x, 0.0, center.z);
        let clean_radius = radius.max(1.0);
        if let Some(slot) = self.hazard_warnings.iter_mut().find(|entry| entry.0 == id) {
            slot.1 = clean_center;
            slot.2 = clean_radius;
        } else {
            self.hazard_warnings.push((id, clean_center, clean_radius));
        }
        self.note_hotspot(clean_center, clean_radius * 1.15);
    }

    #[func]
    fn clear_hazard_warning(&mut self, id: i32) {
        self.hazard_warnings.retain(|entry| entry.0 != id);
    }

    #[func]
    fn hazard_warning_count(&self) -> i32 {
        self.hazard_warnings.len() as i32
    }

    /// Pick a city block with intact buildings or active actors for a desk hazard.
    #[func]
    fn pick_hazard_target(&self) -> Vector3 {
        let margin = (self.world_limit - 32.0).max(0.0);
        let anchor = self.observer_position();
        let mut preferred: Vec<Vector3> = Vec::new();
        let mut fallback: Vec<Vector3> = Vec::new();
        for target in &self.targets {
            if !target.footprint.building || target.grabbed || !target.integrity.blocks() {
                continue;
            }
            let pos = target.footprint.transform.origin;
            let flat = Vector3::new(pos.x, 0.0, pos.z);
            if margin > 0.0 && (flat.x.abs() > margin || flat.z.abs() > margin) {
                continue;
            }
            let dist = horizontal(flat - anchor).length();
            if (40.0..=360.0).contains(&dist) {
                preferred.push(flat);
            } else {
                fallback.push(flat);
            }
        }
        let pool = if !preferred.is_empty() {
            &preferred
        } else if !fallback.is_empty() {
            &fallback
        } else {
            // All buildings gone or tiny map: aim near an active actor if any exist.
            let mut actors: Vec<Vector3> = self
                .giants
                .iter()
                .filter(|giant| giant.health_fraction > 0.0 && !giant.grabbed)
                .map(|giant| {
                    let p = giant.body.get_global_position();
                    Vector3::new(p.x, 0.0, p.z)
                })
                .collect();
            if actors.is_empty() {
                return Vector3::ZERO;
            }
            let pick = (random_range(0.0, actors.len() as f64).floor() as usize)
                .min(actors.len() - 1);
            return actors.swap_remove(pick);
        };
        let pick = (random_range(0.0, pool.len() as f64).floor() as usize).min(pool.len() - 1);
        pool[pick]
    }

    /// Batch-resolve a tabletop desk-hazard impact (unattackable external force):
    /// collapses all intact buildings within `radius`, applies heavy crush damage &
    /// outward knockback to units inside the radius, refreshes hotspots, and triggers
    /// global camera shake obeying `shake_strength`.
    #[func]
    fn apply_desk_hazard_impact(
        &mut self,
        center: Vector3,
        radius: f32,
        damage_fraction: f32,
        knockback_speed: f32,
    ) -> VarDictionary {
        let impact_center = Vector3::new(center.x, 0.0, center.z);
        let impact_radius = radius.max(1.0);
        let area = ImpactArea {
            center: impact_center,
            yaw: 0.0,
            radii: Vector2::splat(impact_radius),
        };
        self.note_hotspot(impact_center, impact_radius * 1.4);

        // 1. Batch-destroy intact buildings inside the strike radius using the existing
        //    3-state MultiMesh collapse & rubble pipeline.
        self.strike += 1;
        let rebuild_at = self.building_rebuild_time();
        let mut buildings_destroyed: i32 = 0;
        let candidate_indices: Vec<usize> = self
            .target_grid
            .near(impact_center, impact_radius)
            .collect();
        for index in candidate_indices {
            let target = &mut self.targets[index];
            if target.grabbed || !target.integrity.blocks() || !area.touches(target.footprint) {
                continue;
            }
            if target.integrity.hit(self.strike, f32::MAX, true) == Damage::Destroyed {
                let rebuild = rebuild_at.filter(|_| target.footprint.building);
                target.node.call(
                    "strike",
                    &[
                        true.to_variant(),
                        Variant::nil(),
                        rebuild.is_some().to_variant(),
                    ],
                );
                if target.footprint.building {
                    if let Some(deadline) = rebuild {
                        self.building_respawns.push((index, deadline));
                    }
                    self.destroyed_buildings += 1;
                    buildings_destroyed += 1;
                }
            }
        }
        if buildings_destroyed > 0 {
            for giant in &mut self.giants {
                giant.replan_in = 0.0;
            }
        }

        // 2. Heavy crush damage + outward knockback on living actors in range.
        //    Foreground hazards are never added to `giants` / `rivals`.
        let growth = self.growth_rules.is_some();
        let mut giants_hit: i32 = 0;
        let mut giants_defeated: i32 = 0;
        let mut giants = std::mem::take(&mut self.giants);
        let world_cap = (self.world_limit - 2.0).max(1.0);
        for actor in &mut giants {
            if actor.health_fraction <= 0.0 || actor.grabbed {
                continue;
            }
            let pos = actor.body.get_global_position();
            let offset = horizontal(pos - impact_center);
            let dist = offset.length();
            let actor_r = self.actor_radius(actor);
            let reach = impact_radius + actor_r;
            if dist > reach {
                continue;
            }
            giants_hit += 1;
            let falloff = desk_hazard_falloff(dist, reach);
            let out_dir = if dist > 0.05 {
                offset / dist
            } else {
                let angle = actor.index as f32 * 2.399_963_2;
                Vector3::new(angle.cos(), 0.0, angle.sin())
            };
            let is_player_victim = actor.index == 0 && self.player == PlayerRole::Giant;
            let victim_height = actor.height(self.max_height);
            actor.body.call("show_hit", &[]);
            actor.memory.note_danger(impact_center, impact_radius * 1.25);
            if let Some(mut audio) = self.audio() {
                audio.call(
                    "play_combat_hit",
                    &[
                        false.to_variant(),
                        is_player_victim.to_variant(),
                        pos.to_variant(),
                        victim_height.to_variant(),
                    ],
                );
            }
            let defeated = if growth {
                let frac = desk_hazard_damage_fraction(dist, reach, damage_fraction);
                let max_hp = self.growth_stat(actor, self.combat_rules().base_health);
                self.hurt_giant(actor, max_hp * frac)
            } else {
                false
            };
            if defeated {
                giants_defeated += 1;
                self.record_growth_defeat(None, actor.index, DefeatMethod::FingerPoke);
                if let Some(mut audio) = self.audio() {
                    audio.call(
                        "play_defeat",
                        &[
                            false.to_variant(),
                            is_player_victim.to_variant(),
                            pos.to_variant(),
                            victim_height.to_variant(),
                        ],
                    );
                }
            } else {
                // Knock surviving giant radially outward and slightly airborne so it clears the fingertip.
                let push_speed = knockback_speed.max(0.0) * (0.55 + 0.45 * falloff);
                let nudge = (reach - dist + 8.0).clamp(6.0, 28.0) * (0.45 + 0.55 * falloff);
                let pushed = pos + out_dir * nudge;
                let clamped = Vector3::new(
                    pushed.x.clamp(-world_cap, world_cap),
                    pos.y + (3.0 + 6.0 * falloff),
                    pushed.z.clamp(-world_cap, world_cap),
                );
                actor.body.set_global_position(clamped);
                actor
                    .body
                    .set_velocity(out_dir * push_speed + Vector3::UP * (8.0 + 10.0 * falloff));
            }
        }
        self.giants = giants;

        // 3. Crush / scatter civilians in range (Sandbox mode).
        let mut civilians_hit: i32 = 0;
        for npc in &mut self.civilians {
            if npc.remove_in.is_some() || npc.grabbed {
                continue;
            }
            let point = npc.body.get_global_position();
            if area.reaches(point, npc.size.radius) {
                civilians_hit += 1;
                npc.hurt(1000.0, true);
            }
        }

        // 4. Strong island-wide camera shake obeying `settings.shake_strength`.
        if self.player != PlayerRole::Spectator && self.settings.shake_strength > 0.0 {
            let observer = self.observer_position();
            let dist = horizontal(observer - impact_center).length();
            let raw_peak = desk_hazard_camera_shake(dist, impact_radius);
            let scaled = raw_peak * self.settings.shake_strength;
            let cutoff = self.shake_cutoff();
            if self.nearby_shake.add_peak(scaled, cutoff)
                && let Some(mut audio) = self.audio()
            {
                audio.call(
                    "play_camera_shake",
                    &[scaled.to_variant(), 600.0_f32.to_variant()],
                );
            }
            self.apply_camera_shake();
        }

        let mut summary = VarDictionary::new();
        summary.set("buildings_destroyed", buildings_destroyed);
        summary.set("giants_hit", giants_hit);
        summary.set("giants_defeated", giants_defeated);
        summary.set("civilians_hit", civilians_hit);
        summary
    }

    #[func]
    pub fn snapshot(&self) -> VarDictionary {
        let mut snapshot = VarDictionary::new();
        snapshot.set("health", self.state.health);
        snapshot.set("stamina", self.state.stamina);
        let giant = &self.giants[0];
        snapshot.set("destroyed", self.destroyed_buildings);
        snapshot.set("giant_destroyed", giant.progress.destroyed);
        snapshot.set("giant_count", self.giants.len() as i32);
        snapshot.set("giant_max_height", self.max_height);
        snapshot.set("total_buildings", self.total_buildings as u32);
        snapshot.set("growth_count", giant.progress.growth_count);
        snapshot.set(
            "ai_target_id",
            giant.chase_target.map_or(0, InstanceId::to_i64),
        );
        snapshot.set("giant_scale", giant.scale);
        snapshot.set("giant_height", giant.height(self.max_height));
        snapshot.set("giant_respawning", giant.health_fraction <= 0.0);
        snapshot.set("giant_respawn_in", giant.respawn_in);
        self.snapshot_growth(giant, &mut snapshot);
        snapshot.set(
            "giant_at_max_height",
            giant.scale >= self.max_height / GIANT_START_HEIGHT,
        );
        snapshot.set(
            "hand_action",
            giant
                .hand_attack
                .as_ref()
                .map_or("", |attack| attack.kind.name()),
        );
        snapshot.set(
            "hand_action_progress",
            giant
                .hand_attack
                .as_ref()
                .map_or(0.0, |attack| attack.progress),
        );
        snapshot.set("giant_grabbed", giant.grabbed);
        snapshot.set("giant_pinned", giant.pinned_by.is_some());
        snapshot.set(
            "sit_action",
            giant.sit.map_or("", |action| action.phase_key()),
        );
        snapshot.set(
            "sit_progress",
            giant.sit.map_or(0.0, |action| action.progress()),
        );
        snapshot.set("sit_idle", giant.sit.is_some_and(|action| action.idle));
        snapshot.set("sit_ready", giant.index == 0 && self.sit_ready(giant));
        snapshot.set("outcome", self.outcome_name());
        if let Some(human) = self.evacuating_human() {
            let exit = horizontal(self.exit - human.get_global_position());
            let view = exit.rotated(Vector3::UP, -self.yaw);
            snapshot.set("exit_angle", view.x.atan2(-view.z));
            snapshot.set("exit_distance", exit.length());
        }
        snapshot
    }

    pub fn outcome_name(&self) -> &'static str {
        match self.state.outcome {
            Outcome::Active => "playing",
            Outcome::Evacuated => "evacuated",
            Outcome::Lost => "lost",
        }
    }

    fn follow_camera(&mut self, dt: f32) {
        if self.player == PlayerRole::Spectator {
            self.orbit
                .as_mut()
                .unwrap()
                .set_rotation(Vector3::new(self.pitch, self.yaw, 0.0));
            return;
        }
        // The body may have pivoted since the last look input; keep the head inside its cone.
        self.clamp_first_person_view();
        let giant = &self.giants[0];
        let player = if self.player == PlayerRole::Giant {
            Some(&giant.body)
        } else {
            self.human.as_ref()
        };
        let Some(body) = player else {
            return;
        };
        let mut position = body.get_global_position();
        let mut camera_pitch = 0.0;
        let (height, pitch) = if self.first_person {
            let height = giant.height(self.max_height);
            // Ride the live Head bone so the eye follows stepping, hand actions and
            // sitting instead of a fixed fraction of the capsule.
            if self.player == PlayerRole::Giant {
                let mut body = body.clone();
                let eye = body
                    .call("first_person_eye_position", &[])
                    .try_to::<Vector3>()
                    .ok()
                    .filter(|eye| eye.is_finite());
                position = eye
                    .unwrap_or_else(|| position + Vector3::UP * (height * FIRST_PERSON_EYE_FRACTION));
            } else {
                position += Vector3::UP * (height * FIRST_PERSON_EYE_FRACTION);
            }
            // The rig already places the eye in front of the face; only the look-down lean is
            // added here. Rigs without a Head bone keep the old fixed forward offset.
            let mut forward = if self.player == PlayerRole::Giant {
                0.0
            } else {
                height * FIRST_PERSON_EYE_FORWARD
            };
            if self.pitch < FIRST_PERSON_LOOK_DOWN_PITCH {
                let look_down = ((FIRST_PERSON_LOOK_DOWN_PITCH - self.pitch)
                    / (FRAC_PI_2 + FIRST_PERSON_LOOK_DOWN_PITCH))
                    .clamp(0.0, 1.0);
                let eased = look_down * look_down * (3.0 - 2.0 * look_down);
                forward += height * FIRST_PERSON_LOOK_DOWN_LEAN * eased;
            }
            // Looking down leans the eye forward over the hidden neck, so the view clears the
            // stump and sees the chest and ground instead of the inside of the head.
            position += Vector3::FORWARD.rotated(Vector3::UP, self.yaw) * forward;
            (0.0, self.pitch)
        } else if self.player == PlayerRole::Giant {
            let height = giant.height(self.max_height);
            let arm_length = self.giant_arm_length(height);
            // Near guard: a zoomed-in camera inside the body climbs toward the chest instead
            // of staring between the thighs.
            let guard = 1.0
                - (arm_length / (height * CAMERA_NEAR_GUARD_RATIO).max(0.001)).clamp(0.0, 1.0);
            let focus_ratio = GIANT_CAMERA_FOCUS_RATIO
                + (CAMERA_NEAR_GUARD_FOCUS - GIANT_CAMERA_FOCUS_RATIO) * guard;
            // Growth mode keeps a small absolute focus floor so a 5 mm human still gets a
            // camera above the pavement instead of under it.
            let focus_floor = if self.growth_rules.is_some() { 0.037 } else { 0.0 };
            let forward = Vector3::FORWARD.rotated(Vector3::UP, self.yaw);
            let want = forward * (height * 0.05);
            self.camera_focus_offset = self
                .camera_focus_offset
                .lerp(want, 1.0 - (-dt * 5.0).exp());
            if self.foot_view {
                // Foot follow: the camera sits outside and in front of the left shoe and looks
                // back along it, so the two legs can never straddle the view.
                let body_yaw = giant.body.get_rotation().y;
                let body_forward = Vector3::FORWARD.rotated(Vector3::UP, body_yaw);
                let body_left = -Vector3::RIGHT.rotated(Vector3::UP, body_yaw);
                self.yaw = (body_yaw + PI + FOOT_VIEW_YAW_OFFSET).rem_euclid(TAU);
                self.camera_focus_offset =
                    body_forward * (height * FOOT_VIEW_FOCUS_FORWARD)
                        + body_left * (height * FOOT_VIEW_FOCUS_LEFT);
                (
                    height * FOOT_VIEW_FOCUS_HEIGHT,
                    self.pitch.clamp(-0.9, 0.3) + FOOT_VIEW_PITCH,
                )
            } else {
                ((height * focus_ratio).max(focus_floor), self.pitch)
            }
        } else {
            let arm_pitch = self.pitch.min(EVAC_ARM_MAX_PITCH);
            camera_pitch = self.pitch - arm_pitch;
            (1.52, arm_pitch)
        };
        if let Some(camera) = &mut self.camera {
            camera.set_rotation(Vector3::RIGHT * camera_pitch);
        }
        // Smooth wheel zoom: the arm and near plane follow the eased value.
        if !self.first_person && (self.camera_zoom - self.camera_zoom_target).abs() > 0.0005 {
            let t = (1.0 - (-dt * CAMERA_ZOOM_SMOOTHING).exp()).clamp(0.0, 1.0);
            if t > 0.0 {
                self.camera_zoom += (self.camera_zoom_target - self.camera_zoom) * t;
                self.sync_camera_arm();
            }
        }
        let orbit = self.orbit.as_mut().unwrap();
        orbit.set_global_position(position + self.camera_focus_offset + Vector3::UP * height);
        orbit.set_rotation(Vector3::new(pitch, self.yaw, 0.0));
    }

    fn apply_camera_distance(&mut self, giant_scale: f32) {
        if let Some(camera) = &mut self.camera {
            let distance = self.settings.view_distance;
            camera.set_meta("district_draw_distance", &distance.to_variant());
            let eye_height = if self.player == PlayerRole::Spectator {
                camera.get_global_position().y
            } else if self.first_person {
                // The eye rides the Head bone, so the old fixed fraction no longer bounds it:
                // use the full body height, which always contains the eye.
                GIANT_START_HEIGHT * giant_scale
            } else {
                0.0
            };
            // The far plane covers the whole island plus the tallest body: pulling back 500 m
            // used to clip the city, and the old 560 m plane flickered the horizon.
            let height = if self.player == PlayerRole::Giant {
                GIANT_START_HEIGHT * giant_scale
            } else {
                eye_height
            };
            // The far plane covers the whole island, the tallest body, and the 30 km
            // single-world bedroom walls & seated Yumeka (Vulkan mobile 32-bit Reversed-Z).
            let regular_far = (self.world_limit * 6.5 + height * 3.0).max(50000.0);
            if regular_far != self.regular_camera_far {
                self.regular_camera_far = regular_far;
                camera.set_far(regular_far);
            }
        }
    }

    fn update_distant_silhouettes(&mut self) {
        let Some(camera) = &mut self.camera else {
            return;
        };
        let view = camera.get_global_transform();
        let eye = view.origin;
        let draw = self.settings.view_distance.max(1.0);
        let fade_start = draw * 0.82;
        let fade_width = (draw - fade_start).max(12.0);
        let mut far = self.regular_camera_far;
        for actor in &mut self.giants {
            let height = actor.height(self.max_height);
            let local_player = self.player == PlayerRole::Giant && actor.index == 0;
            let mut opacity = 0;
            if !local_player
                && !actor.human
                && actor.health_fraction > 0.0
                && height >= DISTANT_SILHOUETTE_HEIGHT
            {
                let offset = actor.body.get_global_position() - eye;
                let distance = horizontal(offset).length();
                let t = ((distance - fade_start) / fade_width).clamp(0.0, 1.0);
                let fade_in = t * t * (3.0 - 2.0 * t);
                let haze = (1.0 - (distance - draw).max(0.0) / 3200.0).max(0.45);
                opacity = (255.0 * 0.28 * fade_in * haze).round() as u8;
                if opacity > 0 {
                    // Leave room for the whole animated body, including crouches and swings.
                    let center = offset + Vector3::UP * (height * 0.5);
                    far = far.max(center.length() + height * GIANT_MESH_BOUND_RATIO + 8.0);
                }
            }
            // Distance detail tiers: real-time shadows and hair springs go first, then the
            // sub-centimetre face pieces. Thresholds scale with the body so a 500 m giant keeps
            // full detail much further out than a 3 m one.
            let offset = actor.body.get_global_position() - self.frame_observer;
            let distance = horizontal(offset).length();
            let full = ANIMATION_FULL_DISTANCE.max(height * 1.2);
            let far = ANIMATION_HALF_DISTANCE.max(full * 2.2);
            let tier: u8 = if distance > far {
                2
            } else if distance > full {
                1
            } else {
                0
            };
            if tier != actor.detail_tier {
                actor.detail_tier = tier;
                actor.body.call("set_detail_tier", &[tier.to_variant()]);
            }
            if actor.silhouette_opacity != opacity {
                actor.silhouette_opacity = opacity;
                actor.body.call(
                    "set_silhouette_opacity",
                    &[(f32::from(opacity) / 255.0).to_variant()],
                );
            }
        }
        let extended = far > self.regular_camera_far + 0.1;
        let forward = -view.basis.col_c();
        for actor in &mut self.giants {
            // Keep ordinary actors clipped at the regular far plane while a silhouette extends it.
            let clipped = extended && actor.silhouette_opacity == 0 && {
                let height = actor.height(self.max_height);
                let center = actor.body.get_global_position() + Vector3::UP * (height * 0.5);
                let near_depth =
                    (center - eye).dot(forward) - height * GIANT_MESH_BOUND_RATIO - 8.0;
                near_depth > self.regular_camera_far
            };
            if clipped != actor.beyond_regular_clip {
                actor.beyond_regular_clip = clipped;
                actor.body.call("set_distant_clip", &[clipped.to_variant()]);
            }
        }
        if (camera.get_far() - far).abs() > 0.1 {
            camera.set_far(far);
        }
    }

    fn move_spectator(&mut self, axes: Vector2, dt: f32) {
        if axes == Vector2::ZERO {
            return;
        }
        let direction = Vector3::new(axes.x, 0.0, axes.y)
            .rotated(Vector3::RIGHT, self.pitch)
            .rotated(Vector3::UP, self.yaw);
        let orbit = self.orbit.as_mut().unwrap();
        let position = orbit.get_global_position();
        let speed = (position.y * 1.6).clamp(0.45, 70.0);
        let mut next = position + direction * (speed * dt);
        next.x = next.x.clamp(-self.world_limit, self.world_limit);
        next.z = next.z.clamp(-self.world_limit, self.world_limit);
        next.y = next
            .y
            .clamp(SPECTATOR_MIN_HEIGHT, self.max_height.max(180.0) + 60.0);
        orbit.set_global_position(next);
        if next.y != position.y {
            self.camera
                .as_mut()
                .unwrap()
                .set_near((next.y * 0.025).clamp(0.05, 0.09));
            self.apply_camera_distance(0.0);
        }
    }

    fn observer_position(&self) -> Vector3 {
        match self.player {
            PlayerRole::Spectator => self.orbit.as_ref().unwrap().get_global_position(),
            PlayerRole::Giant => self.giants[0].body.get_global_position(),
            _ => self.human.as_ref().unwrap().get_global_position(),
        }
    }

    fn evacuating_human(&self) -> Option<&Gd<CharacterBody3D>> {
        self.human
            .as_ref()
            .filter(|_| self.player == PlayerRole::Evacuee)
    }

    /// Current view mode: 0 = third person full body, 1 = diagonal foot follow, 2 = first person.
    fn view_mode(&self) -> u8 {
        if self.first_person {
            2
        } else if self.foot_view {
            1
        } else {
            0
        }
    }

    /// Reads the preference at the current scale unless the player already cycled with `V`.
    fn view_preference(&self, scale: f32) -> u8 {
        match self.manual_view {
            Some(mode) => mode,
            None if self.growth_rules.is_some() && scale < FIRST_PERSON_MAX_SCALE => 2,
            None => 0,
        }
    }

    fn prefers_first_person(&self, scale: f32) -> bool {
        self.view_preference(scale) == 2
    }

    /// Public view mode for touch controls and tests: 0 third person, 1 foot follow, 2 first person.
    #[func]
    fn camera_view_mode(&self) -> i32 {
        self.view_mode() as i32
    }

    /// Selects a view mode directly (touch buttons, tests). `V` cycles through the same modes.
    #[func]
    fn set_camera_view(&mut self, mode: i32) {
        if self.state.outcome != Outcome::Active || self.player != PlayerRole::Giant {
            return;
        }
        self.manual_view = Some(mode.clamp(0, 2) as u8);
        let giant = &self.giants[0];
        self.update_giant_camera_scale(&giant.body.clone(), giant.scale);
        self.follow_camera(0.0);
    }

    /// Wheel zoom clamped to the configured range.
    #[func]
    fn zoom_by(&mut self, steps: f32) {
        if self.player != PlayerRole::Giant || self.state.outcome != Outcome::Active {
            return;
        }
        self.camera_zoom_target = (self.camera_zoom_target * (1.0 + steps * CAMERA_ZOOM_STEP))
            .clamp(CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX);
    }

    /// Arm length for the current body height and zoom.
    fn giant_arm_length(&self, height: f32) -> f32 {
        let base = height.max(0.1) * GIANT_CAMERA_LENGTH_RATIO * self.camera_zoom;
        if self.growth_rules.is_some() {
            base.max(GROWTH_CAMERA_MIN_LENGTH)
        } else {
            base.max(0.05)
        }
    }

    fn starting_giant_camera_pitch(&self, scale: f32) -> f32 {
        if self.prefers_first_person(scale) {
            0.0
        } else {
            -0.34
        }
    }

    fn update_giant_camera_scale(&mut self, body: &Gd<CharacterBody3D>, scale: f32) {
        let growth = self.growth_rules.is_some();
        let mode = self.view_preference(scale);
        let first_person = mode == 2;
        let foot_view = mode == 1;
        let changed = first_person != self.first_person || foot_view != self.foot_view;
        self.first_person = first_person;
        self.foot_view = foot_view;
        let height = self
            .giants
            .first()
            .map_or(GIANT_START_HEIGHT * scale, |giant| {
                giant.height(self.max_height)
            });
        let length = if foot_view {
            (height * FOOT_VIEW_LENGTH_RATIO * self.camera_zoom).max(GROWTH_CAMERA_MIN_LENGTH)
        } else {
            self.giant_arm_length(height)
        };
        if changed {
            self.camera_focus_offset = Vector3::ZERO;
            // The foot view owns the yaw; park the player's look direction while it is on.
            if foot_view {
                self.foot_view_yaw = Some(self.yaw);
            } else if let Some(saved) = self.foot_view_yaw.take() {
                self.yaw = saved;
            }
            if !first_person {
                self.pitch = self.pitch.clamp(-1.15, 0.26);
            }
            body.clone()
                .call("set_first_person", &[first_person.to_variant()]);
        }
        let mut arm = self.base().get_node_as::<SpringArm3D>("Orbit/Arm");
        arm.set_length(length);
        if growth {
            arm.set_margin((0.16 * scale).clamp(0.001, 0.16));
            arm.get_shape()
                .unwrap()
                .cast::<SphereShape3D>()
                .set_radius((0.28 * scale).clamp(0.003, 0.28));
        }
        if let Some(camera) = &mut self.camera {
            if changed {
                let parent = if first_person {
                    self.orbit.as_ref().unwrap().clone()
                } else {
                    arm.upcast::<Node3D>()
                };
                camera
                    .reparent_ex(&parent)
                    .keep_global_transform(false)
                    .done();
                camera.set_position(if first_person {
                    Vector3::ZERO
                } else {
                    Vector3::BACK * length
                });
                camera.set_rotation(Vector3::ZERO);
                camera.make_current();
            } else if !first_person {
                // The arm length follows the body while it grows, so the camera keeps its
                // distance instead of ending up inside the legs.
                camera.set_position(Vector3::BACK * length);
            }
            camera.set_near(if first_person {
                let height = GIANT_START_HEIGHT * scale;
                // Keep far/near <= 1,000,000 (with far >= 50,000 m) so Godot's float32
                // RenderingLightCuller::create_frustum_points() never degenerates.
                (height * 0.12)
                    .clamp(0.05, 0.06)
                    .max((height * 0.005).min(3.0))
            } else {
                // Near plane scales with the arm so a 500 m pull-back never clips the world.
                // 0.018 (was 0.005) pulls the plane 4-5x closer to the body: the 24-bit
                // depth buffer keeps the 1,418 m lot pads and the sunken ground plate apart
                // at grazing angles, and near stays far below the camera-to-body distance.
                (length * 0.018).clamp(0.09, 8.0)
            });
        }
        if changed {
            self.set_camera_shake_offsets(0.0, 0.0);
        }
        if first_person || changed {
            self.apply_camera_distance(scale);
        }
    }

    /// Re-applies the height-scaled arm length and near plane after a zoom step.
    fn sync_camera_arm(&mut self) {
        let Some(giant) = self.giants.first() else {
            return;
        };
        let height = giant.height(self.max_height);
        let length = if self.foot_view {
            (height * FOOT_VIEW_LENGTH_RATIO * self.camera_zoom).max(GROWTH_CAMERA_MIN_LENGTH)
        } else {
            self.giant_arm_length(height)
        };
        let mut arm = self.base().get_node_as::<SpringArm3D>("Orbit/Arm");
        arm.set_length(length);
        if let Some(camera) = &mut self.camera {
            if !self.first_person {
                camera.set_position(Vector3::BACK * length);
                // Mirrors the giant-scale near plane (see update_giant_camera_scale).
                camera.set_near((length * 0.018).clamp(0.09, 8.0));
            }
        }
    }

    fn queue_giant_impact(&mut self, actor: &Giant, at: Vector3, kind: GroundImpact) {
        self.camera_impacts.push(CameraImpact {
            at,
            kind,
            giant: Some((actor.index, actor.scale)),
        });
    }

    fn flush_camera_impacts(&mut self) {
        if self.player == PlayerRole::Spectator {
            self.camera_impacts.clear();
            return;
        }
        if self.camera_impacts.is_empty() {
            return;
        }
        let Some(camera) = &self.camera else { return };
        let player = &self.giants[0];
        let growth = self.growth_rules.is_some();
        let own_impact_unlocked = !growth || self.can_demolish(player);
        let player_is_giant = self.player == PlayerRole::Giant;
        let viewer_height = if player_is_giant {
            player.height(self.max_height)
        } else {
            HUMAN_HEIGHT
        };
        let listener = if growth {
            self.observer_position()
        } else {
            camera.get_global_position()
        };
        let player_defeated = growth && player_is_giant && player.health_fraction <= 0.0;
        let mut own_peak = 0.0_f32;
        let mut own_height = GIANT_START_HEIGHT;
        let mut nearby_peak = 0.0_f32;
        let mut nearby_height = GIANT_START_HEIGHT;
        for event in self.camera_impacts.drain(..) {
            let own = player_is_giant && matches!(event.giant, Some((0, _)));
            if player_defeated || (own && (!self.settings.own_camera_shake || !own_impact_unlocked))
            {
                continue;
            }
            let distance = listener.distance_to(event.at);
            let source_height = event
                .giant
                .map_or(HUMAN_HEIGHT, |(_, scale)| GIANT_START_HEIGHT * scale);
            let strength = if !growth || own {
                let scale = event.giant.map_or(1.0, |(_, scale)| scale);
                event.kind.shake(distance, scale)
            } else {
                event
                    .kind
                    .relative_shake(distance, source_height, viewer_height)
            };
            if own {
                if strength > own_peak {
                    own_peak = strength;
                    own_height = source_height;
                }
            } else if strength > nearby_peak {
                nearby_peak = strength;
                nearby_height = source_height;
            }
        }
        let cutoff = self.shake_cutoff();
        let multiplier = self.settings.shake_strength;
        let own_scaled = own_peak * multiplier;
        let nearby_scaled = nearby_peak * multiplier;
        let own_triggered = self.own_shake.add_peak(own_scaled, cutoff);
        let nearby_triggered = self.nearby_shake.add_peak(nearby_scaled, cutoff);
        let shake_audio = match (own_triggered, nearby_triggered) {
            (true, true) => {
                if own_scaled >= nearby_scaled {
                    Some((own_scaled, own_height))
                } else {
                    Some((nearby_scaled, nearby_height))
                }
            }
            (true, false) => Some((own_scaled, own_height)),
            (false, true) => Some((nearby_scaled, nearby_height)),
            (false, false) => None,
        };
        if let Some((peak, source_height)) = shake_audio
            && let Some(mut audio) = self.audio()
        {
            audio.call(
                "play_camera_shake",
                &[peak.to_variant(), source_height.to_variant()],
            );
        }
    }

    fn shake_cutoff(&self) -> f32 {
        if self.growth_rules.is_some() {
            0.0005
        } else {
            0.003
        }
    }

    fn update_camera_shake(&mut self, dt: f32) {
        if self.own_shake.strength == 0.0 && self.nearby_shake.strength == 0.0 {
            return;
        }
        let cutoff = self.shake_cutoff();
        let attenuation = (-dt * 9.0).exp();
        self.own_shake.decay(dt, attenuation, cutoff);
        self.nearby_shake.decay(dt, attenuation, cutoff);
        self.apply_camera_shake();
    }

    fn apply_camera_shake(&mut self) {
        let shake = if self.own_shake.strength > self.nearby_shake.strength {
            &self.own_shake
        } else {
            &self.nearby_shake
        };
        self.set_camera_shake_offsets(
            (shake.elapsed * 37.0).sin() * shake.strength * 0.30,
            (shake.elapsed * 48.0).cos() * shake.strength,
        );
    }

    fn reset_camera_shake(&mut self) {
        self.own_shake = CameraShake::default();
        self.nearby_shake = CameraShake::default();
        self.set_camera_shake_offsets(0.0, 0.0);
        if let Some(mut audio) = self.audio() {
            audio.call("stop_camera_shake", &[]);
        }
    }

    fn set_camera_shake_offsets(&mut self, x: f32, y: f32) {
        let shoulder = if self.human.is_some() { 0.34 } else { 0.0 };
        if let Some(camera) = &mut self.camera {
            if self.growth_rules.is_some() || self.first_person {
                // Angular motion keeps fine differences in strength visible at centimeter scale.
                let angle = |force: f32| 0.12 * force / (0.65 + force.abs());
                let translation = camera.get_near() * if self.first_person { 0.12 } else { 1.5 };
                camera.set_rotation(Vector3::new(angle(y), angle(x) * 0.45, angle(x)));
                camera.set_h_offset(shoulder + x * translation);
                camera.set_v_offset(y * translation);
                return;
            }
            camera.set_h_offset(shoulder + x);
            camera.set_v_offset(y);
        }
    }

    fn next_npc_spawn(&self) -> f32 {
        self.settings.npc_interval * random_range(0.75, 1.25)
    }

    /// Growth actors start as ordinary humans and only turn into giants at the demolition
    /// height. Outside growth mode every actor is always in its giant stage.
    fn is_human_stage(&self, scale: f32) -> bool {
        self.mode == Mode::Growth
            && self
                .growth_rules
                .is_some_and(|rules| scale < rules.attack_height / GIANT_START_HEIGHT)
    }

    fn actor_radius(&self, actor: &Giant) -> f32 {
        if actor.human {
            HUMAN_RADIUS * actor.height(self.max_height) / HUMAN_HEIGHT
        } else {
            GIANT_RADIUS * actor.scale
        }
    }

    /// Reads the physics-body state the pair passes need once per frame. Positions, safe
    /// margins and speeds used to be fetched inside both pair loops, which turned the frame
    /// quadratic in engine calls once a round had dozens of actors.
    fn capture_pair_frames(&self, dt: f32) -> Vec<PairFrame> {
        let player_is_giant = self.player == PlayerRole::Giant;
        self.giants
            .iter()
            .map(|giant| {
                let start = giant.body.get_global_position();
                let speed = self.giant_speed(giant, player_is_giant && giant.index == 0);
                PairFrame {
                    start,
                    end: start,
                    radius: self.actor_radius(giant),
                    height: giant.height(self.max_height),
                    safe_margin: giant.body.get_safe_margin(),
                    travel: speed * dt,
                    scale: giant.scale,
                    human: giant.human,
                    health: giant.health_fraction,
                    grabbed: giant.grabbed,
                }
            })
            .collect()
    }

    /// Chooses how many physics frames may pass between procedural skeleton updates.
    /// Nearby actors and the player-controlled giant always update every frame; distant
    /// animation is amortized instead of resampling every bone for every actor.
    fn animation_stride(&self, actor: &Giant, position: Vector3) -> u8 {
        if actor.index == 0 && matches!(self.player, PlayerRole::Giant | PlayerRole::Spectator) {
            return 1;
        }
        let distance = horizontal(position - self.frame_observer).length();
        let height = actor.height(self.max_height);
        let full = ANIMATION_FULL_DISTANCE.max(height * 1.2);
        if distance <= full {
            1
        } else if distance <= ANIMATION_HALF_DISTANCE.max(full * 2.2) {
            2
        } else {
            3
        }
    }

    fn sync_actor_stage(&mut self, index: usize) -> bool {
        let human = self.is_human_stage(self.giants[index].scale);
        let became_giant = self.giants[index].human && !human;
        if human != self.giants[index].human {
            self.giants[index].set_stage(human, self.max_height);
        }
        became_giant
    }

    pub(super) fn audio(&self) -> Option<Gd<Node>> {
        self.base()
            .get_tree()
            .get_root()
            .get_node_or_null("HarborAudio")
    }

    pub(super) fn play_audio_2d(&self, id: &str, volume_db: f32, pitch: f32, jitter: f32) {
        if let Some(mut audio) = self.audio() {
            audio.call(
                "play_2d",
                &[
                    StringName::from(id).to_variant(),
                    volume_db.to_variant(),
                    pitch.to_variant(),
                    jitter.to_variant(),
                ],
            );
        }
    }

    fn giant_spawn_position(&self, nominal: Vector3, spacing: f32) -> Option<Vector3> {
        let clearance = GIANT_RADIUS * self.starting_scale + 0.3;
        let is_clear = |at: Vector3| {
            at.x.abs().max(at.z.abs()) + clearance < self.world_limit
                && self.clear_of_giants(at, (spacing - clearance).max(clearance))
                && self
                    .target_grid
                    .near(at, clearance)
                    .all(|index| !self.targets[index].footprint.touches(at, clearance))
        };
        if is_clear(nominal) {
            return Some(nominal);
        }
        self.spawn_points
            .iter()
            .copied()
            .filter(|point| is_clear(*point))
            .min_by(|a, b| {
                a.distance_squared_to(nominal)
                    .total_cmp(&b.distance_squared_to(nominal))
            })
    }

    fn clear_of_giants(&self, point: Vector3, margin: f32) -> bool {
        self.giants
            .iter()
            .filter(|giant| giant.health_fraction > 0.0)
            .all(|giant| {
                let clearance = GIANT_RADIUS * giant.scale + margin;
                horizontal(point - giant.body.get_global_position()).length_squared()
                    > clearance.powi(2)
            })
    }

    fn random_spawn(&self, anchor: Vector3, min: f32, max: f32) -> Option<Vector3> {
        let (min, max) = (min * min, max * max);
        let candidates: Vec<_> = self
            .spawn_points
            .iter()
            .copied()
            .filter(|point| {
                let dist = horizontal(*point - anchor).length_squared();
                (min..=max).contains(&dist)
            })
            .collect();
        random_choice(&candidates)
    }

    fn find_civilian_spawn(&self, can_spawn: impl Fn(Vector3) -> bool) -> Option<Vector3> {
        if self.spawn_points.is_empty() {
            return None;
        }
        let start = godot::global::randi_range(0, self.spawn_points.len() as i64 - 1) as usize;
        let (before, after) = self.spawn_points.split_at(start);
        after
            .iter()
            .chain(before)
            .copied()
            .find(|&point| can_spawn(point))
    }

    fn human_observer_spawn(&self, giant_start: Vector3, height: f32) -> Option<Vector3> {
        let distance = (height * 0.8).max(3.0);
        let inward = horizontal(-giant_start)
            .try_normalized()
            .unwrap_or(Vector3::BACK);
        (0..8)
            .map(|sector| {
                giant_start + inward.rotated(Vector3::UP, sector as f32 * TAU / 8.0) * distance
            })
            .find(|&point| {
                point.x.abs().max(point.z.abs()) + 0.6 < self.world_limit
                    && self.clear_of_giants(point, 0.6)
                    && self
                        .target_grid
                        .near(point, 0.6)
                        .all(|index| !self.targets[index].footprint.touches(point, 0.6))
            })
    }

    fn spawn_civilian(&mut self, anchor: Vector3, initial: bool) {
        let height = HUMAN_HEIGHT;
        let scale = height / HUMAN_HEIGHT;
        let radius = HUMAN_RADIUS * scale;
        let is_safe = |point: Vector3| {
            self.clear_of_giants(point, 12.0)
                && self.evacuating_human().is_none_or(|human| {
                    horizontal(point - human.get_global_position()).length_squared() > 100.0
                })
                && self.civilians.iter().all(|npc| {
                    let clearance = (radius + npc.size.radius + 0.3).max(3.0);
                    horizontal(point - npc.body.get_global_position()).length_squared()
                        > clearance.powi(2)
                })
                && (radius <= 1.2
                    || self.target_grid.near(point, radius).all(|index| {
                        !self.targets[index].integrity.blocks()
                            || !self.targets[index].footprint.touches(point, radius)
                    }))
        };
        let (min, max) = if self.growth_rules.is_some() {
            (12.0, 32.0)
        } else {
            (24.0, 125.0)
        };
        let mut spawn = (0..12)
            .filter_map(|_| self.random_spawn(anchor, min, max))
            .find(|&point| is_safe(point));
        if spawn.is_none() && initial {
            spawn = self.find_civilian_spawn(is_safe);
        }
        let Some(spawn) = spawn else { return };
        let Some(scene) = &self.npc_scene else { return };
        let mut body = scene.instantiate_as::<CharacterBody3D>();
        if scale != 1.0 {
            body.set_scale(Vector3::splat(scale));
            let snap = body.get_floor_snap_length();
            body.set_floor_snap_length(snap * scale);
        }
        // Crowds follow solid scenery but do not pin either playable character.
        body.set_collision_layer(0);
        body.set_collision_mask(SIGHT_MASK);
        self.base()
            .get_node_as::<Node3D>("Civilians")
            .add_child(&body);
        body.set_global_position(spawn);
        let collision = body.get_node_as::<CollisionShape3D>("Collision");
        let size = BodySize::from_capsule(&collision);
        self.civilians.push(Civilian {
            body,
            size,
            position: spawn,
            direction: random_heading(),
            turn_in: random_range(0.6, 2.5),
            speed: random_range(2.8, 4.0),
            remove_in: None,
            grabbed: false,
            health_fraction: 1.0,
            state: CivilianState::Calm,
            panic_left: 0.0,
            sense_in: random_range(0.0, 0.3),
            threat: None,
            cover_goal: None,
        });
    }

    /// Civilian crowd update with the three-state escape behavior: a daily
    /// stroll that breaks into panic sprinting when a giant, collapse shake or
    /// warning circle is sensed nearby, then a sheltering walk toward a corner
    /// away from the threat before calming back down. One cheap sense pass per
    /// pedestrian every ~0.3 s keeps the whole crowd light.
    fn update_civilians(&mut self, dt: f32) {
        if self.growth_rules.is_some() {
            return;
        }
        let giant = self.giants[0].body.get_global_position();
        let observer = self.observer_position();
        // Danger sources for the sense pass, snapshotted once per frame.
        let mut dangers: Vec<(Vector3, f32)> = Vec::new();
        let mut landings = Vec::new();
        for actor in &self.giants {
            if actor.health_fraction <= 0.0 {
                continue;
            }
            let height = actor.height(self.max_height);
            if !actor.human {
                // A giant's stride is dangerous across its whole reach.
                let reach = footfall_reach(actor.scale)
                    .max(height * 1.2);
                dangers.push((actor.body.get_global_position(), reach + 55.0));
            }
            if let Some(landing) = &actor.footfall {
                landings.push(landing);
                dangers.push((landing.sole.center, landing.sole.bounds() + height * 0.35));
            }
            if let Some((center, radius)) = actor.sit_drop_zone() {
                dangers.push((center, radius + 20.0));
            }
        }
        for impact in &self.camera_impacts {
            // Collapses and ground strikes shake the ground: felt even through walls.
            if matches!(impact.kind, GroundImpact::Footfall | GroundImpact::Sit) {
                dangers.push((impact.at, 24.0));
            }
        }
        for &(_, center, radius) in &self.hazard_warnings {
            dangers.push((center, radius + 35.0));
        }
        self.civilians.retain_mut(|npc| {
            if npc.grabbed {
                return true;
            }
            if let Some(left) = npc.remove_in.as_mut() {
                *left -= dt;
                if *left <= 0.0 {
                    npc.body.queue_free();
                    return false;
                }
                return true;
            }
            let at = npc.body.get_global_position();
            npc.position = at;
            let visible = horizontal(at - observer).length_squared() <= NPC_DRAW_RANGE.powi(2);
            if visible != npc.body.is_visible() {
                npc.body.call("set_render_active", &[visible.to_variant()]);
            }

            // An approaching sole takes priority immediately, including during panic.
            // Project along the current heading so pedestrians crossing the step path react too.
            let landing = landings.iter().find(|landing| {
                let projected = at + npc.direction * npc.speed * landing.eta.min(0.45);
                let clearance = npc.size.radius + landing.sole.half_extents.x * 0.30;
                landing.threatens(at, clearance) || landing.threatens(projected, clearance)
            });
            if let Some(landing) = landing {
                npc.state = CivilianState::Panic;
                npc.threat = Some((landing.sole.center, landing.sole.bounds()));
                npc.panic_left = npc.panic_left.max(3.6);
                npc.cover_goal = None;
            }

            // --- Sense pass (staggered, ~0.3 s per pedestrian). ---
            npc.sense_in -= dt;
            if landing.is_none() && npc.sense_in <= 0.0 {
                npc.sense_in = 0.28 + random_range(0.0, 0.08);
                let mut sensed: Option<(Vector3, f32)> = None;
                for &(danger_at, radius) in &dangers {
                    if horizontal(danger_at - at).length() <= radius {
                        sensed = match sensed {
                            None => Some((danger_at, radius)),
                            Some((best, best_radius)) => {
                                if horizontal(danger_at - at).length()
                                    < horizontal(best - at).length()
                                {
                                    Some((danger_at, radius))
                                } else {
                                    Some((best, best_radius))
                                }
                            }
                        };
                    }
                }
                if let Some(threat) = sensed {
                    npc.threat = Some(threat);
                    npc.panic_left = 3.6 + random_range(0.0, 2.2);
                    if npc.state == CivilianState::Calm {
                        npc.state = CivilianState::Panic;
                        npc.turn_in = 0.0;
                        npc.cover_goal = None;
                    }
                }
            }

            let sprinting = npc.state == CivilianState::Panic;
            let speed = if sprinting {
                npc.speed * 2.4
            } else if npc.state == CivilianState::Cover {
                npc.speed * 1.35
            } else {
                npc.speed
            };
            npc.turn_in -= dt;
            match npc.state {
                CivilianState::Calm => {
                    if npc.turn_in <= 0.0 || npc.body.is_on_wall() {
                        npc.turn_in = random_range(1.3, 4.0);
                        npc.direction = random_heading();
                    }
                }
                CivilianState::Panic => {
                    npc.panic_left -= dt;
                    let away = npc
                        .threat
                        .map(|(threat_at, _)| horizontal(npc.position - threat_at))
                        .unwrap_or_else(|| horizontal(-npc.position));
                    let away_dir = if away.length_squared() > 1e-4 {
                        away.normalized_or_zero()
                    } else {
                        npc.direction
                    };
                    // Sprint away from the threat with a jitter; on a wall,
                    // slide along it instead of grinding into the corner.
                    let desired = if npc.body.is_on_wall() {
                        let slide = if away_dir.x + away_dir.z >= 0.0 {
                            1.35
                        } else {
                            -1.35
                        };
                        away_dir.rotated(Vector3::UP, slide)
                    } else {
                        away_dir.rotated(Vector3::UP, random_range(-0.4, 0.4))
                    };
                    if npc.direction.dot(desired) < 0.7 || npc.turn_in <= 0.0 {
                        npc.direction = desired;
                        npc.turn_in = random_range(0.35, 0.8);
                    }
                    if npc.panic_left <= 0.0 {
                        // Catch a breath: head for a sheltered point away from
                        // the last threat, biased along the street grid.
                        npc.state = CivilianState::Cover;
                        let base = npc
                            .threat
                            .map(|(threat_at, _)| horizontal(npc.position - threat_at))
                            .unwrap_or(npc.direction);
                        let away = if base.length_squared() > 1e-4 {
                            base.normalized_or_zero()
                        } else {
                            random_heading()
                        };
                        let limit = (self.world_limit - 6.0).max(4.0);
                        let distance = random_range(14.0, 30.0);
                        let mut goal = npc.position + away * distance;
                        if away.x.abs() > away.z.abs() {
                            goal.z = npc.position.z + random_range(-4.0, 4.0);
                        } else {
                            goal.x = npc.position.x + random_range(-4.0, 4.0);
                        }
                        goal.x = goal.x.clamp(-limit, limit);
                        goal.z = goal.z.clamp(-limit, limit);
                        npc.cover_goal = Some(goal);
                    }
                }
                CivilianState::Cover => {
                    if let Some(goal) = npc.cover_goal {
                        let offset = horizontal(goal - npc.position);
                        if offset.length() < 1.6 {
                            npc.cover_goal = None;
                            npc.state = CivilianState::Calm;
                            npc.turn_in = random_range(0.8, 2.0);
                            npc.direction = random_heading();
                        } else if npc.turn_in <= 0.0 || npc.body.is_on_wall() {
                            npc.turn_in = random_range(0.8, 1.6);
                            npc.direction = offset.normalized_or_zero();
                        }
                    } else {
                        npc.state = CivilianState::Calm;
                    }
                }
            }
            drive(&mut npc.body, npc.direction, speed, dt, 11.0);
            if visible {
                let speed = ground_speed(&npc.body);
                npc.body.call("show_motion", &[speed.to_variant(), sprinting.to_variant()]);
            }
            true
        });
        if !self.settings.npc_respawn {
            return;
        }
        self.npc_spawn_in -= dt;
        if self.npc_spawn_in <= 0.0 {
            self.npc_spawn_in = self.next_npc_spawn();
            if self.civilians.len() < self.npc_limit {
                let anchor = if godot::global::randf() < 0.65 {
                    giant
                } else {
                    self.evacuating_human()
                        .map_or(giant, |human| human.get_global_position())
                };
                self.spawn_civilian(anchor, false);
            }
        }
    }

    fn combat_target(
        &self,
        actor: &mut Giant,
        speed: f32,
        dt: f32,
    ) -> Option<(CombatTarget, bool, GiantSight)> {
        let position = actor.body.get_global_position();
        let can_demolish = self.can_demolish(actor);
        let growth = self.growth_rules.is_some();
        let rules = self.combat_rules();
        let reach = footfall_reach(actor.scale);
        let eye_range = sight_range(actor.scale);
        let mut sight = GiantSight::new(&actor.body, actor.scale)?;
        let actor_height = actor.height(self.max_height);
        let human_ignore_ratio = self.settings.human_ignore_ratio;
        let humans = self
            .evacuating_human()
            .into_iter()
            .map(|body| {
                (
                    body,
                    BodySize::STANDARD_HUMAN,
                    self.evacuee_position
                        .unwrap_or_else(|| body.get_global_position()),
                )
            })
            .chain(
                self.civilians
                    .iter()
                    .filter(|npc| npc.remove_in.is_none() && !npc.grabbed)
                    .map(|npc| (&npc.body, npc.size, npc.position)),
            )
            .chain(
                self.rivals
                    .iter()
                    .filter(|rival| {
                        growth && rival.index != actor.index && self.is_human_stage(rival.scale)
                    })
                    .map(|rival| {
                        (
                            &rival.body,
                            BodySize {
                                height: GIANT_START_HEIGHT * rival.scale,
                                radius: HUMAN_RADIUS * rival.scale * GIANT_START_HEIGHT
                                    / HUMAN_HEIGHT,
                            },
                            rival.position,
                        )
                    }),
            )
            .filter(|(_, size, _)| !ignores_human(actor_height, size.height, human_ignore_ratio));
        let mut candidates = Vec::new();
        let mut tracked = None;
        for target in humans
            .filter(|_| can_demolish)
            .map(|(body, size, position)| CombatTarget {
                body: body.clone(),
                position,
                size,
                rival: None,
            })
            .chain(
                self.rivals
                    .iter()
                    .filter(|rival| rival.index != actor.index)
                    .filter(|rival| !self.is_human_stage(rival.scale))
                    .map(|rival| CombatTarget {
                        body: rival.body.clone(),
                        position: rival.position,
                        size: BodySize {
                            height: GIANT_START_HEIGHT * rival.scale,
                            radius: GIANT_RADIUS * rival.scale,
                        },
                        rival: Some((rival.scale, rival.health_fraction)),
                    }),
            )
        {
            let at = target.position;
            let distance = horizontal(at - position).length();
            if actor.chase_target == Some(target.body.instance_id()) {
                if distance > eye_range || !sight.sees_at(at, target.size.height) {
                    actor.chase_hidden_for += dt;
                    if actor.chase_hidden_for + 0.0001 < TARGET_OCCLUSION_TIME {
                        return Some((target, false, sight));
                    }
                    continue;
                }
                actor.chase_hidden_for = 0.0;
                tracked = Some(target.body.instance_id());
            }

            let score = if let Some((scale, health)) = target.rival {
                if ignores_rival(scale, actor.scale, self.settings.rival_ignore_ratio) {
                    continue;
                }
                // Seven-step relative-size engagement matrix. The ignore ratio
                // above stays the hard gate; the tier decides whether this
                // actor reaches for the rival at all and how far.
                let tier = SizeTier::from_ratio(scale / actor.scale);
                let enemy_reach = footfall_reach(scale) + GIANT_RADIUS * actor.scale;
                let hits = scale * health * rules.base_health / (actor.scale * rules.base_attack);
                let outmatched = scale * health > 1.5 * actor.scale * actor.health_fraction;
                let attack_range = if !can_demolish {
                    if outmatched || (scale >= actor.scale && hits > 2.0) {
                        continue;
                    }
                    reach * if hits <= 1.0 { 3.0 } else { 1.7 }
                } else {
                    match tier {
                        // Incidental footfall in passing only — never a chase.
                        SizeTier::Trivial => reach,
                        // Ambush the uphill rival only while scale×HP + boldness say so.
                        SizeTier::Uphill
                            if !ambush_uphill(
                                actor.scale,
                                actor.health_fraction,
                                scale,
                                health,
                                actor.personality.risk01(),
                            ) =>
                        {
                            continue;
                        }
                        // Fleeing a danger/overwhelming rival is pursue's job.
                        SizeTier::Danger | SizeTier::Overwhelming => continue,
                        SizeTier::Uphill | SizeTier::Prey | SizeTier::Pushover | SizeTier::Peer => {
                            if outmatched {
                                enemy_reach + 1.5
                            } else {
                                rival_engage_range(reach, speed, actor.scale)
                            }
                        }
                    }
                };
                if distance > attack_range
                    && (outmatched || tracked != Some(target.body.instance_id()))
                {
                    continue;
                }
                // A wounded rival in reach is a better opportunity than a long fight.
                distance
                    + if outmatched {
                        0.0
                    } else {
                        hits.min(12.0) * (reach * 0.08)
                    }
            } else {
                if growth
                    && distance > reach + speed * 2.5 + 1.0
                    && tracked != Some(target.body.instance_id())
                {
                    continue;
                }
                distance
            };
            if distance <= eye_range {
                candidates.push((score, target));
            }
        }
        candidates.sort_by(|a, b| a.0.total_cmp(&b.0));
        let (_, target) = candidates.into_iter().find(|(_, target)| {
            tracked == Some(target.body.instance_id())
                || sight.sees_at(target.position, target.size.height)
        })?;
        // Every confirmed sighting refreshes the short-term memory the search
        // intent later walks back to.
        actor.memory.note_seen(target.position);
        Some((target, true, sight))
    }

    fn ai_at_current_cap(&self, actor: &Giant) -> bool {
        at_current_growth_cap(actor.scale, self.max_height, actor.growth_limit)
    }

    fn ai_attacks_scenery(&self, actor: &Giant) -> bool {
        self.can_demolish(actor) && self.mode != Mode::Brawl && !self.ai_at_current_cap(actor)
    }

    fn pursue(&mut self, actor: &mut Giant, speed: f32, dt: f32) -> Vector3 {
        self.refresh_damage_targets(actor);
        if actor.human {
            // Humans only forage for coins. They cannot start a fight, so they never chase one,
            // but a projected footfall underfoot still outranks any coin.
            actor.chase_target = None;
            actor.building_target = None;
            let position = actor.body.get_global_position();
            let radius = self.actor_radius(actor);
            let mut warnings: Vec<(Vector3, f32)> = Vec::new();
            let mut immediate = false;
            for rival in &self.rivals {
                if rival.index == actor.index {
                    continue;
                }
                if let Some(step) = &rival.footfall {
                    let clearance = radius + step.sole.half_extents.x * 0.28;
                    warnings.push((step.sole.center, step.sole.bounds() + clearance));
                    immediate |= step.threatens(position, clearance);
                }
                if let Some((center, sit_radius)) = rival.sit_drop {
                    let reach = sit_radius + radius;
                    warnings.push((center, reach + 0.6));
                    if horizontal(center - position).length() <= reach {
                        immediate = true;
                    }
                }
            }
            for &(_, center, hazard_radius) in &self.hazard_warnings {
                let reach = hazard_radius + radius;
                warnings.push((center, reach + 1.5));
                if horizontal(center - position).length() <= reach {
                    immediate = true;
                }
            }
            if immediate {
                actor.danger_note_in -= dt;
                if actor.danger_note_in <= 0.0
                    && let Some(&(center, reach)) = warnings.first()
                {
                    actor.danger_note_in = 1.0;
                    actor.memory.note_danger(center, reach);
                }
                actor.intent = Intent::Evade;
                return self.drive_escape(actor, position, &warnings, false, dt);
            }
            actor.intent = Intent::Forage;
            return self.forage(actor, speed, dt);
        }
        let position = actor.body.get_global_position();
        let scale = actor.scale;
        let can_demolish = self.can_demolish(actor);
        let attacks_scenery = self.ai_attacks_scenery(actor);
        let crush_buildings = self.can_crush_buildings(actor);
        let roam_crush = !attacks_scenery && crush_buildings;
        let my_height = actor.height(self.max_height);
        let radius = GIANT_RADIUS * scale;

        // Telegraphed danger first: standing inside any projected footfall or sit
        // drop warning circle overrides every scored intent (utility 100+).
        let mut warnings: Vec<(Vector3, f32)> = Vec::new();
        let mut immediate = false;
        for rival in &self.rivals {
            if rival.index == actor.index {
                continue;
            }
            if let Some(step) = &rival.footfall {
                let clearance = radius + step.sole.half_extents.x * 0.28;
                warnings.push((step.sole.center, step.sole.bounds() + clearance));
                immediate |= step.threatens(position, clearance);
            }
            if let Some((center, sit_radius)) = rival.sit_drop {
                let reach = sit_radius + radius;
                warnings.push((center, reach + 1.0));
                if horizontal(center - position).length() <= reach {
                    immediate = true;
                }
            }
        }
        for &(_, center, hazard_radius) in &self.hazard_warnings {
            let reach = hazard_radius + radius;
            warnings.push((center, reach + 2.0));
            if horizontal(center - position).length() <= reach {
                immediate = true;
            }
        }
        if immediate {
            // The first frame of a fresh escape records the danger zone so the
            // actor keeps clear of this fight for the next ~13 s.
            if actor.escape_yaw.is_none()
                && let Some(&(center, reach)) = warnings.first()
            {
                actor.memory.note_danger(center, reach);
            }
            actor.intent = Intent::Evade;
            actor.intent_in = UTILITY_INTERVAL;
            return self.drive_escape(actor, position, &warnings, roam_crush, dt);
        }

        let target = self.combat_target(actor, speed, dt);
        let chosen = target
            .as_ref()
            .map(|(target, _, _)| target.body.instance_id());
        if actor.chase_target != chosen {
            actor.chase_target = chosen;
            actor.chase_hidden_for = 0.0;
            actor.blocking_target = None;
            actor.replan_in = 0.0;
            actor.clear_path();
        }
        // Relative-size tier versus the tracked enemy. The ±10 % hysteresis in
        // `from_ratio_with_hysteresis` keeps edge ratios from flickering between
        // two behaviors every time the pair breathes across a boundary.
        let tier = match (&target, chosen) {
            (Some((target, _, _)), Some(id)) => {
                let ratio = target.size.height / my_height;
                let previous = actor
                    .size_tier
                    .filter(|&(previous_id, _)| previous_id == id)
                    .map(|(_, tier)| tier);
                let tier = SizeTier::from_ratio_with_hysteresis(ratio, previous);
                actor.size_tier = Some((id, tier));
                tier
            }
            _ => {
                actor.size_tier = None;
                SizeTier::Peer
            }
        };

        // Threats that steer the 360° escape: warning circles plus every rival
        // the size matrix says to keep away from.
        let mut threats = warnings.clone();
        for rival in &self.rivals {
            if rival.index == actor.index || rival.human {
                continue;
            }
            let ratio = rival.scale / scale;
            let reach = footfall_reach(rival.scale) + radius + 2.0;
            if horizontal(rival.position - position).length() > reach * 1.6 {
                continue;
            }
            let keep_away = match SizeTier::from_ratio(ratio) {
                SizeTier::Danger | SizeTier::Overwhelming => true,
                SizeTier::Uphill => !ambush_uphill(
                    scale,
                    actor.health_fraction,
                    rival.scale,
                    rival.health_fraction,
                    actor.personality.risk01(),
                ),
                // A badly wounded equal peer is still a fight to walk away from.
                SizeTier::Peer => {
                    rival.scale * rival.health_fraction > scale * actor.health_fraction * 1.5
                }
                _ => false,
            };
            if keep_away {
                threats.push((rival.position, reach));
            }
        }

        let forage_for_coin = chosen.is_none()
            && self.mode == Mode::Brawl
            && self.has_nearby_brawl_coin(actor, position);

        // Utility re-evaluation every ~0.25 s. Between ticks the current intent
        // keeps executing; the +13 inertia bonus inside the scorer damps flicker.
        actor.intent_in -= dt;
        if actor.intent_in <= 0.0 {
            actor.intent_in = UTILITY_INTERVAL + 0.04 * ((actor.index % 7) as f32);
            let visible = target
                .as_ref()
                .map(|(_, visible, _)| *visible)
                .unwrap_or(false);
            actor.intent = self.score_intents(
                actor,
                position,
                target.as_ref().map(|(target, _, _)| target),
                visible,
                tier,
                chosen,
                &threats,
            );
        }
        if actor.intent == Intent::Evade {
            actor.building_target = None;
            return self.drive_escape(actor, position, &threats, roam_crush, dt);
        }
        if chosen.is_some() || !attacks_scenery || actor.intent != Intent::Demolish {
            actor.building_target = None;
            if !attacks_scenery {
                actor.blocking_target = None;
            }
        } else {
            // Destructive personalities prefer the tall landmarks.
            self.choose_building(
                actor,
                position,
                actor.personality.destructiveness01() > 0.6,
            );
        }
        let mut chase_goal = None;
        if let Some((mut target, visible, mut sight)) = target {
            let present = target.body.get_global_position();
            let offset = horizontal(present - position);
            let lead = actor.footfall.as_ref().map_or(0.25, |step| step.eta).clamp(0.0, 0.65);
            let target_radius = target.size.radius;
            let lead_cap = footfall_lead_cap(
                target.rival.map(|(target_scale, _)| target_scale),
                self.settings.human_speed,
                self.settings.giant_speed,
            );
            let lead_range = footfall_reach(scale) + target_radius + lead_cap * lead;
            let predicted = if visible && offset.length_squared() <= lead_range.powi(2) {
                let predicted = predict_footfall_target(&mut target.body, present, lead, lead_cap);
                if predicted == present || sight.sees_at(predicted, target.size.height) {
                    predicted
                } else {
                    present
                }
            } else {
                present
            };
            let approaching = actor.footfall.as_ref()
                .is_some_and(|step| step.threatens(predicted, target_radius));
            if visible && self.mode != Mode::Human
                && self.start_ai_hand_move(actor, &target, approaching)
            {
                return Vector3::ZERO;
            }
            // Trivial targets get incidental footfalls only. Pursued prey is
            // intercepted ahead of its current velocity, offset to put an
            // alternating shoe, rather than the gap between the feet, on course.
            if actor.intent == Intent::Attack && (tier.chases() || target.rival.is_none()) {
                let heading = offset.normalized_or_zero();
                let side = actor.footfall.as_ref().map_or_else(
                    || actor.last_footfall.as_ref().map_or(1.0, |sole| if sole.left { -1.0 } else { 1.0 }),
                    |step| if step.sole.left { 1.0 } else { -1.0 },
                );
                let heel_alignment = if offset.length() <= lead_range {
                    heading.cross(Vector3::UP) * (1.3 * scale * side)
                } else {
                    Vector3::ZERO
                };
                chase_goal = Some(predicted + heel_alignment);
            } else if actor.intent == Intent::Attack && tier == SizeTier::Peer
                && target.rival.is_some()
            {
                let side = if actor.index % 2 == 0 { 0.45 } else { -0.45 };
                chase_goal = Some(predicted + offset.normalized_or_zero().rotated(Vector3::UP, side) * offset.length().min(18.0));
            }
        }
        if forage_for_coin || (!can_demolish && chase_goal.is_none()) {
            return self.forage(actor, speed, dt);
        }
        if !can_demolish
            && let Some(goal) = chase_goal
            && self.clear_ground_path(position, goal, GIANT_RADIUS * scale, false)
        {
            return horizontal(goal - position).normalized_or_zero();
        }

        let building = actor
            .building_target
            .map(|index| self.targets[index].footprint);
        let blocker = actor
            .blocking_target
            .map(|index| self.targets[index].footprint);
        if let Some(target) = blocker.or(building).filter(|_| attacks_scenery && chase_goal.is_none()) {
            if crush_buildings {
                return horizontal(target.transform.origin - position).normalized_or_zero();
            }
            let surface = closest_surface_point(target, position);
            let approach_range = (actor.height(self.max_height) * 0.34)
                .max(footfall_reach(scale) * 1.15)
                .max(GIANT_RADIUS * scale * 1.15);
            if horizontal(surface - position).length() <= approach_range {
                // Approach and face the nearest intact facade for Punch / GrabCrush / SitCrush.
                return horizontal(surface - position).normalized_or_zero();
            }
        }

        let goal = if let Some(goal) = chase_goal {
            actor.roam_goal = None;
            goal
        } else if actor.intent == Intent::Search
            && let Some(goal) = actor
                .memory
                .hit_from
                .map(|(at, _)| at)
                .or(actor.memory.last_seen.map(|(at, _)| at))
        {
            // Search the last sighting locally for the remaining memory TTL
            // (4–8 s). Sight checks still apply during the walk — no wall-hack.
            actor.roam_goal = None;
            goal
        } else if let Some(footprint) = building {
            actor.roam_goal = None;
            if crush_buildings {
                footprint.transform.origin
            } else {
                closest_surface_point(footprint, position)
            }
        } else {
            self.wander_goal(actor, position, GIANT_RADIUS * scale, speed)
        };
        if crush_buildings
            && blocker.is_none()
            && (!roam_crush
                || self.clear_ground_path(position, goal, GIANT_RADIUS * scale, roam_crush))
        {
            return horizontal(goal - position).normalized_or_zero();
        }

        actor.replan_in -= dt;
        if actor.replan_in <= 0.0 {
            actor.replan_in = 0.42;
            self.request_route(actor, position, goal, GIANT_RADIUS * scale, roam_crush);
        }

        // Smooth waypoint consumption avoids jerky 90-degree grid zigzags.
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
        horizontal(next - position).normalized_or_zero()
    }

    /// Scores the five intents 0–100 and keeps the current one with a +13
    /// inertia bonus so re-evaluations every ~0.25 s do not twitch the body.
    #[allow(clippy::too_many_arguments)]
    fn score_intents(
        &self,
        actor: &Giant,
        position: Vector3,
        target: Option<&CombatTarget>,
        target_visible: bool,
        tier: SizeTier,
        chosen: Option<InstanceId>,
        threats: &[(Vector3, f32)],
    ) -> Intent {
        let personality = actor.personality;
        let attacks_scenery = self.ai_attacks_scenery(actor);
        let can_demolish = self.can_demolish(actor);

        // --- Evade: size pressure from rivals the matrix says to keep away from,
        // scaled by the survival drive and the remaining health. ---
        let mut size_pressure: f32 = 0.0;
        for rival in &self.rivals {
            if rival.index == actor.index || rival.human {
                continue;
            }
            let ratio = rival.scale / actor.scale;
            let reach = footfall_reach(rival.scale)
                + GIANT_RADIUS * actor.scale
                + 2.0;
            if horizontal(rival.position - position).length() > reach {
                continue;
            }
            let pressure = match SizeTier::from_ratio(ratio) {
                SizeTier::Overwhelming => 1.0,
                SizeTier::Danger => 0.7,
                SizeTier::Uphill => {
                    if ambush_uphill(
                        actor.scale,
                        actor.health_fraction,
                        rival.scale,
                        rival.health_fraction,
                        personality.risk01(),
                    ) {
                        continue;
                    }
                    0.45
                }
                SizeTier::Peer
                    if rival.scale * rival.health_fraction
                        > actor.scale * actor.health_fraction * 1.5 =>
                {
                    0.4
                }
                _ => continue,
            };
            size_pressure = size_pressure.max(pressure * ((ratio - 1.0) / 4.0).clamp(0.3, 1.0));
        }
        let near_warning = threats
            .iter()
            .any(|&(at, reach)| horizontal(at - position).length() <= reach * 1.5);
        let mut evade = threat_evasion_score(
            size_pressure,
            1.0 - actor.health_fraction,
            personality.survival01(),
        );
        if near_warning {
            evade = (evade + 35.0).min(100.0);
        }

        // --- Attack: tier base score shaped by aggression, grudges and wounds. ---
        let grudge = actor.memory.grudge.map(|(id, _)| id);
        let mut attack = 0.0;
        if target_visible && let Some(target) = target {
            let base = if target.rival.is_none() {
                // Humans and pedestrians are prey by design once they pass the
                // human-ignore gate: hunting them always outranks demolishing.
                100.0
            } else {
                match tier {
                    SizeTier::Trivial => 12.0,
                    SizeTier::Prey => 55.0,
                    SizeTier::Pushover => 65.0,
                    SizeTier::Peer => 48.0,
                    SizeTier::Uphill => 34.0,
                    SizeTier::Danger | SizeTier::Overwhelming => 0.0,
                }
            };
            if base > 0.0 {
                let agg_weight = if target.rival.is_none() {
                    0.85 + 0.15 * personality.aggression01()
                } else {
                    0.45 + 0.55 * personality.aggression01()
                };
                attack = base * agg_weight;
                if chosen.is_some_and(|id| grudge == Some(id)) {
                    attack += personality.vengeance01() * 22.0;
                }
                if let Some((_, enemy_health)) = target.rival {
                    attack += (1.0 - enemy_health) * 18.0;
                }
                // Attack in the gap between the opponent's pending footfalls.
                let approaching_footfall = chosen.is_some_and(|id| {
                    self.rivals
                        .iter()
                        .any(|rival| rival.body.instance_id() == id && rival.footfall.is_some())
                });
                if !approaching_footfall {
                    attack += 10.0;
                }
                attack = attack.min(100.0);
            }
        }

        // --- Forage: only brawl giants actively hunt dropped coins. ---
        let mut forage = 0.0;
        if self.mode == Mode::Brawl && self.has_nearby_brawl_coin(actor, position) {
            forage = 42.0 * (0.5 + 0.5 * personality.growth01());
        }

        // --- Search: the enemy is out of sight but still inside short-term
        // memory. A distant last-sighting is barely worth the walk, so the
        // score falls off with the distance to it — a far deserter yields to
        // nearby development, a close escape stays hot. ---
        let mut search = 0.0;
        if chosen.is_none()
            && let Some(goal) = actor
                .memory
                .hit_from
                .map(|(at, _)| at)
                .or(actor.memory.last_seen.map(|(at, _)| at))
        {
            let reach = horizontal(goal - position).length();
            let falloff = 60.0 / (60.0 + reach);
            search = 40.0 * (0.45 + 0.55 * personality.aggression01()) * falloff;
        }

        // --- Demolish: development drive against nearby building density. ---
        let mut demolish = 0.0;
        if attacks_scenery && can_demolish {
            demolish = demolition_score(
                personality.growth01(),
                personality.destructiveness01(),
                self.demolishable_density(position),
            );
        }

        let score_of = |intent: Intent| match intent {
            Intent::Evade => evade,
            Intent::Attack => attack,
            Intent::Forage => forage,
            Intent::Search => search,
            Intent::Demolish => demolish,
        };
        [
            Intent::Evade,
            Intent::Demolish,
            Intent::Forage,
            Intent::Search,
            Intent::Attack,
        ]
        .into_iter()
        .map(|intent| {
            (
                intent,
                score_of(intent)
                    + if intent == actor.intent {
                        INTENT_INERTIA
                    } else {
                        0.0
                    },
            )
        })
        .max_by(|a, b| a.1.total_cmp(&b.1))
        .map(|(intent, _)| intent)
        .unwrap_or(Intent::Demolish)
    }

    /// Standing demolishable buildings within 120 m, normalized to 0–1.
    fn demolishable_density(&self, position: Vector3) -> f32 {
        let count = self
            .target_grid
            .near(position, 120.0)
            .filter(|&index| {
                let target = &self.targets[index];
                target.footprint.building && target.integrity.blocks()
            })
            .count();
        (count as f32 / 6.0).min(1.0)
    }

    /// Scores 16 candidate headings and returns the best escape direction. A
    /// heading that makes no progress for ~0.45 s is blacklisted for 3–5 s so
    /// the scorer rotates to a fresh tangent instead of grinding into the wall.
    fn drive_escape(
        &mut self,
        actor: &mut Giant,
        position: Vector3,
        threats: &[(Vector3, f32)],
        roam_crush: bool,
        dt: f32,
    ) -> Vector3 {
        let radius = self.actor_radius(actor);
        let heading = actor.body.get_rotation().y;
        let blocked = |probe: Vector3| !self.clear_ground_path(position, probe, radius, roam_crush);
        let direction = escape_direction(
            position,
            radius,
            threats,
            self.world_limit,
            heading,
            blocked,
            |yaw| actor.memory.escape_blocked(yaw),
        );
        let yaw = (-direction.x).atan2(-direction.z);
        let same_heading = actor
            .escape_yaw
            .is_some_and(|previous| ai::yaw_difference(yaw, previous).abs() < 0.4);
        if same_heading {
            actor.escape_elapsed += dt;
            let moved = horizontal(position - actor.escape_origin).length();
            if actor.escape_elapsed > 0.45 && moved < radius.max(1.0) * 0.4 {
                actor.memory.note_failed_escape(yaw);
                actor.escape_yaw = None;
                actor.escape_elapsed = 0.0;
            }
        } else {
            actor.escape_yaw = Some(yaw);
            actor.escape_origin = position;
            actor.escape_elapsed = 0.0;
        }
        direction
    }

    /// Draws the blocking footprints for one route and plans it. Kept separate from the
    /// actor update so the queue can call it without holding a mutable actor borrow.
    fn plan_route(
        &self,
        from: Vector3,
        goal: Vector3,
        radius: f32,
        crush_buildings: bool,
    ) -> Vec<Vector3> {
        let mid = (from + goal) * 0.5;
        let reach = horizontal(from - goal).length() * 0.5 + 70.0;
        let obstacles: Vec<_> = self
            .target_grid
            .near(mid, reach)
            .map(|index| &self.targets[index])
            .filter(|target| {
                target.integrity.blocks() && (!crush_buildings || !target.footprint.building)
            })
            .map(|target| target.footprint)
            .collect();
        route::plan(from, goal, &obstacles, radius, self.world_limit)
    }

    /// Queues an AI route instead of planning it inside the actor update. At sixty actors
    /// the requests would otherwise all run in the same physics frame and stall it.
    fn request_route(
        &mut self,
        actor: &mut Giant,
        from: Vector3,
        goal: Vector3,
        radius: f32,
        crush_buildings: bool,
    ) {
        let Ok(slot) = usize::try_from(actor.index) else {
            return;
        };
        if slot >= self.path_requests.len() {
            return;
        }
        self.path_serial = self.path_serial.wrapping_add(1).max(1);
        actor.pending_path = self.path_serial;
        self.path_requests[slot] = Some(PathRequest {
            serial: self.path_serial,
            from,
            goal,
            radius,
            crush_buildings,
        });
    }

    /// Plans a few deferred routes per frame in round-robin actor order. A request is only
    /// applied while its serial still owns the actor's path, so a cleared route or a newer
    /// request is never overwritten by an older plan.
    fn process_path_requests(&mut self) {
        let count = self.path_requests.len().min(self.giants.len());
        if count == 0 {
            return;
        }
        let begin = Instant::now();
        let mut served = 0;
        let mut examined = 0;
        while served < PATH_PLANS_PER_FRAME && examined < count {
            let index = self.path_cursor % count;
            self.path_cursor = (self.path_cursor + 1) % count;
            examined += 1;
            let Some(request) = self.path_requests[index].take() else {
                continue;
            };
            let Some(actor) = self.giants.get(index) else {
                continue;
            };
            if actor.health_fraction <= 0.0
                || actor.grabbed
                || actor.pending_path != request.serial
            {
                continue;
            }
            let path = self.plan_route(
                request.from,
                request.goal,
                request.radius,
                request.crush_buildings,
            );
            if let Some(actor) = self.giants.get_mut(index)
                && actor.pending_path == request.serial
            {
                actor.path = path;
                actor.pending_path = 0;
            }
            served += 1;
            if begin.elapsed().as_secs_f32() >= PATH_TIME_BUDGET {
                break;
            }
        }
    }

    fn choose_building(&self, actor: &mut Giant, position: Vector3, prefer_tall: bool) {
        if actor.building_target.is_some() {
            return;
        }
        let distance = |index: usize| {
            horizontal(closest_surface_point(self.targets[index].footprint, position) - position)
                .length_squared()
        };
        let standing = |index: usize| {
            let target = &self.targets[index];
            target.footprint.building && target.integrity.blocks()
        };
        // Everyone picks the nearest standing block; destructive personalities
        // break toward the tallest landmark, but only within a short walk of
        // the nearest building so the pick never turns into a cross-city hike.
        let height = |index: usize| self.targets[index].footprint.size.y;
        let pick = |pool: &[usize]| -> Option<usize> {
            let nearest = pool.iter().map(|&i| distance(i)).fold(f32::INFINITY, f32::min);
            if prefer_tall {
                // Destructive personalities lean toward the tallest nearby
                // landmark, but only among buildings that are effectively
                // side by side with the nearest one — a clear nearest pick is
                // never traded for a distant tower.
                pool.iter()
                    .filter(|&&i| distance(i).sqrt() <= nearest.sqrt() + 6.0)
                    .filter(|&&i| height(i) >= pool.iter().map(|&j| height(j)).fold(0.0_f32, f32::max) - 1e-4)
                    .max_by(|&&a, &&b| {
                        height(a)
                            .total_cmp(&height(b))
                            .then_with(|| distance(a).total_cmp(&distance(b)))
                    })
                    .copied()
            } else {
                pool.iter()
                    .min_by(|&&a, &&b| {
                        distance(a).total_cmp(&distance(b)).then(a.cmp(&b))
                    })
                    .copied()
            }
        };
        let local_range = 48.0;
        let local_pool: Vec<usize> = self
            .target_grid
            .near(position, local_range)
            .filter(|&i| standing(i) && distance(i) <= local_range * local_range)
            .collect();
        let global_pool: Vec<usize> = (0..self.targets.len())
            .filter(|&i| standing(i))
            .collect();
        actor.building_target =
            pick(&local_pool).or_else(|| pick(&global_pool));
        if actor.building_target.is_some() {
            actor.replan_in = 0.0;
        }
    }

    /// Goal for an AI giant with nothing to chase or smash. It picks a reachable point a few
    /// seconds of walking away and re-rolls once there, so an idle giant keeps exploring the
    /// harbour instead of standing still. The span follows the body and the stride, and every
    /// candidate has to stay inside the sea wall.
    fn wander_goal(&self, actor: &mut Giant, position: Vector3, radius: f32, speed: f32) -> Vector3 {
        let span = (radius * 4.0).max(speed * 8.0).clamp(0.5, 320.0);
        let stale = actor.roam_goal.is_none_or(|goal| {
            let distance = horizontal(goal - position).length();
            distance < span * 0.35 || distance > span * 2.5
        });
        if stale {
            let roam_without_scenery = !self.ai_attacks_scenery(actor);
            let roam_crush = roam_without_scenery && self.can_crush_buildings(actor);
            let forward = Vector3::FORWARD.rotated(Vector3::UP, actor.body.get_rotation().y);
            let limit = (self.world_limit - radius).max(0.0);
            let inside_wall = |goal: Vector3| goal.x.abs().max(goal.z.abs()) < limit;
            actor.replan_in = 0.0;
            // Prefer forward-sector patrol goals (+/- ~68 deg) when moving freely in open space
            // so roaming giants follow natural continuous arcs instead of reversing 180 deg.
            // If currently blocked by a wall, search all directions immediately to turn clear.
            let prefer_forward = !actor.body.is_on_wall();
            actor.roam_goal = if prefer_forward {
                (0..6)
                    .find_map(|_| {
                        let goal = self.random_spawn(position, span * 0.6, span * 1.8)?;
                        let dir = horizontal(goal - position).normalized_or_zero();
                        (forward.dot(dir) >= 0.36
                            && self.clear_ground_path(position, goal, radius, roam_crush))
                        .then_some(goal)
                    })
                    .or_else(|| {
                        (0..10).find_map(|_| {
                            let angle = random_range(-1.18, 1.18);
                            let goal = position
                                + forward.rotated(Vector3::UP, angle)
                                    * span
                                    * random_range(0.6, 1.4);
                            (inside_wall(goal)
                                && self.clear_ground_path(position, goal, radius, roam_crush))
                            .then_some(goal)
                        })
                    })
            } else {
                None
            }
            .or_else(|| {
                self.random_spawn(position, span * 0.6, span * 1.8)
                    .filter(|goal| self.clear_ground_path(position, *goal, radius, roam_crush))
            })
                .or_else(|| {
                    (0..12).find_map(|_| {
                        let goal = position + random_heading() * span * random_range(0.5, 1.4);
                        (inside_wall(goal)
                            && self.clear_ground_path(position, goal, radius, roam_crush))
                        .then_some(goal)
                    })
                })
                .or_else(|| {
                    if roam_without_scenery {
                        // At a tight corner the clearance probe can reject every long stride.
                        // Let physics try a new heading when walking into a wall invalidates it.
                        let goal = position + random_heading() * span;
                        return Some(Vector3::new(
                            goal.x.clamp(-limit, limit),
                            position.y,
                            goal.z.clamp(-limit, limit),
                        ));
                    }
                    // The harbour is walled, so heading for the middle always stays inside it.
                    let inward = horizontal(-position).normalized_or_zero();
                    let direction = if inward == Vector3::ZERO {
                        random_heading()
                    } else {
                        inward
                    };
                    Some(position + direction * span)
                });
        }
        actor.roam_goal.unwrap_or(position)
    }

    fn resolve_footfall(&mut self, actor: &mut Giant, sole: Footfall) {
        actor.footfall_count += 1;
        actor.last_footfall = Some(sole.clone());
        let height = actor.height(self.max_height);
        self.note_hotspot(sole.center, (sole.bounds() * 2.0).max(height * 0.5).max(3.0));
        self.queue_giant_impact(actor, sole.center, GroundImpact::Footfall);
        self.effects.as_mut().unwrap().call(
            "footfall_effect",
            &[
                sole.center.to_variant(),
                sole.yaw.to_variant(),
                sole.half_extents.to_variant(),
                sole.left.to_variant(),
                height.to_variant(),
                (actor.index == 0 && self.player == PlayerRole::Giant).to_variant(),
                sole.profile.to_variant(),
            ],
        );
        self.apply_ground_strike(actor, StrikeArea::Sole(sole), DefeatMethod::Step);
    }

    fn impact(&mut self, actor: &mut Giant, area: ImpactArea, method: DefeatMethod) {
        let height = actor.height(self.max_height);
        self.note_hotspot(area.center, (area.radii.length() * 2.0).max(16.0).max(height * 0.6));
        if let Some(mut audio) = self.audio() {
            audio.call(
                "play_giant_impact",
                &[
                    area.center.to_variant(),
                    height.to_variant(),
                    (actor.index == 0 && self.player == PlayerRole::Giant).to_variant(),
                ],
            );
        }
        self.queue_giant_impact(actor, area.center, GroundImpact::Sit);
        let shattered = self.apply_ground_strike(actor, StrikeArea::Ellipse(area), method);
        self.show_impact(area, shattered, true, actor.scale.min(1.0));
    }

    fn apply_ground_strike(&mut self, actor: &mut Giant, area: StrikeArea, method: DefeatMethod) -> bool {
        let height = actor.height(self.max_height);
        let center = area.center();
        let giant_damage = self.growth_stat(actor, self.combat_rules().base_attack);
        let crush_buildings = method == DefeatMethod::Step && self.can_crush_buildings(actor);
        let can_demolish = self.can_demolish(actor);
        self.giant_strikes.push(GiantStrike {
            attacker: actor.index as usize,
            area: area.clone(),
            damage: giant_damage,
            height,
            method,
        });
        // Every target in the same impact uses the upgrade state at its start.
        let growth = self.growth_rules.is_some();
        let damage = if growth { giant_damage } else { 1.0 };
        let one_hit_buildings = !growth && actor.progress.one_hit_buildings();
        let building_damage = if growth {
            GROWTH_BUILDING_INTEGRITY / growth_building_hits(height) as f32
        } else {
            damage
        };
        self.strike += 1;
        let rebuild_at = self.building_rebuild_time();
        let mut shattered = false;
        for index in self.target_grid.near(center, area.bounds()).filter(|_| can_demolish) {
            let target = &mut self.targets[index];
            if target.grabbed || !target.integrity.blocks() || !area.touches(target.footprint) {
                continue;
            }
            // Before touch-crush unlocks, walking footsteps cannot damage buildings;
            // demolition requires active Punch / GrabCrush / SitCrush attacks.
            if target.footprint.building && method == DefeatMethod::Step && !crush_buildings {
                continue;
            }
            let destroy_on_hit = (one_hit_buildings || crush_buildings) && target.footprint.building;
            let target_damage = if target.footprint.building {
                building_damage
            } else if growth {
                3000.0
            } else {
                damage
            };
            match target
                .integrity
                .hit(self.strike, target_damage, destroy_on_hit)
            {
                Damage::Ignored => {}
                Damage::Cracked => {
                    target.node.call("strike", &[false.to_variant()]);
                }
                Damage::Destroyed => {
                    let rebuild = rebuild_at.filter(|_| target.footprint.building);
                    let passed_by = if crush_buildings { actor.body.to_variant() } else { Variant::nil() };
                    let rubble = target.node.call(
                        "strike",
                        &[
                            true.to_variant(),
                            passed_by,
                            rebuild.is_some().to_variant(),
                        ],
                    );
                    if crush_buildings && let Ok(body) = rubble.try_to::<Gd<StaticBody3D>>() {
                        actor.rubble_passes.push((target.footprint, body));
                    }
                    shattered = true;
                    if target.footprint.building {
                        if let Some(deadline) = rebuild {
                            self.building_respawns.push((index, deadline));
                        }
                        actor.progress.destroyed += 1;
                        self.destroyed_buildings += 1;
                        self.reward_building_growth(actor);
                    }
                    actor.replan_in = 0.0;
                }
            }
        }
        let sole_tolerance = (height * 0.04).clamp(0.003, 0.25);
        let in_vertical_range = |floor: f32, target_height: f32| {
            let reach = if method == DefeatMethod::Step { sole_tolerance } else { height };
            floor <= center.y + reach && floor + target_height >= center.y - sole_tolerance
        };
        for npc in &mut self.civilians {
            if npc.remove_in.is_some() || npc.grabbed {
                continue;
            }
            let point = npc.body.get_global_position();
            if in_vertical_range(point.y, npc.size.height) && area.reaches(point, npc.size.radius) {
                npc.hurt(damage, self.growth_rules.is_none());
            }
        }
        let mut evacuee_hurt = false;
        if self.player == PlayerRole::Evacuee
            && self.state.outcome == Outcome::Active
            && let Some(human) = &mut self.human
        {
            let position = human.get_global_position();
            if in_vertical_range(position.y, HUMAN_HEIGHT) && area.reaches(position, HUMAN_RADIUS) {
                self.state.hurt();
                if self.state.outcome == Outcome::Lost {
                    human.call("show_fall", &[]);
                } else {
                    evacuee_hurt = true;
                }
            }
        }
        if evacuee_hurt {
            self.play_audio_2d("human_hurt", -1.5, 1.0, 0.04);
        }
        if shattered {
            self.refresh_damage_targets(actor);
        }
        shattered
    }

    fn show_impact(&mut self, area: ImpactArea, shattered: bool, heavy: bool, height_scale: f32) {
        self.effects.as_mut().unwrap().call(
            "impact",
            &[
                area.center.to_variant(),
                area.yaw.to_variant(),
                area.radii.to_variant(),
                shattered.to_variant(),
                heavy.to_variant(),
                height_scale.to_variant(),
            ],
        );
    }

    fn can_crush_buildings(&self, actor: &Giant) -> bool {
        if self.growth_rules.is_some() {
            self.can_demolish(actor) && actor.scale >= GROWTH_CRUSH_HEIGHT / GIANT_START_HEIGHT
        } else {
            actor.progress.touch_crush_buildings()
        }
    }

    fn refresh_damage_targets(&self, actor: &mut Giant) {
        if actor
            .building_target
            .is_some_and(|index| !self.targets[index].integrity.blocks())
        {
            actor.building_target = None;
            actor.replan_in = 0.0;
        }
        if actor
            .blocking_target
            .is_some_and(|index| !self.targets[index].integrity.blocks())
        {
            actor.blocking_target = None;
            actor.replan_in = 0.0;
        }
    }

    fn crush_touched_buildings(&mut self, actor: &mut Giant, position: Vector3) {
        if !self.can_crush_buildings(actor) || !self.can_demolish(actor) {
            return;
        }
        let radius = GIANT_RADIUS * actor.scale;
        let rebuild_at = self.building_rebuild_time();
        let mut any = false;
        let indices: Vec<usize> = self
            .target_grid
            .near(position, radius)
            .filter(|&index| {
                let target = &self.targets[index];
                target.footprint.building
                    && !target.grabbed
                    && target.integrity.blocks()
                    && target.footprint.touches(position, radius)
            })
            .collect();
        for index in indices {
            self.strike += 1;
            let rebuild = rebuild_at.is_some();
            let target = &mut self.targets[index];
            match target.integrity.hit(self.strike, f32::INFINITY, true) {
                Damage::Destroyed => {
                    let rubble = target.node.call(
                        "strike",
                        &[
                            true.to_variant(),
                            actor.body.to_variant(),
                            rebuild.to_variant(),
                        ],
                    );
                    if let Ok(body) = rubble.try_to::<Gd<StaticBody3D>>() {
                        actor.rubble_passes.push((target.footprint, body));
                    }
                    if let Some(deadline) = rebuild_at {
                        self.building_respawns.push((index, deadline));
                    }
                    actor.progress.destroyed += 1;
                    self.destroyed_buildings += 1;
                    self.reward_building_growth(actor);
                    any = true;
                }
                Damage::Ignored | Damage::Cracked => {}
            }
        }
        if any {
            actor.replan_in = 0.0;
            self.refresh_damage_targets(actor);
            let area = ImpactArea {
                center: position,
                yaw: actor.body.get_rotation().y,
                radii: Vector2::splat(radius),
            };
            self.show_impact(area, true, true, actor.scale.min(1.0));
        }
    }
}

/// Maximum sustained speed used to extrapolate a footfall target. Rival giants can move
/// several times faster than a sprinting human once the giant speed multiplier is applied,
/// so their lead must not be capped by `HUMAN_SPRINT`.
/// Whether the smaller side takes the uphill fight anyway: its `scale × HP`
/// must approach the enemy's, and bold personalities need far less parity
/// (`1.2–2.0×` tier of the seven-step size matrix).
fn ambush_uphill(
    own_scale: f32,
    own_health: f32,
    enemy_scale: f32,
    enemy_health: f32,
    risk01: f32,
) -> bool {
    own_scale * own_health >= enemy_scale * enemy_health * (0.85 - risk01 * 0.45)
}

fn footfall_lead_cap(rival_scale: Option<f32>, human_speed: f32, giant_speed: f32) -> f32 {
    match rival_scale {
        Some(scale) => GIANT_WALK * giant_speed * giant_size_speed_factor(scale),
        None => HUMAN_SPRINT * human_speed,
    }
}

fn predict_footfall_target(
    body: &mut Gd<CharacterBody3D>,
    position: Vector3,
    lead: f32,
    speed_cap: f32,
) -> Vector3 {
    let velocity = horizontal(body.get_real_velocity());
    let speed = velocity.length();
    if speed < 0.05 {
        return position;
    }
    let motion = velocity * (lead * (speed_cap / speed).min(1.0));
    let transform = body.get_global_transform();
    let collision = KinematicCollision3D::new_gd();
    if body
        .test_move_ex(transform, motion)
        .collision(&collision)
        .done()
    {
        // Continue along the current line only as far as the capsule can travel.
        let fraction =
            (collision.get_travel().dot(motion) / motion.length_squared()).clamp(0.0, 1.0);
        position + motion * fraction
    } else {
        position + motion
    }
}

fn random_range(min: f64, max: f64) -> f32 {
    godot::global::randf_range(min, max) as f32
}

fn random_choice<T: Copy>(choices: &[T]) -> Option<T> {
    if choices.is_empty() {
        return None;
    }
    let index = godot::global::randi_range(0, choices.len() as i64 - 1);
    Some(choices[index as usize])
}

fn random_heading() -> Vector3 {
    Vector3::FORWARD.rotated(Vector3::UP, random_range(0.0, TAU as f64))
}

/// Refreshes the end-of-movement positions used by the contact pass. Health and grabbed
/// stay live because damage during the contact pass can eliminate a later pair.
fn sync_pair_frames(frames: &mut [PairFrame], giants: &[Giant]) {
    for (frame, giant) in frames.iter_mut().zip(giants) {
        frame.end = giant.body.get_global_position();
        frame.health = giant.health_fraction;
        frame.grabbed = giant.grabbed;
    }
}

fn face(body: &mut Gd<CharacterBody3D>, direction: Vector3, weight: f32) {
    let target_yaw = (-direction.x).atan2(-direction.z);
    let yaw = godot::global::lerp_angle(
        body.get_rotation().y as f64,
        target_yaw as f64,
        weight as f64,
    );
    body.set_rotation(Vector3::UP * yaw as f32);
}

fn drive(body: &mut Gd<CharacterBody3D>, direction: Vector3, speed: f32, dt: f32, turn_rate: f32) {
    let mut velocity = direction * speed;
    velocity.y = if body.is_on_floor() {
        -0.2
    } else {
        body.get_velocity().y - 24.0 * dt
    };
    body.set_velocity(velocity);
    if direction.length_squared() > 0.0001 {
        face(body, direction, (dt * turn_rate).min(1.0));
    }
    body.move_and_slide();
}

fn drive_giant(
    body: &mut Gd<CharacterBody3D>,
    yaw_vel: &mut f32,
    vel_xz: Vector3,
    direction: Vector3,
    dt: f32,
    scale: f32,
    pace: f32,
    human: bool,
) {
    let mut velocity = vel_xz;
    velocity.y = if body.is_on_floor() {
        // Fixed downward travel can be a large fraction of a centimeter giant every tick.
        -0.2 * (GIANT_START_HEIGHT * scale).min(1.0)
    } else {
        body.get_velocity().y - 24.0 * dt
    };
    body.set_velocity(velocity);
    if direction.length_squared() > 0.0001 {
        // Sublinear pace scaling keeps 1x turning identical while preventing 4x Growth/Brawl
        // giants from whipping around at 780 deg/s like spinning tops.
        let turn_pace = pace.max(0.1).sqrt().min(1.65);
        turn_giant_smooth(body, yaw_vel, direction, dt * turn_pace, scale, human);
    } else {
        *yaw_vel *= (1.0 - dt * 10.0).max(0.0);
        if yaw_vel.abs() < 0.01 {
            *yaw_vel = 0.0;
        }
    }
    body.move_and_slide();
}

/// Critically damped second-order yaw controller. Giants use a bounded car-like steering
/// limit (~30-45 deg/step, calmer at larger sizes) for smooth curved arcs without foot cross.
fn turn_giant_smooth(
    body: &mut Gd<CharacterBody3D>,
    yaw_vel: &mut f32,
    direction: Vector3,
    dt: f32,
    scale: f32,
    human: bool,
) {
    let current_yaw = body.get_rotation().y;
    let target_yaw = (-direction.x).atan2(-direction.z);
    let diff = godot::global::angle_difference(current_yaw as f64, target_yaw as f64) as f32;

    let (max_speed, stiffness, damping) = if human {
        let size_factor = scale.powf(-0.15).clamp(0.75, 1.0);
        (3.50 * size_factor, 26.0 * size_factor, 9.2 * size_factor.sqrt())
    } else {
        let size_factor = scale.powf(-0.28).clamp(0.45, 1.05);
        (0.90 * size_factor, 18.0 * size_factor, 7.6 * size_factor.sqrt())
    };

    let accel = diff * stiffness - *yaw_vel * damping;
    *yaw_vel = (*yaw_vel + accel * dt).clamp(-max_speed, max_speed);
    let step = *yaw_vel * dt;
    let next_yaw = if diff.abs() < 0.002 && yaw_vel.abs() < 0.02 {
        *yaw_vel = 0.0;
        target_yaw
    } else if step.abs() > diff.abs() && step.signum() == diff.signum() {
        *yaw_vel = 0.0;
        target_yaw
    } else {
        current_yaw + step
    };
    body.set_rotation(Vector3::UP * next_yaw);
}

fn closest_surface_point(footprint: Footprint, from: Vector3) -> Vector3 {
    let local = footprint.transform.affine_inverse() * from;
    let half = footprint.size * 0.5;
    let clamped = Vector3::new(
        local.x.clamp(-half.x, half.x),
        0.15,
        local.z.clamp(-half.z, half.z),
    );
    let mut world = footprint.transform * clamped;
    world.y = 0.15;
    world
}

fn horizontal(vector: Vector3) -> Vector3 {
    Vector3::new(vector.x, 0.0, vector.z)
}

fn ground_speed(body: &Gd<CharacterBody3D>) -> f32 {
    horizontal(body.get_real_velocity()).length()
}

/// True once an AI giant has reached either the round maximum height or its current
/// height-band ceiling, so it stops actively demolishing buildings and roams when idle.
fn at_current_growth_cap(scale: f32, max_height: f32, growth_limit: f32) -> bool {
    let cap_scale = (max_height / GIANT_START_HEIGHT).min(growth_limit);
    scale + 1e-5 >= cap_scale
}

fn desk_hazard_falloff(distance: f32, reach: f32) -> f32 {
    if reach <= 0.0 {
        return 0.0;
    }
    (1.0 - (distance / reach).clamp(0.0, 1.0)).clamp(0.0, 1.0)
}

fn desk_hazard_damage_fraction(distance: f32, reach: f32, base_fraction: f32) -> f32 {
    if distance > reach || base_fraction <= 0.0 {
        return 0.0;
    }
    let falloff = desk_hazard_falloff(distance, reach);
    // Core under the ~100 m fingertip pad crushes outright (>= 1.0x HP), while
    // units near the outer ~110 m rim take heavy crush damage + radial knockback.
    (base_fraction * (0.62 + 0.76 * falloff)).clamp(0.0, 2.0)
}

fn desk_hazard_camera_shake(distance: f32, impact_radius: f32) -> f32 {
    // 10 km ultra-giant impact shakes across the whole 1,418 m harbour, peaking
    // strongly near the strike zone and tapering to a deep rumble at the far rim.
    let norm = (distance / (impact_radius.max(30.0) * 4.5)).clamp(0.0, 1.0);
    1.55 * (1.0 - norm).powf(1.35) + 0.28
}

#[cfg(test)]
mod tests {
    use super::{
        GIANT_RADIUS, GIANT_START_HEIGHT, GroundImpact, InstanceId, PI, SIGHT_RANGE,
        Vector3, at_current_growth_cap, horizontal, ignores_human,
        rival_engage_range, sight_range, footfall_reach, footfall_lead_cap,
    };
    use crate::rules::HUMAN_SPRINT;

    fn rival_body(height: f32) -> (f32, f32, f32) {
        let scale = height / GIANT_START_HEIGHT;
        (
            scale,
            footfall_reach(scale),
            GIANT_RADIUS * scale,
        )
    }

    #[test]
    fn every_giant_height_can_still_target_a_touching_rival() {
        for height in [25.2, 55.0, 100.0, 200.0, 326.0, 400.0, 500.0, 1000.0] {
            let (scale, reach, body) = rival_body(height);
            for speed in [6.5, 26.0] {
                let engage = rival_engage_range(reach, speed, scale);
                assert!(
                    engage > 2.0 * body,
                    "{height} m giants cannot target a rival whose body is touching them"
                );
                assert!(engage >= reach, "{height} m giants cannot reach a rival at all");
                assert!(
                    sight_range(scale) >= engage,
                    "{height} m giants cannot see as far as they would engage"
                );
            }
        }
        // Small giants keep the original two-and-a-half second chase window.
        let (scale, reach, _) = rival_body(GIANT_START_HEIGHT);
        assert!((rival_engage_range(reach, 6.5, scale) - (reach + 16.25)).abs() < 1e-4);
        // The flat 75 m cap this replaced left touched 500 m pairs out of range.
        let (_, _, body) = rival_body(500.0);
        assert!(2.0 * body > 75.0);
    }

    #[test]
    fn rival_sight_keeps_pace_with_height() {
        assert_eq!(sight_range(1.0), SIGHT_RANGE);
        assert_eq!(sight_range(4.0), SIGHT_RANGE);
        for height in [200.0, 326.0, 500.0, 1000.0] {
            let scale = height / GIANT_START_HEIGHT;
            assert!(sight_range(scale) >= height - 0.001);
        }
    }

    #[test]
    fn footfall_lead_uses_the_target_kind_speed() {
        assert_eq!(footfall_lead_cap(None, 1.0, 4.0), HUMAN_SPRINT);
        assert_eq!(footfall_lead_cap(None, 2.0, 4.0), HUMAN_SPRINT * 2.0);
        assert_eq!(footfall_lead_cap(Some(1.0), 1.0, 4.0), 28.0);
        assert_eq!(footfall_lead_cap(Some(0.5), 1.0, 4.0), 14.0);
        assert!(footfall_lead_cap(Some(19.8), 1.0, 4.0) > 28.0);
        assert!(
            (footfall_lead_cap(Some(19.8), 1.0, 4.0)
                - super::GIANT_WALK * 4.0 * super::giant_size_speed_factor(19.8))
            .abs()
                < 1e-4
        );
    }

    #[test]
    fn human_ignore_ratio_only_lets_the_larger_giant_ignore() {
        assert!(!ignores_human(25.2, 1.8, 30.0));
        assert!(ignores_human(500.0, 1.8, 30.0));
        assert!(!ignores_human(25.2, 500.0, 30.0));
        assert!(ignores_human(30.0, 1.0, 30.0));
        assert!(ignores_human(31.0, 1.0, 30.0));
        assert!(ignores_human(25.2, 1.8, 0.0));
    }

    #[test]
    fn heavy_footfall_and_sit_shake_fall_off_with_distance() {
        for impact in [GroundImpact::Footfall, GroundImpact::Sit] {
            assert!(impact.shake(4.0, 1.0) > impact.shake(40.0, 1.0));
            assert!(impact.shake(40.0, 1.0) > 0.0);
            assert_eq!(impact.shake(200.0, 1.0), 0.0);
        }
        assert!(GroundImpact::Sit.shake(40.0, 1.0) > GroundImpact::Footfall.shake(40.0, 1.0));
    }

    #[test]
    fn growth_shake_increases_with_height_gap_and_falls_off_with_distance() {
        let giant = GroundImpact::Footfall;
        assert_eq!(giant.relative_shake(1.0, 1.8, 1.8), 0.0);
        assert_eq!(giant.relative_shake(1.0, 1.8, 2.0), 0.0);
        assert!(giant.relative_shake(2.0, 2.0, 0.5) > giant.relative_shake(2.0, 1.0, 0.5));
        assert_eq!(giant.relative_shake(18.0, 1.0, 0.5), 0.0);
    }

    #[test]
    fn size_tiers_split_the_seven_matrix_bands() {
        use super::ai::SizeTier;
        let tier = |ratio: f32| SizeTier::from_ratio(ratio);
        assert_eq!(tier(0.05), SizeTier::Trivial);
        assert_eq!(tier(0.1), SizeTier::Prey);
        assert_eq!(tier(0.49), SizeTier::Prey);
        assert_eq!(tier(0.5), SizeTier::Pushover);
        assert_eq!(tier(0.79), SizeTier::Pushover);
        assert_eq!(tier(0.8), SizeTier::Peer);
        assert_eq!(tier(1.19), SizeTier::Peer);
        assert_eq!(tier(1.2), SizeTier::Uphill);
        assert_eq!(tier(1.99), SizeTier::Uphill);
        assert_eq!(tier(2.0), SizeTier::Danger);
        assert_eq!(tier(4.9), SizeTier::Danger);
        assert_eq!(tier(5.0), SizeTier::Overwhelming);
        assert_eq!(tier(50.0), SizeTier::Overwhelming);
        // Only the middle tiers chase; trivial is incidental and the top two flee.
        assert!(SizeTier::Prey.chases());
        assert!(SizeTier::Pushover.chases());
        assert!(SizeTier::Peer.chases());
        assert!(SizeTier::Uphill.chases());
        assert!(!SizeTier::Trivial.chases());
        assert!(!SizeTier::Danger.chases());
        assert!(!SizeTier::Overwhelming.chases());
    }

    #[test]
    fn size_tier_boundaries_keep_ten_percent_hysteresis() {
        use super::ai::SizeTier;
        // A fresh 0.5 ratio classifies as Pushover; a Prey actor keeps its old
        // tier up to 0.55 (0.5 x 1.1) before flipping.
        assert_eq!(
            SizeTier::from_ratio_with_hysteresis(0.52, Some(SizeTier::Prey)),
            SizeTier::Prey
        );
        assert_eq!(
            SizeTier::from_ratio_with_hysteresis(0.56, Some(SizeTier::Prey)),
            SizeTier::Pushover
        );
        // And a Pushover actor hangs on down to 0.45 (0.5 x 0.9).
        assert_eq!(
            SizeTier::from_ratio_with_hysteresis(0.46, Some(SizeTier::Pushover)),
            SizeTier::Pushover
        );
        assert_eq!(
            SizeTier::from_ratio_with_hysteresis(0.44, Some(SizeTier::Pushover)),
            SizeTier::Prey
        );
        // The same holds at the 1.2 and 2.0 edges.
        assert_eq!(
            SizeTier::from_ratio_with_hysteresis(1.25, Some(SizeTier::Peer)),
            SizeTier::Peer
        );
        assert_eq!(
            SizeTier::from_ratio_with_hysteresis(2.1, Some(SizeTier::Uphill)),
            SizeTier::Uphill
        );
        assert_eq!(
            SizeTier::from_ratio_with_hysteresis(1.35, Some(SizeTier::Peer)),
            SizeTier::Uphill
        );
        // Fresh classification ignores the sticky window entirely.
        assert_eq!(
            SizeTier::from_ratio_with_hysteresis(0.52, None),
            SizeTier::Pushover
        );
    }

    #[test]
    fn escape_near_a_corner_returns_a_wall_tangent_not_a_zero_vector() {
        use super::ai::escape_direction;
        // Cornered against the north-east sea wall with the threat deeper in
        // the corner: the escape must open distance without leaving the map.
        let position = Vector3::new(690.0, 0.0, 690.0);
        let threats = [(Vector3::new(685.0, 0.0, 685.0), 10.0)];
        let dir = escape_direction(
            position,
            3.0,
            &threats,
            704.0,
            0.0,
            |_| false,
            |_| false,
        );
        assert!(dir.length_squared() > 0.9, "escape must never idle at zero");
        let probe = position + dir * 12.0;
        assert!(
            probe.x.abs().max(probe.z.abs()) < 704.0,
            "escape probe must stay inside the sea wall"
        );
        let before = horizontal(position - threats[0].0).length();
        let after = horizontal(probe - threats[0].0).length();
        assert!(
            after > before + 2.0,
            "escape must open distance from the threat, not just align with it"
        );

        // A threat pushing the actor straight into the wall: the straight
        // heading is rejected outright and the escape leaves along the wall.
        let dir = escape_direction(
            Vector3::new(690.0, 0.0, 0.0),
            3.0,
            &[(Vector3::new(660.0, 0.0, 0.0), 60.0)],
            704.0,
            0.0,
            |_| false,
            |_| false,
        );
        assert!(dir.length_squared() > 0.9);
        assert!(
            dir.x < 0.95,
            "escape must not run straight into the sea wall"
        );
        let probe = Vector3::new(690.0, 0.0, 0.0) + dir * 12.0;
        assert!(probe.x.abs().max(probe.z.abs()) < 704.0);

        // Fully blocked: every probe hits geometry. The scorer still returns a
        // usable direction (the old narrow-cone retreat returned ZERO and the
        // AI stood in the corner until it died).
        let dir = escape_direction(
            position,
            3.0,
            &threats,
            704.0,
            0.0,
            |_| true,
            |_| false,
        );
        assert!(dir.length_squared() > 0.9, "blocked escapes still move");

        // Blacklisted headings lose to their free neighbours.
        // The best escape here is straight +Z (yaw = PI); blacklisting it must
        // push the scorer to the neighbouring free rays, not back to the threat.
        let dir = escape_direction(
            Vector3::new(0.0, 0.0, 0.0),
            3.0,
            &[(Vector3::new(0.0, 0.0, -40.0), 30.0)],
            704.0,
            0.0,
            |_| false,
            |yaw| (yaw - PI).abs() < 0.55,
        );
        let yaw = (-dir.x).atan2(-dir.z);
        assert!((yaw - PI).abs() > 0.55, "blacklisted headings must lose");
        assert!(dir.z > 0.0, "escape still drifts away from the threat");
    }

    #[test]
    fn combat_memory_expires_by_ttl_and_records_grudges() {
        use super::ai::CombatMemory;
        let mut memory = CombatMemory::default();
        // Sighting memory lives ~6 s then drops out.
        memory.note_seen(Vector3::new(10.0, 0.0, 10.0));
        memory.tick(3.0);
        assert!(memory.last_seen.is_some());
        memory.tick(3.2);
        assert!(memory.last_seen.is_none());
        // A landed hit records both the direction it came from and a grudge
        // against the attacker that boosts the attack score for 20-30 s.
        let attacker = InstanceId::from_i64(42);
        memory.note_hit(Vector3::new(-8.0, 0.0, 2.0), attacker);
        assert_eq!(memory.hit_from.map(|(at, _)| at), Some(Vector3::new(-8.0, 0.0, 2.0)));
        assert_eq!(memory.grudge.map(|(id, _)| id), Some(attacker));
        memory.tick(25.0);
        assert!(memory.hit_from.is_none(), "hit direction expires quickly");
        memory.tick(1.0);
        assert!(
            memory.grudge.is_none(),
            "grudges expire inside the 20-30 s band"
        );
        // Failed escape headings stay blacklisted for 3-5 s, then free again.
        memory.note_failed_escape(1.2);
        assert!(memory.escape_blocked(1.3));
        assert!(!memory.escape_blocked(-1.5));
        memory.tick(4.2);
        assert!(!memory.escape_blocked(1.3), "escape blacklist expires");
        // Danger zones live 12-15 s and merge when refreshed.
        memory.note_danger(Vector3::new(5.0, 0.0, 5.0), 12.0);
        memory.note_danger(Vector3::new(5.4, 0.0, 5.2), 14.0);
        assert_eq!(memory.danger_zones.len(), 1);
        memory.tick(13.5);
        assert!(memory.danger_zones.is_empty(), "danger zones expire");
    }

    #[test]
    fn personality_traits_normalize_into_unit_scores() {
        use super::ai::Personality;
        let personality = Personality {
            aggression: 100.0,
            risk_appetite: 50.0,
            survival_drive: 0.0,
            growth_drive: 75.0,
            vengeance: 12.5,
            destructiveness: 200.0,
        };
        assert_eq!(personality.aggression01(), 1.0);
        assert_eq!(personality.risk01(), 0.5);
        assert_eq!(personality.survival01(), 0.0);
        assert_eq!(personality.growth01(), 0.75);
        assert_eq!(personality.vengeance01(), 0.125);
        // Out-of-range traits clamp instead of amplifying scores.
        assert_eq!(personality.destructiveness01(), 1.0);
        let zero = Personality {
            aggression: 0.0,
            risk_appetite: 0.0,
            survival_drive: 0.0,
            growth_drive: 0.0,
            vengeance: 0.0,
            destructiveness: 0.0,
        };
        assert_eq!(zero.aggression01(), 0.0);
        assert_eq!(zero.destructiveness01(), 0.0);
    }

    #[test]
    fn uphill_ambush_follows_scale_health_and_boldness() {
        use super::ambush_uphill;
        // A bold actor (risk 0.9) takes a 1.6:1 fight at 80 % health...
        assert!(ambush_uphill(1.0, 0.8, 1.6, 1.0, 0.9));
        // ...while a timid one (risk 0.1) wants near-parity before committing.
        assert!(!ambush_uphill(1.0, 0.8, 1.6, 1.0, 0.1));
        // Below roughly a third of the enemy's strength nobody ambushes.
        assert!(!ambush_uphill(1.0, 0.5, 1.6, 1.0, 0.9));
        // Nobody ambushes into a fivefold gap...
        assert!(!ambush_uphill(1.0, 1.0, 5.0, 1.0, 0.9));
        // ...but a healthy bold actor takes a modest uphill swing.
        assert!(ambush_uphill(1.0, 1.0, 1.3, 0.6, 0.5));
    }

    #[test]
    fn capped_ai_detects_both_round_max_and_band_limit() {
        assert!(!at_current_growth_cap(1.0, 50.0, f32::INFINITY));
        assert!(at_current_growth_cap(1.0, GIANT_START_HEIGHT, f32::INFINITY));
        assert!(at_current_growth_cap(2.0, 40.0, f32::INFINITY));
        let band_limit = 7.0 / GIANT_START_HEIGHT;
        assert!(!at_current_growth_cap(6.5 / GIANT_START_HEIGHT, 200.0, band_limit));
        assert!(at_current_growth_cap(band_limit, 200.0, band_limit));
    }

    #[test]
    fn desk_hazard_damage_and_camera_shake_scale_monotonically() {
        use super::{desk_hazard_camera_shake, desk_hazard_damage_fraction};
        let reach = 110.0;
        let core = desk_hazard_damage_fraction(0.0, reach, 0.85);
        let mid = desk_hazard_damage_fraction(55.0, reach, 0.85);
        let edge = desk_hazard_damage_fraction(109.0, reach, 0.85);
        let outside = desk_hazard_damage_fraction(111.0, reach, 0.85);
        assert!(core >= 1.0, "direct fingertip core hit should crush in one strike");
        assert!(core > mid && mid > edge && edge > 0.5);
        assert_eq!(outside, 0.0);

        let near_shake = desk_hazard_camera_shake(20.0, reach);
        let far_shake = desk_hazard_camera_shake(700.0, reach);
        assert!(near_shake > 1.4 && far_shake >= 0.25 && near_shake > far_shake);
    }
}
