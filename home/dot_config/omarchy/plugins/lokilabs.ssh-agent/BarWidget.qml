// SSH agent bar widget for the Omarchy Quickshell bar.
//
// Same contract as the sugarrush widget next door: a plain Item using only the
// properties the bar injects (`bar`, `moduleName`, `settings`), with no import
// of the shell's internal modules. Stock widgets reach for qs.Ui and qs.Commons
// and get their styling for free; this one draws itself instead, so a shell
// release that moves those modules costs it nothing.
//
// All of the thinking is in `agent-status`, which prints one Waybar object.
// This file renders it and runs the fix on click.

import QtQuick
import Quickshell.Io

Item {
  id: root

  // Injected by the bar at load time.
  property var bar
  property string moduleName: "lokilabs.ssh-agent"
  property var settings: ({})

  // Per-widget options, e.g. `omarchy bar set lokilabs.ssh-agent interval 15`.
  //
  // The option is `command`, not `exec`: the bar reads `exec`, `source` and
  // `type` off the layout entry to decide a slot is a built-in command or QML
  // module, and setting any of them would stop this widget from loading.
  readonly property int refreshInterval: (settings && settings.interval > 0 ? settings.interval : 30) * 1000
  readonly property string command: settings && settings.command ? settings.command : "agent-status"
  // A working agent is the normal state, and a permanent green tick is one more
  // thing on a bar that does not need one — the same reason omarchy.system-update
  // hides itself when there is no update. Set alwaysShow to keep it visible and
  // confirm the widget itself is alive.
  readonly property bool alwaysShow: settings && settings.alwaysShow === true
  readonly property string onClick: settings && settings.onClick !== undefined
    ? settings.onClick
    : "omarchy-launch-floating-terminal-with-presentation proton-ssh-load --prompt"

  // Starts as the healthy state: the widget is hidden until the first run says
  // otherwise, so a bar coming up does not flash a fault it has not measured.
  property string label: ""
  property string tooltip: "ssh-agent: waiting for the first check"
  property string stateClass: "ok"

  readonly property bool healthy: stateClass === "ok"
  readonly property bool faulted: stateClass === "empty" || stateClass === "no-agent"

  visible: alwaysShow || !healthy

  readonly property color foreground: bar ? bar.foreground : "white"
  // The bar's own urgent colour rather than a literal, so this follows the
  // theme like everything else on the bar does.
  readonly property color alertColor: {
    if (!faulted) return foreground
    return bar ? bar.urgent : "#ff0000"
  }

  implicitWidth: visible ? text.implicitWidth + 12 : 0
  implicitHeight: bar ? bar.barSize : 26

  // Any run still in flight is dropped first: a check that outlives its poll
  // interval has nothing to say the next one will not. Deferred because setting
  // `running` false then true in one pass is not a change at all, and would
  // leave the widget with no check running.
  function refresh() {
    statusProc.running = false
    Qt.callLater(function () { statusProc.running = true })
  }

  // The bar injects `settings` after the widget is built, so the first poll runs
  // with the default command. Check again as soon as a configured one lands.
  onCommandChanged: pollTimer.restart()

  function apply(out) {
    var payload
    try {
      payload = JSON.parse(String(out || ""))
    } catch (e) {
      // Keep the last state; only the tooltip admits something went wrong. A
      // widget that cannot read its own check must not claim the agent is fine,
      // so this is a fault like any other.
      root.stateClass = "no-agent"
      root.label = "?"
      root.tooltip = "ssh-agent: could not read agent-status output"
      return
    }
    root.label = payload.text || ""
    root.tooltip = payload.tooltip || ""
    root.stateClass = payload["class"] || "no-agent"
  }

  Process {
    id: statusProc
    command: ["bash", "-lc", root.command]
    // The collectors are named and read through their ids: an unqualified
    // `text` in these handlers resolves to the Text element below instead.
    stdout: StdioCollector {
      id: outCollector
      waitForEnd: true
      onStreamFinished: root.apply(outCollector.text)
    }
    stderr: StdioCollector {
      id: errCollector
      waitForEnd: true
      onStreamFinished: if (errCollector.text.trim() !== "") console.warn("lokilabs.ssh-agent", errCollector.text.trim())
    }
  }

  Timer {
    id: pollTimer
    interval: root.refreshInterval
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Text {
    id: text
    anchors.centerIn: parent
    //  is a key; the label the script sends rides beside it, since the
    // count is the part that changes.
    text: " " + root.label
    color: root.alertColor
    font.family: "CaskaydiaMono Nerd Font"
    font.pixelSize: 12
  }

  // The bar draws tooltips itself, on its own surface, and a widget asks for
  // one by exposing `tooltipHovered` and calling showTooltip -- the contract
  // Bar.targetTooltipHovered checks. A QtQuick.Controls ToolTip cannot do this
  // job: it is a popup inside the bar's layer surface, so a bar-height window
  // clips it to nothing and the text is unreadable. That was the first attempt.
  //
  // Both are still only the injected `bar`, so this costs no internal imports.
  property bool tooltipHovered: false

  function showOwnTooltip() {
    if (bar && tooltip !== "") bar.showTooltip(root, tooltip)
  }

  onTooltipHoveredChanged: {
    if (!bar) return
    if (tooltipHovered) showOwnTooltip()
    else bar.hideTooltip(root)
  }

  // The text changes under the pointer -- a poll lands, or the click's recheck
  // returns -- and a tooltip already on screen would otherwise keep describing
  // the state before it.
  onTooltipChanged: if (tooltipHovered) showOwnTooltip()

  // Hidden while hovered leaves the tooltip orphaned on the bar; healthy is
  // exactly when that happens, since the widget disappears.
  onVisibleChanged: if (!visible && bar) bar.hideTooltip(root)

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onContainsMouseChanged: root.tooltipHovered = containsMouse
    // Through the bar's own runner, the way every stock widget launches
    // something: it is the seam that knows about the session.
    onClicked: {
      if (root.bar) root.bar.run(root.onClick)
      // The fix takes a few seconds and the poll interval is longer than that.
      // Without this the bar keeps showing the fault after it is gone.
      recheck.restart()
    }
  }

  Timer {
    id: recheck
    interval: 5000
    repeat: false
    onTriggered: root.refresh()
  }
}
