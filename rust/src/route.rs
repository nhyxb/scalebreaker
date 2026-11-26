use std::cell::RefCell;
use std::cmp::Reverse;
use std::collections::BinaryHeap;

use godot::prelude::*;

const ROAD_SPACING: f32 = 36.0;
const MAX_GRID_SIDE: usize = 128;
const UNREACHABLE: u32 = u32::MAX;
const NO_PARENT: u32 = u32::MAX;
const CELL_RESOLVED: u8 = 1 << 2;
const CELL_BUILDING: u8 = 1;
const CELL_BARRIER: u8 = 1 << 1;
/// Clearance added to a footprint in the building pass and in the cheaper barrier pass.
/// Bucket membership uses the larger pad so a cell never misses an obstacle its own pass
/// would have touched.
const BUILDING_PAD: f32 = 0.32;
const BARRIER_PAD: f32 = 0.1;
/// Guards against a cell centre landing exactly on the transformed footprint bounds.
const BOUND_EPSILON: f32 = 0.001;

#[derive(Clone, Copy)]
pub struct Footprint {
    pub transform: Transform3D,
    pub size: Vector3,
    pub building: bool,
}

impl Footprint {
    pub fn touches(&self, point: Vector3, radius: f32) -> bool {
        let local = self.transform.affine_inverse() * point;
        let dx = (local.x.abs() - self.size.x * 0.5).max(0.0);
        let dz = (local.z.abs() - self.size.z * 0.5).max(0.0);
        dx * dx + dz * dz <= radius * radius
    }
}

/// A footprint with its inverse transform and horizontal world bounds precomputed.
///
/// The old planner inverted a footprint transform for every grid cell it tested. On the
/// harbour's dense maps that was millions of matrix inversions per long route. Preparing
/// each footprint once and bucketing it into the grid cells it can touch keeps a cell query
/// proportional to the few obstacles beside it.
struct Prepared {
    inverse: Transform3D,
    half: Vector3,
    building: bool,
    min_x: f32,
    max_x: f32,
    min_z: f32,
    max_z: f32,
}

impl Prepared {
    fn new(footprint: Footprint, radius: f32) -> Self {
        let half = footprint.size * 0.5;
        let mut min_x = f32::INFINITY;
        let mut max_x = f32::NEG_INFINITY;
        let mut min_z = f32::INFINITY;
        let mut max_z = f32::NEG_INFINITY;
        for corner in [
            Vector3::new(-half.x, 0.0, -half.z),
            Vector3::new(half.x, 0.0, -half.z),
            Vector3::new(half.x, 0.0, half.z),
            Vector3::new(-half.x, 0.0, half.z),
        ] {
            let world = footprint.transform * corner;
            min_x = min_x.min(world.x);
            max_x = max_x.max(world.x);
            min_z = min_z.min(world.z);
            max_z = max_z.max(world.z);
        }
        // The building pass uses the larger clearance, so the bounds cover both passes.
        let pad = radius + BUILDING_PAD + BOUND_EPSILON;
        Self {
            inverse: footprint.transform.affine_inverse(),
            half,
            building: footprint.building,
            min_x: min_x - pad,
            max_x: max_x + pad,
            min_z: min_z - pad,
            max_z: max_z + pad,
        }
    }

    fn touches(&self, point: Vector3, radius: f32) -> bool {
        #[cfg(test)]
        counters::TOUCHES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let local = self.inverse * point;
        let dx = (local.x.abs() - self.half.x).max(0.0);
        let dz = (local.z.abs() - self.half.z).max(0.0);
        dx * dx + dz * dz <= radius * radius
    }
}

#[cfg(test)]
mod counters {
    use std::sync::atomic::{AtomicUsize, Ordering};

    pub(super) static TOUCHES: AtomicUsize = AtomicUsize::new(0);

    pub(super) fn reset() {
        TOUCHES.store(0, Ordering::Relaxed);
    }

    pub(super) fn touches() -> usize {
        TOUCHES.load(Ordering::Relaxed)
    }
}

#[derive(Default)]
struct PlanScratch {
    occupancy: Vec<u8>,
    cost: Vec<u32>,
    parent: Vec<u32>,
    search: BinaryHeap<Reverse<(u32, u32, usize)>>,
    prepared: Vec<Prepared>,
    /// Compressed cell -> prepared-index buckets: `bucket_items[start..end]` for a cell.
    bucket_start: Vec<u32>,
    bucket_cursor: Vec<u32>,
    bucket_items: Vec<u32>,
    route: Vec<Vector3>,
}

thread_local! {
    static SCRATCH: RefCell<PlanScratch> = RefCell::new(PlanScratch::default());
}

/// Searches a window around the endpoints, increasing the grid step on long routes.
///
/// Every cell only tests the obstacles bucketed next to it, so the cost follows the number
/// of obstacles a route can actually reach instead of the whole search window.
pub fn plan(
    start: Vector3,
    goal: Vector3,
    obstacles: &[Footprint],
    radius: f32,
    world_limit: f32,
) -> Vec<Vector3> {
    SCRATCH.with(|scratch| {
        plan_with(
            &mut scratch.borrow_mut(),
            start,
            goal,
            obstacles,
            radius,
            world_limit,
            false,
        )
    })
}

fn plan_with(
    scratch: &mut PlanScratch,
    start: Vector3,
    goal: Vector3,
    obstacles: &[Footprint],
    radius: f32,
    world_limit: f32,
    scan_all: bool,
) -> Vec<Vector3> {
    let span = (goal.x - start.x).abs().max((goal.z - start.z).abs());
    let mut cell = if span <= 140.0 { 2.0 } else { 4.0 };
    let margin = 44.0;

    let lower = Vector2::new(start.x.min(goal.x) - margin, start.z.min(goal.z) - margin);
    let upper = Vector2::new(start.x.max(goal.x) + margin, start.z.max(goal.z) + margin);
    let (min_x, max_x, min_z, max_z, cols, rows) = loop {
        let low = |value: f32| (value.max(-world_limit) / cell).ceil() * cell;
        let high = |value: f32| (value.min(world_limit) / cell).floor() * cell;
        let (min_x, max_x) = (low(lower.x), high(upper.x));
        let (min_z, max_z) = (low(lower.y), high(upper.y));
        let cols = ((max_x - min_x) / cell).round() as usize + 1;
        let rows = ((max_z - min_z) / cell).round() as usize + 1;
        if cols <= MAX_GRID_SIDE && rows <= MAX_GRID_SIDE {
            break (min_x, max_x, min_z, max_z, cols, rows);
        }
        cell *= 2.0;
    };
    let total = cols * rows;

    // Copy the obstacles that can reach this window and prepare them once.
    scratch.prepared.clear();
    for footprint in obstacles {
        let prepared = Prepared::new(*footprint, radius);
        if prepared.max_x < min_x
            || prepared.min_x > max_x
            || prepared.max_z < min_z
            || prepared.min_z > max_z
        {
            continue;
        }
        scratch.prepared.push(prepared);
    }

    // Bucket each prepared footprint into the cells whose centres its bounds can cover.
    // `bucket_start` first stores per-cell counts, then becomes the CSR row offset array.
    scratch.bucket_start.clear();
    scratch.bucket_start.resize(total + 1, 0);
    if !scan_all {
        for index in 0..scratch.prepared.len() {
            let Some((x0, x1, z0, z1)) = prepared_cells(
                &scratch.prepared[index],
                min_x,
                min_z,
                cell,
                cols,
                rows,
            ) else {
                continue;
            };
            for z in z0..=z1 {
                for x in x0..=x1 {
                    scratch.bucket_start[z * cols + x + 1] += 1;
                }
            }
        }
        for index in 0..total {
            scratch.bucket_start[index + 1] += scratch.bucket_start[index];
        }
        let items = scratch.bucket_start[total] as usize;
        scratch.bucket_items.clear();
        scratch.bucket_items.resize(items, 0);
        scratch.bucket_cursor.clear();
        scratch
            .bucket_cursor
            .extend_from_slice(&scratch.bucket_start[..total]);
        for index in 0..scratch.prepared.len() {
            let Some((x0, x1, z0, z1)) = prepared_cells(
                &scratch.prepared[index],
                min_x,
                min_z,
                cell,
                cols,
                rows,
            ) else {
                continue;
            };
            for z in z0..=z1 {
                for x in x0..=x1 {
                    let slot = z * cols + x;
                    let at = scratch.bucket_cursor[slot] as usize;
                    scratch.bucket_items[at] = index as u32;
                    scratch.bucket_cursor[slot] += 1;
                }
            }
        }
    }

    let PlanScratch {
        occupancy,
        cost,
        parent,
        search,
        prepared,
        bucket_start,
        bucket_items,
        route,
        ..
    } = scratch;

    let cell_of = |point: Vector3| -> usize {
        let gx = ((point.x - min_x) / cell)
            .round()
            .clamp(0.0, (cols - 1) as f32) as usize;
        let gz = ((point.z - min_z) / cell)
            .round()
            .clamp(0.0, (rows - 1) as f32) as usize;
        gz * cols + gx
    };
    let center_of = |index: usize| -> Vector3 {
        Vector3::new(
            min_x + (index % cols) as f32 * cell,
            0.0,
            min_z + (index / cols) as f32 * cell,
        )
    };
    let heuristic = |from: usize, to: usize| -> u32 {
        ((from % cols).abs_diff(to % cols) + (from / cols).abs_diff(to / cols)) as u32 * 10
    };
    let distance_sq = |index: usize, point: Vector3| -> f32 {
        center_of(index).distance_squared_to(Vector3::new(point.x, 0.0, point.z))
    };

    occupancy.clear();
    occupancy.resize(total, 0);
    let mut obstacle_flags = |index: usize| -> (bool, bool) {
        let flags = &mut occupancy[index];
        if *flags & CELL_RESOLVED == 0 {
            let point = center_of(index);
            let mut resolved = CELL_RESOLVED;
            let mut check = |obstacle: &Prepared| {
                if obstacle.building {
                    if obstacle.touches(point, radius + BUILDING_PAD) {
                        resolved |= CELL_BUILDING;
                    }
                } else if obstacle.touches(point, radius + BARRIER_PAD) {
                    resolved |= CELL_BARRIER;
                }
            };
            if scan_all {
                for obstacle in prepared.iter() {
                    check(obstacle);
                }
            } else {
                let start = bucket_start[index] as usize;
                let end = bucket_start[index + 1] as usize;
                for &item in &bucket_items[start..end] {
                    check(&prepared[item as usize]);
                }
            }
            *flags = resolved;
        }
        (*flags & CELL_BUILDING != 0, *flags & CELL_BARRIER != 0)
    };

    cost.resize(total, UNREACHABLE);
    cost.fill(UNREACHABLE);
    parent.resize(total, NO_PARENT);
    parent.fill(NO_PARENT);
    search.clear();

    let start_idx = cell_of(start);
    let goal_idx = cell_of(goal);
    let mut closest = start_idx;

    cost[start_idx] = 0;
    search.push(Reverse((heuristic(start_idx, goal_idx), 0, start_idx)));
    while let Some(Reverse((_, traveled, current))) = search.pop() {
        if traveled != cost[current] {
            continue;
        }
        if distance_sq(current, goal) < distance_sq(closest, goal) {
            closest = current;
        }
        if current == goal_idx {
            closest = current;
            break;
        }
        let x = current % cols;
        let z = current / cols;
        for (nx, nz) in [
            (x.wrapping_sub(1), z),
            (x + 1, z),
            (x, z.wrapping_sub(1)),
            (x, z + 1),
        ] {
            if nx >= cols || nz >= rows {
                continue;
            }
            let next = nz * cols + nx;
            let point = center_of(next);
            let (building, barrier) = obstacle_flags(next);
            if building {
                continue;
            }
            let on_road = [point.x, point.z].iter().any(|axis| is_on_road(*axis));
            let entering_barrier = barrier && !obstacle_flags(current).1;
            let new_cost =
                traveled + if on_road { 10 } else { 14 } + if entering_barrier { 26 } else { 0 };
            if new_cost < cost[next] {
                cost[next] = new_cost;
                parent[next] = current as u32;
                search.push(Reverse((
                    new_cost + heuristic(next, goal_idx),
                    new_cost,
                    next,
                )));
            }
        }
    }
    route.clear();
    while parent[closest] != NO_PARENT {
        route.push(center_of(closest));
        closest = parent[closest] as usize;
    }
    // The follower consumes points from the back.
    std::mem::take(route)
}

/// Grid cells whose centres can lie inside the prepared footprint bounds.
fn prepared_cells(
    prepared: &Prepared,
    min_x: f32,
    min_z: f32,
    cell: f32,
    cols: usize,
    rows: usize,
) -> Option<(usize, usize, usize, usize)> {
    let (x0, x1) = cell_range(prepared.min_x, prepared.max_x, min_x, cell, cols)?;
    let (z0, z1) = cell_range(prepared.min_z, prepared.max_z, min_z, cell, rows)?;
    Some((x0, x1, z0, z1))
}

fn cell_range(min: f32, max: f32, origin: f32, cell: f32, count: usize) -> Option<(usize, usize)> {
    let last = origin + count.saturating_sub(1) as f32 * cell;
    if max < origin || min > last {
        return None;
    }
    let first = ((min - origin) / cell).ceil().max(0.0);
    let last = ((max - origin) / cell).floor().min((count - 1) as f32);
    if first > last {
        return None;
    }
    Some((first as usize, last as usize))
}

fn is_on_road(axis: f32) -> bool {
    let abs = axis.abs();
    let rem = abs % ROAD_SPACING;
    rem <= 4.0 || (ROAD_SPACING - rem) <= 4.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules::GIANT_RADIUS;

    #[test]
    fn route_prefers_the_street_through_a_destructible_barrier() {
        let wall = Footprint {
            transform: Transform3D::IDENTITY,
            size: Vector3::new(9.6, 1.0, 1.0),
            building: false,
        };
        let route = plan(
            Vector3::new(0.0, 0.0, 16.0),
            Vector3::new(0.0, 0.0, -18.0),
            &[wall],
            GIANT_RADIUS,
            704.0,
        );
        assert!(route.iter().any(|point| wall.touches(*point, 1.0)));
        assert_eq!(route.first().unwrap().z, -18.0);
    }

    #[test]
    fn route_goes_around_a_standing_building() {
        let building = Footprint {
            transform: Transform3D::IDENTITY,
            size: Vector3::new(10.0, 10.0, 10.0),
            building: true,
        };
        let route = plan(
            Vector3::new(0.0, 0.0, 16.0),
            Vector3::new(0.0, 0.0, -18.0),
            &[building],
            GIANT_RADIUS,
            704.0,
        );
        assert!(
            route
                .iter()
                .all(|point| !building.touches(*point, GIANT_RADIUS))
        );
        assert_eq!(route.first().unwrap().z, -18.0);
    }

    #[test]
    fn route_scales_across_expanded_harbor_districts() {
        let tower = Footprint {
            transform: Transform3D::new(Basis::IDENTITY, Vector3::new(108.0, 0.0, 0.0)),
            size: Vector3::new(14.0, 30.0, 14.0),
            building: true,
        };
        let route = plan(
            Vector3::new(108.0, 0.0, 600.0),
            Vector3::new(108.0, 0.0, -600.0),
            &[tower],
            GIANT_RADIUS,
            704.0,
        );
        assert!(!route.is_empty());
        assert!(route.first().unwrap().z <= -592.0);
        assert!(
            route
                .iter()
                .all(|point| !tower.touches(*point, GIANT_RADIUS))
        );
    }

    fn dense_city(side: usize, spacing: f32, span: f32) -> Vec<Footprint> {
        let mut obstacles = Vec::new();
        for z in 0..side {
            for x in 0..side {
                let fx = -span * 0.5 + x as f32 * spacing + spacing * 0.3;
                let fz = -span * 0.5 + z as f32 * spacing + spacing * 0.3;
                obstacles.push(Footprint {
                    transform: Transform3D::new(Basis::IDENTITY, Vector3::new(fx, 0.0, fz)),
                    size: Vector3::new(9.0, 10.0, 9.0),
                    building: (x * 7 + z * 3) % 5 != 0,
                });
            }
        }
        obstacles
    }

    #[test]
    fn bucketed_queries_match_a_full_obstacle_scan() {
        let obstacles = dense_city(18, 34.0, 620.0);
        for (start, goal) in [
            (
                Vector3::new(-280.0, 0.0, -280.0),
                Vector3::new(280.0, 0.0, 280.0),
            ),
            (
                Vector3::new(-100.0, 0.0, 250.0),
                Vector3::new(260.0, 0.0, -40.0),
            ),
            (Vector3::new(0.0, 0.0, 16.0), Vector3::new(0.0, 0.0, -18.0)),
        ] {
            let bucketed = plan(start, goal, &obstacles, GIANT_RADIUS, 704.0);
            let full = SCRATCH.with(|scratch| {
                plan_with(
                    &mut scratch.borrow_mut(),
                    start,
                    goal,
                    &obstacles,
                    GIANT_RADIUS,
                    704.0,
                    true,
                )
            });
            assert_eq!(
                bucketed, full,
                "bucketing changed the route from {start} to {goal}"
            );
        }
    }

    #[test]
    fn dense_route_only_touches_obstacles_beside_the_search_window() {
        let obstacles = dense_city(28, 25.0, 700.0);
        counters::reset();
        let route = plan(
            Vector3::new(-330.0, 0.0, -330.0),
            Vector3::new(330.0, 0.0, 330.0),
            &obstacles,
            GIANT_RADIUS,
            704.0,
        );
        assert!(!route.is_empty());
        let touches = counters::touches();
        // A scan of every cell against every footprint would be millions of tests here.
        assert!(
            touches < 120_000,
            "bucketed planning tested {touches} footprints; nearby obstacles are not filtered"
        );
    }

    #[test]
    fn prepared_bounds_cover_rotated_footprints() {
        let rotated = Footprint {
            transform: Transform3D::new(
                Basis::from_axis_angle(Vector3::UP, 0.7),
                Vector3::new(20.0, 0.0, -12.0),
            ),
            size: Vector3::new(10.0, 6.0, 26.0),
            building: true,
        };
        let prepared = Prepared::new(rotated, 2.9);
        for point in [
            rotated.transform * Vector3::new(-5.0, 0.0, -13.0),
            rotated.transform * Vector3::new(5.0, 0.0, 13.0),
            rotated.transform * Vector3::new(-5.0, 0.0, 13.0),
            rotated.transform * Vector3::new(5.0, 0.0, -13.0),
        ] {
            assert!(point.x >= prepared.min_x && point.x <= prepared.max_x);
            assert!(point.z >= prepared.min_z && point.z <= prepared.max_z);
        }
    }
}

