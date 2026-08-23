-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- List current monitors and supported resolutions with: hyprctl monitors all

-- 34" 3440x1440 ultrawide (Philips 346B1C) at 1:1 -- one logical pixel per
-- physical pixel, so the logical desktop is the full 3440x1440 and nothing is
-- resampled. This was 1.25 until 2026-08-23. If it ever needs to go back up,
-- 1.25 and 1.6 are the only fractional scales that divide 3440x1440 into whole
-- pixels.
--
-- Omarchy v4 ships `scale = "auto"` here, which the omarchy.monitor bar widget
-- resolves at runtime and writes back into this file -- on the upgrade it chose
-- 1.6, which is why this repo pins a literal. See docs/design-notes.md,
-- "Co-owned configuration files".
--
-- GDK_SCALE is 1, not the v4 default of 2: 2 is the retina-class value and
-- doubles every GTK app on a display that is already 1:1. It is also a single
-- process-global env, so a second display at a different DPI could not have its
-- own value however this rule were keyed -- which is why this stays a catch-all
-- rather than a `desc:`-matched monitor.
local omarchy_gdk_scale = 1
local omarchy_monitor_scale = 1

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })

-- Configure a specific monitor.
-- hl.monitor({ output = "DP-2", mode = "2560x1440@144", position = "0x0", scale = 1 })

-- Portrait/rotated secondary monitor (transform: 1 = 90°, 3 = 270°).
-- hl.monitor({ output = "DP-2", mode = "preferred", position = "auto", scale = 1, transform = 1 })

-- 25" 2560x1440 (Dell U2515H) on HDMI, physically rotated counter-clockwise
-- (panel's top edge points left), so the content needs a 90 degree clockwise
-- turn to come out upright: transform = 1.
--
-- Rotated logical size at scale 1 is 1440x2560. It sits left of the ultrawide
-- at the origin, which leaves the ultrawide at x=1440; y=560 centres the
-- ultrawide's 1440 logical rows against the portrait's 2560.
--
-- The catch-all above still matches this output, so this rule must stay after
-- it -- a later, more specific rule wins.
hl.monitor({ output = "HDMI-A-1", mode = "2560x1440@60", position = "0x0", scale = omarchy_monitor_scale, transform = 1 })
hl.monitor({ output = "DP-1", mode = "3440x1440@60", position = "1440x560", scale = omarchy_monitor_scale })
