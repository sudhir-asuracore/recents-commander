import QtQuick
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.omarchy.recents-commander"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\udb80\udc49" // Nerd font history clock glyph 󰄉
    fontFamily: "Symbols Nerd Font Mono"
    tooltipText: "Recents Commander (Super+Shift+Space)"
    horizontalMargin: 8.0
    onPressed: function(buttonCode) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle io.github.omarchy.recents-commander '{}'")
    }
  }
}
