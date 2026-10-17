# Which way the fish points: tilt, spin, pitch, roll, yaw

The VectorNav on the fish measures three things in its own frame (sensor axes x, y, z), 40 times
a second:

- **acceleration** [m/s²] - mostly gravity, so it says which way is up
- **magnetic field** [gauss] (`vnav.compass`) - says which way magnetic north is
- **rotation rate** [rad/s] (`vnav.gyro`) - how fast it's turning about each axis

The FCTD2 sends these raw, as `$VNMAR` messages, so L0 has no angles: `vnav.yaw`, `vnav.pitch`
and `vnav.roll` are all NaN there (they're filled at L0 only for a sensor set to send `$VNYPR`,
its own yaw-pitch-roll). At L1, `mod_L1_add_vnav_attitude.m` works out five angles from the
acceleration and magnetic field, in two sets:

| Field | Set | What it is |
|---|---|---|
| `vnav.tilt` | the fish's own frame | angle of the long axis from straight up |
| `vnav.spin` | the fish's own frame | rotation about the long axis |
| `vnav.pitch` | VectorNav's angles | x axis up (+) or down (-) |
| `vnav.roll` | VectorNav's angles | rotation about x |
| `vnav.yaw` | VectorNav's angles | magnetic heading of x |

All five are in degrees. They're there for every L1 file whose raw file has VNAV data (made with
this version or later; see How to plot it for older files).

![Left: a fish hanging from the cable, long axis z tilted from straight up (tilt), spinning about z (spin); spin is the angle from magnetic north to x once the tilt is taken out, drawn on the horizontal plane. Right: a level sensor, x forward, y starboard, z down, with roll about x, pitch about y and yaw about z, each right-handed.](images/vnav_attitude_explained.png)

## Where the sensor's axes are on the fish

On the FCTD2 (2026-10-17 ocean test), the sensor's **z axis runs along the fish's long axis**:

- On deck, lying flat, gravity was all in x and y.
- On the upcast, hanging below the cable, the acceleration read +9 m/s² along z, steady.

So z points up the cable when the fish is hauled up.

The accelerometer reads +9.81 m/s² on an axis pointing *up* when the sensor is still
(VectorNav's convention: it measures the push that holds it up, not gravity's pull). The
magnetometer confirms it. In the water, the field then dips 62° below horizontal, about what it
should at 35.5°N; the other sign would make it point up.

## tilt and spin: the fish's own frame

These two describe the fish the way it hangs.

- **tilt** - the angle between the long axis (+z) and straight up. 0 = pointing straight up, 90 =
  horizontal, 180 = straight down.
- **spin** - how far the fish has turned about its own long axis, in degrees, unwrapped (it keeps
  counting past 360). Right-handed about +z, the same sign as the gyro z axis. Its zero: the x
  axis pointing to magnetic north, once the tilt is taken out.

How spin is worked out:

1. Tip the fish back upright by the smallest rotation, about a horizontal axis. That leaves its
   rotation about the long axis alone.
2. Measure the angle from magnetic north to x, counterclockwise seen from above.

Spin comes from the magnetometer, so it doesn't drift. Its change over time is how much the
fish has spun, which is what twists the cable. So `spin / 360` is an independent check on the
gyro twist count. (The twist count is rotation about the vertical, so the two agree while the
long axis points upward, tilt below 90°. With z pointing mostly down, a turn about the long
axis counts the other way in the twist count, scaled by cos(tilt).) On the 2026-10-17 profile the two lie on top of each other (third panel below).

Spin isn't defined when the long axis points almost straight down (tilt within 1° of 180), and
is NaN there. Within an L1 file it starts within ±180° and is unwrapped from there.
`MODvis_vnav_attitude.m` unwraps it across files.

## pitch, roll, yaw: VectorNav's angles

These are the angles the VectorNav itself would report in `$VNYPR`. They give the sensor
frame's orientation from North-East-Down, as three turns in this order:

1. yaw about z (down)
2. then pitch about the new y
3. then roll about the new x

Each angle is right-handed about its axis. All zero means level, x to magnetic north, z down.

- **pitch** - x axis up positive, -90 to 90.
- **roll** - about x, -180 to 180; 0 when z points down.
- **yaw** - magnetic heading of the x axis, clockwise from magnetic north seen from above,
  -180 to 180.

They're the standard aircraft/ship angles, and they work best when z is close to down. **The
FCTD hangs with z up**, so:

- **roll** sits near ±180° on the upcast, and jumps between +180 and -180 as the fish wobbles.
- **yaw** still tracks the heading of x, so it wraps round once per spin.

A plot of roll near ±180° isn't an error; it's how these angles describe an upside-down sensor.
For an FCTD, tilt and spin are usually the easier pair to read.

For `$VNYPR` data, the sensor's own pitch, roll and yaw are kept, and tilt and spin are worked
out from them.

## When to trust them

- **Acceleration other than gravity.** tilt, pitch and roll assume the accelerometer feels
  only gravity. They're right while the fish moves steadily (falling, or being hauled at a
  steady speed). They're wrong for a moment when it jerks (a winch start, the fish hitting the
  water).
- **Near the ship.** The ship's steel bends the magnetic field. On deck the same test read a
  77-79° dip instead of 62°, so spin and yaw are off there.
- **Magnetic, not true, north.** No declination is applied.
- **Tilt and spin vs. yaw.** Spin and yaw both turn once per spin of a hanging fish. Spin
  counts up (right-handed about z = up); yaw counts clockwise from above. So their changes have
  opposite signs.

## What the 2026-10-17 ocean test showed

![MODvis_vnav_attitude.m on the 2026-10-17 FCTD2 ocean test (copies of four raw files processed in a sandbox): pressure, tilt, spin with the gyro twist count, pitch and roll, and yaw](images/MODvis_vnav_attitude_example.png)

**Downcast.** The fish switched between two positions:

- falling: tilt 125-150°, the +z end pointing mostly down
- at the winch pauses (the pressure plateaus near 430 and 1070 dbar): tilt about 60°

Spin and the gyro twist count drifted together, about -8 turns by the bottom.

**Upcast.**
- Tilt steady near 20°.
- The fish spun steadily, about 12 turns in 4 minutes. Spin and the gyro count agree, so the
  steadily falling twist count was real spinning.
- From about 470 dbar (15:36:45), the steady spinning stopped. Yaw swings back and forth instead
  of wrapping round, and the twist count wobbles around a constant value.

## How to plot it

```matlab
fig = MODvis_vnav_attitude(survey_folder);               % its processed/realtime/L1
fig = MODvis_vnav_attitude(L1_folder, [t_start t_end]);  % datetime or datenum
```

L1 files made before this step have no tilt or spin; `MODvis_vnav_attitude.m` works them out
from their vnav when it plots (nothing is written). The diagram above is
`plots/MODplot_vnav_attitude_explained.m`.

## History

**2026-10-17 - tilt, spin, pitch, roll, yaw at L1** (branch `main-fork`).

- New `mod_L1_add_vnav_attitude.m`, called by `MODprocess_single_L0_to_L1.m` before the twist
  count.
- It replaces MOD_fish_lib `EPSILOMETER/epsilib/vnav_pitch_roll_heading.m`, which was never
  ported. That function assumed the opposite accelerometer sign, so its roll was off by 180°.
  On the ocean test its yaw turned only about 1 turn on the upcast, where the gyro and
  magnetometer show about 12.

How it was tested:
- Synthetic attitudes: yaw, pitch, roll and tilt recovered to 1e-13°.
- The `$VNYPR` path gives the same tilt and spin as the `$VNMAR` path.
- A fish spinning 30 turns while swinging 20° reads 30.00 turns.
- On the ocean test (sandbox copies), spin follows the gyro twist count through the whole profile.
