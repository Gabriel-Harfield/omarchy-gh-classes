import QtQuick
import Quickshell.Io

// Un « ouvrier » de lecture : exécute UNE commande à la fois (un appel claude
// sur une page scannée) et signale la fin avec sa sortie. Les parallèles du
// QCM sont plusieurs ouvriers, pas plusieurs Process dans un même objet.
Item {
  id: w
  visible: false
  width: 0
  height: 0

  property string jobId: ""
  property string jobClassId: ""
  property bool busy: false

  signal finished(string classId, string copyId, bool ok, string text)

  function start(classId, copyId, command) {
    if (w.busy) return false
    w.jobClassId = classId
    w.jobId = copyId
    w.busy = true
    proc.command = command
    proc.running = false
    proc.running = true
    return true
  }

  function cancel() { proc.running = false }

  Process {
    id: proc
    stdout: StdioCollector { id: out; waitForEnd: true }
    onExited: function(exitCode) {
      var cid = w.jobClassId, id = w.jobId
      w.busy = false
      w.finished(cid, id, exitCode === 0, String(out.text || ""))
    }
  }
}
