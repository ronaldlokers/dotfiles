-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- List current monitors and supported resolutions with: hyprctl monitors all

-- 34" 3440x1440 ultrawide (Philips 346B1C), scaled up for readability.
-- Native resolution kept (stays sharp); everything renders ~25% larger, so the
-- logical desktop becomes 2752x1152. 1.25 and 1.6 are the only fractional
-- scales that divide 3440x1440 into whole pixels; 1.6 is the fallback if this
-- ever reads too small.
--
-- Omarchy v4 ships `scale = "auto"` here, which the omarchy.monitor bar widget
-- resolves at runtime and writes back into this file -- on the upgrade it chose
-- 1.6, which is why this repo pins a literal. See docs/design-notes.md,
-- "Co-owned configuration files".
--
-- GDK_SCALE is 1, not the v4 default of 2: 2 is the retina-class value and
-- double-scales GTK apps on top of a 1.25 monitor scale. It is also a single
-- process-global env, so a second display at a different DPI could not have its
-- own value however this rule were keyed -- which is why this stays a catch-all
-- rather than a `desc:`-matched monitor.
local omarchy_gdk_scale = 1
local omarchy_monitor_scale = 1.25

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })

-- Configure a specific monitor.
-- hl.monitor({ output = "DP-2", mode = "2560x1440@144", position = "0x0", scale = 1 })

-- Portrait/rotated secondary monitor (transform: 1 = 90°, 3 = 270°).
-- hl.monitor({ output = "DP-2", mode = "preferred", position = "auto", scale = 1, transform = 1 })
