//! Giant sit-crush (坐压) gameplay.
//!
//! The visual side already lives in `scenes/giant_visual.gd`:
//!   `show_sit_crush(progress, delta)`, `show_sit_idle(delta, blend_in)`,
//!   `finish_sit_crush()`. This module owns the timing, the area damage on impact,
//!   the idle sit at the growth cap, and the pinned-victim damage over time.
//!
//! Phases map one-to-one onto the procedural clip:
//!   drop   = visual progress 0.00 .. 0.67 (includes the 0.375 impact beat)
//!   hold   = seamless `show_sit_idle` loop, length scales with body size
//!   rise   = visual progress 0.67 .. 1.00
//!   cancel = a combat sit that lost its target before impact: the pose rewinds from the
//!            drop position back to standing and no damage is dealt.
//!
//! Every sit starts from the *current* facing: the pelvis always lands behind the body, so
//! there is no pivot phase and the warning ring, the AI target check and the impact area all
//! share `sit_center()`.

use super::*;
use crate::rules::{GIANT_START_HEIGHT, HUMAN_HEIGHT};

/// Mirrors SIT_CRUSH_DURATION / IMPACT_TIME / RISE_START in `giant_visual.gd`.
const VISUAL_SECONDS: f32 = 4.80;
const VISUAL_IMPACT: f32 = 0.375;
const VISUAL_RISE_START: f32 = 0.67;
/// Seated footprint radius and pelvis offset at scale 1 (0.295 * model scale 14.8).
const SEAT_RADIUS: f32 = 4.366;
const SEAT_FORWARD: f32 = 2.85;
const DROP_SECONDS: f32 = VISUAL_SECONDS * VISUAL_RISE_START; // 3.216
const IMPACT_SECONDS: f32 = VISUAL_SECONDS * VISUAL_IMPACT; // 1.800
const RISE_SECONDS: f32 = VISUAL_SECONDS * (1.0 - VISUAL_RISE_START); // 1.584
const SIT_COOLDOWN: f32 = 2.6;
const MIN_HOLD: f32 = 0.45;
/// A combat sit is a short commitment, not a rest: cap the seated hold.
const COMBAT_HOLD_CAP: f32 = 2.2;
/// Seconds the rewound pose takes to get back to standing when a combat sit is cancelled.
const CANCEL_SECONDS: f32 = 0.55;
/// A pinned victim loses a fifth of the attacker's attack every tick.
const PIN_DAMAGE_DIVISOR: f32 = 5.0;

#[derive(Clone, Copy)]
pub(super) enum SitPhase {
    Drop { elapsed: f32 },
    /// A combat sit whose target stepped out of the rear landing zone before the
    /// impact: the pose rewinds to standing without dealing any damage.
    Cancel { elapsed: f32, from: f32 },
    Hold { left: f32 },
    Rise { elapsed: f32 },
}

#[derive(Clone, Copy)]
pub(super) struct SitAction {
    pub(super) phase: SitPhase,
    /// True for the "no growth left, nothing in sight" idle sit.
    pub(super) idle: bool,
    /// Impact damage already delivered for this sit.
    pub(super) struck: bool,
    hold: f32,
    /// Timed holds stand up on their own; the player stays seated until pressing X.
    pub(super) timed: bool,
    /// True for a sit aimed at a live target: it keeps a short hold and may be
    /// cancelled while the target walks out of the landing zone before impact.
    pub(super) combat: bool,
}

/// Seated seconds for a body of `scale` (1.0 = the 25.2 m reference giant).
/// Bigger bodies sit longer; the configured base is also the floor.
pub(super) fn crush_hold_seconds(base: f32, per_scale: f32, scale: f32) -> f32 {
    let extra = (scale - 1.0).max(0.0);
    (base + per_scale * extra).max(MIN_HOLD)
}

impl SitAction {
    pub(super) fn phase_key(&self) -> &'static str {
        match self.phase {
            SitPhase::Drop { .. } => "drop",
            SitPhase::Cancel { .. } => "cancel",
            SitPhase::Hold { .. } => "hold",
            SitPhase::Rise { .. } => "rise",
        }
    }

    /// 0..1 across the whole sit cycle, for HUD gauges.
    pub(super) fn progress(&self) -> f32 {
        let drop = VISUAL_RISE_START;
        match self.phase {
            SitPhase::Drop { elapsed } => (elapsed / DROP_SECONDS * drop).clamp(0.0, 1.0),
            SitPhase::Cancel { elapsed, from } => {
                (from * (1.0 - (elapsed / CANCEL_SECONDS).clamp(0.0, 1.0))).clamp(0.0, drop)
            }
            SitPhase::Hold { left } => {
                let span = self.hold.max(MIN_HOLD);
                let fraction = if self.timed {
                    (1.0 - (left / span).clamp(0.0, 1.0)).clamp(0.0, 1.0)
                } else {
                    0.0
                };
                drop + fraction * (1.0 - drop)
            }
            SitPhase::Rise { elapsed } => {
                drop + (elapsed / RISE_SECONDS).clamp(0.0, 1.0) * (1.0 - drop)
            }
        }
    }
}

impl Giant {
    pub(super) fn sitting(&self) -> bool {
        self.sit.is_some()
    }

    /// Where the pelvis actually lands: the sit animation drops the butt behind the body.
    /// Measured from the rig at yaw 0 (pelvis +2.85 m on Z while forward is -Z), so the
    /// warning ring, the AI's target check and the impact all share this one centre.
    fn sit_center(&self) -> Vector3 {
        let yaw = self.body.get_rotation().y;
        let forward = Vector3::FORWARD.rotated(Vector3::UP, yaw);
        let position = self.body.get_global_position();
        let mut center = position - forward * (SEAT_FORWARD * self.scale);
        center.y = position.y + 0.05;
        center
    }

    /// True when `point` (with its own radius) sits inside the rear landing zone, which is
    /// the only place a sit can actually crush something. The reach shares the impact test's
    /// full radius so a target that would be hit is never cancelled as a whiff.
    pub(super) fn lands_on(&self, point: Vector3, target_radius: f32) -> bool {
        let reach = self.sit_radius() + target_radius;
        horizontal(point - self.sit_center()).length() <= reach
    }

    pub(super) fn sit_radius(&self) -> f32 {
        SEAT_RADIUS * self.scale
    }

    /// The live drop zone while a sit is telegraphed (the drop phase): where the pelvis
    /// will land and how wide the crush area is. Snapshotted into `Rival` per frame so
    /// other actors can dodge the warning circle.
    pub(super) fn sit_drop_zone(&self) -> Option<(Vector3, f32)> {
        let sit = self.sit.as_ref()?;
        match sit.phase {
            SitPhase::Drop { .. } => Some((self.sit_center(), self.sit_radius())),
            SitPhase::Cancel { .. } | SitPhase::Hold { .. } | SitPhase::Rise { .. } => None,
        }
    }
}

impl HarborRound {
    /// Called once per actor each frame while the giant is standing and free to act.
    /// AI giants drop into a sit-crush on their own; the player asks for it with the
    /// stand-up key, so steering is never taken away by a surprise sit.
    pub(super) fn maybe_start_sit(
        &mut self,
        actor: &mut Giant,
        player: bool,
        requested: bool,
        dt: f32,
    ) -> bool {
        // A pinned victim is already held down by someone else's sit: its own body must
        // not run a second sit state machine on top (keyboard X used to bypass the pin).
        if actor.human
            || actor.health_fraction <= 0.0
            || actor.grabbed
            || actor.pinned_by.is_some()
        {
            return false;
        }
        if actor.sit.is_some() || actor.hand_attack.is_some() {
            return false;
        }
        let settings = self.settings.sit;

        // The player only has to be a giant: press X and sit, crowd or not. The body
        // does not pivot first — the pelvis lands behind the current facing.
        if player {
            if requested {
                let hold =
                    crush_hold_seconds(settings.hold_base, settings.hold_per_scale, actor.scale);
                self.begin_sit(actor, false, hold, false, false);
                return true;
            }
            return false;
        }
        if actor.sit_in > 0.0 {
            return false;
        }
        if !actor.body.is_on_floor() {
            return false;
        }

        // 1. AI giants sit on a small crowd: at least `crush_targets` bodies <= 1/5 the height
        // that the rear landing zone can actually reach from the current facing. A swing already
        // in motion finishes before the next AI crowd decision.
        if actor.footfall.is_none() && settings.crush_enabled {
            let height = actor.height(self.max_height);
            let max_target = height / settings.crush_ratio.max(1.0);
            if self.rear_landing_targets(actor, Some(max_target)) >= settings.crush_targets as usize
            {
                let hold =
                    crush_hold_seconds(settings.hold_base, settings.hold_per_scale, actor.scale);
                // A crowd crush targets live bodies, so it gets the same short hold and
                // safe cancel as any other combat sit.
                self.begin_sit(actor, false, hold, true, true);
                return true;
            }
        }
        // 2. Idle sit: maxed out on height with an empty horizon, rolled per second.
        // Heavy-step roaming leaves `footfall` pending on most walking frames; because nobody is in
        // sight, idle sit can roll smoothly on every floor frame without waiting for double support.
        if settings.idle_enabled
            && at_current_growth_cap(actor.scale, self.max_height, actor.growth_limit)
            && !self.any_target_in_sight(actor)
            && godot::global::randf() < f64::from(settings.idle_chance * dt)
        {
            self.begin_sit(actor, true, settings.idle_timeout, true, false);
            return true;
        }
        false
    }

    /// Player, AI and touch input all sit down along the *current* facing: the seated
    /// pelvis drops straight behind the body, so the landing zone is always the exact
    /// mirrored footprint used by the warning ring and the impact test.
    fn begin_sit(
        &mut self,
        actor: &mut Giant,
        idle: bool,
        hold: f32,
        timed: bool,
        combat: bool,
    ) {
        let hold = if combat {
            hold.min(COMBAT_HOLD_CAP)
        } else {
            hold
        };
        actor.sit = Some(SitAction {
            phase: SitPhase::Drop { elapsed: 0.0 },
            idle,
            struck: false,
            hold: hold.max(MIN_HOLD),
            timed,
            combat,
        });
        actor.footfall = None;
        actor.pending_hand = None;
        actor.standing_pivot_active = false;
        actor.was_walking = false;
        actor.yaw_velocity = 0.0;
        actor.roam_goal = None;
        actor.clear_path();
    }

    /// Advances one sit frame and drives the procedural visual. Returns false once the
    /// giant is back on its feet (the caller then resumes normal locomotion next frame).
    pub(super) fn drive_sit(&mut self, actor: &mut Giant, dt: f32, stand: bool) -> bool {
        let Some(mut sit) = actor.sit else {
            return false;
        };
        let mut struck_now = false;
        let mut finished = false;
        let mut visual_progress: Option<f32> = None;
        let mut visual_idle = false;

        match sit.phase {
            SitPhase::Drop { elapsed } => {
                let elapsed = elapsed + dt;
                // A combat sit is a bet on the landing zone: if the target walks out
                // before the impact, the body rewinds to standing instead of whiffing.
                let whiffed = sit.combat
                    && !sit.struck
                    && elapsed < IMPACT_SECONDS
                    && self.rear_landing_targets(&*actor, None) == 0;
                if whiffed {
                    sit.phase = SitPhase::Cancel {
                        elapsed: 0.0,
                        from: elapsed / DROP_SECONDS * VISUAL_RISE_START,
                    };
                } else {
                    if !sit.struck && elapsed >= IMPACT_SECONDS {
                        sit.struck = true;
                        struck_now = true;
                    }
                    if elapsed >= DROP_SECONDS {
                        sit.phase = SitPhase::Hold { left: sit.hold };
                        visual_idle = true;
                    } else {
                        sit.phase = SitPhase::Drop { elapsed };
                        visual_progress = Some(elapsed / DROP_SECONDS * VISUAL_RISE_START);
                    }
                }
            }
            SitPhase::Cancel { elapsed, from } => {
                let elapsed = elapsed + dt;
                if elapsed >= CANCEL_SECONDS {
                    finished = true;
                    visual_progress = Some(0.0);
                } else {
                    sit.phase = SitPhase::Cancel { elapsed, from };
                    visual_progress = Some(from * (1.0 - elapsed / CANCEL_SECONDS));
                }
            }
            SitPhase::Hold { left } => {
                let remaining = if sit.timed { left - dt } else { left };
                let expired = sit.timed && remaining <= 0.0;
                let interrupted = stand || (sit.idle && self.any_target_in_sight(actor));
                if expired || interrupted {
                    sit.phase = SitPhase::Rise { elapsed: 0.0 };
                    visual_progress = Some(VISUAL_RISE_START);
                } else {
                    sit.phase = SitPhase::Hold { left: remaining };
                    visual_idle = true;
                }
            }
            SitPhase::Rise { elapsed } => {
                let elapsed = elapsed + dt;
                if elapsed >= RISE_SECONDS {
                    finished = true;
                    visual_progress = Some(1.0);
                } else {
                    sit.phase = SitPhase::Rise { elapsed };
                    visual_progress =
                        Some(VISUAL_RISE_START + elapsed / RISE_SECONDS * (1.0 - VISUAL_RISE_START));
                }
            }
        }

        if finished {
            actor.sit = None;
            actor.sit_in = SIT_COOLDOWN;
        } else {
            actor.sit = Some(sit);
        }

        if visual_idle {
            actor
                .body
                .call("show_sit_idle", &[dt.to_variant(), true.to_variant()]);
        } else if let Some(progress) = visual_progress {
            actor.body.call(
                "show_sit_crush",
                &[progress.clamp(0.0, 1.0).to_variant(), dt.to_variant()],
            );
        }
        let landing_ring = !struck_now && !finished && matches!(sit.phase, SitPhase::Drop { .. });
        if landing_ring {
            let effects = self.effects.as_mut().unwrap();
            effects.call(
                "sit_warn",
                &[
                    actor.sit_center().to_variant(),
                    actor.sit_radius().to_variant(),
                    actor.index.to_variant(),
                ],
            );
        } else {
            self.effects
                .as_mut()
                .unwrap()
                .call("sit_warn_end", &[actor.index.to_variant()]);
        }
        if struck_now {
            self.sit_impact(actor);
        }
        if finished {
            actor.body.call("finish_sit_crush", &[false.to_variant()]);
        }
        actor.sit.is_some()
    }

    /// Sitting on a building only makes sense when the rear landing zone reaches the wall:
    /// the pelvis always drops behind the body, so a front-facing sit would grind through a
    /// full drop/hold/rise cycle without ever damaging the facade.
    pub(super) fn maybe_start_ai_building_sit(
        &mut self,
        actor: &mut Giant,
        target: Vector3,
        target_radius: f32,
    ) -> bool {
        if actor.human
            || actor.health_fraction <= 0.0
            || actor.grabbed
            || actor.pinned_by.is_some()
            || actor.sit.is_some()
            || actor.hand_attack.is_some()
            || actor.sit_in > 0.0
            || actor.footfall.is_some()
            || !actor.body.is_on_floor()
            || !actor.lands_on(target, target_radius)
        {
            return false;
        }
        let settings = self.settings.sit;
        let hold = crush_hold_seconds(settings.hold_base, settings.hold_per_scale, actor.scale);
        self.begin_sit(actor, false, hold, true, true);
        true
    }

    pub(super) fn maybe_start_ai_combat_sit(
        &mut self,
        actor: &mut Giant,
        target: Vector3,
        target_radius: f32,
    ) -> bool {
        if !self.settings.sit.crush_enabled
            || actor.sit_in > 0.0
            || !Self::ready_for_hand_move(actor)
        {
            return false;
        }
        let offset = target - actor.body.get_global_position();
        // Only sit when the rear landing zone the body already faces can reach the
        // target: a front-facing sit would drop on empty ground and whiff.
        if offset.y.abs() > (0.12 * actor.height(self.max_height)).max(0.25)
            || !actor.lands_on(target, target_radius)
        {
            return false;
        }
        let settings = self.settings.sit;
        let hold = crush_hold_seconds(settings.hold_base, settings.hold_per_scale, actor.scale);
        self.begin_sit(actor, false, hold, true, true);
        actor.ai_punched = false;
        true
    }

    fn sit_impact(&mut self, actor: &mut Giant) {
        let area = ImpactArea {
            center: actor.sit_center(),
            yaw: actor.body.get_rotation().y,
            radii: Vector2::splat(actor.sit_radius()),
        };
        // Shares ground-strike damage for buildings, civilians, the evacuating
        // player and the `GiantStrike` hand-off that applies rival damage.
        self.impact(actor, area, DefeatMethod::SitCrush);
    }

    /// True when the player's giant could sit down right now (drives the HUD button).
    /// The player does not need a crowd: the button is live whenever the body is free.
    pub(super) fn sit_ready(&self, actor: &Giant) -> bool {
        !actor.human
            && actor.sit.is_none()
            && actor.hand_attack.is_none()
            && actor.pinned_by.is_none()
    }

    /// Living bodies the rear landing zone can actually crush, filtered by an optional
    /// maximum height. The seated pelvis always drops behind the body, so counting
    /// anyone in *front* would promise a hit the sit cannot deliver.
    fn rear_landing_targets(&self, actor: &Giant, max_height: Option<f32>) -> usize {
        let mut count = 0;
        let mut accept = |position: Vector3, radius: f32, height: f32| {
            if max_height.is_none_or(|limit| height <= limit) && actor.lands_on(position, radius) {
                count += 1;
            }
        };
        for rival in &self.rivals {
            if rival.index == actor.index || rival.health_fraction <= 0.0 {
                continue;
            }
            accept(
                rival.position,
                GIANT_RADIUS * rival.scale,
                GIANT_START_HEIGHT * rival.scale,
            );
        }
        for npc in &self.civilians {
            if npc.remove_in.is_some() || npc.grabbed {
                continue;
            }
            accept(npc.position, HUMAN_RADIUS, npc.size.height);
        }
        if let Some(body) = self.evacuating_human() {
            let position = self
                .evacuee_position
                .unwrap_or_else(|| body.get_global_position());
            accept(position, HUMAN_RADIUS, HUMAN_HEIGHT);
        }
        count
    }

    fn any_target_in_sight(&self, actor: &Giant) -> bool {
        let position = actor.body.get_global_position();
        let range = sight_range(actor.scale);
        let near = |point: Vector3| horizontal(point - position).length() <= range;
        if self
            .rivals
            .iter()
            .any(|rival| rival.index != actor.index && rival.health_fraction > 0.0 && near(rival.position))
        {
            return true;
        }
        if self
            .civilians
            .iter()
            .any(|npc| npc.remove_in.is_none() && !npc.grabbed && near(npc.position))
        {
            return true;
        }
        if let Some(body) = self.evacuating_human() {
            let point = self
                .evacuee_position
                .unwrap_or_else(|| body.get_global_position());
            if near(point) {
                return true;
            }
        }
        false
    }

    /// Pinned victims keep taking a fifth of the attacker's damage twice a second until
    /// the sitting giant gets up or dies.
    pub(super) fn update_pins(&mut self, dt: f32) {
        if self.giants.iter().all(|giant| giant.pinned_by.is_none()) {
            return;
        }
        let interval = self.settings.sit.pin_interval.max(0.05);
        let attack = self.combat_rules().base_attack;
        let mut ticks: Vec<(usize, usize)> = Vec::new();
        for victim in 0..self.giants.len() {
            let Some(by) = self.giants[victim].pinned_by else {
                continue;
            };
            let attacker = by.max(0) as usize;
            let attacker_ok = attacker != victim
                && attacker < self.giants.len()
                && self.giants[attacker].sitting()
                && self.giants[attacker].health_fraction > 0.0;
            if !attacker_ok {
                self.giants[victim].pinned_by = None;
                self.giants[victim].pin_tick = 0.0;
                continue;
            }
            self.giants[victim].pin_tick += dt;
            if self.giants[victim].pin_tick >= interval {
                self.giants[victim].pin_tick -= interval;
                ticks.push((attacker, victim));
            }
        }
        if ticks.is_empty() {
            return;
        }
        // `damage_rival` needs `&mut self`, so move the actors out of the round while the
        // two borrowed combatants are alive.
        let mut giants = std::mem::take(&mut self.giants);
        for (attacker, victim) in ticks {
            let damage = self.growth_stat(&giants[attacker], attack) / PIN_DAMAGE_DIVISOR;
            if attacker < victim {
                let (head, tail) = giants.split_at_mut(victim);
                self.damage_rival(
                    &mut head[attacker],
                    &mut tail[0],
                    damage,
                    DefeatMethod::SitCrush,
                );
            } else {
                let (head, tail) = giants.split_at_mut(attacker);
                self.damage_rival(
                    &mut tail[0],
                    &mut head[victim],
                    damage,
                    DefeatMethod::SitCrush,
                );
            }
        }
        self.giants = giants;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn action(phase: SitPhase) -> SitAction {
        SitAction { phase, idle: false, struck: false, hold: 1.2, timed: true, combat: false }
    }

    #[test]
    fn bigger_giants_sit_longer_and_never_below_the_floor() {
        let small = crush_hold_seconds(1.2, 1.0, 1.0);
        let big = crush_hold_seconds(1.2, 1.0, 4.0);
        assert!((small - 1.2).abs() < 1e-6);
        assert!((big - 4.2).abs() < 1e-6);
        assert!(big > small);
        assert!((crush_hold_seconds(0.0, 0.0, 1.0) - MIN_HOLD).abs() < 1e-6);
        // A body smaller than the reference still gets the configured base.
        assert!((crush_hold_seconds(1.2, 1.0, 0.2) - 1.2).abs() < 1e-6);
    }

    #[test]
    fn sit_progress_advances_through_every_phase() {
        let drop = action(SitPhase::Drop { elapsed: DROP_SECONDS * 0.5 }).progress();
        let hold = action(SitPhase::Hold { left: 0.0 }).progress();
        let hold_start = action(SitPhase::Hold { left: 1.2 }).progress();
        let rise = action(SitPhase::Rise { elapsed: RISE_SECONDS * 0.5 }).progress();
        let done = action(SitPhase::Rise { elapsed: RISE_SECONDS }).progress();
        assert!(drop > 0.0 && drop < VISUAL_RISE_START);
        assert!(hold_start <= hold && hold <= 1.0);
        assert!(rise > VISUAL_RISE_START && rise < 1.0);
        assert!((done - 1.0).abs() < 1e-5);
        assert_eq!(action(SitPhase::Drop { elapsed: 0.0 }).phase_key(), "drop");
        assert_eq!(action(SitPhase::Hold { left: 1.0 }).phase_key(), "hold");
        assert_eq!(action(SitPhase::Rise { elapsed: 0.0 }).phase_key(), "rise");
        assert_eq!(
            action(SitPhase::Cancel { elapsed: 0.0, from: 0.4 }).phase_key(),
            "cancel"
        );
    }

    #[test]
    fn a_cancelled_combat_sit_rewinds_the_pose_and_deals_no_damage() {
        let cancel = action(SitPhase::Cancel { elapsed: CANCEL_SECONDS * 0.5, from: 0.4 }).progress();
        assert!(cancel > 0.0 && cancel < 0.4);
        let done = action(SitPhase::Cancel { elapsed: CANCEL_SECONDS, from: 0.4 }).progress();
        assert!(done < 1e-6);
    }

    #[test]
    fn combat_sits_hold_briefly_and_idle_sits_keep_their_configured_hold() {
        assert!(COMBAT_HOLD_CAP < crush_hold_seconds(1.2, 1.0, 6.0));
        assert!(COMBAT_HOLD_CAP >= MIN_HOLD);
    }
}
