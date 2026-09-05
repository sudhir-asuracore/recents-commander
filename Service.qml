import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "RecentsModel.js" as RecentsModel

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  onShellChanged: {
    if (root.shell) {
      Qt.callLater(function() { root.healState() })
    }
  }

  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string stateDirPath: homeDir + "/.local/state/omarchy/recents-commander"
  readonly property string stateFilePath: stateDirPath + "/recents.json"
  readonly property string bookmarksPath: homeDir + "/.config/gtk-3.0/bookmarks"

  // In-memory state
  property var recentsState: RecentsModel.createEmptyState()
  property bool isDirty: false
  property bool isLoaded: false

  signal recentsChanged()

  function loadState(rawText) {
    root.recentsState = RecentsModel.parseState(rawText)
    root.isLoaded = true
    root.healState()
    root.recentsChanged()
  }

  function flushState() {
    if (!root.isDirty) return
    root.isDirty = false
    var serialized = RecentsModel.serializeState(root.recentsState)
    stateFile.setText(serialized)
  }

  function markDirty() {
    root.isDirty = true
    saveDebounceTimer.restart()
    root.recentsChanged()
  }

  function recordApp(appData) {
    if (!appData || !appData.id) return
    root.recentsState = RecentsModel.recordApp(root.recentsState, appData, 30)
    root.markDirty()
  }

  function recordDirectory(dirPath) {
    if (!dirPath) return
    root.recentsState = RecentsModel.recordDirectory(root.recentsState, dirPath, 30)
    root.markDirty()
  }

  function removeApp(appId) {
    if (!appId) return
    root.recentsState = RecentsModel.removeApp(root.recentsState, appId)
    root.markDirty()
  }

  function removeDirectory(dirPath) {
    if (!dirPath) return
    root.recentsState = RecentsModel.removeDirectory(root.recentsState, dirPath)
    root.markDirty()
  }

  function refreshDirectories() {
    if (!zoxideProc.running) {
      zoxideProc.running = true
    }
  }

  function handleHarvestedZoxide(rawText) {
    if (!rawText) return
    var lines = rawText.split("\n")
    var validPaths = []
    for (var i = 0; i < lines.length; i++) {
      var p = lines[i].trim()
      if (p) validPaths.push(p)
    }
    if (validPaths.length > 0) {
      root.recentsState = RecentsModel.mergeHarvestedDirectories(root.recentsState, validPaths, 30)
      root.markDirty()
    }
  }

  function handleHarvestedBookmarks(rawText) {
    if (!rawText) return
    var lines = rawText.split("\n")
    var bookmarkPaths = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      // Format: file:///path/to/dir Name or file:///path/to/dir
      var parts = line.split(" ")
      var uri = parts[0] || ""
      if (uri.indexOf("file://") === 0) {
        var path = decodeURIComponent(uri.slice(7))
        if (path) bookmarkPaths.push(path)
      }
    }
    if (bookmarkPaths.length > 0) {
      root.recentsState = RecentsModel.mergeHarvestedDirectories(root.recentsState, bookmarkPaths, 30)
      root.markDirty()
    }
  }

  function healState() {
    var appLib = root.shell ? root.shell.appLibrary : null
    if (!appLib || !root.recentsState || !Array.isArray(root.recentsState.apps)) return
    var apps = root.recentsState.apps
    var changed = false
    for (var i = 0; i < apps.length; i++) {
      var app = apps[i]
      var resolved = root.resolveApp(app.id, app.name)
      if (resolved && (resolved.id !== app.id || resolved.icon !== app.icon || (resolved.name && resolved.name !== app.name))) {
        app.id = resolved.id
        app.name = resolved.name
        if (resolved.icon) app.icon = resolved.icon
        if (resolved.description && !app.description) app.description = resolved.description
        changed = true
      }
    }
    if (changed) {
      root.markDirty()
    }
  }

  function resolveApp(appId, title) {
    var cleanAppId = String(appId || "").trim()
    var cleanTitle = String(title || "").trim()
    if (!cleanAppId && !cleanTitle) return null

    var appLib = root.shell ? root.shell.appLibrary : null
    if (appLib) {
      var norm = appLib.normalizeDesktopId ? appLib.normalizeDesktopId(cleanAppId) : cleanAppId
      var entries = appLib.sortedEntries ? appLib.sortedEntries("") : []
      var lowerAppId = cleanAppId.toLowerCase()
      var lowerNorm = norm.toLowerCase()
      var lowerTitle = cleanTitle.toLowerCase()

      // Pass 1: Exact Desktop ID match (case-sensitive and case-insensitive)
      for (var i = 0; i < entries.length; i++) {
        var entry1 = entries[i].entry
        if (!entry1) continue
        var entryId1 = String(entry1.id || "")
        var lowerEntryId1 = entryId1.toLowerCase()
        if (entryId1 === cleanAppId || entryId1 === norm || lowerEntryId1 === lowerNorm || lowerEntryId1 === lowerAppId) {
          return {
            id: entry1.id,
            name: appLib.entryName(entry1) || cleanTitle || entry1.id,
            icon: String(entry1.icon || ""),
            description: appLib.entrySubtext(entry1) || ""
          }
        }
      }

      // Pass 2: StartupWMClass match (e.g. Nuvio: startupClass="com-nuvio-app-MainKt")
      for (var j = 0; j < entries.length; j++) {
        var entry2 = entries[j].entry
        if (!entry2) continue
        var sc = String(entry2.startupClass || "").trim().toLowerCase()
        if (sc && (sc === lowerAppId || sc === lowerNorm)) {
          return {
            id: entry2.id,
            name: appLib.entryName(entry2) || cleanTitle || entry2.id,
            icon: String(entry2.icon || ""),
            description: appLib.entrySubtext(entry2) || ""
          }
        }
      }

      // Pass 3: Application Name exact match (e.g. title="Nuvio" or title="Discord")
      for (var k = 0; k < entries.length; k++) {
        var entry3 = entries[k].entry
        if (!entry3) continue
        var entryName3 = String(appLib.entryName(entry3) || entry3.name || "").trim().toLowerCase()
        if (entryName3 && (entryName3 === lowerTitle || entryName3 === lowerAppId || entryName3 === lowerNorm)) {
          return {
            id: entry3.id,
            name: appLib.entryName(entry3) || cleanTitle || entry3.id,
            icon: String(entry3.icon || ""),
            description: appLib.entrySubtext(entry3) || ""
          }
        }
      }

      // Pass 4: Webapp / Browser class contains desktop entry id or name
      for (var m = 0; m < entries.length; m++) {
        var entry4 = entries[m].entry
        if (!entry4) continue
        var eId4 = String(entry4.id || "").toLowerCase()
        var eName4 = String(appLib.entryName(entry4) || entry4.name || "").toLowerCase()
        if (eId4.length >= 3 && lowerAppId.indexOf(eId4) >= 0) {
          return {
            id: entry4.id,
            name: appLib.entryName(entry4) || cleanTitle || entry4.id,
            icon: String(entry4.icon || ""),
            description: appLib.entrySubtext(entry4) || ""
          }
        }
        if (eName4.length >= 3 && lowerAppId.indexOf(eName4) >= 0) {
          return {
            id: entry4.id,
            name: appLib.entryName(entry4) || cleanTitle || entry4.id,
            icon: String(entry4.icon || ""),
            description: appLib.entrySubtext(entry4) || ""
          }
        }
      }

      // Pass 5: Window Title contains application name (e.g. "Discord - General" or "#announcements | Discord")
      for (var n = 0; n < entries.length; n++) {
        var entry5 = entries[n].entry
        if (!entry5) continue
        var appName5 = String(appLib.entryName(entry5) || entry5.name || "").toLowerCase()
        if (appName5.length >= 3) {
          if (lowerTitle.indexOf(appName5) === 0 || lowerTitle.indexOf(" | " + appName5) >= 0 || lowerTitle.indexOf(" - " + appName5) >= 0 || lowerTitle.indexOf(" — " + appName5) >= 0) {
            return {
              id: entry5.id,
              name: appLib.entryName(entry5) || cleanTitle || entry5.id,
              icon: String(entry5.icon || ""),
              description: appLib.entrySubtext(entry5) || ""
            }
          }
        }
      }
    }

    return {
      id: cleanAppId || cleanTitle,
      name: cleanTitle || cleanAppId,
      icon: cleanAppId || "application-x-executable",
      description: ""
    }
  }

  property var knownToplevels: new Set()
  property bool initialSeeded: false

  function syncToplevels() {
    var values = []
    try {
      values = ToplevelManager.toplevels.values || []
    } catch (e) {
      return
    }

    if (!root.initialSeeded) {
      root.initialSeeded = true
      for (var i = 0; i < values.length; i++) {
        root.knownToplevels.add(values[i])
      }
      return
    }

    var nextSet = new Set()
    for (var j = 0; j < values.length; j++) {
      var tl = values[j]
      nextSet.add(tl)

      if (!root.knownToplevels.has(tl)) {
        root.onNewWindowOpened(tl)
      }
    }

    root.knownToplevels = nextSet
  }

  function onNewWindowOpened(tl) {
    if (!tl) return
    var appId = String(tl.appId || "").trim()
    var title = String(tl.title || "").trim()

    if (!appId || appId === "null" || appId === "undefined") {
      Qt.callLater(function() {
        if (!tl) return
        var deferredAppId = String(tl.appId || "").trim()
        var deferredTitle = String(tl.title || "").trim()
        root.processOpenedApp(deferredAppId, deferredTitle)
      })
      return
    }

    root.processOpenedApp(appId, title)
  }

  function processOpenedApp(appId, title) {
    if (!appId || appId === "null" || appId === "undefined") return
    if (appId.indexOf("omarchy") >= 0 || appId.indexOf("quickshell") >= 0) return

    var resolved = root.resolveApp(appId, title)
    if (resolved) {
      root.recordApp(resolved)
    }
  }

  // Ensure storage directory exists
  Process {
    id: ensureDirProc
    command: ["mkdir", "-p", root.stateDirPath]
    running: true
    onExited: {
      stateFile.reload()
      root.refreshDirectories()
    }
  }

  // State file watcher and persistence
  FileView {
    id: stateFile
    path: root.stateFilePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("{}")
  }

  // GTK bookmarks reader
  FileView {
    id: bookmarksFile
    path: root.bookmarksPath
    watchChanges: true
    printErrors: false
    onLoaded: root.handleHarvestedBookmarks(text())
    onFileChanged: reload()
  }

  // Background zoxide harvester
  Process {
    id: zoxideProc
    command: ["zoxide", "query", "-l"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleHarvestedZoxide(text)
    }
  }

  // Asynchronous Debounce Timer for Disk I/O (5s idle period)
  Timer {
    id: saveDebounceTimer
    interval: 5000
    repeat: false
    onTriggered: root.flushState()
  }

  // Periodic low-frequency directory re-harvest (every 10 minutes)
  Timer {
    id: periodicHarvestTimer
    interval: 600000
    repeat: true
    running: true
    onTriggered: root.refreshDirectories()
  }

  // Listener for newly opened windows via Wayland ToplevelManager
  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() {
      root.syncToplevels()
    }
  }

  Connections {
    target: (root.shell && root.shell.appLibrary) ? root.shell.appLibrary : null
    ignoreUnknownSignals: true
    function onAppsChanged() {
      root.healState()
    }
  }

  Timer {
    id: startupHealTimer
    interval: 1500
    repeat: false
    running: true
    onTriggered: root.healState()
  }

  Component.onCompleted: {
    root.syncToplevels()
    root.healState()
  }
}
