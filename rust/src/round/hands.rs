use super::*;

const GRASP_TIME: f32 = 0.30;
const CRUSH_TIME: f32 = 0.745;
const PUNCH_TIME: f32 = 0.455;
const AI_GRAB_CHANCE_NEAR_LANDING: f64 = 0.10;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum HandMove {
    GrabCrush,
    Punch,
}

impl HandMove {
    pub(super) fn name(self) -> &'static str {
        match self {
            Self::GrabCrush => "grab_crush",
            Self::Punch => "punch",
        }
    }

    pub(super) fn size_allows(self, attacker: f32, target: f32) -> bool {
        let (limit, height) = match self {
            Self::GrabCrush => (3.0 * target, attacker),
            Self::Punch => (2.0 * attacker.min(target), attacker.max(target)),
        };
        // Allow for rounding when the two heights are computed from their model scales.
        let tolerance = limit * 4.0 * f32::EPSILON;
        match self {
            Self::GrabCrush => height + tolerance >= limit,
            Self::Punch => height <= limit + tolerance,
        }
    }

    fn duration(self, pace: f32, scale: f32) -> f32 {
        let seconds = match self {
            Self::GrabCrush => 4.5,
            Self::Punch => 2.4,
        };
        seconds * scale.sqrt().clamp(0.8, 3.0) / pace.sqrt()
    }

    fn contact(self) -> f32 {
        match self {
            Self::GrabCrush => GRASP_TIME,
            Self::Punch => PUNCH_TIME,
        }
    }

    fn reach(self) -> f32 {
        match self {
            Self::GrabCrush => 0.29,
            Self::Punch => 0.48,
        }
    }
}

#[derive(Clone, Copy)]
enum HandTarget {
    Giant(usize),
    Civilian(InstanceId),
    Scenery(usize),
}

struct TargetPose {
    at: Vector3,
    height: f32,
    radius: f32,
    footprint: Option<Footprint>,
}

impl TargetPose {
    fn character(body: &Gd<CharacterBody3D>, height: f32, radius: f32) -> Self {
        Self {
            at: body.get_global_position(),
            height,
            radius,
            footprint: None,
        }
    }

    fn point(&self, origin: Vector3, attacker_height: f32, kind: HandMove) -> Vector3 {
        let toward = horizontal(self.at - origin).normalized_or_zero();
        let mut point = self.footprint.map_or_else(
            || {
                self.at
                    - toward
                        * if kind == HandMove::Punch {
                            self.radius * 0.8
                        } else {
                            0.0
                        }
            },
            |footprint| closest_surface_point(footprint, origin),
        );
        point.y = match kind {
            HandMove::GrabCrush => self.at.y + self.height * 0.5,
            HandMove::Punch => {
                let low = self.at.y
                    + if self.footprint.is_some() {
                        (self.height * 0.08).min(attacker_height * 0.40)
                    } else {
                        self.height * 0.22
                    };
                (origin.y + attacker_height * 0.72).clamp(low, self.at.y + self.height * 0.93)
            }
        };
        point
    }
}

enum HeldTarget {
    Character {
        body: Gd<CharacterBody3D>,
        height: f32,
        origin: Vector3,
        layer: u32,
        mask: u32,
    },
    Scenery(usize),
}

pub(super) struct HandAttack {
    pub kind: HandMove,
    target: HandTarget,
    point: Vector3,
    pub progress: f32,
    duration: f32,
    held: Option<HeldTarget>,
}

impl HarborRound {
    pub(super) fn start_player_hand_move(&self, actor: &mut Giant, kind: HandMove) -> bool {
        if !self.can_demolish(actor) {
            return false;
        }
        let at = actor.body.get_global_position();
        // Hand attacks only target the giant's current body facing, unaffected by camera yaw.
        let aim = Vector3::FORWARD.rotated(Vector3::UP, actor.body.get_rotation().y);
        let height = actor.height(self.max_height);
        let can_demolish = self.can_demolish(actor);
        let figures = self
            .rivals
            .iter()
            .filter(|rival| rival.index != actor.index)
            .map(|rival| {
                let height = rival.scale * GIANT_START_HEIGHT;
                let radius = if rival.human {
                    HUMAN_RADIUS * height / HUMAN_HEIGHT
                } else {
                    rival.scale * GIANT_RADIUS
                };
                (
                    HandTarget::Giant(rival.index as usize),
                    TargetPose::character(&rival.body, height, radius),
                )
            });
        let people = self
            .civilians
            .iter()
            .filter(|npc| can_demolish && npc.remove_in.is_none() && !npc.grabbed)
            .map(|npc| {
                (
                    HandTarget::Civilian(npc.body.instance_id()),
                    TargetPose::character(&npc.body, npc.size.height, npc.size.radius),
                )
            });
        let scenery = self
            .target_grid
            .near(at, kind.reach() * height)
            .filter_map(|index| {
                can_demolish
                    .then(|| {
                        self.scenery_hand_pose(index)
                            .map(|pose| (HandTarget::Scenery(index), pose))
                    })
                    .flatten()
            });
        let selected = figures
            .chain(people)
            .chain(scenery)
            .filter_map(|(target, pose)| {
                let point = self.valid_hand_point(actor, kind, &pose, aim)?;
                let offset = horizontal(point - at);
                let direction = offset.normalized_or_zero();
                let score = offset.length() * (1.0 + 2.0 * (1.0 - aim.dot(direction)));
                Some((score, target, point))
            })
            .min_by(|first, second| first.0.total_cmp(&second.0));
        if let Some((_, target, point)) = selected {
            self.begin_hand_move(actor, kind, target, point);
            return true;
        }
        false
    }

    /// Starts a hand attack when planted and aligned, or gives the direction
    /// to face while settling the current step.
    pub(super) fn try_ai_hand_move(
        &self,
        actor: &mut Giant,
        target: &CombatTarget,
        footfall_in_reach: bool,
    ) -> Option<Vector3> {
        let id = target.body.instance_id();
        let (victim, pose) = if let Some(rival) = self
            .rivals
            .iter()
            .find(|rival| rival.body.instance_id() == id)
        {
            (
                HandTarget::Giant(rival.index as usize),
                TargetPose::character(&rival.body, target.size.height, target.size.radius),
            )
        } else {
            (
                HandTarget::Civilian(id),
                TargetPose::character(&target.body, target.size.height, target.size.radius),
            )
        };
        // AI hand moves also require facing the target within the forward cone rather than
        // snapping 180 degrees around to grab or punch behind.
        let aim = Vector3::FORWARD.rotated(Vector3::UP, actor.body.get_rotation().y);
        let moves: &[HandMove] = if footfall_in_reach {
            &[HandMove::GrabCrush]
        } else {
            &[HandMove::GrabCrush, HandMove::Punch]
        };
        let origin = actor.body.get_global_position();
        let heading = horizontal(pose.at - origin).normalized_or_zero();
        let height = actor.height(self.max_height);
        for &kind in moves {
            // Close to within a reliable hit range before planting the feet for a swing.
            let point = pose.point(origin, height, kind);
            if horizontal(point - origin).length() > height * kind.reach() * 0.8 {
                continue;
            }
            let Some(point) = self.valid_hand_point(actor, kind, &pose, heading) else { continue };
            let ready = Self::ready_for_hand_move(actor) && aim.dot(heading) >= 0.77;
            if footfall_in_reach && (!ready || godot::global::randf() >= AI_GRAB_CHANCE_NEAR_LANDING) {
                return None;
            }
            if ready {
                self.begin_hand_move(actor, kind, victim, point);
                actor.ai_punched = kind == HandMove::Punch;
                return Some(Vector3::ZERO);
            }
            return Some(heading);
        }
        None
    }

    pub(super) fn start_ai_scenery_hand_move(&self, actor: &mut Giant, index: usize) -> bool {
        if !Self::ready_for_hand_move(actor) || !self.can_demolish(actor) {
            return false;
        }
        let Some(pose) = self.scenery_hand_pose(index) else {
            return false;
        };
        let height = actor.height(self.max_height);
        let origin = actor.body.get_global_position();
        let aim = Vector3::FORWARD.rotated(Vector3::UP, actor.body.get_rotation().y);
        for &kind in &[HandMove::Punch, HandMove::GrabCrush] {
            if let Some(point) = self.valid_hand_point(actor, kind, &pose, aim) {
                let dist = horizontal(point - origin).length();
                let arm_reach = height
                    * match kind {
                        HandMove::Punch => 0.34,
                        HandMove::GrabCrush => 0.25,
                    };
                if dist <= arm_reach {
                    self.begin_hand_move(actor, kind, HandTarget::Scenery(index), point);
                    return true;
                }
            }
        }
        false
    }

    pub(super) fn ready_for_hand_move(actor: &mut Giant) -> bool {
        actor.body.is_on_floor()
            && !actor
                .body
                .clone()
                .call("has_step_in_flight", &[])
                .to::<bool>()
    }

    fn begin_hand_move(
        &self,
        actor: &mut Giant,
        kind: HandMove,
        target: HandTarget,
        point: Vector3,
    ) {
        let aim = horizontal(point - actor.body.get_global_position()).normalized_or_zero();
        face(&mut actor.body, aim, 1.0);
        actor.body.set_velocity(Vector3::ZERO);
        actor.yaw_velocity = 0.0;
        actor.hand_attack = Some(HandAttack {
            kind,
            target,
            point,
            progress: 0.0,
            duration: kind.duration(self.settings.giant_speed, actor.scale),
            held: None,
        });
        if let Some(mut audio) = self.audio() {
            audio.call(
                "play_hand_action",
                &[
                    StringName::from("whoosh").to_variant(),
                    actor.body.get_global_position().to_variant(),
                    actor.height(self.max_height).to_variant(),
                ],
            );
        }
    }

    fn scenery_hand_pose(&self, index: usize) -> Option<TargetPose> {
        let target = &self.targets[index];
        let footprint = target.footprint;
        (target.integrity.blocks() && !target.grabbed).then_some(TargetPose {
            at: footprint.transform.origin,
            height: footprint.size.y,
            radius: 0.0,
            footprint: Some(footprint),
        })
    }

    fn valid_hand_point(
        &self,
        actor: &Giant,
        kind: HandMove,
        target: &TargetPose,
        aim: Vector3,
    ) -> Option<Vector3> {
        let height = actor.height(self.max_height);
        // Any giant tall enough to swing can punch an intact building wall/roof in front of her,
        // while character-to-character hand attacks strictly enforce the relative size ratios.
        let size_ok = if target.footprint.is_some() && kind == HandMove::Punch {
            target.height * 0.93 >= height * 0.27
        } else {
            kind.size_allows(height, target.height)
        };
        if !size_ok {
            return None;
        }
        let origin = actor.body.get_global_position();
        let point = target.point(origin, height, kind);
        let offset = horizontal(point - origin);
        let distance = offset.length();
        if distance > height * kind.reach() || distance <= 0.0 || aim.dot(offset / distance) < 0.77
        {
            return None;
        }
        let height_fraction = (point.y - origin.y) / height;
        let permitted_height = match kind {
            HandMove::GrabCrush => -0.08..=0.23,
            HandMove::Punch => {
                if target.footprint.is_some() {
                    0.27..=0.93
                } else {
                    0.34..=0.93
                }
            }
        };
        if !permitted_height.contains(&height_fraction) {
            return None;
        }
        // Stop just before the face of a solid target so scenery can be attacked but walls still occlude.
        let eye = origin + Vector3::UP * height * if kind == HandMove::Punch { 0.72 } else { 0.32 };
        let mut space = actor.body.get_world_3d()?.get_direct_space_state()?;
        let query = PhysicsRayQueryParameters3D::create_ex(eye, eye.lerp(point, 0.98))
            .collision_mask(SIGHT_MASK)
            .done()?;
        space.intersect_ray(&query).is_empty().then_some(point)
    }

    pub(super) fn update_hand_attacks(&mut self, giants: &mut [Giant], dt: f32) {
        for index in 0..giants.len() {
            let (earlier, current) = giants.split_at_mut(index);
            let (actor, later) = current.split_first_mut().unwrap();
            let Some(mut attack) = actor.hand_attack.take() else {
                continue;
            };
            let rival = match attack.target {
                HandTarget::Giant(other) if other < index => earlier.get_mut(other),
                HandTarget::Giant(other) if other > index => later.get_mut(other - index - 1),
                _ => None,
            };
            self.advance_hand_attack(actor, rival, &mut attack, dt);
            if attack.progress < 1.0 {
                actor.hand_attack = Some(attack);
            } else {
                actor.body.call("finish_hand_action", &[]);
            }
        }
    }

    fn advance_hand_attack(
        &mut self,
        actor: &mut Giant,
        mut rival: Option<&mut Giant>,
        attack: &mut HandAttack,
        dt: f32,
    ) {
        if actor.health_fraction <= 0.0 || actor.grabbed || self.state.outcome != Outcome::Active {
            self.release_hand_target(attack, rival.as_deref_mut());
            attack.progress = 1.0;
            return;
        }

        let before = attack.progress;
        attack.progress = (before + dt / attack.duration).min(1.0);
        let contact = attack.kind.contact();
        let at_contact = before < contact && attack.progress >= contact;
        let mut sample = attack.progress;
        let mut in_reach = false;
        if before < contact {
            let target = match attack.target {
                HandTarget::Giant(_) => rival
                    .as_deref()
                    .filter(|rival| rival.health_fraction > 0.0 && !rival.grabbed)
                    .map(|rival| {
                        TargetPose::character(
                            &rival.body,
                            rival.height(self.max_height),
                            self.actor_radius(rival),
                        )
                    }),
                HandTarget::Civilian(id) => self
                    .civilians
                    .iter()
                    .find(|npc| {
                        npc.body.instance_id() == id && npc.remove_in.is_none() && !npc.grabbed
                    })
                    .map(|npc| TargetPose::character(&npc.body, npc.size.height, npc.size.radius)),
                HandTarget::Scenery(index) => self.scenery_hand_pose(index),
            };
            let aim = Vector3::FORWARD.rotated(Vector3::UP, actor.body.get_rotation().y);
            if let Some(point) =
                target.and_then(|target| self.valid_hand_point(actor, attack.kind, &target, aim))
            {
                attack.point = point;
                in_reach = true;
            }
            if at_contact {
                sample = contact;
            }
        }
        let crushing =
            attack.held.is_some() && before < CRUSH_TIME && attack.progress >= CRUSH_TIME;
        if crushing {
            sample = CRUSH_TIME;
        }
        let palm = actor
            .body
            .call(
                "show_hand_action",
                &[
                    (attack.kind as i32).to_variant(),
                    sample.to_variant(),
                    dt.to_variant(),
                    attack.point.to_variant(),
                ],
            )
            .to::<Vector3>();

        let height = actor.height(self.max_height);
        if at_contact && in_reach && palm.distance_to(attack.point) <= height * 0.21 {
            match attack.kind {
                HandMove::GrabCrush => self.grasp_hand_target(attack, rival.as_deref_mut(), height),
                HandMove::Punch => {
                    self.damage_hand_target(actor, attack, rival.as_deref_mut(), palm)
                }
            }
        }
        if let Some(held) = &mut attack.held {
            match held {
                HeldTarget::Character { body, height, .. } => {
                    body.set_global_position(palm - Vector3::UP * *height * 0.5);
                }
                HeldTarget::Scenery(index) => {
                    self.targets[*index]
                        .node
                        .call("hold_for_hand_attack", &[palm.to_variant()]);
                }
            }
        }
        if crushing {
            self.release_hand_target(attack, rival.as_deref_mut());
            self.damage_hand_target(actor, attack, rival, palm);
        }
    }

    fn grasp_hand_target(
        &mut self,
        attack: &mut HandAttack,
        rival: Option<&mut Giant>,
        attacker_height: f32,
    ) {
        if let Some(mut audio) = self.audio() {
            audio.call(
                "play_hand_action",
                &[
                    StringName::from("grab").to_variant(),
                    attack.point.to_variant(),
                    attacker_height.to_variant(),
                ],
            );
        }
        let (body, height) = match attack.target {
            HandTarget::Giant(_) => {
                let rival = rival.unwrap();
                rival.grabbed = true;
                rival.footfall = None;
                rival.pending_hand = None;
                self.rivals.retain(|other| other.index != rival.index);
                let height = rival.height(self.max_height);
                (&mut rival.body, height)
            }
            HandTarget::Civilian(id) => {
                let npc = self
                    .civilians
                    .iter_mut()
                    .find(|npc| npc.body.instance_id() == id)
                    .unwrap();
                npc.grabbed = true;
                npc.body.call("set_render_active", &[true.to_variant()]);
                npc.body
                    .call("show_motion", &[0.0.to_variant(), false.to_variant()]);
                (&mut npc.body, npc.size.height)
            }
            HandTarget::Scenery(index) => {
                self.targets[index].grabbed = true;
                attack.held = Some(HeldTarget::Scenery(index));
                return;
            }
        };
        attack.held = Some(HeldTarget::Character {
            height,
            origin: body.get_global_position(),
            layer: body.get_collision_layer(),
            mask: body.get_collision_mask(),
            body: body.clone(),
        });
        body.set_collision_layer(0);
        body.set_collision_mask(0);
        body.set_velocity(Vector3::ZERO);
    }

    fn release_hand_target(&mut self, attack: &mut HandAttack, rival: Option<&mut Giant>) {
        let Some(held) = attack.held.take() else {
            return;
        };
        match held {
            HeldTarget::Character {
                mut body,
                origin,
                layer,
                mask,
                ..
            } => {
                body.set_global_position(origin);
                body.set_collision_layer(layer);
                body.set_collision_mask(mask);
                if let Some(rival) = rival {
                    rival.grabbed = false;
                } else if let Some(npc) = self.civilians.iter_mut().find(|npc| npc.body == body) {
                    npc.grabbed = false;
                }
            }
            HeldTarget::Scenery(index) => {
                let target = &mut self.targets[index];
                target.grabbed = false;
                target.node.call("release_from_hand_attack", &[]);
            }
        }
    }

    fn damage_hand_target(
        &mut self,
        actor: &mut Giant,
        attack: &HandAttack,
        rival: Option<&mut Giant>,
        palm: Vector3,
    ) {
        let crushing = attack.kind == HandMove::GrabCrush;
        if let Some(mut audio) = self.audio() {
            audio.call(
                "play_hand_action",
                &[
                    StringName::from(if crushing { "crush" } else { "punch" }).to_variant(),
                    palm.to_variant(),
                    actor.height(self.max_height).to_variant(),
                ],
            );
        }
        let punch_damage = 2.0 * self.growth_stat(actor, self.combat_rules().base_attack);
        match attack.target {
            HandTarget::Giant(_) => {
                let rival = rival.unwrap();
                let damage = if crushing {
                    self.growth_stat(rival, self.combat_rules().base_health)
                } else {
                    punch_damage
                };
                let method = if crushing {
                    DefeatMethod::GrabCrush
                } else {
                    DefeatMethod::Punch
                };
                self.damage_rival(actor, rival, damage, method);
                if crushing {
                    rival.body.hide();
                }
            }
            HandTarget::Civilian(id) => {
                let npc = self
                    .civilians
                    .iter_mut()
                    .find(|npc| npc.body.instance_id() == id)
                    .unwrap();
                npc.hurt(punch_damage, crushing || self.growth_rules.is_none());
                if crushing {
                    npc.body.hide();
                }
            }
            HandTarget::Scenery(index) => self.damage_hand_scenery(actor, index, crushing),
        }
        let radius = actor.height(self.max_height) * 0.065;
        self.show_impact(
            ImpactArea {
                center: palm,
                yaw: 0.0,
                radii: Vector2::splat(radius),
            },
            crushing,
            true,
            actor.scale.min(1.0),
        );
    }

    fn damage_hand_scenery(&mut self, actor: &mut Giant, index: usize, crushing: bool) {
        let growth = self.growth_rules;
        let rebuild = self.building_rebuild_time();
        let target = &mut self.targets[index];
        let building = target.footprint.building;
        let hit = if growth.is_some() {
            if building {
                2.0 * GROWTH_BUILDING_INTEGRITY
                    / growth_building_hits(actor.height(self.max_height)) as f32
            } else {
                6000.0
            }
        } else {
            2.0
        };
        self.strike += 1;
        let destroyed = match target.integrity.hit(self.strike, hit, crushing) {
            Damage::Ignored => return,
            Damage::Cracked => false,
            Damage::Destroyed => true,
        };
        target.node.call(
            "strike",
            &[
                destroyed.to_variant(),
                Variant::nil(),
                (building && rebuild.is_some()).to_variant(),
                crushing.to_variant(),
            ],
        );
        if destroyed && building {
            self.destroyed_buildings += 1;
            actor.progress.destroyed += 1;
            actor.replan_in = 0.0;
            if let Some(deadline) = rebuild {
                self.building_respawns.push((index, deadline));
            }
            self.reward_building_growth(actor);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::HandMove::{GrabCrush, Punch};

    #[test]
    fn hand_attack_ratios_include_equality_and_use_the_smaller_height() {
        for factor in [0.01, 1.0, 200.0] {
            assert!(GrabCrush.size_allows(3.0 * factor, factor));
            assert!(GrabCrush.size_allows(4.0 * factor, factor));
            assert!(!GrabCrush.size_allows(2.999 * factor, factor));
            assert!(!GrabCrush.size_allows(factor, 3.0 * factor));
            assert!(Punch.size_allows(factor, 2.0 * factor));
            assert!(Punch.size_allows(2.0 * factor, factor));
            assert!(!Punch.size_allows(factor, 2.001 * factor));
            assert!(!Punch.size_allows(2.001 * factor, factor));
        }
    }
}
