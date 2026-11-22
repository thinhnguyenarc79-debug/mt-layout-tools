/* AUTO LAYOUT PRO – DIM thủ công 2 điểm (v2.14): hàm thuần (không đụng DOM) để bắt điểm & đo.
   Mọi toạ độ ở đây là mm THẬT trong hệ cục bộ của hình (gốc góc trên-trái vùng vẽ, v hướng xuống) –
   cùng hệ với hình học plugin gửi kèm (info.snap[key].segs = [[x1,y1,x2,y2], ...]).
   Giao diện chỉ đổi giấy <-> hình qua khung hình (info.frames[key] = [ox, oy, tỉ lệ, w, h]) nên zoom/pan/tỉ lệ
   không làm lệch điểm bắt. */
(function (root) {
  'use strict';
  var SHELF_MAX = 60; // mm: độ dày tối đa coi là "cùng một tấm" khi chỉnh điểm đo thông thủy về mặt trong

  function Index(segs, w, h) {
    this.segs = segs || [];
    var big = Math.max(w || 1, h || 1, 1);
    this.cell = Math.max(5, big / 64);
    this.grid = {};
    for (var i = 0; i < this.segs.length; i++) {
      var s = this.segs[i];
      var x0 = Math.floor(Math.min(s[0], s[2]) / this.cell), x1 = Math.floor(Math.max(s[0], s[2]) / this.cell);
      var y0 = Math.floor(Math.min(s[1], s[3]) / this.cell), y1 = Math.floor(Math.max(s[1], s[3]) / this.cell);
      if ((x1 - x0 + 1) * (y1 - y0 + 1) > 4096) { (this.grid.all = this.grid.all || []).push(i); continue; }
      for (var gx = x0; gx <= x1; gx++) for (var gy = y0; gy <= y1; gy++) {
        var k = gx + ',' + gy; (this.grid[k] = this.grid[k] || []).push(i);
      }
    }
  }
  Index.prototype.near = function (p, r) {
    var c = this.cell, out = {}, res = [];
    var x0 = Math.floor((p[0] - r) / c), x1 = Math.floor((p[0] + r) / c), y0 = Math.floor((p[1] - r) / c), y1 = Math.floor((p[1] + r) / c);
    if ((x1 - x0 + 1) * (y1 - y0 + 1) > 10000) { for (var a = 0; a < this.segs.length; a++) res.push(a); return res; }
    var add = function (l) { if (l) for (var i = 0; i < l.length; i++) if (!out[l[i]]) { out[l[i]] = 1; res.push(l[i]); } };
    for (var gx = x0; gx <= x1; gx++) for (var gy = y0; gy <= y1; gy++) add(this.grid[gx + ',' + gy]);
    add(this.grid.all);
    return res;
  };

  function foot(p, s) {
    var dx = s[2] - s[0], dy = s[3] - s[1], l2 = dx * dx + dy * dy;
    var t = l2 ? ((p[0] - s[0]) * dx + (p[1] - s[1]) * dy) / l2 : 0;
    t = Math.max(0, Math.min(1, t));
    return [s[0] + t * dx, s[1] + t * dy];
  }
  function dist(a, b) { return Math.hypot(a[0] - b[0], a[1] - b[1]); }
  function inter(s, q) {
    var x1 = s[0], y1 = s[1], x2 = s[2], y2 = s[3], x3 = q[0], y3 = q[1], x4 = q[2], y4 = q[3];
    var d = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4);
    if (Math.abs(d) < 1e-9) return null;
    var t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / d, u = -((x1 - x2) * (y1 - y3) - (y1 - y2) * (x1 - x3)) / d;
    if (t < -1e-6 || t > 1 + 1e-6 || u < -1e-6 || u > 1 + 1e-6) return null;
    return [x1 + t * (x2 - x1), y1 + t * (y2 - y1)];
  }
  function r1(p) { return [Math.round(p[0] * 100) / 100, Math.round(p[1] * 100) / 100]; }

  // Bắt điểm gần p trong bán kính r (mm thật). Ưu tiên: đầu mút/góc ván > giao điểm > điểm trên cạnh.
  // Trả về { p, type: 'end'|'int'|'edge', seg } hoặc null (Smart Snap tắt hoặc không có hình học gần).
  function snap(idx, p, r) {
    if (!idx) return null;
    var ids = idx.near(p, r), best = null;
    var take = function (q, type, rank, seg) {
      var d = dist(p, q); if (d > r) return;
      if (!best || rank < best.rank || (rank === best.rank && d < best.d)) best = { p: r1(q), type: type, rank: rank, d: d, seg: seg };
    };
    var cand = [];
    for (var i = 0; i < ids.length; i++) {
      var s = idx.segs[ids[i]];
      take([s[0], s[1]], 'end', 0, s); take([s[2], s[3]], 'end', 0, s);
      var f = foot(p, s);
      if (dist(p, f) <= r) cand.push([s, f]);
    }
    if (!best || best.rank > 0) {
      var cs = cand.slice(0, 40);
      for (var a = 0; a < cs.length; a++) for (var b = a + 1; b < cs.length; b++) {
        var x = inter(cs[a][0], cs[b][0]); if (x) take(x, 'int', 1, cs[a][0]);
      }
    }
    if (!best) cand.forEach(function (c) { take(c[1], 'edge', 2, c[0]); });
    return best;
  }

  // Tia song song trục: từ p theo hướng dir (+1/-1) dọc trục axis (1 = v/đứng, 0 = u/ngang),
  // trả về toạ độ cạnh đầu tiên cắt tia (không tính cạnh nằm dọc theo tia), hoặc null.
  function ray(segs, p, axis, dir, maxd) {
    var o = 1 - axis, best = null;
    for (var i = 0; i < segs.length; i++) {
      var s = segs[i], ao = s[o], bo = s[o + 2], aa = s[axis], ba = s[axis + 2];
      if (Math.abs(bo - ao) < 1e-6) continue; // song song tia
      var lo = Math.min(ao, bo), hi = Math.max(ao, bo);
      if (p[o] < lo - 1e-6 || p[o] > hi + 1e-6) continue;
      var t = (p[o] - ao) / (bo - ao), c = aa + t * (ba - aa), d = (c - p[axis]) * dir;
      if (d <= 1e-6 || (maxd != null && d > maxd)) continue;
      if (best == null || d < best.d) best = { d: d, c: c };
    }
    return best;
  }

  // Phương đo: 'v' dọc (so v), 'h' ngang (so u), 'a' thẳng. 'auto' theo độ lệch lớn hơn – không lấy đường chéo.
  // sa/sb: cạnh đã bắt của 2 điểm – hai cạnh cùng nằm ngang (mặt đợt) -> đo dọc; cùng đứng (mép vách) -> đo ngang,
  // kể cả khi 2 điểm lệch nhau xa theo phương kia.
  function orient(s) {
    if (!s) return null;
    var dx = Math.abs(s[2] - s[0]), dy = Math.abs(s[3] - s[1]);
    return dy < dx * 0.02 ? 'hz' : (dx < dy * 0.02 ? 'vt' : null);
  }
  function axisOf(a, b, want, sa, sb) {
    if (want === 'v' || want === 'h' || want === 'a') return want;
    var oa = orient(sa), ob = orient(sb);
    if (oa && oa === ob) return oa === 'hz' ? 'v' : 'h';
    return Math.abs(b[1] - a[1]) >= Math.abs(b[0] - a[0]) ? 'v' : 'h';
  }
  function value(a, b, axis) {
    if (axis === 'h') return Math.abs(a[0] - b[0]);
    if (axis === 'a') return Math.hypot(a[0] - b[0], a[1] - b[1]);
    return Math.abs(a[1] - b[1]);
  }

  // Đo THÔNG THỦY: đưa mỗi điểm về mặt của tấm hướng vào khoảng hở (mặt dưới đợt trên / mặt trên đợt dưới).
  // Bắn tia từ giữa khoảng đo về phía từng điểm (giữ nguyên toạ độ ngang của điểm); cạnh đầu tiên gặp nằm cách
  // điểm đã chọn <= độ dày 1 tấm thì dùng cạnh đó (tránh đo tới tim hay mép còn lại của đợt).
  function refineClear(segs, a, b, axis) {
    if (axis === 'a') return [a, b];
    var k = axis === 'v' ? 1 : 0, mid = (a[k] + b[k]) / 2;
    var fix = function (p, q) {
      var dir = p[k] < mid ? -1 : 1, start = p.slice(); start[k] = mid;
      var h = ray(segs, start, k, dir, Math.abs(mid - p[k]) + 1e-6);
      if (!h || Math.abs(h.c - p[k]) > SHELF_MAX) return p;
      var n = p.slice(); n[k] = Math.round(h.c * 100) / 100; return n;
    };
    if (Math.abs(a[k] - b[k]) < 1e-6) return [a, b];
    return [fix(a, b), fix(b, a)];
  }

  // Đo thông thủy 1 nhấp: bấm vào khoảng trống -> cạnh gần nhất phía trên & dưới (hoặc trái & phải).
  function gapAt(segs, p, axis) {
    var k = axis === 'h' ? 0 : 1;
    var lo = ray(segs, p, k, -1, null), hi = ray(segs, p, k, 1, null);
    if (!lo || !hi) return null;
    var o = 1 - k, a = p.slice(), b = p.slice();
    a[o] = b[o] = Math.round(p[o] * 10) / 10; a[k] = Math.round(lo.c * 100) / 100; b[k] = Math.round(hi.c * 100) / 100;
    return [a, b];
  }

  // Vị trí đường DIM theo con trỏ. fr: khung hình [ox, oy, s, w, h] (giấy). c: điểm giấy của con trỏ.
  // side cfg: 'l' bên trái (mặc định), 'r' bên phải, 'free' tự chọn. Trả về { side, off } (mm giấy, 'in' -> mm thật).
  function placeLine(axis, fr, c, cfgSide, others, span) {
    var ox = fr[0], oy = fr[1], s = fr[2], vw = fr[3] / s, vh = fr[4] / s, side, off;
    var clamp = function (x) { return Math.max(1.5, Math.min(80, Math.round(x * 10) / 10)); };
    if (axis === 'h') {
      if (c[1] < oy) { side = 't'; off = clamp(oy - c[1]); } else if (c[1] > oy + vh) { side = 'b'; off = clamp(c[1] - oy - vh); }
      else { side = 'in'; off = Math.round((c[1] - oy) * s * 10) / 10; }
    } else if (cfgSide === 'r') { side = 'r'; off = clamp(c[0] - ox - vw); }
    else if (cfgSide === 'free') {
      if (c[0] < ox) { side = 'l'; off = clamp(ox - c[0]); } else if (c[0] > ox + vw) { side = 'r'; off = clamp(c[0] - ox - vw); }
      else { side = 'in'; off = Math.round((c[0] - ox) * s * 10) / 10; }
    } else { side = 'l'; off = clamp(ox - c[0]); }
    return avoid({ side: side, off: off }, axis, others || [], span);
  }

  // Không chồng lên DIM khác cùng phía: gần (<1.2 mm) một DIM có đoạn đo KHÔNG giao nhau -> nối thành chuỗi
  // thẳng hàng; có đoạn giao nhau -> đẩy ra hàng kế tiếp (+5 mm). others: [{ side, off, lo, hi }] (+ Auto DIM).
  function avoid(pl, axis, others, span) {
    if (pl.side === 'in') return pl;
    for (var guard = 0; guard < 20; guard++) {
      var hit = null, chain = null;
      for (var i = 0; i < others.length; i++) {
        var o = others[i]; if (o.side !== pl.side) continue;
        if (Math.abs(o.off - pl.off) < 1.2) {
          var overl = !span || o.lo == null || (span[0] < o.hi - 0.5 && o.lo < span[1] - 0.5);
          if (overl) { hit = o; break; } else chain = o;
        }
      }
      if (hit) { pl.off = Math.round((hit.off + 5) * 10) / 10; continue; }
      if (chain) pl.off = chain.off;
      break;
    }
    return pl;
  }

  var api = { Index: Index, snap: snap, ray: ray, axisOf: axisOf, value: value, refineClear: refineClear,
              gapAt: gapAt, placeLine: placeLine, avoid: avoid, SHELF_MAX: SHELF_MAX };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.MDIM = api;
})(typeof window !== 'undefined' ? window : this);
