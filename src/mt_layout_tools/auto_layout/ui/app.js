/* AUTO LAYOUT PRO – giao diện biên tập. Ruby dựng bản vẽ (SVG), JS hiển thị, chọn/kéo hình chiếu, quản lý trang. */
(function () {
  'use strict';
  var $ = function (id) { return document.getElementById(id); };
  var PAPERS = { A4: [297, 210], A3: [420, 297], A2: [594, 420], A1: [841, 594], A0: [1189, 841] };
  var FRONTS = { '-Y': 'Trục -Y (mặc định)', '+Y': 'Trục +Y', '-X': 'Trục -X', '+X': 'Trục +X' };

  var S = {
    project: null, models: [], tags: [], viewNames: {}, scales: [],
    cur: null, sel: null, info: null, picked: {},
    undo: [], redo: [], tool: 'select',
    k: 2, panX: 20, panY: 20, fitted: false, timer: null, dirty: false
  };

  // ---------------- cầu nối Ruby ----------------
  function call(name, data) {
    if (!window.sketchup || !sketchup[name]) { msg('Không gọi được SketchUp (' + name + ')', 'err'); return; }
    sketchup[name](typeof data === 'string' ? data : JSON.stringify(data === undefined ? null : data));
  }
  window.ALP = {
    on: function (kind, d) {
      if (kind === 'init') {
        S.project = d.project; S.tags = d.tags; S.viewNames = d.views; S.scales = d.scales;
        setModels(d.models, d.notice); S.status = d.status || {};
        buildStatic(); renderAll();
        if (d.notice) msg(d.notice, 'warn');
        if (S.project.pages.length) openPage(S.project.pages[0].id);
      } else if (kind === 'models') {
        S.tags = d.tags; setModels(d.models, d.notice); if (d.status) S.status = d.status;
        renderModels(); renderTags(); renderPages();
        d.notice ? msg(d.notice, 'warn') : msg('Đã lấy ' + d.models.length + ' đối tượng đang chọn.', 'ok');
      } else if (kind === 'project') {
        snapshot(); S.project = d.project; if (d.status) S.status = d.status; markDirty(); renderAll();
        openPage(d.open || (S.project.pages[0] && S.project.pages[0].id));
        if (d.message) msg(d.message, 'ok');
      } else if (kind === 'page') {
        busy(false);
        if (d.page_id !== S.cur) return;
        showSvg(d.svg, d.info);
      } else if (kind === 'progress') {
        if (d.done) { busy(false); return; }
        busy(true); $('busyText').textContent = d.text || 'Đang xử lý…';
        $('busyPct').textContent = d.pct ? d.pct + '%' : ''; $('busyBar').style.width = (d.pct || 0) + '%';
      } else if (kind === 'doors') {
        var pd = page();
        if (!pd || pd.pid !== d.pid) return;
        snapshot(); pd.doors = d.paths; changed(); requestRender(true);
        msg('Đã nhận ' + d.paths.length + ' cánh: ' + d.names.join(', '), 'ok');
      } else if (kind === 'sheets') {
        S.project.pages.forEach(function (p) { if (d[p.id]) p.sheet_count = d[p.id]; }); renderPages();
      } else if (kind === 'warn') {
        msg(d.message, 'warn');
      } else if (kind === 'saved') {
        msg(d.message, 'ok');
        if (/dự án/.test(d.message)) S.dirty = false;
      } else if (kind === 'error') {
        busy(false); msg(d.message, 'err');
      }
    }
  };

  // ---------------- tiện ích ----------------
  function msg(t, cls) { var m = $('stMsg'); m.textContent = t || ''; m.className = cls || ''; }
  function busy(on) {
    $('busy').style.display = on ? 'block' : 'none';
    if (on && !$('busyText').textContent) $('busyText').textContent = 'Đang dựng bản vẽ…';
    if (!on) { $('busyText').textContent = ''; $('busyPct').textContent = ''; $('busyBar').style.width = '0'; }
  }
  function page() { return S.project && S.project.pages.filter(function (p) { return p.id === S.cur; })[0]; }
  function esc(t) { var d = document.createElement('div'); d.textContent = t == null ? '' : String(t); return d.innerHTML; }
  function opt(sel, items, val) {
    sel.innerHTML = items.map(function (it) { return '<option value="' + esc(it[0]) + '">' + esc(it[1]) + '</option>'; }).join('');
    if (val !== undefined) sel.value = String(val);
  }
  function snapshot() {
    if (!S.project) return;
    S.undo.push(JSON.stringify(S.project)); if (S.undo.length > 100) S.undo.shift(); S.redo = [];
  }
  function markDirty() { S.dirty = true; }
  function changed(render) { markDirty(); if (render !== false) requestRender(); }

  // Danh sách = đúng các đối tượng đang chọn trong SketchUp; tất cả được tick sẵn.
  function setModels(models, notice) {
    S.models = models || []; S.notice = notice || null; S.picked = {};
    S.models.forEach(function (m) { S.picked[m.pid] = true; });
  }

  // ---------------- dựng giao diện tĩnh ----------------
  function buildStatic() {
    opt($('pPaper'), Object.keys(PAPERS).map(function (k) { return [k, k + ' ngang (' + PAPERS[k].join('×') + ')']; }));
    var scales = [[0, 'Tự động (vừa khổ)']].concat(S.scales.map(function (s) { return [s, '1:' + s]; }));
    opt($('dScale'), scales); opt($('pgScale'), scales);
    var fronts = Object.keys(FRONTS).map(function (k) { return [k, FRONTS[k]]; });
    opt($('dFront'), fronts); opt($('pgFront'), fronts);
    var vh = Object.keys(S.viewNames).map(function (k) {
      return '<label><input type="checkbox" value="' + k + '"> ' + esc(cap(S.viewNames[k])) + '</label>';
    }).join('');
    $('dViews').innerHTML = vh; $('pgViews').innerHTML = vh;
  }
  function cap(t) { t = String(t).toLowerCase(); return t.charAt(0).toUpperCase() + t.slice(1); }

  function renderAll() {
    var p = S.project;
    $('pName').value = p.name; $('pPaper').value = p.paper;
    var d = p.defaults;
    setChecks($('dViews'), d.views);
    $('dScale').value = String(d.scale); $('dFront').value = d.front;
    $('dGap').value = d.min_gap; $('dRound').value = d.round; $('dFill').checked = d.fill; $('dDims').checked = d.dims;
    document.querySelectorAll('[data-tb]').forEach(function (i) { i.value = p.tb[i.dataset.tb] || ''; });
    renderModels(); renderTags(); renderPages(); renderPageProps();
  }
  function setChecks(box, list) {
    box.querySelectorAll('input').forEach(function (c) { c.checked = list.indexOf(c.value) >= 0; });
  }
  function getChecks(box) {
    var out = []; box.querySelectorAll('input:checked').forEach(function (c) { out.push(c.value); }); return out;
  }

  function renderModels() {
    var q = $('mSearch').value.trim().toLowerCase();
    var list = S.models.filter(function (m) { return !q || m.name.toLowerCase().indexOf(q) >= 0; });
    $('mCount').textContent = S.models.length;
    $('mList').innerHTML = list.length ? list.map(function (m) {
      return '<div class="it' + (S.picked[m.pid] ? ' sel' : '') + '" data-pid="' + m.pid + '">' +
        '<input type="checkbox"' + (S.picked[m.pid] ? ' checked' : '') + '>' +
        '<span class="nm" title="' + esc(m.kind + ' · Tag: ' + (m.tag || '-')) + '">' + esc(m.name) + '</span>' +
        '<span class="sz" title="Rộng × Cao × Sâu (mm)">' + m.size.join(' × ') + '</span>' +
        '<button class="pick" title="Chọn và phóng tới đối tượng trong SketchUp">👁</button></div>';
    }).join('') : '<div class="empty">' + esc(S.models.length ? 'Không có đối tượng khớp từ khoá.' : (S.notice ||
      'Bạn chưa chọn Group hoặc Component trong SketchUp. Hãy chọn đối tượng cần triển khai trước.')) + '</div>';
  }

  function renderTags() {
    var ex = S.project.exclude_tags;
    $('tCount').textContent = S.tags.length;
    $('tList').innerHTML = S.tags.map(function (t) {
      return '<label class="it"><input type="checkbox" data-tag="' + esc(t.name) + '"' + (ex.indexOf(t.name) < 0 ? ' checked' : '') + '>' +
        '<span class="nm">' + esc(t.name) + (t.visible ? '' : ' <i>(đang ẩn)</i>') + '</span></label>';
    }).join('');
    opt($('doorTag'), [['', '(không có)']].concat(S.tags.map(function (t) { return [t.name, t.name]; })), S.project.door_tag);
  }

  function renderPages() {
    var ps = S.project.pages, rows = sheetRows();
    $('pgCount').textContent = rows.length;
    $('pgList').innerHTML = rows.length ? rows.map(function (r) {
      var p = r.page, cur = p.id === S.cur && r.j === (S.sheet || 0);
      return '<div class="it' + (cur ? ' cur' : '') + '" data-id="' + p.id + '" data-j="' + r.j + '">' +
        '<span class="no">' + esc(r.code) + '</span><span class="nm">' + esc(p.name) + '</span>' +
        '<span class="sz">' + (r.n > 1 ? 'Tờ ' + (r.j + 1) + '/' + r.n : p.views.length + ' hình') + (r.j === 0 ? badge(p) : '') + '</span></div>';
    }).join('') : '<div class="empty">Chưa có trang.</div>';
    var bad = badPages().length;
    $('pgClean').style.display = bad ? 'block' : 'none';
    $('pgClean').textContent = '🧹 Dọn ' + bad + ' trang lỗi (bộ phận con / đã xoá)';
    $('empty').style.display = ps.length ? 'none' : 'flex';
    $('paper').style.display = ps.length ? 'block' : 'none';
    renderNav();
  }

  var STATUS = { nested: '⚠ bộ phận con', deleted: '⚠ đã xoá' };
  var RESULT = { partial: '◐ chưa đầy đủ', empty: '○ chưa có bản vẽ' };
  function badge(p) {
    var st = (S.status || {})[p.id], rs = (S.result || {})[p.id];
    if (STATUS[st]) return ' · <b style="color:#b3261e">' + STATUS[st] + '</b>';
    return RESULT[rs] ? ' · <b style="color:#8a5a12">' + RESULT[rs] + '</b>' : '';
  }
  function badPages() { return S.project.pages.filter(function (p) { return STATUS[(S.status || {})[p.id]]; }); }

  function curCode() {
    var rows = sheetRows(), p = page();
    for (var i = 0; i < rows.length; i++) if (rows[i].page === p && rows[i].j === 0) return rows[i].code;
    return p ? p.sheet_no : '';
  }
  function renderPageProps() {
    renderSections(); renderNotes(); renderDetails();
    var p = page(), box = $('propPage');
    box.querySelectorAll('input,select,button').forEach(function (e) { e.disabled = !p; });
    if (!p) return;
    $('pgName').value = p.name; $('pgNo').value = curCode(); $('pgScale').value = String(p.scale);
    $('pgFront').value = p.front; setChecks($('pgViews'), p.views);
    $('pgFrontDims').value = p.front_dims || 'auto';
    $('pgGap').value = p.min_gap; $('pgRound').value = p.round; $('pgFill').checked = p.fill; $('pgDims').checked = p.dims;
  }

  function renderViewProps() {
    var b = S.info && S.sel && S.info.boxes[S.sel];
    if (!b) { $('propView').innerHTML = '<p class="hint">Bấm vào một hình chiếu trên giấy để chọn; kéo để di chuyển.</p>'; return; }
    var off = (page().offsets || {})[S.sel] || [0, 0];
    $('propView').innerHTML = '<table>' +
      '<tr><td>Hình</td><td>' + esc(cap(S.viewNames[S.sel] || S.sel)) + '</td></tr>' +
      '<tr><td>Vị trí trên giấy</td><td>' + b[0].toFixed(1) + ', ' + b[1].toFixed(1) + ' mm</td></tr>' +
      '<tr><td>Khung chiếm chỗ</td><td>' + b[2].toFixed(1) + ' × ' + b[3].toFixed(1) + ' mm</td></tr>' +
      '<tr><td>Dịch so với tự động</td><td>' + off[0].toFixed(1) + ', ' + off[1].toFixed(1) + ' mm</td></tr>' +
      '</table><div class="btns"><button id="vReset">Về vị trí tự động</button></div>';
    $('vReset').onclick = function () {
      snapshot(); delete page().offsets[S.sel]; changed();
    };
  }

  // ---------------- tờ giấy: mỗi tờ thật = 1 dòng ----------------
  function incCode(code, j) {
    if (!j) return code;
    var m = /^(.*?)(\d+)(\D*)$/.exec(code || '');
    if (!m) return (code || 'A') + '-' + (j + 1);
    var n = String(parseInt(m[2], 10) + j); while (n.length < m[2].length) n = '0' + n;
    return m[1] + n + m[3];
  }
  // cùng thuật toán với ProjectStore.sheet_codes (Ruby)
  function sheetRows() {
    var rows = [], prev = null;
    S.project.pages.forEach(function (p) {
      var n = Math.max(1, Math.min(50, p.sheet_count || 1));
      var base = (p.auto_no !== false && prev) ? incCode(prev, 1) : (p.sheet_no || 'A-01');
      for (var j = 0; j < n; j++) rows.push({ page: p, j: j, n: n, code: incCode(base, j) });
      prev = incCode(base, n - 1);
    });
    return rows;
  }
  function curRowIndex(rows) {
    for (var i = 0; i < rows.length; i++) if (rows[i].page.id === S.cur && rows[i].j === (S.sheet || 0)) return i;
    return -1;
  }
  function gotoRow(k) {
    var rows = sheetRows(); if (!rows.length) return;
    k = Math.max(0, Math.min(rows.length - 1, k));
    var r = rows[k];
    if (r.page.id === S.cur) { S.sheet = r.j; S.selNote = null; renderPages(); requestRender(true); }
    else openPage(r.page.id, r.j);
  }
  function renderNav() {
    var rows = sheetRows(), i = curRowIndex(rows);
    $('shLbl').textContent = i >= 0 ? rows[i].code + ' · ' + (i + 1) + '/' + rows.length : '–';
    $('shPrev').disabled = i <= 0; $('shNext').disabled = i < 0 || i >= rows.length - 1;
  }

  // ---------------- cánh tủ ----------------
  function renderDoors() {
    var p = page(), box = $('doorList'); if (!p) { box.innerHTML = ''; return; }
    var ds = (S.info && S.info.doors) || [];
    box.innerHTML = ds.length ? '<label>Đã xác định ' + ds.length + ' cánh</label>' + ds.map(function (d) {
      return '<div class="door-it"><span>' + esc(d.name || 'Cánh') + '</span><span class="why">' + esc(d.reason) + '</span></div>';
    }).join('') : '<p class="hint" style="color:#8a5a12">Chưa xác định được cánh: mặt đứng chính chỉ ghi kích thước ngoài và không tạo hình tháo cánh. ' +
      'Bấm đúp mở Group tủ trong SketchUp, chọn các cánh, rồi bấm nút dưới.</p>';
  }

  // ---------------- mặt cắt ----------------
  var AXIS = { x: 'Cắt đứng theo chiều rộng (X)', z: 'Cắt ngang theo cao độ (Z)', y: 'Cắt song song mặt trước (Y)' };
  var DIRS = { x: [[1, '→ nhìn sang +X'], [-1, '← nhìn sang -X']], z: [[-1, '↓ nhìn xuống'], [1, '↑ nhìn lên']],
               y: [[1, 'nhìn từ trước ra sau'], [-1, 'nhìn từ sau ra trước']] };
  function renderSections() {
    var p = page(), box = $('secList');
    if (!p) { box.innerHTML = ''; return; }
    var list = p.sections || [];
    box.innerHTML = list.length ? list.map(function (sc, i) {
      return '<div class="sec" data-i="' + i + '"><div class="hd"><span class="lb">' + sc.label + '-' + sc.label + '</span>' +
        (sc.auto ? '<span class="auto">(đề xuất)</span>' : '') + '<button class="del" title="Xoá đường cắt">✕</button></div>' +
        '<select class="ax">' + Object.keys(AXIS).map(function (k) { return '<option value="' + k + '"' + (k === sc.axis ? ' selected' : '') + '>' + AXIS[k] + '</option>'; }).join('') + '</select>' +
        '<div class="row"><div><label>Vị trí (mm)</label><input class="pos" type="number" step="1" value="' + sc.pos + '"></div>' +
        '<div><label>Hướng nhìn</label><select class="dir">' + DIRS[sc.axis].map(function (d) { return '<option value="' + d[0] + '"' + (d[0] === sc.dir ? ' selected' : '') + '>' + d[1] + '</option>'; }).join('') + '</select></div></div></div>';
    }).join('') : '<p class="hint">' + (p.sections == null ? 'Plugin sẽ đề xuất vị trí cắt khi dựng trang.' : 'Chưa có mặt cắt.') + '</p>';
  }
  function extentMid(axis) {
    var e = S.info && S.info.extent && S.info.extent[axis];
    return e ? Math.round((e[0] + e[1]) / 2) : 0;
  }
  $('secList').addEventListener('change', function (e) {
    var row = e.target.closest('.sec'); if (!row) return;
    var p = page(), sc = p.sections[+row.dataset.i];
    snapshot();
    if (e.target.classList.contains('ax')) { sc.axis = e.target.value; sc.dir = DIRS[sc.axis][0][0]; sc.pos = extentMid(sc.axis); }
    if (e.target.classList.contains('pos')) sc.pos = parseFloat(e.target.value) || 0;
    if (e.target.classList.contains('dir')) sc.dir = parseInt(e.target.value, 10);
    sc.auto = false; renderSections(); changed();
  });
  $('secList').addEventListener('click', function (e) {
    if (!e.target.classList.contains('del')) return;
    var p = page(), i = +e.target.closest('.sec').dataset.i, sc = p.sections[i];
    if (!window.confirm('Xoá đường cắt ' + sc.label + '-' + sc.label + ' và bản vẽ MẶT CẮT ' + sc.label + '-' + sc.label + ' liên kết?')) return;
    snapshot(); p.sections.splice(i, 1); if (p.offsets) delete p.offsets['sec:' + sc.label];
    renderSections(); changed();
  });
  $('secAdd').onclick = function () {
    var p = page(); if (!p) return;
    snapshot(); p.sections = p.sections || [];
    var used = p.sections.map(function (x) { return x.label; }), lb = 'A';
    while (used.indexOf(lb) >= 0 && lb < 'Z') lb = String.fromCharCode(lb.charCodeAt(0) + 1);
    if (used.indexOf(lb) >= 0) { msg('Đã đủ 26 mặt cắt.', 'err'); return; }
    p.sections.push({ label: lb, axis: 'x', pos: extentMid('x'), dir: 1, auto: false });
    renderSections(); changed();
  };
  $('secAuto').onclick = function () {
    var p = page(); if (!p) return;
    if (p.sections && p.sections.length && !window.confirm('Thay các mặt cắt hiện có bằng vị trí plugin đề xuất?')) return;
    snapshot(); (p.sections || []).forEach(function (x) { if (p.offsets) delete p.offsets['sec:' + x.label]; });
    p.sections = null; renderSections(); changed();
  };

  // ---------------- chú thích & chi tiết ----------------
  var TYPE_NAME = { text: 'Text', mtext: 'Ghi chú nhiều dòng', leader: 'Leader', material: 'Ghi chú vật liệu' };
  function toPaper(e) {
    var r = $('stage').getBoundingClientRect();
    return [(e.clientX - r.left - S.panX) / S.k, (e.clientY - r.top - S.panY) / S.k];
  }
  function newId(p) { return p + Math.random().toString(36).slice(2, 10); }
  function selNote() { var p = page(); return p && (p.notes || []).filter(function (n) { return n.id === S.selNote; })[0]; }
  function matText(i) { var m = (S.info && S.info.materials) || []; return m[i] ? 'MAT-' + ('0' + (i + 1)).slice(-2) + ': ' + m[i] : ''; }

  function addNote(type, at, tip) {
    var p = page(); if (!p) return;
    snapshot(); p.notes = p.notes || [];
    var mats = (S.info && S.info.materials) || [];
    if (type === 'material' && !mats.length) { msg('Model không có vật liệu nào để ghi chú. Dùng Leader để ghi chú tự do.', 'err'); S.undo.pop(); return; }
    var n = { id: newId('n'), type: type, x: at[0], y: at[1], tx: (tip || at)[0], ty: (tip || at)[1],
              text: type === 'material' ? matText(0) : (type === 'mtext' ? 'Dòng 1\nDòng 2' : 'Ghi chú'),
              size: 2.5, color: '#1E1E1E', arrow: 'arrow', layer: 'GHI CHÚ', sheet: S.sheet || 0 };
    p.notes.push(n); S.selNote = n.id; S.sel = null;
    renderNotes(); changed(); requestRender(true);
    setTimeout(function () { var t = $('nText'); if (t) { t.focus(); t.select(); } }, 50);
  }

  function renderNotes() {
    var p = page(), n = selNote(), box = $('noteBox');
    if (!p || !n) {
      box.innerHTML = '<p class="hint">Chọn công cụ Text / Leader / Vật liệu trên thanh trên rồi bấm lên giấy. Bấm vào chú thích để sửa; kéo để dời; phím Delete để xoá.</p>';
    } else {
      var mats = (S.info && S.info.materials) || [];
      box.innerHTML = '<label>' + TYPE_NAME[n.type] + '</label>' +
        (n.type === 'material' ? '<select id="nMat">' + mats.map(function (m, i) { var t = matText(i); return '<option value="' + i + '"' + (t === n.text ? ' selected' : '') + '>' + esc(t) + '</option>'; }).join('') + '</select>' : '') +
        (n.type === 'text' ? '<input id="nText" type="text" value="' + esc(n.text) + '">' : '<textarea id="nText">' + esc(n.text) + '</textarea>') +
        '<div class="row"><div><label>Cỡ chữ (mm)</label><input id="nSize" type="number" min="1" max="20" step="0.25" value="' + n.size + '"></div>' +
        '<div><label>Màu</label><input id="nColor" type="color" value="' + n.color + '"></div></div>' +
        ((n.type === 'leader' || n.type === 'material') ? '<label>Đầu mũi tên</label><select id="nArrow"><option value="arrow">Mũi tên</option><option value="dot">Chấm tròn</option><option value="none">Không</option></select>' : '') +
        '<label>Layer</label><input id="nLayer" type="text" value="' + esc(n.layer) + '">' +
        '<p class="hint">Font: Noto Sans (nhúng sẵn trong PDF, đủ dấu tiếng Việt).</p>' +
        '<div class="btns"><button id="nDel" class="danger">✕ Xoá chú thích</button></div>';
      if ($('nArrow')) $('nArrow').value = n.arrow;
      var upd = function (render) { return function () {
        snapshot();
        if ($('nMat')) { n.text = matText(+$('nMat').value); $('nText').value = n.text; }
        n.text = $('nText').value; n.size = parseFloat($('nSize').value) || 2.5; n.color = $('nColor').value;
        if ($('nArrow')) n.arrow = $('nArrow').value;
        n.layer = $('nLayer').value.trim() || 'GHI CHÚ';
        changed(render); renderLayers();
      }; };
      ['nText', 'nSize', 'nColor', 'nArrow', 'nLayer'].forEach(function (id) { if ($(id)) $(id).addEventListener('change', upd()); });
      if ($('nMat')) $('nMat').addEventListener('change', function () { $('nText').value = matText(+this.value); upd()(); });
      $('nDel').onclick = deleteNote;
    }
    renderLayers();
  }
  function deleteNote() {
    var p = page(), n = selNote(); if (!n) return;
    snapshot(); p.notes = p.notes.filter(function (x) { return x.id !== n.id; }); S.selNote = null;
    renderNotes(); changed();
  }
  function renderLayers() {
    var p = page(), box = $('layerBox'); if (!p) { box.innerHTML = ''; return; }
    var names = []; (p.notes || []).forEach(function (n) { if (names.indexOf(n.layer) < 0) names.push(n.layer); });
    var hidden = p.hidden_layers || [];
    box.innerHTML = names.length ? '<label>Layer chú thích (bỏ tick để ẩn khi xem & xuất)</label>' + names.map(function (l) {
      return '<label class="it"><input type="checkbox" data-layer="' + esc(l) + '"' + (hidden.indexOf(l) < 0 ? ' checked' : '') + '> ' + esc(l) + '</label>';
    }).join('') : '';
  }
  $('layerBox').addEventListener('change', function (e) {
    var l = e.target.dataset.layer; if (l === undefined) return;
    var p = page(); snapshot(); p.hidden_layers = p.hidden_layers || [];
    var i = p.hidden_layers.indexOf(l);
    if (e.target.checked && i >= 0) p.hidden_layers.splice(i, 1);
    if (!e.target.checked && i < 0) p.hidden_layers.push(l);
    changed();
  });

  function renderDetails() {
    var p = page(), box = $('detBox'); if (!p) { box.innerHTML = ''; return; }
    var list = p.details || [];
    box.innerHTML = (list.length ? list.map(function (d, i) {
      return '<div class="sec" data-i="' + i + '"><div class="hd"><span class="lb">CHI TIẾT ' + d.n + '</span><span class="auto">từ ' +
        esc(cap(S.viewNames[d.src] || d.src.replace('sec:', 'Mặt cắt ').replace(/([A-Z])$/, '$1-$1'))) + '</span><button class="del" title="Xoá chi tiết">✕</button></div>' +
        '<label>Tỉ lệ 1:</label><input class="dsc" type="number" min="1" max="100" step="1" value="' + d.scale + '"></div>';
    }).join('') : '') + '<p class="hint">Chọn công cụ ⊡ Chi tiết rồi kéo khung quanh vị trí cấu tạo trên một hình chiếu hoặc mặt cắt.</p>';
  }
  $('detBox').addEventListener('change', function (e) {
    if (!e.target.classList.contains('dsc')) return;
    var d = page().details[+e.target.closest('.sec').dataset.i];
    snapshot(); d.scale = Math.max(1, Math.min(100, parseInt(e.target.value, 10) || 4)); changed();
  });
  $('detBox').addEventListener('click', function (e) {
    if (!e.target.classList.contains('del')) return;
    var p = page(), i = +e.target.closest('.sec').dataset.i, d = p.details[i];
    if (!window.confirm('Xoá CHI TIẾT ' + d.n + '?')) return;
    snapshot(); p.details.splice(i, 1); if (p.offsets) delete p.offsets['det:' + d.n]; renderDetails(); changed();
  });
  function addDetail(key, a, b) {
    var f = S.info && S.info.frames && S.info.frames[key]; if (!f) return;
    var p = page(); var toV = function (q) { return [(q[0] - f[0]) * f[2], (q[1] - f[1]) * f[2]]; };
    var u = toV(a), v = toV(b);
    var cl = function (x, hi) { return Math.max(0, Math.min(hi, x)); }; // chỉ trong phạm vi hình nguồn
    var rect = [cl(Math.min(u[0], v[0]), f[3]), cl(Math.min(u[1], v[1]), f[4]), cl(Math.max(u[0], v[0]), f[3]), cl(Math.max(u[1], v[1]), f[4])];
    if (rect[2] - rect[0] < 2 || rect[3] - rect[1] < 2) { msg('Khung chi tiết quá nhỏ.', 'err'); return; }
    var big = Math.max(rect[2] - rect[0], rect[3] - rect[1]), scale = 1;
    [1, 2, 4, 5, 10, 15, 20, 25].some(function (s) { scale = s; return big / s <= 70; }); // vừa khoảng 70 mm trên giấy
    snapshot(); p.details = p.details || [];
    var n = p.details.reduce(function (m, d) { return Math.max(m, d.n); }, 0) + 1;
    p.details.push({ n: n, src: key, rect: rect.map(function (x) { return Math.round(x * 10) / 10; }), scale: scale });
    renderDetails(); changed(); requestRender(true);
    msg('Đã tạo CHI TIẾT ' + n + ' (TL 1:' + scale + ').', 'ok');
  }
  var place = null; // trạng thái đặt leader (đã có điểm mũi tên)
  function ghost(cls, css) {
    var el = document.createElement('div'); el.className = cls; Object.assign(el.style, css); $('stage').appendChild(el); return el;
  }

  // ---------------- trang & dựng ----------------
  function openPage(id, j) {
    S.cur = id || null; S.sel = null; S.info = null; S.sheet = j || 0; S.selNote = null;
    renderPages(); renderPageProps(); renderViewProps();
    $('paper').innerHTML = '';
    if (S.cur) requestRender(true);
  }
  function requestRender(now) {
    if (!S.cur) return;
    clearTimeout(S.timer);
    S.timer = setTimeout(function () {
      busy(true); call('render', { project: S.project, page_id: S.cur, sheet: S.sheet || 0 });
    }, now ? 0 : 350);
  }
  function showSvg(svg, info) {
    S.info = info;
    var pp = page();
    if (pp && info.sheets && pp.sheet_count !== info.sheets) {
      pp.sheet_count = info.sheets; markDirty(); // số tờ thật thay đổi (đổi tỉ lệ...) -> danh sách cập nhật ngay
      if ((S.sheet || 0) >= info.sheets) { S.sheet = info.sheets - 1; renderPages(); requestRender(true); return; }
    }
    S.result = S.result || {};
    S.result[S.cur] = info.complete ? 'ok' : (info.levels && Object.keys(info.levels).length ? 'partial' : 'empty');
    renderPages();
    var paper = $('paper');
    paper.innerHTML = svg;
    var p = page();
    if (p && info.offsets) p.offsets = info.offsets; // đồng bộ vị trí đã kẹp trong vùng vẽ
    if (p && info.sections && p.sections == null) p.sections = info.sections; // nhận vị trí cắt plugin đề xuất
    renderSections(); renderDetails(); renderDoors(); if (S.selNote) renderNotes();
    renderNav();
    var svgEl = paper.querySelector('svg');
    svgEl.removeAttribute('width'); svgEl.removeAttribute('height');
    svgEl.querySelectorAll('g.view').forEach(function (g) {
      var b = info.boxes[g.getAttribute('data-key')];
      if (!b) return;
      var r = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      r.setAttribute('class', 'selbox'); r.setAttribute('x', b[0]); r.setAttribute('y', b[1]);
      r.setAttribute('width', b[2]); r.setAttribute('height', b[3]);
      r.style.display = 'none'; g.appendChild(r);
      // vùng bấm: cả khung chiếm chỗ của hình
      var hit = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      hit.setAttribute('x', b[0]); hit.setAttribute('y', b[1]); hit.setAttribute('width', b[2]); hit.setAttribute('height', b[3]);
      hit.setAttribute('fill', 'transparent'); g.insertBefore(hit, g.firstChild);
    });
    if (!S.fitted) { fit(); S.fitted = true; } else applyView();
    highlight();
    var paperName = S.project.paper;
    $('stInfo').textContent = paperName + ' ngang · TL 1:' + info.scale + ' · ' + (info.ms || 0) + ' ms';
    if (info.note) msg(info.note, 'warn');
  }
  function highlight() {
    document.querySelectorAll('#paper g.view').forEach(function (g) {
      var on = g.getAttribute('data-key') === S.sel;
      var r = g.querySelector('rect.selbox'); if (r) r.style.display = on ? 'block' : 'none';
    });
    document.querySelectorAll('#paper g.note').forEach(function (g) { g.classList.toggle('hl', g.getAttribute('data-id') === S.selNote); });
    renderViewProps();
  }

  // ---------------- khung nhìn: zoom/pan ----------------
  function paperSize() { return PAPERS[S.project.paper] || PAPERS.A3; }
  function applyView() {
    var ps = paperSize(), el = $('paper');
    el.style.width = (ps[0] * S.k) + 'px'; el.style.height = (ps[1] * S.k) + 'px';
    el.style.left = S.panX + 'px'; el.style.top = S.panY + 'px';
    var svg = el.querySelector('svg'); if (svg) { svg.style.width = '100%'; svg.style.height = '100%'; }
  }
  function fit() {
    var st = $('stage'), ps = paperSize();
    S.k = Math.max(0.3, Math.min((st.clientWidth - 40) / ps[0], (st.clientHeight - 40) / ps[1]));
    S.panX = (st.clientWidth - ps[0] * S.k) / 2; S.panY = (st.clientHeight - ps[1] * S.k) / 2;
    applyView();
  }
  function zoomAt(f, cx, cy) {
    var nk = Math.max(0.3, Math.min(40, S.k * f));
    S.panX = cx - (cx - S.panX) * nk / S.k; S.panY = cy - (cy - S.panY) * nk / S.k; S.k = nk; applyView();
  }

  // ---------------- chuột trên giấy ----------------
  var drag = null;
  $('stage').addEventListener('wheel', function (e) {
    e.preventDefault();
    var r = this.getBoundingClientRect();
    zoomAt(e.deltaY < 0 ? 1.15 : 1 / 1.15, e.clientX - r.left, e.clientY - r.top);
  }, { passive: false });
  $('stage').addEventListener('mousedown', function (e) {
    if (e.button === 0 && !spaceDown && S.cur && /^(text|mtext|leader|material|detail)$/.test(S.tool)) {
      var pt = toPaper(e);
      if (S.tool === 'text' || S.tool === 'mtext') { addNote(S.tool, pt); setTool('select'); }
      else if (S.tool === 'leader' || S.tool === 'material') {
        if (!place) { place = { tip: pt, el: ghost('tip-dot', { left: e.clientX - $('stage').getBoundingClientRect().left + 'px', top: e.clientY - $('stage').getBoundingClientRect().top + 'px' }) }; msg('Bấm vị trí đặt chữ.', ''); }
        else { place.el.remove(); var tool = S.tool; var tip = place.tip; place = null; addNote(tool, pt, tip); setTool('select'); }
      } else if (S.tool === 'detail') {
        var gv = e.target.closest && e.target.closest('g.view');
        if (!gv) { msg('Kéo khung bắt đầu từ bên trong một hình chiếu hoặc mặt cắt.', 'err'); return; }
        var r = $('stage').getBoundingClientRect();
        drag = { mode: 'detail', key: gv.getAttribute('data-key'), a: pt, x: e.clientX, y: e.clientY,
                 el: ghost('ghost-rect', { left: (e.clientX - r.left) + 'px', top: (e.clientY - r.top) + 'px', width: '0', height: '0' }) };
      }
      e.preventDefault(); return;
    }
    var gn = e.button === 0 && S.tool === 'select' && !spaceDown && e.target.closest && e.target.closest('g.note');
    if (gn) {
      S.selNote = gn.getAttribute('data-id'); S.sel = null; highlight(); renderNotes();
      var n = selNote(), pt2 = toPaper(e);
      var nearTip = n && (n.type === 'leader' || n.type === 'material') && Math.hypot(pt2[0] - n.tx, pt2[1] - n.ty) < 2.5;
      drag = { mode: nearTip ? 'tip' : 'note', g: gn, x: e.clientX, y: e.clientY, dx: 0, dy: 0 };
      e.preventDefault(); return;
    }
    var ds = e.button === 0 && S.tool === 'select' && !spaceDown && e.target.closest && e.target.closest('g.dimset');
    if (ds) {
      drag = { mode: 'dim', g: ds, key: ds.getAttribute('data-key'), side: ds.getAttribute('data-side'), x: e.clientX, y: e.clientY, dx: 0, dy: 0 };
      e.preventDefault(); e.stopPropagation(); return;
    }
    var mk = e.button === 0 && S.tool === 'select' && !spaceDown && e.target.closest && e.target.closest('g.secmark');
    if (mk) {
      drag = { mode: 'sec', g: mk, label: mk.getAttribute('data-sec'), axis: mk.getAttribute('data-axis'), x: e.clientX, y: e.clientY, dx: 0, dy: 0 };
      e.preventDefault(); e.stopPropagation(); return;
    }
    var g = e.target.closest && e.target.closest('g.view');
    if (e.button === 1 || S.tool === 'pan' || spaceDown || !g) {
      if (e.button === 1 || S.tool === 'pan' || spaceDown) {
        drag = { mode: 'pan', x: e.clientX, y: e.clientY, px: S.panX, py: S.panY };
        $('stage').classList.add('panning');
      } else if (S.sel) { S.sel = null; highlight(); }
      e.preventDefault(); return;
    }
    if (e.button !== 0) return;
    S.sel = g.getAttribute('data-key'); S.selNote = null; highlight(); renderNotes();
    drag = { mode: 'move', g: g, x: e.clientX, y: e.clientY, dx: 0, dy: 0 };
    e.preventDefault();
  });
  window.addEventListener('mousemove', function (e) {
    window.__lastX = e.clientX; window.__lastY = e.clientY;
    if (!drag) return;
    if (drag.mode === 'pan') {
      S.panX = drag.px + e.clientX - drag.x; S.panY = drag.py + e.clientY - drag.y; applyView();
    } else if (drag.mode === 'detail') {
      var r = $('stage').getBoundingClientRect();
      Object.assign(drag.el.style, { left: (Math.min(e.clientX, drag.x) - r.left) + 'px', top: (Math.min(e.clientY, drag.y) - r.top) + 'px',
        width: Math.abs(e.clientX - drag.x) + 'px', height: Math.abs(e.clientY - drag.y) + 'px' });
    } else if (drag.mode === 'note' || drag.mode === 'tip') {
      drag.dx = (e.clientX - drag.x) / S.k; drag.dy = (e.clientY - drag.y) / S.k;
      if (drag.mode === 'note') drag.g.setAttribute('transform', 'translate(' + drag.dx + ' ' + drag.dy + ')');
    } else if (drag.mode === 'dim') {
      drag.dx = (e.clientX - drag.x) / S.k; drag.dy = (e.clientY - drag.y) / S.k;
      drag.g.setAttribute('transform', drag.side === 'top' ? 'translate(0 ' + drag.dy + ')' : 'translate(' + drag.dx + ' 0)');
    } else if (drag.mode === 'sec') {
      drag.dx = (e.clientX - drag.x) / S.k; drag.dy = (e.clientY - drag.y) / S.k;
      drag.g.setAttribute('transform', drag.axis === 'x' ? 'translate(' + drag.dx + ' 0)' : 'translate(0 ' + drag.dy + ')');
    } else {
      drag.dx = (e.clientX - drag.x) / S.k; drag.dy = (e.clientY - drag.y) / S.k;
      drag.g.setAttribute('transform', 'translate(' + drag.dx + ' ' + drag.dy + ')');
    }
  });
  window.addEventListener('mouseup', function () {
    if (!drag) return;
    var d = drag; drag = null; $('stage').classList.remove('panning');
    if (d.mode === 'detail') {
      d.el.remove(); setTool('select');
      addDetail(d.key, d.a, [d.a[0] + (window.__lastX - d.x) / S.k, d.a[1] + (window.__lastY - d.y) / S.k]);
      return;
    }
    if (d.mode === 'note' || d.mode === 'tip') {
      if (Math.abs(d.dx) < 0.2 && Math.abs(d.dy) < 0.2) return;
      var n = selNote(); if (!n) return;
      snapshot();
      if (d.mode === 'note') { n.x += d.dx; n.y += d.dy; } else { n.tx += d.dx; n.ty += d.dy; }
      changed(); requestRender(true); return;
    }
    if (d.mode === 'dim') {
      var mv = d.side === 'top' ? d.dy : d.dx;
      if (Math.abs(mv) < 0.2) return;
      var pg = page(); snapshot();
      pg.dimoff = pg.dimoff || {}; pg.dimoff[d.key] = pg.dimoff[d.key] || {};
      var cur = pg.dimoff[d.key][d.side] || 0;
      pg.dimoff[d.key][d.side] = Math.max(-60, Math.min(60, Math.round((cur + mv) * 100) / 100));
      changed(); requestRender(true); return;
    }
    if (d.mode === 'sec') {
      var moved = d.axis === 'x' ? d.dx : d.dy;
      if (Math.abs(moved) < 0.2 || !S.info) return;
      var sc = (page().sections || []).filter(function (x) { return x.label === d.label; })[0]; if (!sc) return;
      snapshot();
      // giấy -> mm thật: X theo chiều ngang; Z (mặt đứng) và Y (mặt bằng) ngược chiều trục giấy
      sc.pos = Math.round((sc.pos + (d.axis === 'x' ? d.dx : -d.dy) * S.info.scale) * 10) / 10;
      sc.auto = false; renderSections(); changed(); requestRender(true);
      return;
    }
    if (d.mode === 'move' && (Math.abs(d.dx) > 0.3 || Math.abs(d.dy) > 0.3)) {
      snapshot();
      var p = page(); p.offsets = p.offsets || {};
      var o = p.offsets[S.sel] || [0, 0];
      p.offsets[S.sel] = [o[0] + d.dx, o[1] + d.dy];
      changed(); requestRender(true);
    }
  });

  // ---------------- phím tắt ----------------
  var spaceDown = false;
  document.addEventListener('keydown', function (e) {
    var typing = /INPUT|SELECT|TEXTAREA/.test(document.activeElement.tagName);
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'z') { if (!typing) { e.preventDefault(); undo(); } return; }
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'y') { if (!typing) { e.preventDefault(); redo(); } return; }
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); save(); return; }
    if (typing) return;
    if (e.key === ' ') { spaceDown = true; $('stage').classList.add('pan'); e.preventDefault(); }
    if (e.key === 'v' || e.key === 'V') setTool('select');
    if (e.key === 'h' || e.key === 'H') setTool('pan');
    if (e.key === 'f' || e.key === 'F') fit();
    if (e.key === 't' || e.key === 'T') setTool('text');
    if (e.key === 'l' || e.key === 'L') setTool('leader');
    if (e.key === 'd' || e.key === 'D') setTool('detail');
    if (e.key === 'Escape') setTool('select');
    if (e.key === 'PageDown') { e.preventDefault(); gotoRow(curRowIndex(sheetRows()) + 1); }
    if (e.key === 'PageUp') { e.preventDefault(); gotoRow(curRowIndex(sheetRows()) - 1); }
    if ((e.key === 'Delete' || e.key === 'Backspace') && S.selNote) { e.preventDefault(); deleteNote(); return; }
    if (S.sel && /^Arrow/.test(e.key)) {
      e.preventDefault(); snapshot();
      var st = e.shiftKey ? 10 : 1, p = page(), o = p.offsets[S.sel] || [0, 0];
      var dx = e.key === 'ArrowLeft' ? -st : e.key === 'ArrowRight' ? st : 0;
      var dy = e.key === 'ArrowUp' ? -st : e.key === 'ArrowDown' ? st : 0;
      p.offsets[S.sel] = [o[0] + dx, o[1] + dy]; changed();
    }
  });
  document.addEventListener('keyup', function (e) {
    if (e.key === ' ') { spaceDown = false; if (S.tool !== 'pan') $('stage').classList.remove('pan'); }
  });
  function setTool(t) {
    if (place) { place.el.remove(); place = null; }
    S.tool = t;
    $('stage').classList.toggle('place', /^(text|mtext|leader|material|detail)$/.test(t));
    document.querySelectorAll('.tool').forEach(function (b) { b.classList.toggle('on', b.dataset.tool === t); });
    $('stage').classList.toggle('pan', t === 'pan');
  }
  function undo() {
    if (!S.undo.length) return;
    S.redo.push(JSON.stringify(S.project)); S.project = JSON.parse(S.undo.pop());
    afterHistory();
  }
  function redo() {
    if (!S.redo.length) return;
    S.undo.push(JSON.stringify(S.project)); S.project = JSON.parse(S.redo.pop());
    afterHistory();
  }
  function afterHistory() {
    if (!page()) S.cur = S.project.pages[0] ? S.project.pages[0].id : null;
    markDirty(); renderAll(); requestRender(true);
  }
  function save() { call('save', S.project); }

  // ---------------- gắn sự kiện ----------------
  document.querySelectorAll('#left section h3').forEach(function (h) {
    h.onclick = function () { h.parentNode.classList.toggle('open'); };
  });
  document.querySelectorAll('.tool').forEach(function (b) { b.onclick = function () { setTool(b.dataset.tool); }; });
  $('zin').onclick = function () { var s = $('stage'); zoomAt(1.25, s.clientWidth / 2, s.clientHeight / 2); };
  $('zout').onclick = function () { var s = $('stage'); zoomAt(1 / 1.25, s.clientWidth / 2, s.clientHeight / 2); };
  $('zfit').onclick = fit;
  $('undo').onclick = undo; $('redo').onclick = redo;
  $('cancel').onclick = function () { call('cancel', null); };
  $('shPrev').onclick = function () { gotoRow(curRowIndex(sheetRows()) - 1); };
  $('shNext').onclick = function () { gotoRow(curRowIndex(sheetRows()) + 1); };
  $('pickDoors').onclick = function () { var p = page(); if (p) call('pick_doors', String(p.pid)); };
  $('clearDoors').onclick = function () {
    var p = page(); if (!p || !(p.doors || []).length) return;
    if (!window.confirm('Bỏ ' + p.doors.length + ' cánh đã chọn tay của trang này?')) return;
    snapshot(); p.doors = []; changed();
  };
  $('refresh').onclick = function () { if (!S.cur) return; busy(true); call('refresh', { project: S.project, page_id: S.cur, sheet: S.sheet || 0 }); };
  $('save').onclick = save;
  $('pdfPage').onclick = function () { if (S.cur) call('export_pdf', { project: S.project, page_ids: [S.cur], sheet: S.sheet || 0 }); };
  $('pdfAll').onclick = function () { call('export_pdf', { project: S.project, page_ids: [] }); };
  $('svgPage').onclick = function () { if (S.cur) call('export_svg', { project: S.project, page_id: S.cur, sheet: S.sheet || 0 }); };
  $('openJson').onclick = function () { call('open_json', null); };
  $('saveJson').onclick = function () { call('save_json', S.project); };
  window.addEventListener('resize', function () { if (S.cur) applyView(); });

  // Dự án
  $('pName').onchange = function () { snapshot(); S.project.name = this.value; changed(false); };
  $('pPaper').onchange = function () { snapshot(); S.project.paper = this.value; S.fitted = false; changed(); };

  // Model
  $('mSearch').oninput = renderModels;
  $('mList').onclick = function (e) {
    var it = e.target.closest('.it'); if (!it) return;
    var pid = parseInt(it.dataset.pid, 10);
    if (e.target.classList.contains('pick')) { call('pick', String(pid)); return; }
    S.picked[pid] = !S.picked[pid]; renderModels();
  };
  // Đọc lại selection: thay thế danh sách model, không tạo trang.
  $('scan').onclick = function () { call('scan', S.project); };
  $('getSel').onclick = function () { call('scan', S.project); };
  $('mAll').onclick = function () { S.models.forEach(function (m) { S.picked[m.pid] = true; }); renderModels(); };
  $('mNone').onclick = function () { S.picked = {}; renderModels(); };
  $('generate').onclick = function () {
    var pids = S.models.filter(function (m) { return S.picked[m.pid]; }).map(function (m) { return m.pid; });
    if (!S.models.length) { msg(S.notice || 'Bạn chưa chọn Group hoặc Component trong SketchUp. Hãy chọn đối tượng cần triển khai trước.', 'err'); return; }
    if (!pids.length) { msg('Tick ít nhất 1 model ở danh sách.', 'err'); return; }
    call('generate', { project: S.project, pids: pids, replace: $('replace').checked });
  };

  // Tag
  $('tList').onchange = function (e) {
    var t = e.target.dataset.tag; if (t === undefined) return;
    snapshot();
    var ex = S.project.exclude_tags, i = ex.indexOf(t);
    if (e.target.checked && i >= 0) ex.splice(i, 1);
    if (!e.target.checked && i < 0) ex.push(t);
    changed();
  };
  $('doorTag').onchange = function () { snapshot(); S.project.door_tag = this.value; changed(); };

  // Mặc định dàn trang
  function readDefaults() {
    snapshot();
    var d = S.project.defaults;
    d.views = getChecks($('dViews')); d.scale = parseInt($('dScale').value, 10); d.front = $('dFront').value;
    d.min_gap = parseFloat($('dGap').value) || 0; d.round = parseFloat($('dRound').value) || 1;
    d.fill = $('dFill').checked; d.dims = $('dDims').checked; changed(false);
  }
  ['dViews', 'dScale', 'dFront', 'dGap', 'dRound', 'dFill', 'dDims'].forEach(function (id) { $(id).addEventListener('change', readDefaults); });

  // Trang giấy
  $('pgList').onclick = function (e) {
    var it = e.target.closest('.it'); if (!it) return;
    var j = parseInt(it.dataset.j || '0', 10);
    if (it.dataset.id === S.cur) { if (j !== S.sheet) { S.sheet = j; S.selNote = null; renderPages(); requestRender(true); } }
    else openPage(it.dataset.id, j);
  };
  $('pgList').ondblclick = function (e) {
    var it = e.target.closest('.it'); if (!it) return;
    var p = S.project.pages.filter(function (x) { return x.id === it.dataset.id; })[0];
    var n = window.prompt('Tên trang:', p.name); if (n === null) return;
    snapshot(); p.name = n.trim() || p.name; changed(); renderPages(); renderPageProps();
  };
  function movePage(dir) {
    var ps = S.project.pages, i = ps.indexOf(page()), j = i + dir;
    if (i < 0 || j < 0 || j >= ps.length) return;
    snapshot(); var t = ps[i]; ps[i] = ps[j]; ps[j] = t; changed(false); renderPages();
  }
  $('pgUp').onclick = function () { movePage(-1); };
  $('pgDown').onclick = function () { movePage(1); };
  $('pgDel').onclick = function () {
    var p = page(); if (!p) return;
    var n = p.sheet_count || 1;
    if (!window.confirm('Xoá ' + (n > 1 ? n + ' tờ' : 'trang') + ' của model "' + p.name + '"? (Hoàn tác được bằng Ctrl+Z)')) return;
    snapshot(); var ps = S.project.pages, i = ps.indexOf(p); ps.splice(i, 1); changed(false);
    openPage(ps[Math.min(i, ps.length - 1)] ? ps[Math.min(i, ps.length - 1)].id : null);
  };

  $('pgClean').onclick = function () {
    var bad = badPages(); if (!bad.length) return;
    var list = bad.map(function (p) { return p.sheet_no + ' – ' + p.name + ' (' + STATUS[S.status[p.id]].replace('⚠ ', '') + ')'; });
    if (!window.confirm('Xoá ' + bad.length + ' trang không còn là model riêng?\n\n' + list.slice(0, 25).join('\n') +
      (list.length > 25 ? '\n…' : '') + '\n\nCác trang khác giữ nguyên. Hoàn tác được bằng Ctrl+Z; nhớ bấm 💾 Lưu.')) return;
    snapshot();
    var ids = bad.map(function (p) { return p.id; });
    S.project.pages = S.project.pages.filter(function (p) { return ids.indexOf(p.id) < 0; });
    changed(false);
    openPage(S.project.pages[0] ? S.project.pages[0].id : null);
    msg('Đã dọn ' + ids.length + ' trang lỗi. Bấm 💾 Lưu để ghi vào file SketchUp.', 'ok');
  };

  // Thuộc tính trang
  function readPage() {
    var p = page(); if (!p) return;
    snapshot();
    p.name = $('pgName').value;
    if ($('pgNo').value !== curCode()) { p.sheet_no = $('pgNo').value; p.auto_no = false; }
    p.scale = parseInt($('pgScale').value, 10);
    p.front = $('pgFront').value; p.views = getChecks($('pgViews'));
    p.front_dims = $('pgFrontDims').value;
    p.min_gap = parseFloat($('pgGap').value) || 0; p.round = parseFloat($('pgRound').value) || 1;
    p.fill = $('pgFill').checked; p.dims = $('pgDims').checked;
    renderPages(); changed();
  }
  ['pgName', 'pgNo', 'pgScale', 'pgFront', 'pgFrontDims', 'pgViews', 'pgGap', 'pgRound', 'pgFill', 'pgDims'].forEach(function (id) {
    $(id).addEventListener('change', readPage);
  });
  $('pgPick').onclick = function () { var p = page(); if (p) call('pick', String(p.pid)); };
  $('pgReset').onclick = function () { var p = page(); if (!p) return; snapshot(); p.offsets = {}; changed(); };

  // Khung tên
  $('tbForm').addEventListener('change', function (e) {
    var k = e.target.dataset.tb; if (!k) return;
    snapshot(); S.project.tb[k] = e.target.value; changed();
  });

  window.addEventListener('beforeunload', function (e) { if (S.dirty) { e.returnValue = 'Dự án chưa lưu.'; } });
  window.onload = function () { call('ready', null); };
})();
