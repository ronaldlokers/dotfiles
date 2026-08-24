import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Workspace indicators grouped by the monitor that owns them.
//
// Hyprland keeps one global pool of workspaces and each one sits on exactly one
// monitor, but a bar surface exists per screen and stock Omarchy paints the
// same marks on every one of them -- so nothing on either strip says where a
// space actually lives.
//
// The answer here is a band: each monitor's run of spaces sits on a soft panel
// in that monitor's colour, and the band belonging to the screen you are
// looking at is outlined. Ownership is read off the container rather than off a
// mark repeated on every pill, which leaves the numbers themselves alone --
// they keep the full/faint fill that already means "has windows" and the block
// that means "focused".
//
// Grouping is also the one approach that survives more displays: a third
// monitor adds a third band rather than making every existing mark smaller.
// Established bars reach for the same shape -- Waybar's persistent-workspaces
// bands, and FieldofClay/hyprland-workspaces, which hands Eww an array *of
// monitors* rather than a flat list.
//
// The cost, accepted deliberately: the numbers leave numeric order, so "third
// pill along" is no longer stable when a space changes monitor.
BarWidget {
  id: root
  moduleName: "lokilabs.workspace"

  // Which physical screen this instance of the widget is painted on. Bar.qml
  // injects only bar/moduleName/settings, but each bar panel is a Variants
  // delegate over Quickshell.screens, so the window underneath is per-monitor.
  // Same route Tray.qml uses to place its menus on the right output.
  readonly property string screenName: {
    var window = root.QsWindow ? root.QsWindow.window : null
    return window && window.screen ? String(window.screen.name || "") : ""
  }

  // Monitors in id order, so a space keeps its colour across a reload. Sorting
  // by name instead would re-tint everything the moment a display is added
  // whose name sorts before an existing one.
  readonly property var monitorNames: {
    var names = []
    var values = Hyprland.monitors.values

    for (var i = 0; i < values.length; i++) {
      if (values[i] && values[i].name) names.push({ id: values[i].id, name: String(values[i].name) })
    }

    names.sort(function(left, right) { return left.id - right.id })
    return names.map(function(entry) { return entry.name })
  }

  function monitorIndex(name) {
    return name ? root.monitorNames.indexOf(name) : -1
  }

  // Monitor colours come out of the active theme's own palette rather than
  // being synthesised. Color.qml already reads theme/colors.toml but keeps only
  // foreground/background/accent/muted/urgent from it -- the named hues sitting
  // in the same file are discarded, so this re-reads it.
  //
  // Not every theme defines every name, and Omarchy accepts alacritty-style
  // colorN keys too, so the preference list below is a wish list: whatever is
  // actually present and legible gets used, in this order.
  readonly property var paletteOrder: [
    "accent", "green", "blue", "magenta", "yellow", "cyan", "red",
    "bright_green", "bright_blue", "bright_magenta", "bright_yellow", "bright_cyan", "bright_red",
    "color2", "color4", "color5", "color3", "color6", "color1"
  ]

  property var palette: ({})

  function parsePalette(raw) {
    var found = {}
    var lines = String(raw || "").split("\n")

    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (match) found[match[1]] = match[2]
    }

    root.palette = found
  }

  // WCAG relative luminance, used only for the ratio below.
  function luminance(c) {
    function channel(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
  }

  function contrastRatio(a, b) {
    var la = root.luminance(a)
    var lb = root.luminance(b)
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
  }

  function hueDistance(a, b) {
    var d = Math.abs(a - b) % 1.0
    return Math.min(d, 1.0 - d)
  }

  // An explicit choice wins over the shortlist. Set it on this widget's entry
  // in ~/.config/omarchy/shell.json, in monitor order:
  //
  //   { "id": "lokilabs.workspace", "monitorColors": ["magenta", "yellow"] }
  //
  // Entries are either a key from the theme's colors.toml ("magenta") or a
  // literal "#rrggbb". Anything the theme doesn't define is skipped rather than
  // shifting the monitors after it onto the wrong colour.
  readonly property var chosenColors: {
    var requested = root.settings && root.settings.monitorColors ? root.settings.monitorColors : []
    var out = []

    for (var i = 0; i < requested.length; i++) {
      var name = String(requested[i] || "")
      var hex = name.charAt(0) === "#" ? name : root.palette[name]
      if (hex) out.push(Qt.color(hex))
    }

    return out
  }

  // The shortlist: theme hues that are saturated enough to read as a colour,
  // bright enough against the bar, and far enough from the ones already taken
  // that two monitors can't end up wearing near-identical dots.
  readonly property var monitorPalette: {
    var barBackground = root.bar ? root.bar.background : Color.bar.background
    var picked = []

    for (var i = 0; i < root.paletteOrder.length; i++) {
      var hex = root.palette[root.paletteOrder[i]]
      if (!hex) continue

      var candidate = Qt.color(hex)
      if (candidate.hslSaturation < 0.2) continue
      if (root.contrastRatio(candidate, barBackground) < 1.6) continue

      var clashes = false
      for (var j = 0; j < picked.length; j++) {
        if (root.hueDistance(candidate.hslHue, picked[j].hslHue) < 0.08) { clashes = true; break }
      }
      if (clashes) continue

      picked.push(candidate)
    }

    return picked
  }

  // Falls back to rotating the accent around the hue wheel when the theme has
  // fewer usable hues than there are monitors. The 0.38 step is close to the
  // golden angle, so successive monitors stay apart without landing on exact
  // complements. Saturation and lightness get floors first: several stock
  // themes ship a near-grey accent (Omarchy's default is #cacccc), and rotating
  // the hue of a grey returns the same grey.
  function monitorColor(index) {
    if (index < 0) return "transparent"

    var chosen = root.chosenColors
    if (index < chosen.length) return chosen[index]

    var fromTheme = root.monitorPalette
    if (index < fromTheme.length) return fromTheme[index]

    var accent = root.bar ? root.bar.urgent : Color.bar.active
    var saturation = Math.max(accent.hslSaturation, 0.55)
    var lightness = Math.min(Math.max(accent.hslLightness, 0.45), 0.72)
    var hue = (accent.hslHue + (index - Math.max(fromTheme.length - 1, 0)) * 0.38) % 1.0

    return Qt.hsla(hue, saturation, lightness, 1.0)
  }

  // Color.qml reads this same file once at startup and takes theme switches
  // over IPC instead, so watching it here is not redundant: it is what makes a
  // `omarchy theme set` recolour the dots without restarting the shell.
  FileView {
    id: paletteFile
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.parsePalette(text())
  }

  // A theme switch swaps the directory the path above points into, which does
  // not always register as a change to the watched file. Color.accent is
  // pushed over IPC on every switch, so it doubles as the reload signal.
  Connections {
    target: Color
    function onAccentChanged() { paletteFile.reload() }
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }

    return null
  }

  function workspaceMonitorName(workspace) {
    return workspace && workspace.monitor && workspace.monitor.name ? String(workspace.monitor.name) : ""
  }

  // The bar's own screen, as an index into monitorNames — the badge's colour.
  readonly property int screenIndex: root.monitorIndex(root.screenName)

  function workspaceIds() {
    var ids = [1, 2, 3, 4, 5]
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id > 0 && id <= 10 && ids.indexOf(id) === -1) ids.push(id)
    }

    ids.sort(function(left, right) { return left - right })
    return ids
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  // Spaces bucketed by owner, monitors in their fixed order, then whatever no
  // monitor claims. Hyprland always reports a monitor for a live workspace, so
  // the trailing bucket only ever holds the placeholder ids the widget draws
  // whether or not they exist yet.
  readonly property var workspaceGroups: {
    var byMonitor = {}
    var loose = []

    root.workspaceIds().forEach(function(id) {
      var workspace = root.workspaceById(id)
      var owner = root.workspaceMonitorName(workspace)

      if (owner && root.monitorIndex(owner) >= 0) {
        if (!byMonitor[owner]) byMonitor[owner] = []
        byMonitor[owner].push(id)
      } else {
        loose.push(id)
      }
    })

    var groups = []
    root.monitorNames.forEach(function(name, index) {
      if (byMonitor[name]) groups.push({ monitor: name, index: index, ids: byMonitor[name] })
    })
    if (loose.length) groups.push({ monitor: "", index: -1, ids: loose })

    return groups
  }

  implicitWidth: layout.implicitWidth + trailingGap
  implicitHeight: layout.implicitHeight

  Grid {
    id: layout
    anchors.centerIn: parent
    columns: root.vertical ? 1 : Math.max(1, root.workspaceGroups.length)
    spacing: Style.spaceReal(4)
    verticalItemAlignment: Grid.AlignVCenter
    horizontalItemAlignment: Grid.AlignHCenter

    Repeater {
      model: root.workspaceGroups

      Rectangle {
        id: band
        required property var modelData

        readonly property bool owned: modelData.index >= 0
        readonly property bool mine: modelData.monitor === root.screenName
        readonly property color tint: owned ? root.monitorColor(modelData.index) : "transparent"

        // Every band is outlined, not just this screen's -- a fill alone
        // washes out against a saturated bar background, which left a foreign
        // band reading as a vague lighter patch rather than as that monitor's
        // colour. The edge carries the hue; weight and fill then separate
        // "yours" from "theirs".
        color: owned ? Qt.rgba(tint.r, tint.g, tint.b, mine ? 0.30 : 0.16) : "transparent"
        border.width: owned ? Math.max(1, Style.spaceReal(mine ? 1.5 : 1)) : 0
        border.color: Qt.rgba(tint.r, tint.g, tint.b, mine ? 0.85 : 0.40)
        radius: Style.spaceReal(5)

        implicitWidth: pills.implicitWidth + (owned ? Style.spaceReal(5) * 2 : 0)
        implicitHeight: root.vertical ? pills.implicitHeight + (owned ? Style.spaceReal(5) * 2 : 0) : root.barSize

        Behavior on color {
          enabled: !root.bar || root.bar.foregroundAnimationEnabled
          ColorAnimation { duration: 160 }
        }

        Grid {
          id: pills
          anchors.centerIn: parent
          columns: root.vertical ? 1 : Math.max(1, band.modelData.ids.length)
          spacing: 0
          verticalItemAlignment: Grid.AlignVCenter
          horizontalItemAlignment: Grid.AlignHCenter

          Repeater {
            model: band.modelData.ids

            WidgetButton {
              required property int modelData

              readonly property var workspace: root.workspaceById(modelData)
              readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
              readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData

              bar: root.bar
              text: focused ? "󱓻" : (modelData === 10 ? "0" : String(modelData))
              opacity: occupied || focused ? 1 : 0.5
              horizontalMargin: 6
              verticalPadding: 6
              fixedWidth: root.vertical ? root.barSize : Style.space(18)
              fixedHeight: root.vertical ? root.barSize : root.barSize - Style.spaceReal(4)
              tooltipText: band.owned
                ? "Workspace " + modelData + " \u00b7 " + band.modelData.monitor + (band.mine ? " (this screen)" : "")
                : "Workspace " + modelData
              onPressed: function() { root.focusWorkspace(modelData) }
            }
          }
        }
      }
    }
  }
}
