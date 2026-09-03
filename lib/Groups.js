// Automatic group generation with "these students can't be together"
// constraints. Best-effort, not a full constraint solver: shuffle, deal
// round-robin, then repair conflicts by swapping — good enough for a
// classroom-sized roster (a few dozen students, a handful of constraint
// sets), not meant to prove optimality.

.pragma library

function shuffled(arr) {
  var a = arr.slice()
  for (var i = a.length - 1; i > 0; i--) {
    var j = Math.floor(Math.random() * (i + 1))
    var tmp = a[i]; a[i] = a[j]; a[j] = tmp
  }
  return a
}

function pairKey(a, b) {
  return a < b ? a + "|" + b : b + "|" + a
}

// incompatibilities: [[studentId, ...], ...] — every pair within a set
// conflicts. Returns a Set-like object (plain map) of "id1|id2" -> true.
function buildConflictMap(incompatibilities) {
  var map = {}
  for (var i = 0; i < incompatibilities.length; i++) {
    var set = incompatibilities[i]
    for (var a = 0; a < set.length; a++) {
      for (var b = a + 1; b < set.length; b++) {
        map[pairKey(set[a], set[b])] = true
      }
    }
  }
  return map
}

function hasConflict(conflictMap, id1, id2) {
  return !!conflictMap[pairKey(id1, id2)]
}

function groupConflicts(group, conflictMap) {
  var out = []
  for (var a = 0; a < group.length; a++) {
    for (var b = a + 1; b < group.length; b++) {
      if (hasConflict(conflictMap, group[a].id, group[b].id)) out.push([a, b])
    }
  }
  return out
}

// Returns { groups: [[Student, ...], ...], unresolved: [[Student, Student], ...] }
function generateGroups(students, numGroups, incompatibilities) {
  var n = Math.max(1, Math.min(students.length || 1, Math.floor(numGroups) || 1))
  var conflictMap = buildConflictMap(incompatibilities || [])
  var pool = shuffled(students)

  var groups = []
  for (var g = 0; g < n; g++) groups.push([])
  for (var i = 0; i < pool.length; i++) groups[i % n].push(pool[i])

  var maxPasses = 30
  for (var pass = 0; pass < maxPasses; pass++) {
    var anyConflict = false
    for (var gi = 0; gi < groups.length; gi++) {
      var conflicts = groupConflicts(groups[gi], conflictMap)
      if (conflicts.length === 0) continue
      anyConflict = true
      var pairIdx = conflicts[0]
      var moverIdx = pairIdx[1] // move the second member of the conflicting pair
      var mover = groups[gi][moverIdx]

      var swapped = false
      for (var gj = 0; gj < groups.length && !swapped; gj++) {
        if (gj === gi) continue
        for (var k = 0; k < groups[gj].length && !swapped; k++) {
          var candidate = groups[gj][k]
          // Would moving `mover` into group gj (replacing candidate) and
          // `candidate` into group gi create any NEW conflict in either
          // resulting group? Check against every other member.
          var okInGi = true
          for (var x = 0; x < groups[gi].length; x++) {
            if (x === moverIdx) continue
            if (hasConflict(conflictMap, groups[gi][x].id, candidate.id)) { okInGi = false; break }
          }
          var okInGj = true
          if (okInGi) {
            for (var y = 0; y < groups[gj].length; y++) {
              if (y === k) continue
              if (hasConflict(conflictMap, groups[gj][y].id, mover.id)) { okInGj = false; break }
            }
          }
          if (okInGi && okInGj) {
            groups[gi][moverIdx] = candidate
            groups[gj][k] = mover
            swapped = true
          }
        }
      }
      if (swapped) continue
    }
    if (!anyConflict) break
  }

  var unresolved = []
  for (var gz = 0; gz < groups.length; gz++) {
    var rem = groupConflicts(groups[gz], conflictMap)
    for (var r = 0; r < rem.length; r++) {
      unresolved.push([groups[gz][rem[r][0]], groups[gz][rem[r][1]]])
    }
  }

  return { groups: groups, unresolved: unresolved }
}
