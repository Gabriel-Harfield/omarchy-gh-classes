import QtQuick
import qs.Commons
import qs.Ui

// Gear-icon popover: configure (or clear) the folder GH Classes syncs
// classes.json through. Same UX shape as GH Grilles' own SyncSettingsPopover
// (self-contained, own text field, not wired to Panel.qml's page-level
// path-entry bar) — see Panel.qml's runSync()/Store.js's mergeClasses() for
// the actual merge mechanism, which is additive but reconciles draw
// history/reset timestamps rather than doing a plain union like Grilles'
// criteria bank.
Item {
  id: root

  property bool opened: false
  property string currentDir: ""
  // agent.md's global path (Gabriel, 2026-10-03) — set once here instead of
  // per-évaluation; unrelated to sync but this is the plugin's only
  // settings surface today, see Panel.qml's header comment on agentPath.
  property string currentAgentPath: ""
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal dirConfirmed(string dir)
  signal dirCleared()
  signal agentConfirmed(string path)
  signal canceled()

  visible: opened
  anchors.fill: parent

  onOpenedChanged: if (opened) {
    dirField.text = root.currentDir
    agentField.text = root.currentAgentPath
    Qt.callLater(function() { dirField.forceActiveFocus() })
  }

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.background, 0.7)

    MouseArea { anchors.fill: parent; onClicked: root.canceled() }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(32), Style.space(440))
      height: Math.min(parent.height - Style.space(32),
        cardContent.implicitHeight + card.contentTopInset + card.contentBottomInset)
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.flat(root.accent, Style.normalBorderWidth)
      padding: Style.space(16)
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: cardContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: card.contentTopInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        spacing: Style.spacing.lg

        Text {
          text: "Synchronisation des classes"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          wrapMode: Text.WordWrap
          width: parent.width
        }

        Text {
          text: root.currentDir === ""
            ? "Non configurée pour l'instant."
            : "Dossier actuel : " + root.currentDir
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
          wrapMode: Text.WrapAnywhere
          width: parent.width
        }

        Text {
          text: "La fusion est additive et automatique (à l'ouverture de GH Classes et à chaque tirage/groupe/import) : les tirages des deux machines se combinent, et un reset des tirages est bien respecté par la fusion. Supprimer une classe ici ne la supprime pas automatiquement de l'autre machine — à faire des deux côtés si besoin. Important : une classe importée séparément sur chaque machine restera deux classes distinctes ; pour qu'une classe se synchronise, créez-la sur une seule machine puis laissez la synchro l'apporter sur l'autre."
          color: Qt.darker(root.foreground, 1.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.italic: true
          wrapMode: Text.WordWrap
          width: parent.width
        }

        TextField {
          id: dirField
          width: parent.width
          placeholderText: "chemin du dossier de synchronisation…"
          foreground: root.foreground
          accent: root.accent
          maximumLength: 1024
          Keys.onReturnPressed: root.dirConfirmed(dirField.text.trim())
          Keys.onEnterPressed: root.dirConfirmed(dirField.text.trim())
          Keys.onEscapePressed: root.canceled()
        }

        Row {
          spacing: Style.spacing.controlGap

          Button {
            text: "Valider"
            bordered: true
            foreground: root.foreground
            accent: root.accent
            onClicked: root.dirConfirmed(dirField.text.trim())
          }
          Button {
            text: "Désactiver"
            bordered: true
            visible: root.currentDir !== ""
            foreground: root.foreground
            accent: root.accent
            onClicked: root.dirCleared()
          }
          Button {
            text: "Fermer"
            bordered: true
            foreground: root.foreground
            accent: root.accent
            onClicked: root.canceled()
          }
        }

        Text {
          text: "Agent de correction par défaut"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          width: parent.width
        }

        Text {
          text: "Un seul fichier agent.md, appliqué à toute nouvelle évaluation (Corrections) — plus besoin de le repointer chaque fois."
          color: Qt.darker(root.foreground, 1.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.italic: true
          wrapMode: Text.WordWrap
          width: parent.width
        }

        TextField {
          id: agentField
          width: parent.width
          placeholderText: "chemin du fichier agent.md…"
          foreground: root.foreground
          accent: root.accent
          maximumLength: 1024
          Keys.onReturnPressed: root.agentConfirmed(agentField.text.trim())
          Keys.onEnterPressed: root.agentConfirmed(agentField.text.trim())
          Keys.onEscapePressed: root.canceled()
        }

        Button {
          text: "Valider l'agent"
          bordered: true
          foreground: root.foreground
          accent: root.accent
          onClicked: root.agentConfirmed(agentField.text.trim())
        }
      }
    }
  }
}
