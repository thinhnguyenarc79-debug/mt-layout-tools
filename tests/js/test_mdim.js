// Kiểm thử hàm thuần của DIM thủ công (ui/mdim.js): bắt điểm, đo thông thủy, đặt vị trí. Chạy: node tests/js/test_mdim.js
'use strict';
const assert = require('assert');
const M = require('../../src/mt_layout_tools/auto_layout/ui/mdim.js');
let n = 0;
const t = (name, fn) => { fn(); n++; console.log('  ok', name); };

// Mặt đứng tủ 1200 x 2000: hông 0..18 & 1182..1200; đợt (v trên, v dưới): nóc 0..18, đợt 768 -> 1214..1232, đợt 400 -> 1582..1600, đáy 1982..2000
const segs = [];
const rect = (x0, y0, x1, y1) => { segs.push([x0, y0, x1, y0], [x1, y0, x1, y1], [x0, y1, x1, y1], [x0, y0, x0, y1]); };
rect(0, 0, 18, 2000); rect(1182, 0, 1200, 2000);
[[0, 18], [1214, 1232], [1582, 1600], [1982, 2000]].forEach(([a, b]) => rect(18, a, 1182, b));
const idx = new M.Index(segs, 1200, 2000);

t('bắt mép dưới đợt trên khi trỏ gần', () => {
  const s = M.snap(idx, [600, 1233.5], 3);
  assert.strictEqual(s.type, 'edge'); assert.deepStrictEqual(s.p, [600, 1232]);
});
t('ưu tiên góc ván (đầu mút) hơn điểm trên cạnh', () => {
  const s = M.snap(idx, [19, 1231], 3);
  assert.strictEqual(s.type, 'end'); assert.deepStrictEqual(s.p, [18, 1232]);
});
t('ngoài bán kính -> không bắt', () => { assert.strictEqual(M.snap(idx, [600, 1400], 3), null); });
t('bán kính theo zoom: cùng điểm, zoom gần (r nhỏ) không bắt, zoom xa bắt', () => {
  assert.strictEqual(M.snap(idx, [600, 1240], 2), null);
  assert.deepStrictEqual(M.snap(idx, [600, 1240], 10).p, [600, 1232]);
});
t('thông thủy đúng 350 khi bấm đúng mặt', () => {
  const [a, b] = M.refineClear(segs, [600, 1232], [600, 1582], 'v');
  assert.strictEqual(M.value(a, b, 'v'), 350);
});
t('thông thủy: bấm nhầm mặt trên đợt trên & mặt dưới đợt dưới -> tự về mặt trong (350)', () => {
  const [a, b] = M.refineClear(segs, [600, 1214], [600, 1600], 'v');
  assert.deepStrictEqual(a, [600, 1232]); assert.deepStrictEqual(b, [600, 1582]);
});
t('thông thủy: bấm giữa chiều dày đợt (tim) -> về mặt trong', () => {
  const [a, b] = M.refineClear(segs, [600, 1223], [600, 1591], 'v');
  assert.strictEqual(M.value(a, b, 'v'), 350);
});
t('đo xuyên qua đợt giữa: không bị kéo về đợt giữa', () => {
  const [a, b] = M.refineClear(segs, [600, 1232], [600, 1982], 'v'); // giữa có đợt 1582..1600
  assert.deepStrictEqual([a, b], [[600, 1232], [600, 1982]]);
});
t('hai điểm lệch ngang: đo dọc lấy hiệu v, không lấy đường chéo', () => {
  assert.strictEqual(M.axisOf([100, 1232], [900, 1582], 'auto', [18, 1232, 1182, 1232], [18, 1582, 1182, 1582]), 'v', 'hai mặt đợt -> đo dọc');
  assert.strictEqual(M.axisOf([18, 100], [1182, 900], 'auto', [18, 0, 18, 2000], [1182, 0, 1182, 2000]), 'h', 'hai mép vách -> đo ngang');
  assert.strictEqual(M.axisOf([100, 1232], [900, 1582], 'v'), 'v');
  assert.strictEqual(M.value([100, 1232], [900, 1582], 'v'), 350);
  assert.strictEqual(M.value([100, 1232], [900, 1582], 'h'), 800);
});
t('đo thông thủy 1 nhấp vào khoảng trống', () => {
  const g = M.gapAt(segs, [600, 1400], 'v');
  assert.deepStrictEqual(g, [[600, 1232], [600, 1582]]);
  const h = M.gapAt(segs, [600, 1400], 'h');
  assert.strictEqual(M.value(h[0], h[1], 'h'), 1164);
});
t('đặt bên trái mặc định, theo khoảng cách chuột', () => {
  const fr = [100, 50, 20, 1200, 2000];
  assert.deepStrictEqual(M.placeLine('v', fr, [90, 100], 'l', []), { side: 'l', off: 10 });
  assert.deepStrictEqual(M.placeLine('v', fr, [300, 100], 'l', []), { side: 'l', off: 1.5 }, 'trỏ bên phải hình vẫn giữ bên trái');
  assert.strictEqual(M.placeLine('v', fr, [175, 100], 'r', []).side, 'r');
  assert.strictEqual(M.placeLine('v', fr, [130, 100], 'free', []).side, 'in');
});
t('không chồng DIM cũ: đoạn giao nhau -> đẩy ra; không giao -> nối chuỗi thẳng hàng', () => {
  const fr = [100, 50, 20, 1200, 2000];
  const old = [{ side: 'l', off: 4.5, lo: 1232, hi: 1582 }];
  assert.strictEqual(M.placeLine('v', fr, [95.2, 0], 'l', old, [1300, 1600]).off, 9.5);
  assert.strictEqual(M.placeLine('v', fr, [95.0, 0], 'l', old, [1582, 1982]).off, 4.5);
});
console.log(n + ' kiểm thử JS DIM thủ công: OK');
