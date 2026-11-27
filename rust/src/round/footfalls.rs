use super::*;

/// Broad-phase reach used for navigation and danger scoring. Actual hit tests
/// use the current shoe's outline and never this radius.
pub(super) fn footfall_reach(scale: f32) -> f32 {
    7.5 * scale
}

#[derive(Clone)]
pub(super) struct Footfall {
    pub center: Vector3,
    pub yaw: f32,
    pub half_extents: Vector2,
    pub left: bool,
    /// The skin's convex sole outline, normalized in local X/Z (toe toward -Z).
    pub profile: PackedVector2Array,
}

impl Footfall {
    pub fn from_script(contact: &VarDictionary) -> Option<Self> {
        let center: Vector3 = contact.get("center")?.try_to().ok()?;
        let yaw: f32 = contact.get("yaw")?.try_to().ok()?;
        let half_extents: Vector2 = contact.get("half_extents")?.try_to().ok()?;
        let left: bool = contact.get("left")?.try_to().ok()?;
        let profile: PackedVector2Array = contact.get("profile")?.try_to().ok()?;
        if !center.is_finite()
            || !yaw.is_finite()
            || !half_extents.is_finite()
            || half_extents.x <= 0.0
            || half_extents.y <= 0.0
            || profile.len() < 3
        {
            return None;
        }
        Some(Self {
            center,
            yaw,
            half_extents,
            left,
            profile,
        })
    }

    pub fn bounds(&self) -> f32 {
        self.half_extents.length()
    }

    fn local(&self, point: Vector3) -> Vector2 {
        let offset = (point - self.center).rotated(Vector3::UP, -self.yaw);
        Vector2::new(offset.x, offset.z)
    }

    pub fn reaches(&self, point: Vector3, radius: f32) -> bool {
        if horizontal(point - self.center).length_squared() > (self.bounds() + radius).powi(2) {
            return false;
        }
        let shape = LocalSole {
            points: self.profile.as_slice(),
            half_extents: self.half_extents,
        };
        shape.reaches(self.local(point), radius)
    }

    pub fn touches(&self, footprint: Footprint) -> bool {
        let half = footprint.size * 0.5;
        let corners = [
            Vector3::new(-half.x, 0.0, -half.z),
            Vector3::new(half.x, 0.0, -half.z),
            Vector3::new(half.x, 0.0, half.z),
            Vector3::new(-half.x, 0.0, half.z),
        ]
        .map(|corner| self.local(footprint.transform * corner));
        let shape = LocalSole {
            points: self.profile.as_slice(),
            half_extents: self.half_extents,
        };
        shape.touches(&corners)
    }

    pub fn set_debug(&self, row: &mut VarDictionary, landed: bool) {
        if landed {
            row.set("last_footfall_center", self.center);
            row.set("last_footfall_yaw", self.yaw);
            row.set("last_footfall_half_extents", self.half_extents);
            row.set("last_footfall_left", self.left);
        } else {
            row.set("footfall_center", self.center);
            row.set("footfall_yaw", self.yaw);
            row.set("footfall_half_extents", self.half_extents);
            row.set("footfall_left", self.left);
            row.set("footfall_profile", &self.profile);
        }
    }
}

#[derive(Clone)]
pub(super) struct FootfallPreview {
    pub sole: Footfall,
    pub eta: f32,
}

impl FootfallPreview {
    pub fn from_script(value: Variant) -> Option<Self> {
        let dict: VarDictionary = value.try_to().ok()?;
        let eta: f32 = dict.get("eta")?.try_to().ok()?;
        Some(Self {
            sole: Footfall::from_script(&dict)?,
            eta,
        })
    }

    pub fn threatens(&self, position: Vector3, radius: f32) -> bool {
        (position.y - self.sole.center.y).abs() <= (radius * 2.0).max(0.25)
            && self.sole.reaches(position, radius)
    }
}

struct LocalSole<'a> {
    points: &'a [Vector2],
    half_extents: Vector2,
}

impl LocalSole<'_> {
    fn edges(&self) -> impl Iterator<Item = (Vector2, Vector2)> + '_ {
        edges(self.points).map(|(a, b)| (a * self.half_extents, b * self.half_extents))
    }

    fn reaches(&self, point: Vector2, radius: f32) -> bool {
        point_in_convex_polygon(self.edges(), point)
            || self.edges().any(|(a, b)| {
                let edge = b - a;
                let t = ((point - a).dot(edge) / edge.length_squared().max(f32::MIN_POSITIVE))
                    .clamp(0.0, 1.0);
                point.distance_squared_to(a + edge * t) <= radius * radius
            })
    }

    fn touches(&self, corners: &[Vector2; 4]) -> bool {
        // Separating axes for both convex polygons include every outline edge.
        let sole = || self.points.iter().map(|point| *point * self.half_extents);
        self.edges().chain(edges(corners)).all(|(a, b)| {
            let axis = Vector2::new(b.y - a.y, a.x - b.x);
            let bounds = |points: &mut dyn Iterator<Item = Vector2>| {
                points.fold((f32::INFINITY, f32::NEG_INFINITY), |(min, max), point| {
                    let projection = point.dot(axis);
                    (min.min(projection), max.max(projection))
                })
            };
            let (sole_min, sole_max) = bounds(&mut sole());
            let (target_min, target_max) = bounds(&mut corners.iter().copied());
            sole_min <= target_max && target_min <= sole_max
        })
    }
}

fn edges(points: &[Vector2]) -> impl Iterator<Item = (Vector2, Vector2)> + '_ {
    points
        .iter()
        .copied()
        .zip(points.iter().copied().cycle().skip(1))
}

fn point_in_convex_polygon(
    edges: impl Iterator<Item = (Vector2, Vector2)>,
    point: Vector2,
) -> bool {
    let mut positive = false;
    let mut negative = false;
    for (start, end) in edges {
        let side = (end - start).cross(point - start);
        positive |= side > 0.0;
        negative |= side < 0.0;
        if positive && negative {
            return false;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    const OUTLINE: [Vector2; 7] = [
        Vector2::new(-0.60, -1.0),
        Vector2::new(0.65, -1.0),
        Vector2::new(1.0, -0.55),
        Vector2::new(0.45, 0.95),
        Vector2::new(-0.35, 1.0),
        Vector2::new(-0.6, 0.3),
        Vector2::new(-1.0, -0.55),
    ];

    #[test]
    fn sole_hit_uses_shaped_edges_and_world_radius() {
        let sole = LocalSole {
            points: &OUTLINE,
            half_extents: Vector2::new(1.0, 2.0),
        };
        assert!(sole.reaches(Vector2::new(-0.4, -1.9), 0.0));
        assert!(!sole.reaches(Vector2::new(0.85, 1.70), 0.20));
        assert!(sole.reaches(Vector2::new(0.85, 1.70), 0.36));
    }

    #[test]
    fn rotated_building_edges_intersect_the_sole_but_corner_voids_do_not() {
        let sole = LocalSole {
            points: &OUTLINE,
            half_extents: Vector2::new(1.0, 2.0),
        };
        let crossing = [
            Vector2::new(-3.0, -0.4),
            Vector2::new(-2.9, -0.6),
            Vector2::new(3.0, 0.4),
            Vector2::new(2.9, 0.6),
        ];
        let outside = [
            Vector2::new(0.85, 1.9),
            Vector2::new(1.0, 1.8),
            Vector2::new(1.15, 1.9),
            Vector2::new(1.0, 2.0),
        ];
        assert!(sole.touches(&crossing));
        assert!(!sole.touches(&outside));
    }
}
