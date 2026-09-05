.pragma library

/**
 * RecentsModel.js - Core business logic for Recents Commander.
 * Provides in-memory storage, frecency scoring, debounced persistence helpers,
 * and high-performance search filtering.
 */

var DEFAULT_MAX_APPS = 30;
var DEFAULT_MAX_DIRS = 30;

function createEmptyState() {
  return {
    version: 1,
    lastUpdated: new Date().toISOString(),
    apps: [],
    directories: []
  };
}

function parseState(rawText) {
  if (!rawText || typeof rawText !== "string") {
    return createEmptyState();
  }
  try {
    var data = JSON.parse(rawText);
    if (!data || typeof data !== "object") return createEmptyState();
    return {
      version: 1,
      lastUpdated: data.lastUpdated || new Date().toISOString(),
      apps: Array.isArray(data.apps) ? sortEntries(data.apps) : [],
      directories: Array.isArray(data.directories) ? sortEntries(data.directories) : []
    };
  } catch (e) {
    return createEmptyState();
  }
}

function serializeState(state) {
  var cleanState = {
    version: 1,
    lastUpdated: new Date().toISOString(),
    apps: Array.isArray(state.apps) ? sortEntries(state.apps).slice(0, 50) : [],
    directories: Array.isArray(state.directories) ? sortEntries(state.directories).slice(0, 50) : []
  };
  return JSON.stringify(cleanState, null, 2) + "\n";
}

function calculateFrecency(lastOpenedIso, openCount) {
  var count = typeof openCount === "number" ? openCount : 1;
  var timestamp = lastOpenedIso ? new Date(lastOpenedIso).getTime() : 0;
  var now = Date.now();
  var ageMs = Math.max(0, now - timestamp);
  var ageHours = ageMs / (1000 * 60 * 60);

  var recencyWeight = 20;
  if (ageHours < 4) {
    recencyWeight = 100;
  } else if (ageHours < 24) {
    recencyWeight = 80;
  } else if (ageHours < 72) {
    recencyWeight = 60;
  } else if (ageHours < 168) { // 7 days
    recencyWeight = 40;
  }

  return count * recencyWeight;
}

function sortEntries(entries) {
  return entries.slice().sort(function(a, b) {
    var timeA = a.lastOpened ? new Date(a.lastOpened).getTime() : 0;
    var timeB = b.lastOpened ? new Date(b.lastOpened).getTime() : 0;
    return timeB - timeA;
  });
}

function normalizePath(rawPath) {
  if (!rawPath || typeof rawPath !== "string") return "";
  var p = rawPath.trim();
  if (p.length > 1 && p.charAt(p.length - 1) === "/") {
    p = p.slice(0, -1);
  }
  return p;
}

function abbreviatePath(fullPath, homeDir) {
  if (!fullPath) return "";
  var home = homeDir || "";
  if (home && fullPath.indexOf(home) === 0) {
    return "~" + fullPath.slice(home.length);
  }
  return fullPath;
}

function directoryBaseName(dirPath) {
  if (!dirPath) return "";
  var normalized = normalizePath(dirPath);
  var lastSlash = normalized.lastIndexOf("/");
  if (lastSlash >= 0) {
    var name = normalized.slice(lastSlash + 1);
    return name || "/";
  }
  return normalized;
}

function formatRelativeTime(isoString) {
  if (!isoString) return "";
  var date = new Date(isoString);
  var diffSeconds = Math.round((Date.now() - date.getTime()) / 1000);
  if (isNaN(diffSeconds) || diffSeconds < 0) return "just now";

  if (diffSeconds < 60) return "just now";
  var diffMinutes = Math.floor(diffSeconds / 60);
  if (diffMinutes < 60) return diffMinutes + "m ago";
  var diffHours = Math.floor(diffMinutes / 60);
  if (diffHours < 24) return diffHours + "h ago";
  var diffDays = Math.floor(diffHours / 24);
  if (diffDays === 1) return "yesterday";
  if (diffDays < 7) return diffDays + "d ago";
  var diffWeeks = Math.floor(diffDays / 7);
  if (diffWeeks < 4) return diffWeeks + "w ago";
  return Qt.formatDate ? Qt.formatDate(date, "MMM d") : date.toLocaleDateString();
}

function recordApp(state, appData, maxLimit) {
  if (!appData || !appData.id) return state;
  var limit = maxLimit || DEFAULT_MAX_APPS;
  var id = String(appData.id);
  var nowIso = new Date().toISOString();

  var apps = Array.isArray(state.apps) ? state.apps.slice() : [];
  var existingIndex = -1;
  for (var i = 0; i < apps.length; i++) {
    if (apps[i].id === id) {
      existingIndex = i;
      break;
    }
  }

  if (existingIndex >= 0) {
    var current = apps[existingIndex];
    apps[existingIndex] = {
      id: current.id,
      name: appData.name || current.name || id,
      icon: appData.icon || current.icon || "",
      description: appData.description || current.description || "",
      lastOpened: nowIso,
      openCount: (current.openCount || 1) + 1
    };
  } else {
    apps.push({
      id: id,
      name: appData.name || id,
      icon: appData.icon || "",
      description: appData.description || "",
      lastOpened: nowIso,
      openCount: 1
    });
  }

  var sorted = sortEntries(apps).slice(0, limit);
  return {
    version: 1,
    lastUpdated: nowIso,
    apps: sorted,
    directories: state.directories || []
  };
}

function recordDirectory(state, dirPath, maxLimit) {
  var normalized = normalizePath(dirPath);
  if (!normalized) return state;
  var limit = maxLimit || DEFAULT_MAX_DIRS;
  var nowIso = new Date().toISOString();

  var dirs = Array.isArray(state.directories) ? state.directories.slice() : [];
  var existingIndex = -1;
  for (var i = 0; i < dirs.length; i++) {
    if (normalizePath(dirs[i].path) === normalized) {
      existingIndex = i;
      break;
    }
  }

  var baseName = directoryBaseName(normalized);
  if (existingIndex >= 0) {
    var current = dirs[existingIndex];
    dirs[existingIndex] = {
      path: normalized,
      name: current.name || baseName,
      lastOpened: nowIso,
      openCount: (current.openCount || 1) + 1,
      isGit: current.isGit !== undefined ? current.isGit : false
    };
  } else {
    dirs.push({
      path: normalized,
      name: baseName,
      lastOpened: nowIso,
      openCount: 1,
      isGit: false
    });
  }

  var sorted = sortEntries(dirs).slice(0, limit);
  return {
    version: 1,
    lastUpdated: nowIso,
    apps: state.apps || [],
    directories: sorted
  };
}

function mergeHarvestedDirectories(state, pathsList, maxLimit) {
  if (!Array.isArray(pathsList) || pathsList.length === 0) return state;
  var limit = maxLimit || DEFAULT_MAX_DIRS;
  var dirs = Array.isArray(state.directories) ? state.directories.slice() : [];
  var dirMap = {};

  for (var i = 0; i < dirs.length; i++) {
    var p = normalizePath(dirs[i].path);
    if (p) dirMap[p] = dirs[i];
  }

  var now = Date.now();
  for (var j = 0; j < pathsList.length; j++) {
    var rawPath = pathsList[j];
    var norm = normalizePath(rawPath);
    if (!norm) continue;

    if (!dirMap[norm]) {
      // Estimated synthetic recency based on position in zoxide list
      var syntheticAgeMs = j * 3600000; // 1 hour per rank position
      var syntheticDate = new Date(now - syntheticAgeMs).toISOString();
      dirMap[norm] = {
        path: norm,
        name: directoryBaseName(norm),
        lastOpened: syntheticDate,
        openCount: Math.max(1, 10 - Math.min(9, Math.floor(j / 2))),
        isGit: false
      };
      dirs.push(dirMap[norm]);
    }
  }

  var sorted = sortEntries(dirs).slice(0, limit);
  return {
    version: 1,
    lastUpdated: new Date().toISOString(),
    apps: state.apps || [],
    directories: sorted
  };
}

function removeApp(state, appId) {
  if (!appId) return state;
  var apps = (state.apps || []).filter(function(a) { return a.id !== appId; });
  return {
    version: 1,
    lastUpdated: new Date().toISOString(),
    apps: apps,
    directories: state.directories || []
  };
}

function removeDirectory(state, dirPath) {
  var norm = normalizePath(dirPath);
  if (!norm) return state;
  var dirs = (state.directories || []).filter(function(d) {
    return normalizePath(d.path) !== norm;
  });
  return {
    version: 1,
    lastUpdated: new Date().toISOString(),
    apps: state.apps || [],
    directories: dirs
  };
}

function fuzzyScore(text, pattern) {
  var t = String(text || "").toLowerCase();
  var p = String(pattern || "").toLowerCase();
  if (!p) return 1;
  var exactIdx = t.indexOf(p);
  if (exactIdx === 0) return 100; // starts with pattern
  if (exactIdx > 0) return 50;    // contains pattern

  // Subsequence match
  var tIdx = 0;
  var pIdx = 0;
  var score = 0;
  while (tIdx < t.length && pIdx < p.length) {
    if (t.charAt(tIdx) === p.charAt(pIdx)) {
      score += 5;
      pIdx++;
    }
    tIdx++;
  }
  return pIdx === p.length ? score : 0;
}

function filterRecents(state, query, activeCategory, homeDir, maxResults) {
  var cleanQuery = (query || "").trim().toLowerCase();
  var category = activeCategory || "all";
  var home = homeDir || "";
  var limit = maxResults || 50;

  var appResults = [];
  var dirResults = [];

  if (category === "all" || category === "apps") {
    var rawApps = Array.isArray(state.apps) ? state.apps : [];
    for (var a = 0; a < rawApps.length; a++) {
      var app = rawApps[a];
      var nameScore = fuzzyScore(app.name, cleanQuery);
      var descScore = fuzzyScore(app.description, cleanQuery);
      var idScore = fuzzyScore(app.id, cleanQuery);
      var maxAppScore = Math.max(nameScore, descScore, idScore);

      if (!cleanQuery || maxAppScore > 0) {
        appResults.push({
          type: "app",
          section: "Applications",
          id: app.id,
          title: app.name || app.id,
          subtitle: app.description || app.id,
          icon: app.icon || "application-x-executable",
          path: "",
          relativeTime: formatRelativeTime(app.lastOpened),
          matchScore: maxAppScore,
          raw: app
        });
      }
    }
  }

  if (category === "all" || category === "directories") {
    var rawDirs = Array.isArray(state.directories) ? state.directories : [];
    for (var d = 0; d < rawDirs.length; d++) {
      var dir = rawDirs[d];
      var dirNameScore = fuzzyScore(dir.name, cleanQuery);
      var dirPathScore = fuzzyScore(dir.path, cleanQuery);
      var maxDirScore = Math.max(dirNameScore, dirPathScore);

      if (!cleanQuery || maxDirScore > 0) {
        var displayPath = abbreviatePath(dir.path, home);
        dirResults.push({
          type: "directory",
          section: "Directories",
          id: dir.path,
          title: dir.name || directoryBaseName(dir.path),
          subtitle: displayPath,
          icon: dir.isGit ? "folder-git" : "folder",
          path: dir.path,
          relativeTime: formatRelativeTime(dir.lastOpened),
          matchScore: maxDirScore,
          raw: dir
        });
      }
    }
  }

  function compareEntries(x, y) {
    if (cleanQuery && x.matchScore !== y.matchScore) {
      return y.matchScore - x.matchScore;
    }
    var timeX = x.raw && x.raw.lastOpened ? new Date(x.raw.lastOpened).getTime() : 0;
    var timeY = y.raw && y.raw.lastOpened ? new Date(y.raw.lastOpened).getTime() : 0;
    return timeY - timeX;
  }

  appResults.sort(compareEntries);
  dirResults.sort(compareEntries);

  var flatList = [];
  if (category === "all") {
    var cappedApps = appResults.slice(0, Math.min(appResults.length, Math.floor(limit / 2)));
    var cappedDirs = dirResults.slice(0, Math.min(dirResults.length, Math.floor(limit / 2)));

    for (var i = 0; i < cappedApps.length; i++) {
      cappedApps[i].isFirstInSection = (i === 0);
      cappedApps[i].sectionCount = cappedApps.length;
      flatList.push(cappedApps[i]);
    }

    for (var j = 0; j < cappedDirs.length; j++) {
      cappedDirs[j].isFirstInSection = (j === 0);
      cappedDirs[j].sectionCount = cappedDirs.length;
      flatList.push(cappedDirs[j]);
    }
  } else if (category === "apps") {
    var slicedApps = appResults.slice(0, limit);
    for (var k = 0; k < slicedApps.length; k++) {
      slicedApps[k].isFirstInSection = (k === 0);
      slicedApps[k].sectionCount = slicedApps.length;
      flatList.push(slicedApps[k]);
    }
  } else if (category === "directories") {
    var slicedDirs = dirResults.slice(0, limit);
    for (var m = 0; m < slicedDirs.length; m++) {
      slicedDirs[m].isFirstInSection = (m === 0);
      slicedDirs[m].sectionCount = slicedDirs.length;
      flatList.push(slicedDirs[m]);
    }
  }

  return {
    apps: appResults,
    directories: dirResults,
    flatList: flatList,
    totalCount: flatList.length
  };
}

// Export for Node unit tests if running under CommonJS
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    createEmptyState: createEmptyState,
    parseState: parseState,
    serializeState: serializeState,
    calculateFrecency: calculateFrecency,
    formatRelativeTime: formatRelativeTime,
    normalizePath: normalizePath,
    abbreviatePath: abbreviatePath,
    recordApp: recordApp,
    recordDirectory: recordDirectory,
    mergeHarvestedDirectories: mergeHarvestedDirectories,
    removeApp: removeApp,
    removeDirectory: removeDirectory,
    sortEntries: sortEntries,
    filterRecents: filterRecents
  };
}
