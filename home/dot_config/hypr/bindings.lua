-- Keep only your personal keybinding overrides here. Add new bindings or
-- unbind defaults before replacing them.

-- See current bindings and descriptions:
--   omarchy menu keybindings --print

-- To disable every Omarchy default binding, set this in
-- ~/.config/hypr/hyprland.lua before require("default.hypr.omarchy"), then add
-- only the bindings you want below:
--   omarchy_default_bindings = false

-- To disable all preinstalled app/webapp bindings, set:
--   omarchy_preinstalled_bindings = false

-- Add a new binding.
-- o.bind("SUPER + SHIFT + R", "SSH", "alacritty -e ssh your-server")

-- Change an existing binding by unbinding it first, then binding the key again.
-- This example changes SUPER+SPACE from the launcher to the Omarchy root menu.
-- hl.unbind("SUPER + SPACE")
-- o.bind("SUPER + SPACE", "Omarchy menu", "omarchy-menu toggle root")

-- Disable a default binding without replacing it.
-- hl.unbind("SUPER + SHIFT + B")

-- Logitech MX Keys examples:
-- o.bind("SUPER + SHIFT + S", nil, "omarchy-capture-screenshot")
-- o.bind("SUPER + H", nil, "voxtype record toggle")
-- o.bind("SUPER + PERIOD", nil, "omarchy-shell shell toggle omarchy.emojis")

-- Dictation (handy), driven by the compositor rather than by the app.
--
-- Handy's own hotkey backends both fail here. The `tauri` one grabs through
-- X11, and its suspend/resume path re-registers without unregistering first --
-- so every visit to handy's settings screen kills the binding with
-- "Shortcut '...' is already in use" until the app is restarted. The
-- `handy_keys` one wants write access to /dev/uinput, which is root-owned 0600
-- and would need a udev rule granting the input group write access to a device
-- that can synthesise keystrokes system-wide.
--
-- Hyprland already owns the keyboard, so it takes the key and hands handy a
-- CLI toggle. `--toggle-transcription` signals the running instance; pressing
-- starts the recording and releasing stops it, which is what push-to-talk
-- means. Nothing needs root, and nothing depends on handy holding a grab.
--
-- Right Alt alone, rather than a chord. A key held while speaking wants one
-- finger, and this layout is plain `us` with no `intl` variant, so Right Alt
-- carries no AltGr and no compose -- compose lives on Caps Lock
-- (`compose:caps`). It is the only genuinely unused key on the board.
--
-- ignore_mods because Right Alt *is* a modifier: pressing it sets the Alt bit
-- in the very event this bind has to match, so a bind demanding no modifiers
-- would never fire. The consequence is that an Alt combo typed with the right
-- hand also starts a recording -- accepted, since combos here use Left Alt.
--
-- For tap-to-toggle instead of hold-to-talk, delete the second bind.
o.bind("Alt_R", "Dictate", "handy --toggle-transcription", { ignore_mods = true })
o.bind("Alt_R", nil, "handy --toggle-transcription", { release = true, ignore_mods = true })

-- Arrange the active workspace into columns: three windows become 20/60/20,
-- any other count is split evenly. The script is dot_local/bin/hypr-columns.
--
-- A script rather than a dispatcher because Hyprland has no "lay this workspace
-- out like so" command: `colresize` acts on the focused column only, so three
-- different widths means visiting each column in a known order, and the order
-- can only be known by reading the windows' on-screen positions first.
--
-- SUPER + SHIFT + T was unbound in both Omarchy's defaults and this file, so
-- there is no hl.unbind above it.
o.bind("SUPER + SHIFT + T", "Arrange columns 20/60/20", "hypr-columns")
