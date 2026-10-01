import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../lib/CompetencyGrids.js" as CompetencyGrids

// "Répartir les points" — per-criterion weighting for the grid-first
// pipeline's note calculation (Gabriel, 2026-09-27, see
// [[gh-corrections-plugin]]): a small point-buy screen, one stepper per
// checkable criterion, feeding CompetencyGrids.computeWeightedNote(). Used
// both from the évaluation-creation wizard (operating on a draft object
// that doesn't exist yet) and on an already-created évaluation (Gabriel
// wants to rebalance mid-devoir and see the effect on copies already
// corrected, without recreating anything) — this component only ever
// deals with a plain `weights` object and a `weightChanged` signal, the
// caller decides where that goes.
Item {
  id: root

  property bool opened: false
  property var grid: null // CompetencyGrids grid object ({ id, name, rows })
  property var weights: ({}) // { "<rowIndex>": points (0-10) }
  property int total: 20 // évaluation's barème (10 or 20) — Gabriel, 2026-10-01
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal canceled()
  signal weightChanged(int rowIndex, real points)
  signal resetRequested()

  function weightFor(rowIndex) {
    var v = root.weights[String(rowIndex)]
    return v === undefined ? 0 : v
  }

  function totalDistributed() {
    var total = 0
    for (var k in root.weights) total += Number(root.weights[k]) || 0
    return total
  }

  visible: opened

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.background, 0.7)

    MouseArea { anchors.fill: parent; onClicked: root.canceled() }

    BorderSurface {
      id: card
      width: parent.width - Style.space(40)
      height: parent.height - Style.space(40)
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.flat(root.accent, Style.normalBorderWidth)
      padding: Style.space(18)
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      ScrollView {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        Column {
          width: card.width - card.contentLeftInset - card.contentRightInset
          spacing: Style.spacing.lg

          Text {
            text: "Répartir les points par critère"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            wrapMode: Text.WordWrap
            width: parent.width
            textFormat: Text.PlainText
          }

          Text {
            width: parent.width
            text: "Chaque critère vaut le nombre de points que vous lui donnez ici, sur un total de " + root.total + ". Idéalement, répartissez exactement " + root.total + " points au total. Un critère gagne : Maîtrisé = tous ses points, En cours de maîtrise = 2/3, Insuffisamment maîtrisé = 1/3, Non maîtrisé = 0. La note finale est la somme de ce que chaque critère rapporte."
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            text: "Total distribué : " + CompetencyGrids.formatNote(root.totalDistributed()) + " / " + root.total
            color: root.totalDistributed() === root.total ? root.accent : Qt.darker(root.foreground, 1.3)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            visible: !root.grid
            text: "Aucune grille associée à cette évaluation."
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.grid ? root.grid.rows : []
            delegate: Row {
              required property var modelData
              required property int index
              visible: modelData.checkable
              width: parent.width
              spacing: Style.spacing.controlGap

              Text {
                width: parent.width - Style.space(140)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.text
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
              }

              Button {
                text: "−"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                enabled: root.weightFor(index) > 0
                onClicked: root.weightChanged(index, root.weightFor(index) - 0.5)
              }

              Text {
                width: Style.space(36)
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
                text: CompetencyGrids.formatNote(root.weightFor(index))
                font.bold: true
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Button {
                text: "+"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                enabled: root.weightFor(index) < root.total
                onClicked: root.weightChanged(index, root.weightFor(index) + 0.5)
              }
            }
          }

          Row {
            spacing: Style.spacing.controlGap
            Button {
              text: "🔄 Réinitialiser les points"
              bordered: true
              foreground: root.foreground
              accent: Color.urgent
              onClicked: root.resetRequested()
            }
            Button {
              text: "Fermer"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              onClicked: root.canceled()
            }
          }
        }
      }
    }
  }
}
