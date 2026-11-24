// Maps camera pixels to monitor pixels using the visible markers.
var Region = (function () {
  // Normalising transform: returns [scale, cx, cy].
  function norm(points) {
    var cx = 0, cy = 0, d = 0, n = points.length;
    points.forEach(function (p) { cx += p.x / n; cy += p.y / n; });
    points.forEach(function (p) { d += Math.hypot(p.x - cx, p.y - cy) / n; });
    return [1 / (d || 1), cx, cy];
  }

  function solve8(A, b) {
    var n = 8, i, j, k;
    for (i = 0; i < n; i++) {
      var pivot = i;
      for (j = i + 1; j < n; j++) if (Math.abs(A[j][i]) > Math.abs(A[pivot][i])) pivot = j;
      if (Math.abs(A[pivot][i]) < 1e-12) return null;
      var t = A[i]; A[i] = A[pivot]; A[pivot] = t;
      var u = b[i]; b[i] = b[pivot]; b[pivot] = u;
      for (j = i + 1; j < n; j++) {
        var f = A[j][i] / A[i][i];
        for (k = i; k < n; k++) A[j][k] -= f * A[i][k];
        b[j] -= f * b[i];
      }
    }
    for (i = n - 1; i >= 0; i--) {
      for (k = i + 1; k < n; k++) b[i] -= A[i][k] * b[k];
      b[i] /= A[i][i];
    }
    return b;
  }

  // Least-squares homography from -> to. Returns a point mapper or null.
  function fit(from, to) {
    var a = norm(from), c = norm(to), i, j;
    var A = [], b = [];
    for (i = 0; i < 8; i++) { A.push([0, 0, 0, 0, 0, 0, 0, 0]); b.push(0); }
    function add(row, value) {
      for (i = 0; i < 8; i++) {
        for (j = 0; j < 8; j++) A[i][j] += row[i] * row[j];
        b[i] += row[i] * value;
      }
    }
    from.forEach(function (p, n) {
      var x = (p.x - a[1]) * a[0], y = (p.y - a[2]) * a[0];
      var X = (to[n].x - c[1]) * c[0], Y = (to[n].y - c[2]) * c[0];
      add([x, y, 1, 0, 0, 0, -X * x, -X * y], X);
      add([0, 0, 0, x, y, 1, -Y * x, -Y * y], Y);
    });
    var h = solve8(A, b);
    if (!h) return null;
    return function (p) {
      var x = (p.x - a[1]) * a[0], y = (p.y - a[2]) * a[0];
      var w = h[6] * x + h[7] * y + 1;
      if (w < 0.05) return null; // at or beyond the horizon
      return {
        x: (h[0] * x + h[1] * y + h[2]) / w / c[0] + c[1],
        y: (h[3] * x + h[4] * y + h[5]) / w / c[0] + c[2]
      };
    };
  }

  // detected: [{id, corners}], view: 4 corners of the viewfinder in camera pixels.
  function locate(detected, layout, view) {
    var byId = {}, groups = {};
    layout.markers.forEach(function (k) { byId[k.id] = k; });
    detected.forEach(function (d) {
      var k = byId[d.id];
      if (k) (groups[k.m] = groups[k.m] || []).push({ k: k, corners: d.corners });
    });
    var best = null;
    Object.keys(groups).forEach(function (m) {
      if (best === null || groups[m].length > groups[best].length) best = m;
    });
    if (best === null) return null;

    var from = [], to = [];
    groups[best].forEach(function (g) {
      var k = g.k;
      from.push.apply(from, g.corners);
      to.push({ x: k.x, y: k.y }, { x: k.x + k.s, y: k.y }, { x: k.x + k.s, y: k.y + k.s }, { x: k.x, y: k.y + k.s });
    });
    var map = fit(from, to);
    if (!map) return null;
    // A misread marker shows up as a large residual.
    var limit = groups[best][0].k.s * 0.5;
    for (var i = 0; i < from.length; i++) {
      var q = map(from[i]);
      if (!q || Math.hypot(q.x - to[i].x, q.y - to[i].y) > limit) return null;
    }
    var pts = view.map(map);
    if (pts.some(function (p) { return !p; })) return null;
    // Averaging the two outermost corners per side straightens a tilted view.
    var num = function (p, r) { return p - r; };
    var xs = pts.map(function (p) { return p.x; }).sort(num);
    var ys = pts.map(function (p) { return p.y; }).sort(num);
    var mon = layout.monitors[best];
    var clamp = function (v, hi) { return Math.round(Math.max(0, Math.min(hi, v))); };
    var x0 = clamp((xs[0] + xs[1]) / 2, mon.w), x1 = clamp((xs[2] + xs[3]) / 2, mon.w);
    var y0 = clamp((ys[0] + ys[1]) / 2, mon.h), y1 = clamp((ys[2] + ys[3]) / 2, mon.h);
    if (x1 - x0 < 8 || y1 - y0 < 8) return null;
    return { m: +best, x: x0, y: y0, w: x1 - x0, h: y1 - y0, markers: groups[best].length, version: layout.version };
  }

  return { fit: fit, locate: locate };
})();
if (typeof module !== 'undefined') module.exports = Region;
