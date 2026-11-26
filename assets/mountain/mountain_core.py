
import math
import numpy as np
from mathutils import Vector, noise

# Canonical mountain dimensions (meters)
W_DEF = 1418.0
D_DEF = 1300.0
H_DEF = 400.0
HALF_W = W_DEF * 0.5   # 709.0
HALF_D = D_DEF * 0.5   # 650.0

# Key summit landmarks — seamlessly nestled into the broad summit ridge!
PEAK_CENTER    = (-165.0, -68.0)   # Main Peak 400.0m (west-central crest, harbor-side of center)
PLATEAU_CENTER = (65.0,   -82.0)   # Harbor-facing Overlook Plateau ON the broad ridge (zero turret!)
PLATEAU_RX     = 58.0              # ~116m wide east-west
PLATEAU_RY     = 36.0              # ~72m deep north-south
PLATEAU_Z      = 350.0             # Overlook plateau height (main peak rises 50m higher to 400m!)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def smootherstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


# Cross-section profile matching user's reference graph:
# u = (y + 650) / 1300 in [0, 1], left=0 (接郊外), right=1 (向内陆)
_PROFILE_U = np.array([
    0.00, 0.075, 0.135, 0.195, 0.255, 0.315, 0.370, 0.420,
    0.458, 0.505, 0.575, 0.655, 0.740, 0.825, 0.905, 0.960, 1.00
], dtype=np.float64)

_PROFILE_H = np.array([
    0.0,  0.0,   12.0,  46.0,  108.0, 214.0, 322.0, 368.0,
    392.0, 372.0, 324.0, 266.0, 198.0, 126.0, 64.0,  22.0, 0.0
], dtype=np.float64)


def _pchip_interp_1d(u, xs, ys):
    u = np.clip(u, xs[0], xs[-1])
    n = len(xs)
    h = np.diff(xs)
    delta = np.diff(ys) / h
    m = np.zeros(n, dtype=np.float64)
    for i in range(1, n - 1):
        if delta[i - 1] * delta[i] > 0.0:
            w1 = 2.0 * h[i] + h[i - 1]
            w2 = h[i] + 2.0 * h[i - 1]
            m[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i])
    idx = np.clip(np.searchsorted(xs, u, side='right') - 1, 0, n - 2)
    x0 = xs[idx]
    x1 = xs[idx + 1]
    t = (u - x0) / (x1 - x0)
    t2 = t * t
    t3 = t2 * t
    return (
        (2 * t3 - 3 * t2 + 1) * ys[idx] +
        (t3 - 2 * t2 + t) * (x1 - x0) * m[idx] +
        (-2 * t3 + 3 * t2) * ys[idx + 1] +
        (t3 - t2) * (x1 - x0) * m[idx + 1]
    )


def _blender_geology_noise(x, y):
    """True Blender C++ multi-octave Perlin & Ridged Multifractal geology."""
    fx = x.ravel()
    fy = y.ravel()
    n = len(fx)
    macro = np.empty(n, dtype=np.float64)
    ridged = np.empty(n, dtype=np.float64)
    detail = np.empty(n, dtype=np.float64)

    _fbm = noise.fractal
    _rmf = noise.ridged_multi_fractal
    _Vec = Vector

    s_macro = 1.0 / 320.0
    s_ridge = 1.0 / 210.0
    s_det   = 1.0 / 82.0

    for i in range(n):
        px = float(fx[i])
        py = float(fy[i])
        wx = _fbm(_Vec((px * 0.0022 + 11.3, py * 0.0022 - 4.7, 1.2)), 0.9, 2.0, 2) * 56.0
        wy = _fbm(_Vec((px * 0.0022 - 7.1,  py * 0.0022 + 9.4, 3.8)), 0.9, 2.0, 2) * 56.0
        qx = px + wx
        qy = py + wy

        macro[i]  = _fbm(_Vec((qx * s_macro + 3.1, qy * s_macro + 7.4, 2.5)), 0.85, 2.05, 4)
        r_val = _rmf(_Vec((qx * s_ridge + 17.2, qy * s_ridge - 5.9, 4.1)), 0.85, 2.1, 4, 1.0, 1.6)
        ridged[i] = r_val - 0.85
        detail[i] = _fbm(_Vec((px * s_det - 2.3, py * s_det + 13.7, 6.4)), 0.9, 2.0, 3)

    return macro.reshape(x.shape), ridged.reshape(x.shape), detail.reshape(x.shape)


_PEAK_SCALE_CALIB = 1.0


def natural_height_array(x, y):
    x = np.asarray(x, dtype=np.float64)
    y = np.asarray(y, dtype=np.float64)

    crest_shift = 28.0 * np.sin((x + 110.0) * 0.0036) + 0.00014 * (x + 20.0) ** 2
    y_eff = y - crest_shift

    u = (y_eff + HALF_D) / D_DEF
    base_prof = _pchip_interp_1d(u, _PROFILE_U, _PROFILE_H)

    # Organic coastal massif width envelope — broad across backslope so switchbacks stay supported,
    # while sloping naturally on all flanks (never boxy, never cylindrical!).
    back_w = smoothstep(-280.0, 240.0, y)
    x_center = -30.0 * (1.0 - back_w) - 5.0 * back_w
    dx_c = x - x_center

    east_side = smootherstep(-60.0, 180.0, dx_c)
    rx_west = 545.0 + 70.0 * back_w
    rx_east = 465.0 + 115.0 * back_w
    rx = rx_west * (1.0 - east_side) + rx_east * east_side

    nx = np.abs(dx_c) / rx
    ew_env = np.power(np.clip(1.0 - smootherstep(0.36, 1.08, nx), 0.0, 1.0), 0.82)

    # Natural geological spurs providing authentic support under East/West switchback shoulders & Overlook Ridge!
    spur_sw  = 130.0 * np.exp(-(((x + 410.0) / 170.0) ** 2 + ((y + 130.0) / 170.0) ** 2))
    spur_nw  = 175.0 * np.exp(-(((x + 400.0) / 190.0) ** 2 + ((y - 260.0) / 220.0) ** 2))
    spur_ne  = 190.0 * np.exp(-(((x - 380.0) / 195.0) ** 2 + ((y - 185.0) / 215.0) ** 2))
    # Broad natural eastern ridge shoulder supporting the Overlook Plateau & summit road arrival seamlessly!
    spur_ovl = 355.0 * np.exp(-(((x - 105.0) / 230.0) ** 2 + ((y + 62.0) / 155.0) ** 2))

    # Strict perimeter zero-skirt
    edge_front = smootherstep(-HALF_D + 55.0, -HALF_D + 165.0, y)
    edge_back  = 1.0 - smootherstep(HALF_D - 110.0, HALF_D - 18.0, y)
    edge_x     = 1.0 - smootherstep(HALF_W - 105.0, HALF_W - 18.0, np.abs(x))
    perimeter  = edge_front * edge_back * edge_x

    h = base_prof * ew_env
    # Smooth-max blend of main massif + spurs (C1 smooth, never sharp creases)
    spurs_base = spur_sw + spur_nw + spur_ne
    h = np.maximum(h, h * 0.58 + spurs_base * 0.82)

    # Smooth-max with the eastern ridge shoulder (k=45m) so the Overlook Plateau sits ON a natural mountain crest!
    k_sm = 45.0
    h_sh = spur_ovl * perimeter
    h_diff = np.clip(0.5 + 0.5 * (h_sh - h) / k_sm, 0.0, 1.0)
    h = h * (1.0 - h_diff) + h_sh * h_diff + k_sm * h_diff * (1.0 - h_diff) * 0.25

    # Heroic Main Peak 400m at (-165, -68) + West secondary shoulder at (-335, -45)
    d_peak = np.sqrt(((x - PEAK_CENTER[0]) / 185.0) ** 2 + ((y - PEAK_CENTER[1]) / 148.0) ** 2)
    peak_dome = 78.0 * np.exp(-d_peak ** 1.85 * 1.35)

    d_wpeak = np.sqrt(((x + 335.0) / 145.0) ** 2 + ((y + 45.0) / 130.0) ** 2)
    w_shoulder = 44.0 * np.exp(-d_wpeak ** 2 * 1.4)

    # Broad walkable summit ridge spine linking Main Peak (-165) cleanly across to Overlook Plateau (+65)
    ridge_t = np.clip((x - (-220.0)) / 380.0, 0.0, 1.0)
    ridge_y_center = -68.0 - 16.0 * ridge_t
    ridge_dist_y = np.abs(y - ridge_y_center)
    ridge_spine = (
        np.exp(-(ridge_dist_y / 96.0) ** 2)
        * smoothstep(-360.0, -175.0, x)
        * (1.0 - smoothstep(155.0, 325.0, x))
    )
    h = np.maximum(h, 336.0 * ridge_spine) + peak_dome + w_shoulder

    # True multi-octave Perlin + Ridged Multifractal coastal cliff geology
    macro, ridged, detail = _blender_geology_noise(x, y)
    front_cliff_w = (1.0 - smoothstep(-145.0, 65.0, y)) * smoothstep(-510.0, -205.0, y)
    back_slope_w  = smoothstep(-20.0, 175.0, y)
    alt_mask      = np.clip(h / 65.0, 0.0, 1.0)

    relief = (
        27.0 * macro  * (0.55 + 0.45 * front_cliff_w) +
        25.0 * ridged * (0.35 + 0.65 * front_cliff_w) +
        6.5  * detail * (0.45 + 0.55 * front_cliff_w)
    )
    relief = relief * (1.0 - 0.45 * back_slope_w) * alt_mask

    h = np.maximum(0.0, h + relief) * perimeter
    h = h * _PEAK_SCALE_CALIB

    # Seamlessly grade the flat Harbor Overlook Plateau INTO the natural ~350m ridge crest!
    # Wide feathering (0.95 -> 2.45) guarantees natural sloped cliffs around the terrace — ZERO turret look!
    px = (x - PLATEAU_CENTER[0]) / PLATEAU_RX
    py = (y - PLATEAU_CENTER[1]) / PLATEAU_RY
    pr = np.power(np.abs(px) ** 3.0 + np.abs(py) ** 3.0, 1.0 / 3.0)
    plat_blend = 1.0 - smootherstep(0.95, 2.35, pr)
    h = h * (1.0 - plat_blend) + PLATEAU_Z * plat_blend

    return np.maximum(0.0, h)


def _calibrate_peak():
    global _PEAK_SCALE_CALIB
    _PEAK_SCALE_CALIB = 1.0
    xs = np.linspace(-HALF_W, HALF_W, 180)
    ys = np.linspace(-HALF_D, HALF_D, 160)
    XX, YY = np.meshgrid(xs, ys)
    raw = natural_height_array(XX, YY)
    mx = float(np.max(raw))
    if mx > 1.0:
        _PEAK_SCALE_CALIB = H_DEF / mx

_calibrate_peak()


def natural_height_scalar(x, y):
    return float(natural_height_array(np.array([x]), np.array([y]))[0])


def find_backslope_y(x_val, z_target, y_min=-35.0, y_max=575.0):
    ys = np.linspace(y_min, y_max, 220)
    xs = np.full_like(ys, x_val)
    hs = natural_height_array(xs, ys)
    idx = int(np.argmin(np.abs(hs - z_target)))
    return float(ys[idx])


def _eval_catmull_rom_chain(ctrl_pts, samples_per_seg=44):
    pts = np.asarray(ctrl_pts, dtype=np.float64)
    p_start = 2.0 * pts[0] - pts[1]
    p_end = 2.0 * pts[-1] - pts[-2]
    ext = np.vstack([p_start, pts, p_end])
    out = []
    for i in range(1, len(ext) - 2):
        P0, P1, P2, P3 = ext[i - 1], ext[i], ext[i + 1], ext[i + 2]
        def tj(ti, pa, pb):
            return ti + max(float(np.linalg.norm(pb - pa)), 1e-6) ** 0.5
        t0 = 0.0
        t1 = tj(t0, P0, P1)
        t2 = tj(t1, P1, P2)
        t3 = tj(t2, P2, P3)
        n_s = samples_per_seg if i < len(ext) - 3 else samples_per_seg + 1
        ts = np.linspace(t1, t2, n_s, endpoint=(i == len(ext) - 3))
        for t in ts:
            A1 = (t1 - t) / (t1 - t0) * P0 + (t - t0) / (t1 - t0) * P1
            A2 = (t2 - t) / (t2 - t1) * P1 + (t - t1) / (t2 - t1) * P2
            A3 = (t3 - t) / (t3 - t2) * P2 + (t - t2) / (t3 - t2) * P3
            B1 = (t2 - t) / (t2 - t0) * A1 + (t - t0) / (t2 - t0) * A2
            B2 = (t3 - t) / (t3 - t1) * A2 + (t - t1) / (t3 - t1) * A3
            C  = (t2 - t) / (t2 - t1) * B1 + (t - t1) / (t2 - t1) * B2
            out.append(C)
    return np.array(out, dtype=np.float64)


def _resample_arc_length_2d(xy, step=4.5):
    diffs = np.diff(xy, axis=0)
    seg_len = np.hypot(diffs[:, 0], diffs[:, 1])
    cum = np.concatenate([[0.0], np.cumsum(seg_len)])
    total = cum[-1]
    n = int(round(total / step)) + 1
    s_new = np.linspace(0.0, total, n)
    x_new = np.interp(s_new, cum, xy[:, 0])
    y_new = np.interp(s_new, cum, xy[:, 1])
    return np.column_stack([x_new, y_new]), s_new, total


def _smooth_gaussian_1d(arr, sigma_pts=6.0):
    radius = int(math.ceil(sigma_pts * 3.0))
    k = np.arange(-radius, radius + 1, dtype=np.float64)
    w = np.exp(-0.5 * (k / sigma_pts) ** 2)
    w /= w.sum()
    padded = np.pad(arr, radius, mode='edge')
    return np.convolve(padded, w, mode='valid')


def build_road_design(sample_step=4.5):
    """
    Contour-hugging switchback mountain highway:
    - Enters flush at suburban road edge (X=575, Y=-650, Z=0.0, 0% grade)
    - Stays LOW along the flat East foothill skirt (0 -> 26m) before sweeping onto the broad backslope
    - Climbs 4 wide sweeping switchback tiers with 3 huge hairpins (width 12m -> 22.5m, R >= 52m)
    - Arrives seamlessly flush at Z=350.0m (0% grade) on the Harbor Overlook Plateau!
    """
    def cp_back(x_v, z_v, y_min=-30.0, y_max=580.0):
        return (x_v, find_backslope_y(x_v, z_v, y_min=y_min, y_max=y_max))

    def hairpin_arc(x_entry, y_hi, y_lo, side_sign, n_pts=5):
        cy = 0.5 * (y_hi + y_lo)
        r = 0.5 * abs(y_hi - y_lo)
        pts = []
        for ang_deg in np.linspace(62.0, -62.0, n_pts):
            a = math.radians(ang_deg)
            pts.append((x_entry + side_sign * r * math.cos(a), cy + r * math.sin(a)))
        return pts

    # Place switchback tiers tightly on natural backslope contours!
    # Leg 1 starts low (~48m at east backslope) and climbs E->W to ~128m
    l1_e  = cp_back(340.0,  52.0, 390.0, 585.0)
    l1_m1 = cp_back(110.0,  78.0, 380.0, 580.0)
    l1_m2 = cp_back(-115.0, 102.0, 360.0, 575.0)
    l1_w  = cp_back(-310.0, 122.0, 330.0, 560.0)

    # Hairpin 1 (West Lower): climbs around natural west spur from ~122m to ~164m
    l2_w  = cp_back(-310.0, 166.0, 215.0, 425.0)
    hp1_mid_y = 0.5 * (l1_w[1] + l2_w[1])
    if abs(l1_w[1] - l2_w[1]) < 120.0:
        l1_w = (l1_w[0], hp1_mid_y + 60.0)
        l2_w = (l2_w[0], hp1_mid_y - 60.0)

    # Leg 2 (W->E): ~166 -> 228m
    l2_m1 = cp_back(-100.0, 186.0, 180.0, 410.0)
    l2_m2 = cp_back(120.0,  208.0, 160.0, 390.0)
    l2_e  = cp_back(310.0,  228.0, 140.0, 365.0)

    # Hairpin 2 (East Mid): climbs around natural NE spur from ~228m to ~262m
    l3_e  = cp_back(305.0,  262.0, 60.0, 275.0)
    hp2_mid_y = 0.5 * (l2_e[1] + l3_e[1])
    if abs(l2_e[1] - l3_e[1]) < 118.0:
        l2_e = (l2_e[0], hp2_mid_y + 59.0)
        l3_e = (l3_e[0], hp2_mid_y - 59.0)

    # Leg 3 (E->W): ~262 -> 304m
    l3_m1 = cp_back(95.0,   278.0, 40.0, 255.0)
    l3_m2 = cp_back(-110.0, 294.0, 30.0, 235.0)
    l3_w  = cp_back(-260.0, 306.0, 25.0, 215.0)

    # Hairpin 3 (West Upper): climbs from ~306m to ~330m
    l4_w  = cp_back(-260.0, 330.0, -30.0, 130.0)
    hp3_mid_y = 0.5 * (l3_w[1] + l4_w[1])
    if abs(l3_w[1] - l4_w[1]) < 114.0:
        l3_w = (l3_w[0], hp3_mid_y + 57.0)
        l4_w = (l4_w[0], hp3_mid_y - 57.0)

    # Leg 4 (W->E->S along broad natural ridge -> Overlook Plateau at (65, -82, 350))
    l4_m1 = cp_back(-90.0,  340.0, -30.0, 115.0)
    l4_m2 = cp_back(75.0,   346.0, -35.0,  95.0)

    ctrl_xy = [
        # Suburban highway foot entry (straight +Y, Z=0.0 flush!)
        (575.0, -650.0),
        (575.0, -535.0),
        (576.0, -370.0),
        # Low eastern coastal foothill corridor sweeping gently inland
        (580.0, -170.0),
        (582.0,   45.0),
        (572.0,  265.0),
        (536.0,  435.0),
        (465.0,  525.0),
        # Leg 1 (East -> West)
        l1_e, l1_m1, l1_m2, l1_w,
        # Hairpin 1 (West Lower)
        *hairpin_arc(l1_w[0], l1_w[1], l2_w[1], -1.0, n_pts=5),
        l2_w,
        # Leg 2 (West -> East)
        l2_m1, l2_m2, l2_e,
        # Hairpin 2 (East Mid)
        *hairpin_arc(l2_e[0], l2_e[1], l3_e[1], +1.0, n_pts=5),
        l3_e,
        # Leg 3 (East -> West)
        l3_m1, l3_m2, l3_w,
        # Hairpin 3 (West Upper)
        *hairpin_arc(l3_w[0], l3_w[1], l4_w[1], -1.0, n_pts=5),
        l4_w,
        # Leg 4 -> Wide graceful curve along natural eastern crest onto Overlook Plateau!
        l4_m1, l4_m2,
        (178.0,   24.0),
        (225.0,  -22.0),
        (214.0,  -72.0),
        (158.0,  -82.0),
        (102.0,  -82.0),
    ]

    dense_xy = _eval_catmull_rom_chain(ctrl_xy, samples_per_seg=44)
    xy, s, total_len = _resample_arc_length_2d(dense_xy, step=sample_step)
    end_lock = smootherstep(40.0, 120.0, s) * (1.0 - smootherstep(total_len - 105.0, total_len - 35.0, s))
    xy_sm_x = _smooth_gaussian_1d(xy[:, 0], sigma_pts=5.5)
    xy_sm_y = _smooth_gaussian_1d(xy[:, 1], sigma_pts=5.5)
    xy[:, 0] = xy[:, 0] * (1.0 - end_lock) + xy_sm_x * end_lock
    xy[:, 1] = xy[:, 1] * (1.0 - end_lock) + xy_sm_y * end_lock
    xy, s, total_len = _resample_arc_length_2d(xy, step=sample_step)

    dx = np.gradient(xy[:, 0], s)
    dy = np.gradient(xy[:, 1], s)
    spd = np.hypot(dx, dy)
    tx, ty = dx / spd, dy / spd
    ddx, ddy = np.gradient(tx, s), np.gradient(ty, s)
    kappa = tx * ddy - ty * ddx
    abs_kappa = np.abs(kappa)

    # Curvature-driven road widening: 12.0m straight -> 22.5m hairpins (18-24m target!)
    k_smooth = _smooth_gaussian_1d(abs_kappa, sigma_pts=7.5)
    widen_fac = smootherstep(0.0046, 0.0148, k_smooth)
    summit_flare = smootherstep(total_len - 48.0, total_len, s) * 0.65
    width = 12.0 + 10.5 * widen_fac + 8.0 * summit_flare

    z_nat = natural_height_array(xy[:, 0], xy[:, 1])

    # C2-smooth strictly grade-limited elevation profile hugging the natural backslope!
    # Keep grade very gentle along the low East foothill corridor (s < 1100m) so road stays near ground,
    # then climb steadily at ~8-10% up the backslope switchbacks!
    ds = np.diff(s)
    end_env = smootherstep(58.0, 210.0, s) * (1.0 - smootherstep(total_len - 165.0, total_len - 38.0, s))
    # Foothill corridor stays gentle (~2.5-3.5% max) before entering backslope at s ~ 1050m!
    foothill_fac = 0.28 + 0.72 * smootherstep(780.0, 1280.0, s)
    g_cap = (0.104 - 0.030 * widen_fac) * foothill_fac * end_env

    z_nat_sm = np.maximum(0.0, _smooth_gaussian_1d(z_nat, sigma_pts=20.0))
    base_g = (PLATEAU_Z / max(float(np.sum((foothill_fac * end_env)[:-1] * ds)), 1.0)) * foothill_fac * end_env
    nat_g = np.clip(np.gradient(z_nat_sm, s), 0.0, 0.12) * end_env
    g = 0.35 * base_g + 0.65 * nat_g

    for it in range(70):
        g = _smooth_gaussian_1d(g, sigma_pts=8.0) * end_env
        g = np.clip(g, 0.0, g_cap)
        z_cur = np.concatenate([[0.0], np.cumsum(0.5 * (g[:-1] + g[1:]) * ds)])
        for _ in range(14):
            err = PLATEAU_Z - float(z_cur[-1])
            if abs(err) < 1e-4:
                break
            if err > 0.0:
                slack = np.maximum(0.0, g_cap - g)
                avail = float(np.sum(0.5 * (slack[:-1] + slack[1:]) * ds))
                if avail > 1e-6:
                    g = g + slack * min(1.0, err / avail)
            else:
                avail = float(np.sum(0.5 * (g[:-1] + g[1:]) * ds))
                if avail > 1e-6:
                    g = g * max(0.0, 1.0 + err / avail)
            z_cur = np.concatenate([[0.0], np.cumsum(0.5 * (g[:-1] + g[1:]) * ds)])
        if it < 48:
            dz_err = z_nat_sm - z_cur
            g = np.clip(g + np.gradient(dz_err, s) * 0.28 * end_env, 0.0, g_cap)

    z = np.concatenate([[0.0], np.cumsum(0.5 * (g[:-1] + g[1:]) * ds)])
    if z[-1] > 1.0:
        z = z * (PLATEAU_Z / z[-1])
    grade = np.gradient(z, s)

    rx, ry = ty, -tx
    probe = 22.0
    z_nat_right = natural_height_array(xy[:, 0] + rx * probe, xy[:, 1] + ry * probe)
    z_nat_left  = natural_height_array(xy[:, 0] - rx * probe, xy[:, 1] - ry * probe)

    return {
        "xy": xy, "z": z, "s": s, "total_len": float(total_len),
        "tx": tx, "ty": ty, "rx": rx, "ry": ry,
        "kappa": kappa, "width": width, "grade": grade,
        "z_nat": z_nat, "z_nat_left": z_nat_left, "z_nat_right": z_nat_right,
    }


def carve_terrain_with_road(XX, YY, Z_nat, road):
    pts_xy = road["xy"]
    road_z = road["z"]
    road_hw = road["width"] * 0.5

    shape = XX.shape
    fx = XX.ravel()
    fy = YY.ravel()
    fz = Z_nat.ravel().copy()
    N = len(fx)

    best_idx = np.zeros(N, dtype=np.int32)
    chunk = 4096
    rx = pts_xy[:, 0][None, :]
    ry = pts_xy[:, 1][None, :]
    for start in range(0, N, chunk):
        end = min(N, start + chunk)
        dx = fx[start:end, None] - rx
        dy = fy[start:end, None] - ry
        best_idx[start:end] = np.argmin(dx * dx + dy * dy, axis=1)

    idx0 = np.clip(best_idx - 1, 0, len(pts_xy) - 2)
    idx1 = np.clip(best_idx, 0, len(pts_xy) - 2)

    def seg_proj(seg_i):
        ax, ay = pts_xy[seg_i, 0], pts_xy[seg_i, 1]
        bx, by = pts_xy[seg_i + 1, 0], pts_xy[seg_i + 1, 1]
        abx, aby = bx - ax, by - ay
        ab2 = np.maximum(abx * abx + aby * aby, 1e-9)
        t = np.clip(((fx - ax) * abx + (fy - ay) * aby) / ab2, 0.0, 1.0)
        px = ax + t * abx
        py = ay + t * aby
        dist = np.hypot(fx - px, fy - py)
        rz = road_z[seg_i] * (1.0 - t) + road_z[seg_i + 1] * t
        rhw = road_hw[seg_i] * (1.0 - t) + road_hw[seg_i + 1] * t
        s_val = road["s"][seg_i] * (1.0 - t) + road["s"][seg_i + 1] * t
        return dist, rz, rhw, s_val

    d0, rz0, hw0, s0 = seg_proj(idx0)
    d1, rz1, hw1, s1 = seg_proj(idx1)
    use1 = d1 < d0
    dist = np.where(use1, d1, d0)
    rz = np.where(use1, rz1, rz0)
    hw = np.where(use1, hw1, hw0)
    sv = np.where(use1, s1, s0)

    inner_r = hw + 2.4
    is_cut = fz > rz
    blend_w = np.where(is_cut, 22.0, 30.0)
    w = 1.0 - smootherstep(inner_r, inner_r + blend_w, dist)

    # 0.16m sub-base clearance across roadbed, smoothly zeroing at flat foot & summit plateau ends
    end_clr = smootherstep(15.0, 58.0, sv) * (1.0 - smootherstep(road["total_len"] - 42.0, road["total_len"] - 10.0, sv))
    target_z = np.maximum(0.0, rz - 0.16 * end_clr)
    carved = fz * (1.0 - w) + target_z * w

    # Re-enforce exact flat Overlook Plateau core at Z = PLATEAU_Z
    px = (fx - PLATEAU_CENTER[0]) / (PLATEAU_RX * 0.94)
    py = (fy - PLATEAU_CENTER[1]) / (PLATEAU_RY * 0.94)
    pr = np.power(np.abs(px) ** 3.0 + np.abs(py) ** 3.0, 1.0 / 3.0)
    plat_core = 1.0 - smootherstep(0.86, 1.15, pr)
    carved = carved * (1.0 - plat_core) + PLATEAU_Z * plat_core

    # Re-enforce exact Z=0.0 around outer perimeter
    edge_y0 = smootherstep(-HALF_D + 14.0, -HALF_D + 48.0, fy)
    edge_y1 = 1.0 - smootherstep(HALF_D - 40.0, HALF_D - 10.0, fy)
    edge_x = 1.0 - smootherstep(HALF_W - 40.0, HALF_W - 10.0, np.abs(fx))
    carved = carved * edge_y0 * edge_y1 * edge_x

    return carved.reshape(shape)
