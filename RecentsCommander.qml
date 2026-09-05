import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "RecentsModel.js" as RecentsModel

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // State
  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property string activeCategory: "all" // "all" | "apps" | "directories"
  readonly property string homeDir: Quickshell.env("HOME")

  // Theme tokens
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int cardWidth: Math.min(Style.space(680), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(540), panel.height - Style.gapsOut * 2)

  // Toast feedback for Shift+Enter copy
  property bool toastVisible: false
  property string toastMessage: ""

  property var service: null
  property var fallbackState: RecentsModel.createEmptyState()

  FileView {
    id: fallbackStateFile
    path: root.homeDir + "/.local/state/omarchy/recents-commander/recents.json"
    watchChanges: false
    printErrors: false
    onLoaded: root.fallbackState = RecentsModel.parseState(text())
    onLoadFailed: root.fallbackState = RecentsModel.createEmptyState()
  }

  function open(payloadJson) {
    if (fallbackStateFile) fallbackStateFile.reload()
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.activeCategory = "all"
    root.toastVisible = false
    if (root.shell && root.shell.appLibrary && root.shell.appLibrary.refreshIcons) {
      root.shell.appLibrary.refreshIcons()
    }
    if (root.service) {
      if (root.service.healState) root.service.healState()
      root.service.refreshDirectories()
    }
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.toastVisible = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function showToast(msg) {
    root.toastMessage = msg
    root.toastVisible = true
    toastTimer.restart()
  }

  function getRecentsState() {
    if (root.service && root.service.recentsState) {
      return root.service.recentsState
    }
    return root.fallbackState
  }

  function rebuildDisplay() {
    var state = root.getRecentsState()
    var result = RecentsModel.filterRecents(state, root.filterText, root.activeCategory, root.homeDir, 50)

    displayModel.clear()
    for (var i = 0; i < result.flatList.length; i++) {
      var item = result.flatList[i]
      displayModel.append({
        itemType: item.type,
        sectionTitle: item.section,
        itemId: item.id,
        title: item.title,
        subtitle: item.subtitle,
        icon: item.icon,
        path: item.path,
        relativeTime: item.relativeTime,
        isFirstInSection: item.isFirstInSection === true,
        sectionCount: item.sectionCount || 0
      })
    }

    if (displayModel.count === 0) {
      root.selectedIndex = 0
    } else if (root.selectedIndex >= displayModel.count) {
      root.selectedIndex = displayModel.count - 1
    } else if (root.selectedIndex < 0) {
      root.selectedIndex = 0
    }

    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function selectDelta(delta) {
    if (displayModel.count === 0) return
    root.selectedIndex = (root.selectedIndex + delta + displayModel.count) % displayModel.count
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function selectAbsolute(index) {
    if (displayModel.count === 0) return
    root.selectedIndex = Math.max(0, Math.min(index, displayModel.count - 1))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function cycleCategory(forward) {
    var categories = ["all", "apps", "directories"]
    var currentIdx = categories.indexOf(root.activeCategory)
    var step = forward ? 1 : -1
    var nextIdx = (currentIdx + step + categories.length) % categories.length
    root.activeCategory = categories[nextIdx]
    root.selectedIndex = 0
    root.rebuildDisplay()
  }

  function setFilter(text) {
    root.filterText = text
    root.selectedIndex = 0
    root.rebuildDisplay()
  }

  function activateCurrent() {
    if (displayModel.count === 0 || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var item = displayModel.get(root.selectedIndex)
    root.close()

    if (item.itemType === "app") {
      var launchId = item.itemId
      if (root.service && root.service.resolveApp) {
        var resolved = root.service.resolveApp(item.itemId, item.title)
        if (resolved && resolved.id) launchId = resolved.id
      }
      if (root.service) {
        root.service.recordApp({ id: launchId, name: item.title, icon: item.icon, description: item.subtitle })
      }
      if (root.shell && root.shell.appLibrary) {
        root.shell.appLibrary.launch(launchId, item.title)
      } else {
        Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(launchId + ".desktop"))
      }
    } else if (item.itemType === "directory") {
      if (root.service) {
        root.service.recordDirectory(item.path)
      }
      Quickshell.execDetached(["gio", "open", item.path])
    }
  }

  function copyCurrentPath() {
    if (displayModel.count === 0 || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var item = displayModel.get(root.selectedIndex)

    if (item.itemType === "directory" && item.path) {
      Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(item.path) + " | wl-copy"])
      root.showToast("Copied path to clipboard: " + item.subtitle)
    }
  }

  function removeCurrent() {
    if (displayModel.count === 0 || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var item = displayModel.get(root.selectedIndex)

    if (root.service) {
      if (item.itemType === "app") root.service.removeApp(item.itemId)
      else if (item.itemType === "directory") root.service.removeDirectory(item.path)
    }
    root.rebuildDisplay()
  }

  function resolveAppIcon(iconName, itemId, title) {
    if (root.shell && root.shell.appLibrary) {
      var appLib = root.shell.appLibrary
      var src = ""

      // 1. Direct lookup by icon name
      if (iconName) {
        src = appLib.iconSource(iconName)
        if (src && src.indexOf("application-x-executable") === -1) {
          return src
        }
      }

      // 2. Correlate with DesktopEntries by itemId, title, or iconName
      var entries = appLib.sortedEntries ? appLib.sortedEntries("") : []
      var searchTerms = [itemId, title, iconName].filter(function(s) { return s && String(s).trim().length > 0 })
      for (var s = 0; s < searchTerms.length; s++) {
        var term = String(searchTerms[s]).trim().toLowerCase()
        for (var i = 0; i < entries.length; i++) {
          var entry = entries[i].entry
          if (!entry) continue
          var entryId = String(entry.id || "").toLowerCase()
          var entryName = String(appLib.entryName(entry) || entry.name || "").toLowerCase()
          var sc = String(entry.startupClass || "").toLowerCase()

          if (entryId === term || entryName === term || (sc && sc === term) ||
              (term.length >= 3 && (entryId.indexOf(term) >= 0 || term.indexOf(entryId) >= 0 || entryName.indexOf(term) >= 0 || term.indexOf(entryName) >= 0))) {
            if (entry.icon) {
              var foundSrc = appLib.iconSource(entry.icon)
              if (foundSrc && foundSrc.indexOf("application-x-executable") === -1) {
                return foundSrc
              }
            }
          }
        }
      }

      if (src) return src
      if (iconName) return appLib.iconSource(iconName)
    }

    if (iconName) {
      var themed = Quickshell.iconPath(iconName, true)
      if (themed) return themed
    }
    return Quickshell.iconPath("application-x-executable", true)
  }

  Connections {
    target: root.service || null
    enabled: root.service !== null
    ignoreUnknownSignals: true
    function onRecentsChanged() {
      if (root.opened) root.rebuildDisplay()
    }
  }

  Timer {
    id: toastTimer
    interval: 1800
    repeat: false
    onTriggered: root.toastVisible = false
  }

  ListModel {
    id: displayModel
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-recents"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.filterText.length > 0) {
              root.setFilter("")
            } else {
              root.close()
            }
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.selectDelta(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.selectDelta(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.selectDelta(-6)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.selectDelta(6)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.selectAbsolute(0)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.selectAbsolute(displayModel.count - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Tab) {
            root.cycleCategory(true)
            event.accepted = true
          } else if (event.key === Qt.Key_Backtab) {
            root.cycleCategory(false)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (event.modifiers & Qt.ShiftModifier) {
              root.copyCurrentPath()
            } else {
              root.activateCurrent()
            }
            event.accepted = true
          } else if (event.key === Qt.Key_Delete || (event.key === Qt.Key_Backspace && (event.modifiers & Qt.ShiftModifier))) {
            root.removeCurrent()
            event.accepted = true
          } else if (event.key === Qt.Key_Backspace) {
            if (root.filterText.length > 0) {
              root.setFilter(root.filterText.slice(0, -1))
            }
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }

        Column {
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          spacing: Style.spacing.md

          // Header: Search prompt
          Rectangle {
            id: searchHeader
            width: parent.width
            height: Style.space(42)
            color: "transparent"

            Row {
              anchors.fill: parent
              spacing: Style.space(12)

              Text {
                text: "󰄉" // Nerd font history clock glyph 󰄉
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: root.filterText || "Search recent apps and directories…"
                color: root.foreground
                opacity: root.filterText ? 1.0 : 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                elide: Text.ElideRight
                width: parent.width - Style.space(80)
              }

              Text {
                visible: root.filterText.length > 0
                text: "\u2715" // Close / clear icon
                color: root.foreground
                opacity: 0.6
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setFilter("")
                }
              }
            }
          }

          // Category Selector Pills
          Row {
            id: categoryRow
            spacing: Style.space(8)

            Repeater {
              model: [
                { id: "all", label: "All" },
                { id: "apps", label: "󰀻  Apps" },
                { id: "directories", label: "  Directories" }
              ]

              Rectangle {
                width: pillText.implicitWidth + Style.space(20)
                height: Style.space(26)
                radius: Style.space(13)
                color: root.activeCategory === modelData.id ? root.selectedBackground : "transparent"
                border.color: root.activeCategory === modelData.id ? root.border : Qt.rgba(root.border.r, root.border.g, root.border.b, 0.4)
                border.width: 1

                Text {
                  id: pillText
                  anchors.centerIn: parent
                  text: modelData.label
                  color: root.activeCategory === modelData.id ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: root.activeCategory === modelData.id
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.activeCategory = modelData.id
                    root.selectedIndex = 0
                    root.rebuildDisplay()
                  }
                }
              }
            }
          }

          // List View
          Item {
            width: parent.width
            height: parent.height - searchHeader.height - categoryRow.height - footerItem.height - Style.spacing.md * 3

            ListView {
              id: resultList
              anchors.fill: parent
              clip: true
              model: displayModel
              spacing: Style.spacing.xs

              delegate: Column {
                width: resultList.width

                // Section Header
                Item {
                  width: parent.width
                  height: model.isFirstInSection ? Style.space(32) : 0
                  visible: model.isFirstInSection

                  Row {
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.space(6)
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(6)
                    spacing: Style.space(8)

                    Text {
                      text: (model.sectionTitle || "").toUpperCase()
                      color: root.foreground
                      opacity: 0.65
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }

                    Text {
                      text: "(" + model.sectionCount + ")"
                      color: root.foreground
                      opacity: 0.4
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                // Row Item
                Rectangle {
                  id: rowRect
                  width: parent.width
                  height: Style.space(48)
                  radius: Style.cornerRadius
                  color: index === root.selectedIndex ? root.selectedBackground : "transparent"

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPositionChanged: root.selectedIndex = index
                    onClicked: root.activateCurrent()
                  }

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    spacing: Style.space(14)

                    // Icon
                    Item {
                      width: Style.space(28)
                      height: Style.space(28)
                      anchors.verticalCenter: parent.verticalCenter

                      Image {
                        visible: model.itemType === "app"
                        anchors.fill: parent
                        source: model.itemType === "app" ? root.resolveAppIcon(model.icon, model.itemId, model.title) : ""
                        fillMode: Image.PreserveAspectFit
                        sourceSize.width: 32
                        sourceSize.height: 32
                      }

                      Text {
                        visible: model.itemType === "directory"
                        anchors.centerIn: parent
                        text: model.icon === "folder-git" ? "" : ""
                        color: index === root.selectedIndex ? root.selectedText : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.title
                      }
                    }

                    // Titles
                    Column {
                      width: parent.width - Style.space(120)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(2)

                      Text {
                        width: parent.width
                        text: model.title || ""
                        color: index === root.selectedIndex ? root.selectedText : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        text: model.subtitle || ""
                        color: index === root.selectedIndex ? root.selectedText : root.foreground
                        opacity: 0.65
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    // Relative Time
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: model.relativeTime || ""
                      color: index === root.selectedIndex ? root.selectedText : root.foreground
                      opacity: 0.5
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }

            // Empty state message
            Text {
              anchors.centerIn: parent
              visible: displayModel.count === 0
              text: root.filterText ? "No recents matching \"" + root.filterText + "\"" : "No recent applications or directories found."
              color: root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          // Footer shortcut hints & Toast
          Item {
            id: footerItem
            width: parent.width
            height: Style.space(20)

            // Shortcut guide
            Text {
              visible: !root.toastVisible
              anchors.left: parent.left
              anchors.leftMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              text: "\u2191\u2193 Navigate   \u23ce Open   \u21e7\u23ce Copy Path   Del Remove   Esc Close"
              color: root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Toast feedback
            Rectangle {
              visible: root.toastVisible
              anchors.centerIn: parent
              height: Style.space(24)
              width: toastText.implicitWidth + Style.space(20)
              radius: Style.space(12)
              color: root.selectedBackground

              Text {
                id: toastText
                anchors.centerIn: parent
                text: root.toastMessage
                color: root.selectedText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }
        }
      }
    }
  }
}
