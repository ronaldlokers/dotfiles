-- Change the default Omarchy look'n'feel.

-- https://wiki.hypr.land/Configuring/Basics/Variables/#general
-- hl.config({
--   general = {
--     -- No gaps between windows or borders.
--     gaps_in = 0,
--     gaps_out = 0,
--     border_size = 0,
--
--     -- Change to niri-like side-scrolling layout.
--     layout = "scrolling",
--   },
-- })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#decoration
hl.config({
	decoration = {
		-- Use round window corners.
		rounding = 8,

		-- Dim unfocused windows (0.0 = no dim, 1.0 = fully dimmed).
		dim_inactive = true,
		dim_strength = 0.15,
	},
})

-- https://wiki.hypr.land/Configuring/Basics/Variables/#animations
-- hl.config({
--   animations = {
--     -- Disable all animations.
--     enabled = false,
--   },
-- })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#layout
-- hl.config({
--   layout = {
--     -- Avoid overly wide single-window layouts on wide screens.
--     single_window_aspect_ratio = { 1, 1 },
--   },
-- })

-- https://wiki.hypr.land/Configuring/Layouts/Scrolling-Layout/
-- hl.config({
--   scrolling = {
--     -- See only one column per screen instead of two.
--     column_width = 0.97,
--   },
-- })

-- Keep Zen fully opaque when it does not have focus.
--
-- A window rule rather than a decoration setting, and it lives in this file
-- rather than hyprland.lua because it is the same question the block above
-- answers -- what unfocused windows look like -- and because hyprland.lua is
-- not managed here, so a rule put there would not survive a rebuild.
--
-- The transparency is not Hyprland's inactive_opacity, which is 1.0 and unset.
-- Omarchy's default/hypr/apps/browser.lua tags zen `+firefox-based-browser`
-- and then gives that tag `opacity = "1.0 0.985"`, so every Firefox derivative
-- goes 1.5% see-through when it loses focus. Reading through a browser window
-- to the wallpaper behind it is a poor trade on a screen that is mostly text,
-- and dim_inactive above already marks the unfocused window without making it
-- transparent.
--
-- `1 1` is active and inactive alpha. The form matches Omarchy's own opt-outs
-- in default/hypr/apps/steam.lua and qemu.lua. This file is required after
-- `default.hypr.omarchy` in hyprland.lua, so it wins over the browser rule.
o.window("zen", { opacity = "1 1" })
