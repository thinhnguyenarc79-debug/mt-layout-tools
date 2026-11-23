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
        S.dirty = !!d.unsaved_session; setSaveState(S.dirty ? 'unsaved' : (S.project.saved_at ? 'saved' : 'none'));
        if (S.project.pages.length) openPage(S.project.pages[0].id);
        if (d.draft) draftDialog(d.draft);
      } else if (kind === 'models') {
        S.tags = d.tags; setModels(d.models, d.notice); if (d.status) S.status = d.status;
        renderModels(); renderTags(); renderPages();
        if (S.pendingAdd) {
          S.pendingAdd = false;
          if (!d.models.length) { msg(d.notice || 'Chưa chọn Group/Component nào trong SketchUp.', 'err'); return; }
          busy(true); call('add_models', { project: S.project, pids: d.models.map(function (m) { return m.pid; }) });
          return;
        }
        d.notice ? msg(d.notice, 'warn') : msg('Đã lấy ' + d.models.length + ' đối tượng đang chọn.', 'ok');
      } else if (kind === 'models_added') {
        onModelsAdded(d);
      } else if (kind === 'project_saved') {
        S.project.saved_at = d.saved_at; S.project.project_id = d.project_id; S.dirty = false;
        clearTimeout(S.autoTimer); setSaveState('saved'); msg(d.message, d.skp_saved ? 'ok' : 'warn');
      } else if (kind === 'autosaved') {
        if (S.dirty) setSaveState('drafted', d.at);
      } else if (kind === 'autosave_error') {
        setSaveState('error'); msg(d.message, 'err');
      } else if (kind === 'project') {
        snapshot(); S.project = d.project; if (d.status) S.status = d.status; markDirty(); renderAll();
        openPage(d.open || (S.project.pages[0] && S.project.pages[0].id));
        if (d.message) msg(d.message, 'ok');
      } else if (kind === 'snap') {
        if (d.page_id !== S.cur) return;
        S.snapData = S.snapData || {}; S.snapData[d.key] = d; if (S.mdIdx) S.mdIdx[d.key] = null;
      } else if (kind === 'page') {
        busy(false);
        if (d.page_id !== S.cur) return;
        showSvg(d.svg, d.info);
      } else if (kind === 'progress') {
        if (d.done) { busy(false); return; }
        busy(true); $('busyText').textContent = d.text || 'Đang xử lý…';
        $('busyPct').textContent = d.pct ? d.pct + '%' : ''; $('busyBar').style.width = (d.pct || 0) + '%';
      } else if (kind === 'assigned') {
        var pa = page(); if (!pa || pa.pid !== d.pid) return;
        snapshot(); pa.roles = pa.roles || {};
        d.paths.forEach(function (x) { pa.roles[x] = d.role; });
        changed(); requestRender(true);
        msg('Đã gán ' + d.paths.length + ' bộ phận là "' + ROLES[d.role] + '": ' + d.names.join(', '), 'ok');
      } else if (kind === 'doors') {
        var pd = page();
        if (!pd || pd.pid !== d.pid) return;
        snapshot(); pd.doors = d.paths; changed(); requestRender(true);
        msg('Đã nhận ' + d.paths.length + ' cánh: ' + d.names.join(', '), 'ok');
      } else if (kind === 'sheets') {
        S.project.pages.forEach(function (p) { if (d[p.id]) p.sheet_count = d[p.id]; }); renderPages();
      } else if (kind === 'warn') {
        msg(d.message, 'warn');
      } else if (kind === 'perf') {
        perfUi(d);
      } else if (kind === 'saved') {
        msg(d.message, 'ok');
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
  // Trạng thái lưu: none | saved | unsaved | drafting | drafted | error. Tự lưu BẢN NHÁP sau 2 s không thao tác
  // (không theo từng pixel kéo chuột: chỉ gọi khi dữ liệu dự án đã đổi).
  function setSaveState(st, at) {
    S.saveState = st; var el = $('saveState'); if (!el) return;
    var t = at ? new Date(at) : null, hm = t ? ('0' + t.getHours()).slice(-2) + ':' + ('0' + t.getMinutes()).slice(-2) : '';
    var map = { none: ['Chưa lưu dự án', 'unsaved'], saved: ['✓ Đã lưu dự án', 'saved'], unsaved: ['● Chưa lưu', 'unsaved'],
                drafting: ['Đang lưu nháp…', 'draft'], drafted: ['Đã lưu bản nháp ' + hm, 'draft'], error: ['⚠ Lỗi lưu', 'err'] };
    var m = map[st] || map.none; el.textContent = m[0]; el.className = 'savest ' + m[1];
  }
  function markDirty() {
    S.dirty = true; if (S.saveState !== 'drafting') setSaveState('unsaved');
    clearTimeout(S.autoTimer);
    S.autoTimer = setTimeout(function () { if (S.project && S.dirty) { setSaveState('drafting'); call('autosave', S.project); } }, 2000);
  }
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
    $('pgIsoMode').value = p.iso_mode || 'material'; $('pgIsoHidden').checked = !!p.iso_hidden;
  }

  // ---------------- tỉ lệ riêng / khóa từng hình chiếu (v2.6) ----------------
  var SCALE_MENU = [5, 10, 15, 20, 25, 40, 50, 75, 100];
  var DOOR_TYPES = { none: 'Không ký hiệu', left: 'Mở trái (bản lề trái)', right: 'Mở phải (bản lề phải)', double: 'Cánh đôi',
    up: 'Lật lên (bản lề trên)', down: 'Lật xuống (bản lề dưới)', slide_left: 'Lùa sang trái', slide_right: 'Lùa sang phải', drawer: 'Ngăn kéo (kéo ra)' };
  function viewName(k) {
    if (S.viewNames[k]) return cap(S.viewNames[k]);
    if (/^sec:/.test(k)) return 'Mặt cắt ' + k.slice(4) + '-' + k.slice(4);
    if (/^det:/.test(k)) { var dd = (page() && (page().details || []).filter(function (x) { return 'det:' + x.n === k; })[0]); return dd && dd.label ? dd.label : 'Chi tiết ' + k.slice(4); }
    if (/^cp:/.test(k)) { var cc = (page() && (page().copies || []).filter(function (x) { return 'cp:' + x.n === k; })[0]); return 'Bản sao ' + (cc ? viewName(cc.src) : k); }
    return k;
  }
  function vprops(k, create) {
    var p = page(); if (!p) return null;
    p.view_props = p.view_props || {};
    if (!p.view_props[k] && create) p.view_props[k] = { scale_override: null, scale_locked: false, position_locked: false };
    return p.view_props[k] || null;
  }
  function tidyProps(k) {
    var p = page(), v = p && p.view_props && p.view_props[k];
    if (v && !v.scale_override) v.scale_locked = false;
    if (v && !v.scale_override && !v.position_locked && v.x_mm == null) delete p.view_props[k];
  }
  // Vị trí thủ công (mm giấy, góc trên-trái khung hình) – lưu trong dữ liệu dự án, không phải pixel màn hình.
  function placeManual(k, x, y) {
    var v = vprops(k, true), p = page();
    v.placement_mode = 'manual'; v.x_mm = Math.round(x * 100) / 100; v.y_mm = Math.round(y * 100) / 100; v.sheet = S.sheet || 0;
    if (p.offsets) delete p.offsets[k]; // bỏ kiểu dịch tương đối cũ
  }
  function placeAuto(k) {
    var v = vprops(k), p = page();
    if (v) { v.placement_mode = 'auto'; v.x_mm = v.y_mm = v.sheet = null; tidyProps(k); } // dựng lại sẽ chốt chỗ tự động mới
    if (p.offsets) delete p.offsets[k];
  }
  function isManual(k) { var v = vprops(k); return !!(v && v.placement_mode === 'manual'); }
  function frameOf(k) { return S.info && S.info.frames && S.info.frames[k]; }
  function effScale(k) {
    var v = vprops(k), f = frameOf(k);
    if (v && v.scale_override) return v.scale_override;
    return f ? f[2] : (page() ? page().scale : 0);
  }
  function scaleLocked(k) { var v = vprops(k); return !!(v && v.scale_locked); }
  function posLocked(k) { var v = vprops(k); return !!(v && v.position_locked); }
  function setViewScale(k, sc) {
    if (scaleLocked(k)) { msg(viewName(k) + ' đang khóa tỉ lệ 1:' + effScale(k) + ' – mở khóa trước khi đổi.', 'err'); return; }
    snapshot();
    if (sc) vprops(k, true).scale_override = sc;
    else if (vprops(k)) { vprops(k).scale_override = null; vprops(k).base_scale = null; tidyProps(k); }
    S.pendingCheck = { kind: 'view', key: k }; // chỉ hình này đổi; dựng xong kiểm tra chồng hình / tràn giấy
    changed(); requestRender(true);
    msg(sc ? viewName(k) + ': tỉ lệ riêng 1:' + sc + ' – vị trí giữ nguyên (chồng hình/tràn giấy sẽ được báo; dùng "Dàn trang lại" nếu cần).' : viewName(k) + ': theo tỉ lệ mặc định của trang.', 'ok');
  }
  function customScale(k) {
    var v = window.prompt('Tỉ lệ riêng cho ' + viewName(k) + ' – nhập N cho 1:N', String(effScale(k) || 20));
    if (v === null) return;
    var n = parseInt(String(v).replace(/^1\s*:\s*/, ''), 10);
    if (!(n >= 1 && n <= 500)) { msg('Tỉ lệ không hợp lệ (1 – 500).', 'err'); return; }
    setViewScale(k, n);
  }
  function lockScale(k, on) {
    snapshot();
    var v = vprops(k, true);
    if (on) { v.scale_override = v.scale_override || effScale(k); v.scale_locked = true; } else v.scale_locked = false;
    tidyProps(k); changed(); requestRender(true);
    msg(on ? viewName(k) + ': đã khóa tỉ lệ 1:' + v.scale_override + '.' : viewName(k) + ': đã mở khóa tỉ lệ (vẫn giữ 1:' + effScale(k) + ' cho tới khi đổi).', 'ok');
  }
  function lockPos(k, on) {
    snapshot();
    var b = S.info && S.info.boxes && S.info.boxes[k], v0 = vprops(k, true);
    if (on && v0.x_mm == null && b) { v0.placement_mode = 'auto'; v0.x_mm = b[0]; v0.y_mm = b[1]; v0.sheet = S.sheet || 0; } // giữ đúng X/Y đang thấy
    vprops(k, true).position_locked = !!on; tidyProps(k); changed(false); renderViewProps(); overlay();
    msg(viewName(k) + (on ? ': đã khóa vị trí.' : ': đã mở khóa vị trí.'), 'ok');
  }
  // DÀN TRANG LẠI – chỉ khi người dùng chủ động chọn. Xoá vị trí đã chốt của các hình CHƯA KHÓA trong phạm vi
  // (kể cả hình đã chỉnh tay nếu người dùng đồng ý); hình đã khóa giữ nguyên. Tỉ lệ, DIM, chú thích không đổi. Có ↶.
  function relayoutPages(pages, sheetOnly, withManual) {
    var n = 0;
    pages.forEach(function (p) {
      var vp = p.view_props || {};
      Object.keys(vp).forEach(function (k) {
        var v = vp[k];
        if (v.position_locked || v.x_mm == null) return;
        if (sheetOnly != null && (v.sheet || 0) !== sheetOnly) return;
        if (v.placement_mode === 'manual' && !withManual) return;
        v.placement_mode = 'auto'; v.x_mm = v.y_mm = v.sheet = null; n++;
        if (!v.scale_override) delete vp[k];
      });
      if (p.offsets && sheetOnly == null) Object.keys(p.offsets).forEach(function (k) { if (!(vp[k] && vp[k].position_locked)) delete p.offsets[k]; });
    });
    return n;
  }
  function manualCount(pages) {
    var n = 0; pages.forEach(function (p) { var vp = p.view_props || {}; Object.keys(vp).forEach(function (k) { if (vp[k].placement_mode === 'manual' && !vp[k].position_locked) n++; }); });
    return n;
  }
  function relayout() { relayoutDialog(); } // tương thích lời gọi cũ
  function relayoutDialog() {
    if (!S.project.pages.length) { msg('Chưa có trang nào.', 'warn'); return; }
    var p = page();
    var body = '<label class="opt"><input type="radio" name="rs" value="sheet" checked> Tờ đang xem' + (p ? ' (' + esc(curCode()) + ')' : '') + '</label>' +
      '<label class="opt"><input type="radio" name="rs" value="page"> Model hiện tại – mọi tờ' + (p ? ' (' + esc(p.name) + ')' : '') + '</label>' +
      '<label class="opt"><input type="radio" name="rs" value="chosen"> Các model được chọn:</label><div class="sub">' +
      S.project.pages.map(function (x) { return '<label class="opt"><input type="checkbox" class="rp" value="' + esc(x.id) + '"> ' + esc(x.sheet_no + ' – ' + x.name) + '</label>'; }).join('') + '</div>' +
      '<label class="opt"><input type="radio" name="rs" value="all"> Toàn bộ dự án (' + S.project.pages.length + ' model)</label>' +
      '<label class="opt"><input type="checkbox" id="rsManual" checked> Dàn lại cả hình đã chỉnh tay (hình đã KHÓA luôn giữ nguyên)</label>' +
      '<p class="hint">Chỉ đổi vị trí hình chiếu. Tỉ lệ, khóa, DIM, Text, Leader, mặt cắt giữ nguyên. Có thể ↶ hoàn tác.</p>';
    dialog('Dàn trang lại', body, [['Hủy', null], ['Dàn trang lại', function () {
      var sc = document.querySelector('input[name=rs]:checked').value, pages = [], sheetOnly = null;
      if (sc === 'sheet' || sc === 'page') { if (!p) return; pages = [p]; if (sc === 'sheet') sheetOnly = S.sheet || 0; }
      if (sc === 'all') pages = S.project.pages.slice();
      if (sc === 'chosen') { var ids = Array.prototype.map.call(document.querySelectorAll('.rp:checked'), function (c) { return c.value; }); pages = S.project.pages.filter(function (x) { return ids.indexOf(x.id) >= 0; }); }
      if (!pages.length) { msg('Chưa chọn model nào.', 'warn'); return false; }
      var withManual = $('rsManual').checked, man = manualCount(pages);
      if (withManual && man && !window.confirm(man + ' hình đã được bạn chỉnh tay trong phạm vi này sẽ về vị trí tự động. Tiếp tục? (có thể ↶ hoàn tác)')) return false;
      snapshot();
      var n = relayoutPages(pages, sheetOnly, withManual);
      changed(); requestRender(true);
      msg('Đã dàn lại ' + n + ' hình trong ' + pages.length + ' model. Hình đã khóa giữ nguyên. ↶ để hoàn tác.', 'ok');
    }, 'gold']]);
  }

  // Hộp thoại chung: buttons [[nhãn, hàm|null, class]] – hàm trả false để giữ hộp thoại mở
  function dialog(title, html, buttons) {
    $('dlgTitle').textContent = title; $('dlgBody').innerHTML = html;
    var bx = $('dlgBtns'); bx.innerHTML = '';
    buttons.forEach(function (b) {
      var el = document.createElement('button'); el.textContent = b[0]; if (b[2]) el.className = b[2];
      el.onclick = function () { if (b[1] && b[1]() === false) return; $('dlg').hidden = true; };
      bx.appendChild(el);
    });
    $('dlg').hidden = false;
  }

  // Khôi phục bản nháp sau khi SketchUp tắt bất thường – không tự ghi đè bản chính.
  function draftDialog(dr) {
    var fmt = function (t) { return t ? new Date(t).toLocaleString('vi-VN') : 'chưa từng lưu'; };
    var info = '<table><tr><td>Bản nháp</td><td>' + fmt(dr.draft_at) + ' · ' + dr.pages + ' trang</td></tr>' +
      '<tr><td>Bản lưu chính</td><td>' + fmt(dr.main_saved_at) + ' · ' + dr.main_pages + ' trang</td></tr>' +
      '<tr><td>File SKP</td><td>' + esc(dr.skp_path || '(chưa lưu)') + '</td></tr></table>';
    var restore = function () {
      snapshot(); S.project = dr.project; S.dirty = true; renderAll();
      openPage(S.project.pages[0] && S.project.pages[0].id); setSaveState('unsaved');
      msg('Đã khôi phục bản nháp. Bấm 💾 Lưu dự án để ghi thành bản chính.', 'warn');
    };
    var useMain = function () { call('discard_draft', { project_id: dr.project.project_id }); };
    dialog('Phát hiện bản nháp chưa được lưu chính thức', '<p>Bạn muốn khôi phục không?</p><div id="drInfo" hidden>' + info + '</div>',
      [['Xem thông tin bản nháp', function () { $('drInfo').hidden = !$('drInfo').hidden; return false; }],
       ['Mở bản lưu chính', useMain], ['Khôi phục bản nháp', restore, 'gold']]);
  }

  // THÊM MODEL: kết quả giao dịch từ Ruby – chỉ GHÉP trang mới vào cuối, không sửa trang cũ.
  function onModelsAdded(d) {
    busy(false);
    var parts = [];
    if (d.pages.length) {
      snapshot(); // ↶ hoàn tác cả lần thêm
      var have = S.project.pages.map(function (x) { return x.pid; });
      d.pages.forEach(function (pg) { if (have.indexOf(pg.pid) < 0) S.project.pages.push(pg); });
      markDirty(); renderAll(); openPage(d.pages[0].id);
      parts.push('Đã thêm ' + d.pages.length + ' model vào cuối dự án (trang cũ giữ nguyên)');
    }
    if (d.failed.length) parts.push('Không thêm được: ' + d.failed.map(function (f) { return f.name + ' (' + f.message + ')'; }).join('; '));
    if (d.missing.length) parts.push(d.missing.length + ' model không còn trong SketchUp');
    if (parts.length) msg(parts.join('. ') + '.', d.failed.length ? 'warn' : 'ok');
    if (d.existing.length) {
      var ex = S.project.pages.filter(function (x) { return d.existing.indexOf(x.pid) >= 0; });
      dialog('Model đã có trong dự án', '<p>' + ex.length + ' model đã có bản vẽ – không tạo trang trùng:</p><div class="sub">' +
        ex.map(function (x) { return esc(x.sheet_no + ' – ' + x.name); }).join('<br>') + '</div>' +
        '<p class="hint">Cập nhật = đọc lại hình học, GIỮ NGUYÊN bố cục, tỉ lệ, DIM, chú thích.</p>',
        [['Bỏ qua', null], ['Cập nhật các model này', function () {
          openPage(ex[0].id); busy(true);
          call('refresh', { project: S.project, page_id: ex[0].id, sheet: 0 });
          msg('Đang cập nhật hình học – bố cục giữ nguyên.', 'ok');
        }, 'gold']]);
    }
  }

  function renderViewProps() {
    var b = S.info && S.sel && S.info.boxes[S.sel];
    if (!b) { $('propView').innerHTML = '<p class="hint">Bấm vào một hình chiếu trên giấy để chọn; kéo để di chuyển. Chuột phải để đổi tỉ lệ riêng / khóa.</p>'; return; }
    var k = S.sel, off = (page().offsets || {})[k] || [0, 0], v = vprops(k) || {}, eff = effScale(k), lk = scaleLocked(k);
    var base = /^det:/.test(k) ? 'Theo tỉ lệ chi tiết' : 'Theo tỉ lệ trang (' + (page().scale ? '1:' + page().scale : 'tự động') + ')';
    var list = SCALE_MENU.slice(); if (v.scale_override && list.indexOf(v.scale_override) < 0) list.push(v.scale_override);
    list.sort(function (a, c) { return a - c; });
    $('propView').innerHTML = '<table>' +
      '<tr><td>Hình</td><td>' + esc(viewName(k)) + '</td></tr>' +
      '<tr><td>Tỉ lệ đang in</td><td><b>1:' + eff + '</b>' + (lk ? ' 🔒' : '') + '</td></tr>' +
      '<tr><td>Vị trí trên giấy</td><td>' + b[0].toFixed(1) + ', ' + b[1].toFixed(1) + ' mm</td></tr>' +
      '<tr><td>Khung chiếm chỗ</td><td>' + b[2].toFixed(1) + ' × ' + b[3].toFixed(1) + ' mm</td></tr>' +
      '<tr><td>Trạng thái vị trí</td><td>' + (v.position_locked ? '🔒 Đã khóa' : v.placement_mode === 'manual' ? 'Đã chỉnh thủ công' : 'Tự động') + (v.x_mm != null ? ' (tờ ' + ((v.sheet || 0) + 1) + ')' : '') + '</td></tr>' +
      '</table><label>Tỉ lệ riêng của hình</label><select id="vScale"' + (lk ? ' disabled title="Đang khóa tỉ lệ"' : '') + '>' +
      '<option value="0">' + esc(base) + '</option>' +
      list.map(function (n) { return '<option value="' + n + '"' + (v.scale_override === n ? ' selected' : '') + '>1:' + n + '</option>'; }).join('') +
      '<option value="custom">Tùy chỉnh…</option></select>' +
      '<div class="checks"><label><input id="vLock" type="checkbox"' + (lk ? ' checked' : '') + '> Khóa tỉ lệ</label>' +
      '<label><input id="vPos" type="checkbox"' + (v.position_locked ? ' checked' : '') + '> Khóa vị trí</label></div>' +
      '<div class="btns"><button id="vReset"' + (v.position_locked ? ' disabled' : '') + '>Về vị trí tự động</button><button id="vRelayout">Dàn trang lại…</button></div>';
    $('vScale').onchange = function () {
      if (this.value === 'custom') { customScale(k); renderViewProps(); return; }
      setViewScale(k, parseInt(this.value, 10) || null);
    };
    $('vLock').onchange = function () { lockScale(k, this.checked); };
    $('vPos').onchange = function () { lockPos(k, this.checked); };
    $('vReset').onclick = function () { snapshot(); placeAuto(k); changed(); };
    $('vRelayout').onclick = function () { relayoutDialog(); };
  }

  // Biểu tượng khóa / tỉ lệ riêng: chỉ hiện trong trình biên tập (vẽ thêm phía JS, không có trong PDF/SVG xuất).
  function overlay() {
    var svg = $('paper').querySelector('svg'); if (!svg || !S.info || !S.info.frames) return;
    svg.querySelectorAll('g.edonly').forEach(function (g) { g.remove(); });
    var NS = 'http://www.w3.org/2000/svg';
    var g = document.createElementNS(NS, 'g'); g.setAttribute('class', 'edonly');
    Object.keys(S.info.frames).forEach(function (k) {
      var v = vprops(k); if (!v || (!v.scale_override && !v.position_locked)) return;
      var f = S.info.frames[k], cx = f[0] + f[3] / f[2] / 2, y = f[1] + f[4] / f[2] + 11.1;
      var lock = function (x, color) {
        var r = document.createElementNS(NS, 'rect');
        r.setAttribute('x', x); r.setAttribute('y', y - 1.9); r.setAttribute('width', 2.0); r.setAttribute('height', 1.5);
        r.setAttribute('rx', 0.2); r.setAttribute('fill', color); g.appendChild(r);
        var a = document.createElementNS(NS, 'path');
        a.setAttribute('d', 'M' + (x + 0.45) + ' ' + (y - 1.9) + 'v-0.5a0.55 0.55 0 0 1 1.1 0v0.5');
        a.setAttribute('fill', 'none'); a.setAttribute('stroke', color); a.setAttribute('stroke-width', 0.3); g.appendChild(a);
      };
      if (v.scale_locked) lock(cx + 6, '#C9A45C');
      else if (v.scale_override) {
        var t = document.createElementNS(NS, 'text');
        t.setAttribute('x', cx + 6); t.setAttribute('y', y - 0.4); t.setAttribute('font-size', 1.8); t.setAttribute('fill', '#C9A45C');
        t.textContent = 'riêng'; g.appendChild(t);
      }
      if (v.position_locked) lock(cx - 8, '#8A8F8B');
    });
    svg.appendChild(g);
    // điểm điều khiển vùng trích của chi tiết đang chọn (chỉ khi biên tập)
    svg.querySelectorAll('g.edhandles').forEach(function (x) { x.remove(); });
    var dsel = S.selDet && (page().details || []).filter(function (x) { return x.n === S.selDet; })[0];
    var fs = dsel && S.info.frames[dsel.src];
    if (fs) {
      var hg = document.createElementNS(NS, 'g'); hg.setAttribute('class', 'edhandles');
      var R = dsel.rect, P = [[R[0], R[1]], [R[2], R[1]], [R[2], R[3]], [R[0], R[3]]];
      P.forEach(function (q, i) {
        var hr = document.createElementNS(NS, 'rect');
        hr.setAttribute('x', fs[0] + q[0] / fs[2] - 1.2); hr.setAttribute('y', fs[1] + q[1] / fs[2] - 1.2);
        hr.setAttribute('width', 2.4); hr.setAttribute('height', 2.4); hr.setAttribute('class', 'dh'); hr.setAttribute('data-c', i);
        hr.setAttribute('fill', '#FFFFFF'); hr.setAttribute('stroke', '#C9A45C'); hr.setAttribute('stroke-width', 0.4);
        hg.appendChild(hr);
      });
      svg.appendChild(hg);
    }
  }

  // ---------------- ký hiệu cánh (v2.6) ----------------
  function symStyle() {
    return { w: parseFloat($('symW').value) || 0.18, color: $('symColor').value || '#6B6F6C', dash: $('symDash').value || 'dash' };
  }
  function doorList() {
    var seen = {}, out = [];
    var di = (S.info && S.info.door_items) || {};
    Object.keys(di).forEach(function (k) { di[k].forEach(function (it) { if (!seen[it.path]) { seen[it.path] = 1; out.push({ path: it.path, name: it.name }); } }); });
    ((S.info && S.info.doors) || []).forEach(function (d) { if (d.path && !seen[d.path]) { seen[d.path] = 1; out.push({ path: d.path, name: d.name }); } });
    return out;
  }
  function setDoorSym(path, patch) {
    var p = page(); if (!p) return;
    snapshot(); p.door_symbols = p.door_symbols || {};
    var d = p.door_symbols[path] || { type: 'none', style: symStyle(), visible: true };
    Object.keys(patch).forEach(function (x) { d[x] = patch[x]; });
    p.door_symbols[path] = d; changed(); renderSyms();
  }
  // cấu hình ký hiệu mở nhìn từ trên – dữ liệu chung page.swing (mọi hình nhìn từ trên dùng chung)
  function renderSwing() {
    var p = page(); if (!p) return;
    var w = p.swing || {};
    $('swPlan').checked = w.plan !== false; $('swSec').checked = w.section !== false;
    var a = w.angle || 90, sel = $('swAngle');
    if (!Array.prototype.some.call(sel.options, function (o) { return +o.value === a; })) {
      var op = document.createElement('option'); op.value = a; op.textContent = a + '°'; sel.insertBefore(op, sel.lastChild);
    }
    sel.value = String(a); $('swOpen').value = w.open || 'out'; $('swLeaf').value = w.leaf || 'solid'; $('swArc').value = w.arc || 'dash';
  }
  ['swPlan', 'swSec', 'swAngle', 'swOpen', 'swLeaf', 'swArc'].forEach(function (id) {
    $(id).addEventListener('change', function () {
      var p = page(); if (!p) return;
      var ang = $('swAngle').value;
      if (ang === 'custom') {
        var v = window.prompt('Góc mở ký hiệu (5 – 180°):', String((p.swing || {}).angle || 90));
        ang = v === null ? String((p.swing || {}).angle || 90) : v;
      }
      ang = Math.max(5, Math.min(180, parseFloat(ang) || 90));
      snapshot();
      p.swing = { plan: $('swPlan').checked, section: $('swSec').checked, angle: ang, open: $('swOpen').value, leaf: $('swLeaf').value, arc: $('swArc').value };
      renderSwing(); changed();
    });
  });
  function renderSyms() {
    var p = page(), box = $('symList'); if (!box) return;
    renderSwing();
    var list = p ? doorList() : [];
    var ds = (p && p.door_symbols) || {};
    box.innerHTML = list.length ? list.map(function (d) {
      var cur = ds[d.path] || {}, t = cur.type || 'none';
      return '<div class="it" data-path="' + esc(d.path) + '"><span class="nm" title="' + esc(d.path) + '">' + esc(d.name) + '</span>' +
        '<select class="sym">' + Object.keys(DOOR_TYPES).map(function (x) { return '<option value="' + x + '"' + (x === t ? ' selected' : '') + '>' + DOOR_TYPES[x] + '</option>'; }).join('') + '</select>' +
        '<select class="opn" title="Hướng mở (mặt bằng / mặt cắt nhìn từ trên)"><option value="">mặc định</option><option value="out"' + (cur.open === 'out' ? ' selected' : '') + '>ra ngoài</option><option value="in"' + (cur.open === 'in' ? ' selected' : '') + '>vào trong</option></select>' +
        '<input class="vis" type="checkbox" title="Hiện ký hiệu"' + (cur.visible === false ? '' : ' checked') + '></div>';
    }).join('') : '<p class="hint">Chưa có cánh trên trang này (gán vai trò "Cánh" ở mục CẤU TẠO TỦ).</p>';
  }
  $('symList').addEventListener('change', function (e) {
    var it = e.target.closest('.it'); if (!it) return;
    if (e.target.classList.contains('sym')) setDoorSym(it.dataset.path, { type: e.target.value });
    if (e.target.classList.contains('vis')) setDoorSym(it.dataset.path, { visible: e.target.checked });
    if (e.target.classList.contains('opn')) setDoorSym(it.dataset.path, { open: e.target.value || null });
  });
  $('symApply').onclick = function () {
    var p = page(); if (!p) return;
    var st = symStyle(); snapshot(); p.door_symbols = p.door_symbols || {};
    Object.keys(p.door_symbols).forEach(function (k) { p.door_symbols[k].style = JSON.parse(JSON.stringify(st)); });
    changed(); msg('Đã áp kiểu nét cho ' + Object.keys(p.door_symbols).length + ' cánh.', 'ok');
  };
  function doorAt(k, pt) {
    var f = frameOf(k), items = (S.info && S.info.door_items && S.info.door_items[k]) || [], best = null;
    if (!f) return null;
    items.forEach(function (it) {
      var b = it.box, x0 = f[0] + b[0] / f[2], x1 = f[0] + b[1] / f[2], y0 = f[1] + b[2] / f[2], y1 = f[1] + b[3] / f[2];
      if (pt[0] >= x0 && pt[0] <= x1 && pt[1] >= y0 && pt[1] <= y1) {
        var a = (x1 - x0) * (y1 - y0); if (!best || a < best.a) best = { a: a, path: it.path, name: it.name };
      }
    });
    return best;
  }

  // ---------------- menu chuột phải trên hình chiếu ----------------
  function hideCtx() { var m = $('ctxMenu'); if (!m.hidden) S.ctxClosed = Date.now(); m.hidden = true; m.innerHTML = ''; }
  function showCtx(x, y, k, door) {
    var m = $('ctxMenu'), lk = scaleLocked(k), v = vprops(k) || {}, eff = effScale(k), h = [];
    var it = function (act, label, opts) {
      opts = opts || {};
      h.push('<div class="it' + (opts.off ? ' off' : '') + (opts.on ? ' on' : '') + '" data-act="' + act + '"' + (opts.title ? ' title="' + esc(opts.title) + '"' : '') + '>' + esc(label) + '</div>');
    };
    h.push('<div class="hd">' + esc(viewName(k)) + '<small>TL 1:' + eff + (lk ? ' · đã khóa' : v.scale_override ? ' · riêng' : '') + '</small></div>');
    var cands = S.ctxParts || [];
    if (cands.length) {
      var cp0 = cands[S.ctxPartIdx || 0], eff = ((page().roles || {})[cp0.path]) || cp0.role || 'unknown';
      h.push('<div class="lb">Bộ phận: <b>' + esc(partLabelShort(cp0)) + '</b>' + ((S.ctxPartIdx || 0) === 0 ? ' (phía trước)' : '') + ' – ' + esc(ROLES[eff] || eff) + '</div><div class="grid">' +
        [['door', 'Cánh'], ['side', 'Vách'], ['shelf', 'Đợt'], ['back', 'Hậu'], ['drawer', 'Ngăn kéo'], ['top', 'Nóc'], ['bottom', 'Đáy'], ['handle', 'Tay nắm'], ['accessory', 'Khác'], ['glass', 'Kính']]
          .map(function (r) { return '<span data-act="role:' + r[0] + '" class="' + (eff === r[0] ? 'on' : '') + '">' + r[1] + '</span>'; }).join('') + '</div>');
      it('pview', 'Xem bộ phận trong SketchUp'); it('punset', 'Bỏ phân loại (về tự nhận)', { off: !((page().roles || {})[cp0.path]) });
      if (cands.length > 1) {
        h.push('<div class="lb">Bộ phận khác tại điểm bấm (trước → sau)</div>');
        cands.forEach(function (c, i) { if (i !== (S.ctxPartIdx || 0)) it('pick:' + i, partLabelShort(c) + ' – ' + (ROLES[((page().roles || {})[c.path]) || c.role] || '?')); });
      }
      h.push('<div class="sep"></div>');
    }
    if (door) {
      var cur = ((page().door_symbols || {})[door.path] || {}).type || 'none';
      h.push('<div class="lb">Ký hiệu cánh – ' + esc(door.name) + '</div>');
      Object.keys(DOOR_TYPES).forEach(function (t) { it('door:' + t, DOOR_TYPES[t], { on: t === cur }); });
      h.push('<div class="sep"></div>');
    }
    if (k !== 'iso' && S.info && S.info.snap && S.info.snap[k]) {
      var mc = mdCfg();
      h.push('<div class="lb">DIM THỦ CÔNG</div>');
      it('mdadd', 'Thêm DIM 2 điểm (M)'); it('mdgap', 'Đo thông thủy – 1 nhấp vào khoảng trống');
      it('mdsnap', 'Smart Snap: ' + (mc.snap ? 'BẬT (bấm để tắt)' : 'TẮT (bấm để bật)'), { on: mc.snap });
      h.push('<div class="grid">' + [['l', 'Trái'], ['r', 'Phải'], ['free', 'Tự chọn']].map(function (x) {
        return '<span data-act="mdside:' + x[0] + '" class="' + (mc.side === x[0] ? 'on' : '') + '">' + x[1] + '</span>'; }).join('') + '</div>');
      h.push('<div class="sep"></div>');
    }
    h.push('<div class="lb">Đổi tỷ lệ riêng' + (lk ? ' (đang khóa)' : '') + '</div><div class="grid' + (lk ? ' off' : '') + '">' +
      SCALE_MENU.map(function (n) { return '<span data-act="scale:' + n + '" class="' + (v.scale_override === n ? 'on' : '') + '">1:' + n + '</span>'; }).join('') + '</div>');
    it('custom', 'Tùy chỉnh tỷ lệ…', { off: lk });
    it('page', /^det:/.test(k) ? 'Theo tỷ lệ chi tiết' : 'Trở về tỷ lệ mặc định của trang', { off: lk || !v.scale_override, title: lk ? 'Mở khóa trước' : '' });
    h.push('<div class="sep"></div>');
    it(lk ? 'unlock' : 'lock', lk ? 'Mở khóa tỷ lệ' : 'Khóa tỷ lệ (1:' + eff + ')');
    it(v.position_locked ? 'unpos' : 'pos', v.position_locked ? 'Mở khóa vị trí' : 'Khóa vị trí');
    h.push('<div class="sep"></div>');
    var isDet = /^det:/.test(k), dn = isDet ? +k.slice(4) : 0;
    if (isDet) {
      var det = (page().details || []).filter(function (x) { return x.n === dn; })[0] || {}, mkr = det.marker || {};
      h.push('<div class="lb">Chi tiết – tỷ lệ</div><div class="grid">' + [1, 2, 4, 5, 10, 15, 20].map(function (n) {
        return '<span data-act="dsc:' + n + '" class="' + (det.scale === n ? 'on' : '') + '">1:' + n + '</span>'; }).join('') + '</div>');
      h.push('<div class="lb">Kiểu marker</div>');
      [['rect', 'Chữ nhật nét đứt'], ['circle', 'Tròn nét đứt'], ['ellipse', 'Elip nét đứt']].forEach(function (x) { it('dmk:' + x[0], x[1], { on: (mkr.shape || 'rect') === x[0] }); });
      it('darrow', 'Có mũi tên', { on: !!mkr.arrow }); it('dbubble', 'Có bóng số tham chiếu', { on: mkr.bubble !== false });
      var fillOn = det.fill == null ? !!page().fill : det.fill;
      it('dfill1', 'Tô màu vật liệu', { on: fillOn }); it('dfill0', 'Nét kỹ thuật đơn sắc', { on: !fillOn });
      h.push('<div class="sep"></div>');
      it('dtype', det.type === 'section' ? 'Chuyển thành phóng to vùng 2D' : 'Chuyển thành chi tiết cấu tạo (mặt cắt thật)');
      if (det.type === 'section') {
        var ct = det.cut || {};
        it('dorient', 'Đổi hướng cắt → ' + (ct.orient === 'h' ? 'đứng' : 'ngang'));
        it('dflip', 'Đảo hướng nhìn'); it('dpickcut', 'Đặt lại vị trí đường cắt…');
        h.push('<div class="lb">Độ sâu thể hiện sau mặt cắt</div><div class="grid">' + [[0, 'Toàn bộ'], [20, '20'], [50, '50'], [100, '100'], [200, '200']].map(function (x) {
          return '<span data-act="ddep:' + x[0] + '" class="' + ((det.depth || 0) === x[0] ? 'on' : '') + '">' + x[1] + '</span>'; }).join('') + '</div>');
        it('dlabels', 'Chú thích vật liệu tự động', { on: det.labels !== false });
      }
      it('drename', 'Đổi tên chi tiết…'); it('dreselect', 'Chỉnh / chọn lại vùng trích chi tiết');
    }
    h.push('<div class="lb">' + (isDet ? 'Chuyển chi tiết sang trang' : 'Chuyển sang trang khác') + '</div>' + sheetGrid('mv:', S.sheet || 0));
    h.push('<div class="lb">' + (isDet ? 'Tạo bản sao chi tiết sang trang' : 'Tạo bản sao sang trang khác') + '</div>' + sheetGrid('cp:', null));
    it('copyhere', 'Tạo bản sao tại trang này');
    it('clip', 'Sao chép (để dán ở trang khác)');
    if (!isDet) {
      it('refreshv', 'Cập nhật hình chiếu');
      h.push('<div class="lb">Trích chi tiết</div>');
      it('mkdet', 'Phóng to vùng 2D…'); if (!/^iso/.test(k)) it('mkcdet', 'Trích chi tiết cấu tạo (mặt cắt thật)…');
    }
    it('delv', isDet ? 'Xóa chi tiết' : 'Xóa hình chiếu');
    h.push('<div class="sep"></div>');
    it('relayout', 'Dàn trang lại…');
    m.innerHTML = h.join(''); m.hidden = false;
    var w = m.offsetWidth, hh = m.offsetHeight;
    m.style.left = Math.max(4, Math.min(x, window.innerWidth - w - 4)) + 'px';
    m.style.top = Math.max(4, Math.min(y, window.innerHeight - hh - 4)) + 'px';
    m.onclick = function (e) {
      var a = e.target.closest('[data-act]'); if (!a || a.classList.contains('off') || a.parentNode.classList.contains('off')) return;
      var act = a.dataset.act;
      if (act.indexOf('pick:') === 0) { S.ctxPartIdx = +act.slice(5); showCtx(x, y, k, door); return; } // đổi bộ phận đang gán, giữ menu
      hideCtx();
      var cpx = (S.ctxParts || [])[S.ctxPartIdx || 0];
      if (act.indexOf('role:') === 0 && cpx) { setRoles([cpx.path], act.slice(5), 'Đã gán ' + partLabelShort(cpx) + ' là "' + ROLES[act.slice(5)] + '"'); return; }
      if (act === 'pview' && cpx) { call('highlight_part', { pid: page().pid, path: cpx.path }); return; }
      if (act === 'punset' && cpx) { setRoles([cpx.path], '', 'Đã bỏ phân loại tay của ' + partLabelShort(cpx)); return; }
      if (act === 'mdadd') { mdStart(false); return; }
      if (act === 'mdgap') { mdStart(true); return; }
      if (act === 'mdsnap') { mdCfg().snap = !mdCfg().snap; markDirty(); renderMd(); msg('Smart Snap ' + (mdCfg().snap ? 'BẬT' : 'TẮT') + '.', ''); return; }
      if (act.indexOf('mdside:') === 0) { mdCfg().side = act.slice(7); markDirty(); renderMd(); msg('Vị trí DIM thủ công mặc định: ' + { l: 'bên trái', r: 'bên phải', free: 'tự chọn theo chuột' }[act.slice(7)] + '.', ''); return; }
      if (act.indexOf('door:') === 0) setDoorSym(door.path, { type: act.slice(5) });
      else if (act.indexOf('scale:') === 0) setViewScale(k, parseInt(act.slice(6), 10));
      else if (act === 'custom') customScale(k);
      else if (act === 'page') setViewScale(k, null);
      else if (act === 'lock') lockScale(k, true);
      else if (act === 'unlock') lockScale(k, false);
      else if (act === 'pos') lockPos(k, true);
      else if (act === 'unpos') lockPos(k, false);
      else if (act === 'relayout') relayoutDialog();
      else if (act.indexOf('mv:') === 0) moveView(k, +act.slice(3));
      else if (act.indexOf('cp:') === 0) copyView(k, +act.slice(3), null);
      else if (act === 'copyhere') copyView(k, S.sheet || 0, null);
      else if (act === 'clip') { S.clip = k; msg('Đã sao chép ' + viewName(k) + ' – chuột phải vào chỗ trống ở tờ cần dán → "Dán hình chiếu đã copy".', 'ok'); }
      else if (act === 'refreshv') $('refresh').click();
      else if (act === 'mkdet') { S.detMode = 'enlarge'; setTool('detail'); msg('Kéo khung quanh vị trí cần phóng to trên ' + viewName(k) + '.', ''); }
      else if (act === 'mkcdet') { S.detMode = 'section'; setTool('detail'); msg('Kéo khung quanh vị trí cấu tạo cần làm rõ trên ' + viewName(k) + ' – plugin cắt thật qua hình học 3D tại giữa vùng.', ''); }
      else if (act === 'dtype') editDetail(dn, function (d) {
        d.type = d.type === 'section' ? 'enlarge' : 'section';
        if (d.type === 'section' && !d.cut) d.cut = { orient: $('detOrient').value, at: null };
      });
      else if (act === 'dorient') editDetail(dn, function (d) { d.cut = { orient: (d.cut || {}).orient === 'h' ? 'v' : 'h', at: null, dir: null }; });
      else if (act === 'dflip') editDetail(dn, function (d) { var c = d.cut || {}; var cur = c.dir == null ? (c.orient === 'h' ? -1 : 1) : c.dir; d.cut = Object.assign({}, c, { dir: -cur }); });
      else if (act.indexOf('ddep:') === 0) editDetail(dn, function (d) { var v = +act.slice(5); d.depth = v || null; });
      else if (act === 'dlabels') editDetail(dn, function (d) { d.labels = d.labels === false; });
      else if (act === 'dpickcut') { S.pickCut = dn; msg('Bấm vào vị trí đặt đường cắt bên trong vùng gọi chi tiết trên hình nguồn.', ''); }
      else if (act === 'delv') deleteView(k);
      else if (act.indexOf('dsc:') === 0) editDetail(dn, function (d) { d.scale = +act.slice(4); });
      else if (act.indexOf('dmk:') === 0) editDetail(dn, function (d) { d.marker = Object.assign({}, d.marker || {}, { shape: act.slice(4) }); });
      else if (act === 'dfill1' || act === 'dfill0') editDetail(dn, function (d) { d.fill = act === 'dfill1'; });
      else if (act === 'darrow') editDetail(dn, function (d) { d.marker = Object.assign({}, d.marker || {}); d.marker.arrow = !d.marker.arrow; });
      else if (act === 'dbubble') editDetail(dn, function (d) { d.marker = Object.assign({}, d.marker || {}); d.marker.bubble = d.marker.bubble === false; });
      else if (act === 'drename') {
        var cd = (page().details || []).filter(function (x) { return x.n === dn; })[0];
        var nm = window.prompt('Tên chi tiết (marker nguồn đổi theo):', cd && cd.label ? cd.label : 'CHI TIẾT ' + dn);
        if (nm !== null) editDetail(dn, function (d) { d.label = nm.trim() || null; });
      } else if (act === 'dreselect') { S.reDetail = dn; setTool('detail'); msg('Kéo khung vùng trích mới cho ' + viewName(k) + ' trên hình nguồn.', ''); }
    };
  }

  // ---------------- trang / bản sao / chi tiết (v2.10) ----------------
  function sheetCount() { var p = page(); return Math.max(1, (S.info && S.info.sheets) || (p && p.sheet_count) || 1); }
  function sheetCode(j) {
    var rows = sheetRows(), p = page();
    for (var i = 0; i < rows.length; i++) if (rows[i].page === p && rows[i].j === j) return rows[i].code;
    return 'tờ mới';
  }
  function sheetGrid(prefix, skip) {
    var n = sheetCount(), h = '<div class="grid">';
    for (var j = 0; j <= n; j++) {
      if (j === skip) continue;
      h += '<span data-act="' + prefix + j + '">' + (j === n ? '+ Tờ mới' : esc(sheetCode(j))) + '</span>';
    }
    return h + '</div>';
  }
  function sheetOf(k) {
    var v = vprops(k); if (v && v.sheet != null) return v.sheet;
    var L = S.info && S.info.layout && S.info.layout[k]; return L ? L[2] : null;
  }
  // CHUYỂN: bản gốc rời tờ cũ, sang tờ đích (đặt vào chỗ trống, hoặc đúng điểm bấm nếu có). Không tạo trùng.
  function moveView(k, j, at) {
    if (posLocked(k)) { msg(viewName(k) + ' đang khóa vị trí – mở khóa trước khi chuyển trang.', 'err'); return; }
    var from = sheetOf(k);
    snapshot();
    var v = vprops(k, true);
    if (at) { v.placement_mode = 'manual'; v.x_mm = at[0]; v.y_mm = at[1]; } else { v.placement_mode = 'auto'; v.x_mm = v.y_mm = null; }
    v.sheet = j;
    if (page().offsets) delete page().offsets[k];
    if (/^det:/.test(k)) editDetail(+k.slice(4), function (d) { d.sheet = j; }, true);
    S.pendingPlace = at ? null : k;
    if (at) S.pendingCheck = { kind: 'view', key: k };
    changed();
    if (j !== (S.sheet || 0)) { S.sheet = j; renderPages(); }
    requestRender(true);
    msg('Đã CHUYỂN ' + viewName(k) + (from != null ? ' từ ' + sheetCode(from) : '') + ' sang ' + sheetCode(j) + ' – tờ cũ KHÔNG còn hình này. ↶ để hoàn tác.', 'ok');
  }
  // BẢN SAO: bản gốc giữ nguyên ở tờ cũ; thêm bản sao độc lập ở tờ đích.
  function copyView(k, j, at) {
    var p = page(); snapshot();
    var nk;
    if (/^det:/.test(k)) {
      var d0 = (p.details || []).filter(function (x) { return 'det:' + x.n === k; })[0]; if (!d0) return;
      var n = p.details.reduce(function (m, d) { return Math.max(m, d.n); }, 0) + 1;
      var d1 = JSON.parse(JSON.stringify(d0)); d1.n = n; d1.sheet = j; d1.label = d0.label ? d0.label + ' (bản sao)' : null;
      p.details.push(d1); nk = 'det:' + n; renderDetails();
    } else {
      var src = /^cp:/.test(k) ? ((p.copies || []).filter(function (x) { return 'cp:' + x.n === k; })[0] || {}).src : k;
      p.copies = p.copies || [];
      var m2 = p.copies.reduce(function (m, c) { return Math.max(m, c.n); }, 0) + 1;
      p.copies.push({ n: m2, src: src }); nk = 'cp:' + m2;
    }
    if (p.manual_dims && p.manual_dims[k] && p.manual_dims[k].length) { // bản sao mang theo DIM thủ công của hình gốc
      p.manual_dims[nk] = p.manual_dims[k].map(function (d) { var c = JSON.parse(JSON.stringify(d)); c.id = newId('md'); return c; });
    }
    var v = vprops(nk, true);
    if (at) { v.placement_mode = 'manual'; v.x_mm = at[0]; v.y_mm = at[1]; } else { v.placement_mode = 'auto'; v.x_mm = v.y_mm = null; }
    v.sheet = j;
    var sc0 = vprops(k); if (sc0 && sc0.scale_override) v.scale_override = sc0.scale_override; else if (sc0 && sc0.base_scale) v.base_scale = sc0.base_scale;
    S.pendingPlace = at ? null : nk;
    if (at) S.pendingCheck = { kind: 'view', key: nk };
    changed();
    if (j !== (S.sheet || 0)) { S.sheet = j; renderPages(); }
    requestRender(true);
    msg('Đã TẠO BẢN SAO ' + viewName(k) + ' ở ' + sheetCode(j) + ' – bản gốc VẪN Ở ' + sheetCode(sheetOf(k) || 0) + '. ↶ để hoàn tác.', 'ok');
    return nk;
  }
  function editDetail(n, fn, quiet) {
    var p = page(), d = (p.details || []).filter(function (x) { return x.n === n; })[0]; if (!d) return;
    if (!quiet) snapshot();
    fn(d); renderDetails();
    if (!quiet) { changed(); requestRender(true); }
  }
  function deleteView(k) {
    var p = page(); if (!p) return;
    if (!window.confirm('Xóa ' + viewName(k) + ' khỏi trang? (↶ để hoàn tác)')) return;
    snapshot();
    if (/^det:/.test(k)) p.details = (p.details || []).filter(function (x) { return 'det:' + x.n !== k; });
    else if (/^cp:/.test(k)) p.copies = (p.copies || []).filter(function (x) { return 'cp:' + x.n !== k; });
    else if (/^sec:/.test(k)) p.sections = (p.sections || []).filter(function (x) { return 'sec:' + x.label !== k; });
    else p.views = (p.views || []).filter(function (x) { return x !== k; });
    // bản sao / chi tiết lấy từ hình vừa xóa cũng bỏ (không để bản mồ côi)
    p.copies = (p.copies || []).filter(function (x) { return x.src !== k; });
    p.details = (p.details || []).filter(function (x) { return x.src !== k; });
    if (p.view_props) delete p.view_props[k];
    if (p.offsets) delete p.offsets[k];
    S.sel = null; renderPageProps(); renderDetails(); renderSections && renderSections(); changed(); requestRender(true);
    msg('Đã xóa ' + viewName(k) + '.', 'ok');
  }
  function noRoomDialog(k) {
    dialog('Trang hiện tại không đủ chỗ', '<p>' + esc(viewName(k)) + ' không vừa chỗ trống của tờ ' + esc(sheetCode(S.sheet || 0)) + '. Bạn muốn:</p>',
      [['Hủy (↶)', function () { $('undo').click(); }],
       ['Chọn tỷ lệ khác', function () { customScale(k); }],
       ['Chọn vị trí khác', function () { var b = S.info.boxes[k] || [0, 0, 80, 60]; startPlacing(b[2], b[3], viewName(k), function (at) { snapshot(); placeManual(k, at[0], at[1]); S.pendingCheck = { kind: 'view', key: k }; changed(); requestRender(true); }); }],
       ['Chuyển sang trang khác', function () { moveView(k, sheetCount()); }],
       ['Tự bố trí lại trang này', function () { snapshot(); relayoutPages([page()], S.sheet || 0, false); changed(); requestRender(true); }, 'gold']]);
  }

  // Xem trước vị trí đặt: khung theo chuột, bấm để xác nhận, Esc để hủy
  function startPlacing(w, h, label, done) {
    stopPlacing();
    var el = ghost('ghost-rect', { width: w * S.k + 'px', height: h * S.k + 'px', pointerEvents: 'none' });
    el.textContent = label; el.style.fontSize = '11px'; el.style.color = '#2F4A3A'; el.style.padding = '2px';
    S.placing = { el: el, done: done };
    msg('Di chuột tới chỗ đặt ' + label + ' và bấm để xác nhận (Esc để hủy).', '');
  }
  function stopPlacing() { if (S.placing) { S.placing.el.remove(); S.placing = null; } }
  window.addEventListener('mousemove', function (e) {
    if (!S.placing) return;
    var r = $('stage').getBoundingClientRect();
    S.placing.el.style.left = (e.clientX - r.left) + 'px'; S.placing.el.style.top = (e.clientY - r.top) + 'px';
  });
  $('stage').addEventListener('mousedown', function (e) {
    if (!S.placing || e.button !== 0) return;
    var pl = S.placing, at = toPaper(e); stopPlacing();
    pl.done([Math.round(at[0] * 100) / 100, Math.round(at[1] * 100) / 100]);
    e.stopImmediatePropagation(); e.preventDefault();
  }, true);
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && S.placing) { stopPlacing(); msg('Đã hủy thêm hình.', ''); } });

  // ---------------- xung đột sau khi đổi tỉ lệ / thêm hình ----------------
  function conflictCheck(chk, info) {
    var cs = (info.conflicts || []).filter(function (c) { return chk.kind === 'page' || c.a === chk.key || c.b === chk.key; });
    if (!cs.length) return;
    var txt = cs.map(function (c) { return c.type === 'overflow' ? viewName(c.a) + ' tràn ra ngoài vùng vẽ' : viewName(c.a) + ' chồng lên ' + viewName(c.b); });
    var k = chk.key;
    var btns = [['Hủy thay đổi', function () { $('undo').click(); }],
                ['Giữ nguyên, hiện cảnh báo', function () { msg('Giữ nguyên bố cục – còn ' + cs.length + ' xung đột (xem dòng trạng thái).', 'warn'); }]];
    if (k) btns.push(['Chuyển hình này sang trang mới', function () { moveView(k, sheetCount()); }]);
    else btns.push(['Chuyển hình xung đột sang trang mới', function () {
      var ks = []; cs.forEach(function (c) { var x = c.b && !posLocked(c.a) ? c.a : c.a; if (ks.indexOf(x) < 0 && !posLocked(x)) ks.push(x); });
      snapshot(); var j = sheetCount();
      ks.forEach(function (x) { var v = vprops(x, true); v.placement_mode = 'auto'; v.x_mm = v.y_mm = null; v.sheet = j; });
      changed(); requestRender(true); msg('Đã chuyển ' + ks.length + ' hình sang tờ mới.', 'ok');
    }]);
    btns.push(['Dàn lại các hình chưa khóa', function () {
      snapshot(); var n = relayoutPages([page()], S.sheet || 0, false); changed(); requestRender(true);
      msg('Đã dàn lại ' + n + ' hình tự động trên tờ này (hình chỉnh tay / khóa giữ nguyên).', 'ok');
    }, 'gold']);
    dialog('Bố cục bị xung đột', '<p>Sau thay đổi vừa rồi:</p><div class="sub">' + txt.map(esc).join('<br>') + '</div>' +
      '<p class="hint">Plugin không tự giảm tỉ lệ, không tự đẩy hình khác, không tự chuyển trang.</p>', btns);
  }

  // ---------------- gán bộ phận ngay trên bản vẽ 2D ----------------
  function partsAt(k, pt) {
    var f = frameOf(k), rects = (S.info && S.info.part_hits && S.info.part_hits[k]) || [];
    if (!f || !rects.length) return [];
    var u = (pt[0] - f[0]) * f[2], v = (pt[1] - f[1]) * f[2];
    var byPath = {}; ((S.info && S.info.parts) || []).forEach(function (x) { byPath[x.path] = x; });
    return rects.filter(function (r) { return u >= r[1] && u <= r[2] && v >= r[3] && v <= r[4]; })
      .sort(function (a, b) { return b[5] - a[5]; }) // gần người xem trước
      .slice(0, 8).map(function (r) { var x = byPath[r[0]] || {}; return { path: r[0], name: x.name || r[0], role: x.role, size: x.size }; });
  }
  function partLabelShort(c) { var z = (c.size || []).join('×'); return (c.name && !/^(group|component)\s*#?\d*$/i.test(c.name) ? c.name : 'Bộ phận') + (z ? ' ' + z : ''); }

  // ---------------- menu chuột phải trên VÙNG GIẤY TRỐNG ----------------
  function showPaperCtx(x, y, pt) {
    var m = $('ctxMenu'), h = [];
    var it = function (act, label, off) { h.push('<div class="it' + (off ? ' off' : '') + '" data-act="' + act + '">' + esc(label) + '</div>'); };
    h.push('<div class="hd">Tờ ' + esc(sheetCode(S.sheet || 0)) + '<small>' + pt[0].toFixed(0) + ', ' + pt[1].toFixed(0) + ' mm</small></div>');
    it('add', 'Thêm hình chiếu vào trang này…');
    it('paste', S.clip ? 'Dán hình chiếu đã copy (' + viewName(S.clip) + ')' : 'Dán hình chiếu đã copy', !S.clip);
    it('newdet', 'Tạo chi tiết mới');
    it('relay', 'Tự động bố trí lại trang này');
    it('fill', 'Tự động đề xuất lấp khoảng trống…');
    m.innerHTML = h.join(''); m.hidden = false;
    m.style.left = Math.max(4, Math.min(x, window.innerWidth - m.offsetWidth - 4)) + 'px';
    m.style.top = Math.max(4, Math.min(y, window.innerHeight - m.offsetHeight - 4)) + 'px';
    m.onclick = function (e) {
      var a = e.target.closest('[data-act]'); if (!a || a.classList.contains('off')) return;
      hideCtx();
      var act = a.dataset.act;
      if (act === 'add') addViewDialog(pt);
      else if (act === 'paste') copyView(S.clip, S.sheet || 0, pt);
      else if (act === 'newdet') { setTool('detail'); msg('Kéo khung quanh vị trí cần phóng to trên một hình chiếu của tờ này.', ''); }
      else if (act === 'relay') {
        var p = page(), man = Object.keys(p.view_props || {}).filter(function (k) { var v = p.view_props[k]; return (v.sheet || 0) === (S.sheet || 0) && v.placement_mode === 'manual' && !v.position_locked; }).length;
        var withMan = man ? window.confirm(man + ' hình trên tờ này đã chỉnh tay. Dàn lại cả các hình đó? (OK = có, Cancel = chỉ hình tự động; hình khóa luôn giữ)') : false;
        snapshot(); var n = relayoutPages([p], S.sheet || 0, withMan); changed(); requestRender(true);
        msg('Đã bố trí lại ' + n + ' hình trên tờ này. ↶ để hoàn tác.', 'ok');
      } else if (act === 'fill') fillDialog();
    };
  }
  // Danh sách hình có thể thêm: hình của trang (mọi tờ), mặt cắt, chi tiết, bản sao + hình chưa bật
  var ADD_KEYS = [['front', 'Mặt đứng'], ['open', 'Mặt đứng tháo cánh'], ['top', 'Mặt bằng'], ['left', 'Mặt bên trái'], ['right', 'Mặt bên phải'],
                  ['back', 'Mặt sau'], ['iso', 'Trục đo']];
  function addViewDialog(pt) {
    var p = page(), here = S.sheet || 0, rows = [];
    ADD_KEYS.forEach(function (x) { rows.push([x[0], x[1], (p.views || []).indexOf(x[0]) >= 0]); });
    (p.sections || []).forEach(function (sc) { rows.push(['sec:' + sc.label, 'Mặt cắt ' + sc.label + '-' + sc.label, true]); });
    (p.details || []).forEach(function (d) { rows.push(['det:' + d.n, viewName('det:' + d.n), true]); });
    var def = 0;
    for (var q = 0; q < rows.length; q++) { if (rows[q][2] && sheetOf(rows[q][0]) !== here) { def = q; break; } }
    var body = '<p class="hint">Hình sẽ đặt tại điểm bạn bấm (' + pt[0].toFixed(0) + ', ' + pt[1].toFixed(0) + ' mm) trên tờ ' + esc(sheetCode(here)) + '.</p><div class="sub">' +
      rows.map(function (r, i) {
        var sh = r[2] ? sheetOf(r[0]) : null;
        var st = !r[2] ? 'chưa có trên trang – sẽ thêm mới' : (sh === here ? 'đang ở tờ này' : 'đang ở tờ ' + sheetCode(sh == null ? 0 : sh));
        return '<label class="opt"><input type="radio" name="av" value="' + i + '"' + (i === def ? ' checked' : '') + '> <b>' + esc(r[1]) + '</b> <span class="hint">– ' + st + '</span></label>';
      }).join('') + '</div>' +
      '<label class="opt"><input type="radio" name="am" value="move" checked> <b>CHUYỂN từ trang khác sang</b> – bản gốc rời khỏi tờ cũ, không tạo trùng</label>' +
      '<label class="opt"><input type="radio" name="am" value="copy"> <b>TẠO THÊM BẢN SAO</b> – bản gốc vẫn giữ ở tờ cũ, thêm 1 bản ở tờ này</label>' +
      '<label>Tỷ lệ cho hình này</label><select id="avScale"><option value="keep">Giữ tỷ lệ hiện có</option><option value="page">Theo tỷ lệ trang' +
      (p.scale ? ' (1:' + p.scale + ')' : '') + '</option>' + SCALE_MENU.map(function (n) { return '<option value="' + n + '">1:' + n + '</option>'; }).join('') + '</select>' +
      '<p class="hint">Bấm Thêm → khung xem trước đi theo chuột, bấm vào giấy để xác nhận vị trí (Esc để hủy). Các hình cũ không đổi tỷ lệ, không đổi vị trí.</p>';
    dialog('Thêm hình chiếu vào trang này', body, [['Hủy', null], ['Thêm', function () {
      var r = rows[+document.querySelector('input[name=av]:checked').value], mode = document.querySelector('input[name=am]:checked').value;
      var scv = $('avScale').value;
      if (r[2] && mode === 'move' && sheetOf(r[0]) === here) { msg(r[1] + ' đã ở tờ này – chọn "Tạo thêm bản sao" nếu muốn có 2 hình.', 'warn'); return false; }
      var L = S.info && S.info.layout && S.info.layout[r[0]];
      var cur = L && L[5] ? L[5] : (p.scale || 20), ns = scv === 'keep' ? cur : scv === 'page' ? (p.scale || cur) : +scv;
      var w = L ? L[3] * cur / ns : 80, h = L ? L[4] * cur / ns : 60;
      startPlacing(w, h, r[1] + (L ? '' : ' (kích thước thật hiện sau khi dựng)'), function (at) {
        var key = r[0];
        if (!r[2]) { // hình chưa bật: thêm mới vào trang, đặt tại điểm chọn
          snapshot(); p.views = (p.views || []).concat([r[0]]);
          var v = vprops(r[0], true); v.placement_mode = 'manual'; v.x_mm = at[0]; v.y_mm = at[1]; v.sheet = here;
          S.pendingCheck = { kind: 'view', key: key }; renderPageProps();
          msg('Đã thêm ' + r[1] + ' vào tờ ' + sheetCode(here) + ' (hình mới, không có bản gốc ở tờ khác).', 'ok');
        } else if (mode === 'move') moveView(r[0], here, at);
        else key = copyView(r[0], here, at);
        var vv = vprops(key, true);
        if (scv === 'page') { vv.scale_override = null; vv.base_scale = null; }
        else if (scv !== 'keep') { vv.scale_override = +scv; vv.scale_locked = false; }
        changed(); requestRender(true);
      });
    }, 'gold']]);
  }
  // Lấp khoảng trống: hình ở tờ khác vừa chỗ trống của tờ này -> đề xuất chuyển sang
  function freeSpotJS(occ, bw, bh, area) {
    var pad = 3;
    for (var y = area[1]; y + bh <= area[3] + 0.01; y += 2) {
      var x = area[0];
      while (x + bw <= area[2] + 0.01) {
        var hit = null;
        for (var i = 0; i < occ.length; i++) { var b = occ[i]; if (x < b[0] + b[2] + pad && b[0] < x + bw + pad && y < b[1] + b[3] + pad && b[1] < y + bh + pad) { hit = b; break; } }
        if (!hit) return [x, y];
        x = hit[0] + hit[2] + pad;
      }
    }
    return null;
  }
  function fillDialog() {
    var info = S.info, here = S.sheet || 0;
    if (!info || !info.layout || !info.area) { msg('Chưa có dữ liệu bố cục – thử lại sau khi dựng xong.', 'warn'); return; }
    var occ = Object.keys(info.boxes).map(function (k) { return info.boxes[k]; });
    if (info.legend_h) occ.push([info.area[2] - 64, info.area[3] - info.legend_h, 64, info.legend_h]);
    var cands = Object.keys(info.layout).filter(function (k) {
      var L = info.layout[k]; if (L[2] === here || posLocked(k) || !L[3]) return false;
      var spot = freeSpotJS(occ, L[3], L[4], info.area); if (!spot) return false;
      occ.push([spot[0], spot[1], L[3], L[4]]); return true;
    });
    if (!cands.length) { msg('Không có hình nào ở tờ khác vừa chỗ trống của tờ này.', 'warn'); return; }
    dialog('Đề xuất lấp khoảng trống tờ ' + sheetCode(here), '<p>Các hình ở tờ khác vừa chỗ trống của tờ này:</p><div class="sub">' +
      cands.map(function (k) { return '<label class="opt"><input type="checkbox" class="fc" value="' + esc(k) + '" checked> ' + esc(viewName(k)) + ' <span class="hint">– đang ở ' + esc(sheetCode(info.layout[k][2])) + '</span></label>'; }).join('') +
      '</div><p class="hint">Các hình được CHUYỂN (không tạo bản sao). ↶ để hoàn tác.</p>',
      [['Hủy', null], ['Chuyển sang tờ này', function () {
        var ks = Array.prototype.map.call(document.querySelectorAll('.fc:checked'), function (c) { return c.value; });
        if (!ks.length) return;
        snapshot();
        ks.forEach(function (k) { var v = vprops(k, true); v.placement_mode = 'auto'; v.x_mm = v.y_mm = null; v.sheet = here; });
        changed(); requestRender(true); msg('Đã chuyển ' + ks.length + ' hình sang tờ ' + sheetCode(here) + '.', 'ok');
      }, 'gold']]);
  }
  $('stage').addEventListener('contextmenu', function (e) {
    e.preventDefault();
    if (!S.info) { hideCtx(); return; }
    if (e.target.classList && e.target.classList.contains('grip') && dimSel()) { showDimCtx(e.clientX, e.clientY, dimSel()); return; }
    var gmd = e.target.closest && e.target.closest('g.dim, g.mdim');
    if (gmd) {
      var sl2 = selOf(gmd), already = (S.selDims || []).some(function (x) { return x.key === sl2.key && x.id === sl2.id; });
      if (!already) selectDim(sl2, false);
      showDimCtx(e.clientX, e.clientY, sl2); return;
    }
    var gcp = e.target.closest && e.target.closest('g.vcap');
    if (gcp) { S.selCap = gcp.getAttribute('data-key'); textCtx(e.clientX, e.clientY, 'cap', S.selCap); return; }
    var gnt = e.target.closest && e.target.closest('g.note');
    if (gnt) { var nn = (page().notes || []).filter(function (x) { return x.id === gnt.getAttribute('data-id'); })[0]; if (nn) { S.selNote = nn.id; highlight(); textCtx(e.clientX, e.clientY, 'note', nn); return; } }
    var mk = e.target.closest && e.target.closest('g.detmark');
    if (mk) { S.ctxParts = []; S.selDet = +mk.getAttribute('data-det'); overlay(); showCtx(e.clientX, e.clientY, 'det:' + mk.getAttribute('data-det'), null); return; }
    var g = e.target.closest && e.target.closest('g.view');
    if (!g) {
      if (e.target.closest && e.target.closest('#paper svg')) showPaperCtx(e.clientX, e.clientY, toPaper(e));
      else hideCtx();
      return;
    }
    var k = g.getAttribute('data-key');
    S.sel = k; S.selNote = null; highlight();
    var ptc = toPaper(e);
    S.ctxParts = /^(sec|det):/.test(k) ? [] : partsAt(k, ptc); S.ctxPartIdx = 0;
    showCtx(e.clientX, e.clientY, k, doorAt(k, ptc));
  });
  $('stage').addEventListener('dblclick', function (e) {
    if (!S.info) return;
    if (e.target.classList && e.target.classList.contains('grip') && dimSel()) { dimDialog(dimSel()); return; } // grip nằm đè lên số DIM
    var gd = e.target.closest && e.target.closest('g.dim, g.mdim');
    if (gd && (S.tool === 'select' || S.tool === 'edit')) { var sl3 = selOf(gd); selectDim(sl3, false); dimDialog(sl3); return; }
    var gc = e.target.closest && e.target.closest('g.vcap');
    if (gc && (S.tool === 'edit' || S.tool === 'select')) { editCaption(gc.getAttribute('data-key')); return; }
    var gnn = e.target.closest && e.target.closest('g.note');
    if (gnn) { var nn2 = (page().notes || []).filter(function (x) { return x.id === gnn.getAttribute('data-id'); })[0]; if (nn2) { editNoteInline(nn2); return; } }
    var g = e.target.closest && e.target.closest('g.view');
    if (!g || !S.info || S.tool !== 'select') return;
    var k = g.getAttribute('data-key'), d = doorAt(k, toPaper(e));
    if (d) showCtx(e.clientX, e.clientY, k, d);
  });
  document.addEventListener('mousedown', function (e) { if (!e.target.closest('#ctxMenu')) hideCtx(); }, true);
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') hideCtx(); });

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

  // ---------------- cấu tạo tủ ----------------
  var ROLES = { door: 'Cánh', side: 'Vách đứng', shelf: 'Đợt', top: 'Nóc', bottom: 'Đáy', back: 'Hậu', drawer: 'Ngăn kéo',
                handle: 'Tay nắm', glass: 'Kính/gương', accessory: 'Phụ kiện', unknown: 'Chưa xác định' };
  function roleOpts(sel, withAuto) {
    return (withAuto ? '<option value="">(tự nhận)</option>' : '') + Object.keys(ROLES).map(function (k) {
      return '<option value="' + k + '"' + (k === sel ? ' selected' : '') + '>' + ROLES[k] + '</option>';
    }).join('');
  }
  function renderDoors() { renderParts(); } // tương thích
  // ---------------- quản lý cấu tạo theo model (v2.7) ----------------
  // Dữ liệu: S.info.parts của model đang mở (không quét lại SketchUp khi lọc/mở nhóm). Danh sách ảo: chỉ dựng các dòng đang thấy.
  var ROW_H = 26, GRP_MAX = 11;
  S.partOpen = { unknown: true }; S.partSel = {}; S.partSelPage = null;
  function effRole(pt, roles) { return roles[pt.path] || pt.role || 'unknown'; }
  function generic(name) { return !name || /^(group|nhóm|component|bộ phận|chi tiết)\s*#?\s*\d*$/i.test(String(name).trim()); }
  function partLabel(pt) {
    var sz = (pt.size || []).join('×');
    return generic(pt.name) ? (sz ? sz + ' mm' : 'Bộ phận') : pt.name + (sz ? '  ·  ' + sz : '');
  }
  function partsView() {
    var p = page(), parts = (S.info && S.info.parts) || [], roles = (p && p.roles) || {};
    var q = $('partSearch').value.trim().toLowerCase(), f = $('partFilter').value, cl = $('partCluster').value;
    return parts.filter(function (pt) {
      if (cl && pt.cluster !== cl) return false;
      var r = effRole(pt, roles), manual = !!roles[pt.path];
      if (f === 'sug' && (manual || pt.sure)) return false;
      if (f === 'manual' && !manual) return false;
      if (f && f !== 'sug' && f !== 'manual' && r !== f) return false;
      return !q || (partLabel(pt) + ' ' + pt.name + ' ' + ROLES[r]).toLowerCase().indexOf(q) >= 0;
    });
  }
  function rowHtml(pt, roles, i) {
    var manual = roles[pt.path], r = effRole(pt, roles), sel = !!S.partSel[pt.path];
    return '<div class="it' + (sel ? ' sel' : '') + '" data-path="' + esc(pt.path) + '" style="top:' + i * ROW_H + 'px">' +
      '<input type="checkbox" class="ck"' + (sel ? ' checked' : '') + '>' +
      '<span class="nm" title="' + esc(pt.name + ' · ' + (pt.size || []).join('×') + ' mm · ' + pt.source + ' · ' + pt.path) + '">' + esc(partLabel(pt)) + '</span>' +
      '<span class="src' + (manual || pt.sure ? '' : ' sug') + '">' + (manual ? 'gán tay' : (pt.sure ? '✓' : (pt.role === 'unknown' ? '?' : 'đề xuất ' + Math.round((pt.confidence || 0) * 100) + '%'))) + '</span>' +
      '<select class="role">' + Object.keys(ROLES).map(function (k) { return '<option value="' + k + '"' + (k === r ? ' selected' : '') + '>' + ROLES[k] + '</option>'; }).join('') +
      (manual ? '<option value="">↺ bỏ gán tay</option>' : '') + '</select></div>';
  }
  function drawWindow(box) {
    var rows = box._rows, roles = (page() && page().roles) || {};
    var s = Math.max(0, Math.floor(box.scrollTop / ROW_H) - 2), e = Math.min(rows.length, s + Math.ceil((box.clientHeight || ROW_H * GRP_MAX) / ROW_H) + 5);
    var h = ''; for (var i = s; i < e; i++) h += rowHtml(rows[i], roles, i);
    box.firstChild.innerHTML = h;
  }
  function renderParts() {
    var p = page();
    if (!p) { $('partGroups').innerHTML = ''; $('partCounts').innerHTML = ''; $('partModel').innerHTML = ''; return; }
    if (S.partSelPage !== p.id) { S.partSel = {}; S.partSelPage = p.id; }
    if (!$('assignRole').options.length) {
      $('assignRole').innerHTML = roleOpts('door', false); $('bulkRole').innerHTML = roleOpts('door', false) + '<option value="">↺ Bỏ gán tay</option>';
      $('partFilter').innerHTML = '<option value="">Tất cả loại</option><option value="sug">Chờ xác nhận (đề xuất)</option><option value="unknown">Chưa xác định</option><option value="manual">Chỉ gán tay</option>' +
        Object.keys(ROLES).filter(function (k) { return k !== 'unknown'; }).map(function (k) { return '<option value="' + k + '">Chỉ ' + ROLES[k] + '</option>'; }).join('');
    }
    var parts = (S.info && S.info.parts) || [], roles = p.roles || {}, cnt = {};
    // cụm tủ (cấp 1 trong Group cha) – chỉ để lọc, không tách model
    var cls = (S.info && S.info.clusters) || {}, ccount = {};
    parts.forEach(function (pt) { ccount[pt.cluster] = (ccount[pt.cluster] || 0) + 1; });
    var ckeys = Object.keys(ccount).filter(function (c) { return cls[c] && ccount[c] > 1; });
    var csel = $('partCluster'), cv = csel.value;
    csel.parentNode.parentNode.style.display = ckeys.length > 1 ? '' : 'none';
    csel.innerHTML = '<option value="">Tất cả cụm tủ (' + ckeys.length + ')</option>' + ckeys.map(function (c) {
      return '<option value="' + esc(c) + '"' + (c === cv ? ' selected' : '') + '>' + esc(cls[c]) + ' · ' + ccount[c] + ' bộ phận</option>';
    }).join('');
    if (cv && ckeys.indexOf(cv) < 0) csel.value = '';
    renderScanSum(parts, roles);
    parts.forEach(function (pt) { var r = effRole(pt, roles); cnt[r] = (cnt[r] || 0) + 1; });
    var total = (S.info && S.info.parts_total) || parts.length;
    $('partModel').innerHTML = esc(p.name || 'Model') + ' <small>· ' + total + ' bộ phận' + (total > parts.length ? ' (hiện ' + parts.length + ')' : '') + '</small>';
    var f = $('partFilter').value;
    $('partCounts').innerHTML = Object.keys(ROLES).filter(function (k) { return cnt[k]; }).map(function (k) {
      return '<span data-role="' + k + '" class="' + (k === 'unknown' ? 'u' : '') + (f === k ? ' on' : '') + '" title="Bấm để chỉ xem nhóm này">' + ROLES[k] + ': ' + cnt[k] + '</span>';
    }).join('') + ((S.info && S.info.missing_roles && S.info.missing_roles.length) ? '<span class="u">⚠ ' + S.info.missing_roles.length + ' gán tay đã mất</span>' : '');
    var list = partsView(), groups = {};
    list.forEach(function (pt) { (groups[effRole(pt, roles)] = groups[effRole(pt, roles)] || []).push(pt); });
    var keys = Object.keys(ROLES).filter(function (k) { return groups[k]; });
    var box = $('partGroups');
    if (!keys.length) { box.innerHTML = '<div class="empty">' + (S.info ? (parts.length ? 'Không có bộ phận khớp bộ lọc.' : 'Chưa có bộ phận (dựng trang trước).') : '') + '</div>'; updateSelN(); return; }
    var one = keys.length === 1;
    box.innerHTML = keys.map(function (k) {
      var g = groups[k], open = one || !!S.partOpen[k], nSug = g.filter(function (pt) { return !roles[pt.path] && !pt.sure; }).length;
      var allSel = g.every(function (pt) { return S.partSel[pt.path]; });
      return '<div class="pgrp' + (k === 'unknown' ? ' u' : '') + '" data-role="' + k + '"><div class="gh"><span class="tw">' + (open ? '▾' : '▸') + '</span>' +
        '<input type="checkbox" class="gck" title="Tick cả nhóm"' + (allSel ? ' checked' : '') + '><span class="gn">' + ROLES[k] + '</span>' +
        (nSug && k !== 'unknown' ? '<button class="ok" title="Chốt ' + nSug + ' mục đề xuất của nhóm thành gán tay">Xác nhận ' + nSug + '</button>' : '') +
        '<span class="gc">' + g.length + '</span></div>' +
        (open ? '<div class="vl" style="height:' + Math.min(g.length, GRP_MAX) * ROW_H + 'px"><div style="height:' + g.length * ROW_H + 'px;position:relative"></div></div>' : '') + '</div>';
    }).join('');
    box.querySelectorAll('.pgrp').forEach(function (el) {
      var vl = el.querySelector('.vl'); if (!vl) return;
      vl._rows = groups[el.dataset.role]; vl.onscroll = function () { drawWindow(vl); }; drawWindow(vl);
    });
    updateSelN();
  }
  // Tóm tắt nhận diện: cánh chắc chắn / đề xuất / chưa xác định + thao tác hàng loạt
  function sugDoors(parts, roles) {
    return parts.filter(function (pt) { return !roles[pt.path] && !pt.sure && pt.role === 'door'; });
  }
  function renderScanSum(parts, roles) {
    var box = $('scanSum'); if (!parts.length) { box.innerHTML = ''; return; }
    var sure = parts.filter(function (pt) { return effRole(pt, roles) === 'door' && (roles[pt.path] || pt.sure); }).length;
    var sug = sugDoors(parts, roles).length;
    var sugAll = parts.filter(function (pt) { return !roles[pt.path] && !pt.sure && pt.role !== 'unknown'; }).length;
    var unk = parts.filter(function (pt) { return effRole(pt, roles) === 'unknown'; }).length;
    box.innerHTML =
      '<div class="r ok"><b>' + sure + '</b><span class="lb">cánh chắc chắn (dùng cho DIM & tháo cánh)</span></div>' +
      '<div class="r sug"><b>' + sug + '</b><span class="lb">cánh đề xuất – chờ xác nhận</span>' +
      (sug ? '<button data-a="hlsug">Tô sáng</button><button data-a="oksug" class="gold">Xác nhận ' + sug + '</button>' : '') + '</div>' +
      (sugAll > sug ? '<div class="r sug"><b>' + (sugAll - sug) + '</b><span class="lb">bộ phận khác đề xuất</span><button data-a="okall">Xác nhận tất cả</button></div>' : '') +
      '<div class="r unk"><b>' + unk + '</b><span class="lb">chưa xác định</span>' + (unk ? '<button data-a="hlunk">Tô sáng</button>' : '') + '</div>';
  }
  $('scanSum').addEventListener('click', function (e) {
    var a = e.target.dataset && e.target.dataset.a; if (!a) return;
    var p = page(), parts = (S.info && S.info.parts) || [], roles = (p && p.roles) || {};
    if (a === 'hlsug') call('highlight_parts', { pid: p.pid, paths: sugDoors(parts, roles).map(function (pt) { return pt.path; }), label: 'cánh đề xuất' });
    if (a === 'hlunk') call('highlight_parts', { pid: p.pid, paths: parts.filter(function (pt) { return effRole(pt, roles) === 'unknown'; }).map(function (pt) { return pt.path; }), label: 'chưa xác định' });
    if (a === 'oksug') setRoles(sugDoors(parts, roles).map(function (pt) { return pt.path; }), 'door', 'Đã xác nhận ' + sugDoors(parts, roles).length + ' cánh');
    if (a === 'okall') {
      var list = parts.filter(function (pt) { return !roles[pt.path] && !pt.sure && pt.role !== 'unknown'; });
      var pp = page(); snapshot(); pp.roles = pp.roles || {};
      list.forEach(function (pt) { pp.roles[pt.path] = pt.role; });
      changed(); requestRender(true); msg('Đã xác nhận ' + list.length + ' bộ phận đề xuất. ↶ để hoàn tác.', 'ok');
    }
  });
  $('scanParts').onclick = function () {
    var p = page(); if (!p) { msg('Chưa có trang – bấm Tự động triển khai trước.', 'warn'); return; }
    busy(true); call('scan_parts', { project: S.project, page_id: S.cur, sheet: S.sheet || 0 });
    msg('Đang đọc lại hình học và nhận diện cấu tạo…', 'ok');
  };
  $('partCluster').onchange = renderParts;
  function updateSelN() {
    var n = Object.keys(S.partSel).length;
    $('partSelN').textContent = n + ' đã tick'; $('bulkBtn').disabled = !n;
  }
  function setRoles(paths, role, note) {
    var p = page(); if (!p || !paths.length) return;
    snapshot(); p.roles = p.roles || {};
    paths.forEach(function (x) { if (role) p.roles[x] = role; else delete p.roles[x]; });
    changed(); requestRender(true);
    msg((note || (role ? 'Đã gán ' + paths.length + ' bộ phận là "' + ROLES[role] + '"' : 'Đã bỏ gán tay ' + paths.length + ' bộ phận')) + '. ↶ để hoàn tác, 💾 Lưu để ghi vào file.', 'ok');
  }
  $('partSearch').oninput = renderParts;
  $('partFilter').onchange = renderParts;
  $('partCounts').addEventListener('click', function (e) {
    var c = e.target.closest('span[data-role]'); if (!c) return;
    $('partFilter').value = $('partFilter').value === c.dataset.role ? '' : c.dataset.role; renderParts();
  });
  $('partGroups').addEventListener('click', function (e) {
    var gh = e.target.closest('.gh');
    if (gh) {
      var k = gh.parentNode.dataset.role;
      if (e.target.classList.contains('gck')) return;
      if (e.target.classList.contains('ok')) {
        var p = page(), roles = (p && p.roles) || {};
        var paths = ((S.info && S.info.parts) || []).filter(function (pt) { return !roles[pt.path] && !pt.sure && pt.role === k; }).map(function (pt) { return pt.path; });
        setRoles(paths, k, 'Đã xác nhận ' + paths.length + ' bộ phận là "' + ROLES[k] + '"'); return;
      }
      S.partOpen[k] = !S.partOpen[k]; renderParts(); return;
    }
    var it = e.target.closest('.it'); if (!it) return;
    if (e.target.classList.contains('nm')) { var pp = page(); call('highlight_part', { pid: pp.pid, path: it.dataset.path }); }
  });
  $('partGroups').addEventListener('change', function (e) {
    if (e.target.classList.contains('gck')) {
      var k = e.target.closest('.pgrp').dataset.role, roles = (page() && page().roles) || {};
      partsView().forEach(function (pt) { if (effRole(pt, roles) === k) { if (e.target.checked) S.partSel[pt.path] = 1; else delete S.partSel[pt.path]; } });
      renderParts(); return;
    }
    var it = e.target.closest('.it'); if (!it) return;
    if (e.target.classList.contains('ck')) {
      if (e.target.checked) S.partSel[it.dataset.path] = 1; else delete S.partSel[it.dataset.path];
      it.classList.toggle('sel', e.target.checked); updateSelN(); return;
    }
    if (e.target.classList.contains('role')) setRoles([it.dataset.path], e.target.value);
  });
  $('bulkBtn').onclick = function () { var paths = Object.keys(S.partSel); setRoles(paths, $('bulkRole').value); S.partSel = {}; updateSelN(); };
  $('bulkClear').onclick = function () { S.partSel = {}; renderParts(); };
  $('assignBtn').onclick = function () { var p = page(); if (p) call('assign_parts', { pid: p.pid, role: $('assignRole').value }); };

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
    snapshot(); p.sections.splice(i, 1); if (p.offsets) delete p.offsets['sec:' + sc.label]; if (p.view_props) delete p.view_props['sec:' + sc.label];
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
    snapshot(); (p.sections || []).forEach(function (x) { if (p.offsets) delete p.offsets['sec:' + x.label]; if (p.view_props) delete p.view_props['sec:' + x.label]; });
    p.sections = null; renderSections(); changed();
  };

  // ---------------- chú thích & chi tiết ----------------
  var TYPE_NAME = { text: 'Text', mtext: 'Ghi chú nhiều dòng', leader: 'Leader', material: 'Ghi chú vật liệu' };
  function viewAtPaper(pt) {
    var fr = (S.info && S.info.frames) || {}, best = null;
    Object.keys(fr).forEach(function (k) {
      var f = fr[k], w = f[3] / f[2], h = f[4] / f[2];
      if (pt[0] >= f[0] && pt[0] <= f[0] + w && pt[1] >= f[1] && pt[1] <= f[1] + h && (!best || w * h < best.a)) best = { k: k, a: w * h };
    });
    return best && best.k;
  }
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

  function detStyle() { return { shape: $('detShape').value, arrow: $('detArrow').checked, bubble: $('detBubble').checked }; }
  function renderDetails() {
    var p = page(), box = $('detBox'); if (!p) { box.innerHTML = ''; return; }
    var list = p.details || [];
    box.innerHTML = (list.length ? list.map(function (d, i) {
      var mk = d.marker || {}, sh = sheetOf('det:' + d.n);
      return '<div class="sec" data-i="' + i + '"><div class="hd"><span class="lb">' + esc(viewName('det:' + d.n)) + '</span><span class="auto">' + (d.type === 'section' ? 'cấu tạo · ' : 'phóng to · ') + 'từ ' +
        esc(viewName(d.src)) + (d.src_sheet != null ? ' (' + esc(sheetCode(d.src_sheet)) + ')' : '') + ' → ' + esc(sheetCode(sh == null ? 0 : sh)) + '</span><button class="del" title="Xoá chi tiết">✕</button></div>' +
        '<div class="row"><div><label>Tên</label><input class="dlb" type="text" value="' + esc(d.label || '') + '" placeholder="CHI TIẾT ' + d.n + '"></div>' +
        '<div style="max-width:70px"><label>Tỉ lệ 1:</label><input class="dsc" type="number" min="1" max="100" step="1" value="' + d.scale + '"></div></div>' +
        '<div class="row"><div><select class="dmk"><option value="rect"' + ((mk.shape || 'rect') === 'rect' ? ' selected' : '') + '>Chữ nhật nét đứt</option>' +
        '<option value="circle"' + (mk.shape === 'circle' ? ' selected' : '') + '>Tròn nét đứt</option><option value="ellipse"' + (mk.shape === 'ellipse' ? ' selected' : '') + '>Elip nét đứt</option></select></div></div>' +
        '<div class="checks"><label><input type="checkbox" class="dar"' + (mk.arrow ? ' checked' : '') + '> Mũi tên</label><label><input type="checkbox" class="dbb"' + (mk.bubble !== false ? ' checked' : '') + '> Bóng số</label></div></div>';
    }).join('') : '') + '<p class="hint">Chọn ⊡ Chi tiết rồi kéo khung trên một hình chiếu: chi tiết nằm ngay tờ đang trích. Chuột phải vào chi tiết hoặc marker để đổi tỷ lệ, kiểu, tên, chuyển trang…</p>';
  }
  $('detBox').addEventListener('change', function (e) {
    var el = e.target.closest('.sec'); if (!el) return;
    var d = page().details[+el.dataset.i]; if (!d) return;
    snapshot();
    if (e.target.classList.contains('dsc')) d.scale = Math.max(1, Math.min(100, parseInt(e.target.value, 10) || 4));
    if (e.target.classList.contains('dlb')) d.label = e.target.value.trim() || null;
    d.marker = Object.assign({ shape: 'rect', arrow: false, bubble: true }, d.marker || {});
    if (e.target.classList.contains('dmk')) d.marker.shape = e.target.value;
    if (e.target.classList.contains('dar')) d.marker.arrow = e.target.checked;
    if (e.target.classList.contains('dbb')) d.marker.bubble = e.target.checked;
    changed();
  });
  $('detBox').addEventListener('click', function (e) {
    if (!e.target.classList.contains('del')) return;
    var p = page(), i = +e.target.closest('.sec').dataset.i, d = p.details[i];
    if (!window.confirm('Xoá CHI TIẾT ' + d.n + '?')) return;
    snapshot(); p.details.splice(i, 1); if (p.offsets) delete p.offsets['det:' + d.n]; if (p.view_props) delete p.view_props['det:' + d.n]; renderDetails(); changed();
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
    rect = rect.map(function (x) { return Math.round(x * 10) / 10; });
    if (S.reDetail) { // chọn lại vùng trích cho chi tiết đã có
      var od = p.details.filter(function (x) { return x.n === S.reDetail; })[0]; S.reDetail = null;
      if (od) { od.src = key; od.rect = rect; od.src_sheet = S.sheet || 0; renderDetails(); changed(); requestRender(true); msg('Đã chọn lại vùng trích cho ' + viewName('det:' + od.n) + '.', 'ok'); return; }
    }
    var n = p.details.reduce(function (m, d) { return Math.max(m, d.n); }, 0) + 1;
    var st = detStyle();
    // chi tiết nằm NGAY TỜ đang trích (chờ đặt vào chỗ trống của tờ này) – không tự về A-01
    var dtype = S.detMode || $('detType').value; S.detMode = null;
    var nd = { n: n, src: key, rect: rect, scale: scale, src_sheet: S.sheet || 0, sheet: S.sheet || 0, marker: st, label: null, type: dtype };
    if (dtype === 'section') {
      if (/^(iso|det:)/.test(key)) { msg('Chi tiết cấu tạo cần hình chiếu vuông góc hoặc mặt cắt làm nguồn.', 'err'); return; }
      var ori = $('detOrient').value;
      nd.cut = { orient: ori, at: Math.round((ori === 'v' ? (rect[0] + rect[2]) : (rect[1] + rect[3])) / 2 * 10) / 10 };
      nd.depth = $('detDepth').value ? +$('detDepth').value : null;
      nd.labels = true;
    }
    p.details.push(nd);
    vprops('det:' + n, true).sheet = S.sheet || 0;
    S.pendingPlace = 'det:' + n;
    renderDetails(); changed(); requestRender(true);
    msg('Đã tạo CHI TIẾT ' + n + (dtype === 'section' ? ' – CẤU TẠO (mặt cắt thật qua hình học 3D, đường cắt giữa vùng; chuột phải để đổi hướng/vị trí cắt)' : ' – phóng to 2D') +
        ' (TL 1:' + scale + ') trên tờ ' + sheetCode(S.sheet || 0) + '.', 'ok');
  }
  var place = null; // trạng thái đặt leader (đã có điểm mũi tên)
  function ghost(cls, css) {
    var el = document.createElement('div'); el.className = cls; Object.assign(el.style, css); $('stage').appendChild(el); return el;
  }

  // ---------------- DIM THỦ CÔNG 2 ĐIỂM (v2.14) ----------------
  // Dữ liệu: page.manual_dims = { key hình: [{ id, a:[u,v], b:[u,v], axis, kind, side, off, ra, rb, hidden }] } – mm thật
  // trong hệ cục bộ của hình; Ruby đo, bám lại theo model và vẽ (SVG/PDF). Auto DIM nằm riêng, không đụng tới.
  var MD_TYPES = { end: 'Đầu mút / góc ván', int: 'Giao điểm cạnh', edge: 'Trên cạnh', free: 'Tự do (không bắt)' };
  var MD_AXES = { v: 'Dọc', h: 'Ngang', a: 'Thẳng (chéo)' };
  function mdCfg() {
    var c = S.project.mdim || (S.project.mdim = {});
    if (c.kind !== 'free') c.kind = 'clear';
    if (['auto', 'v', 'h', 'a'].indexOf(c.axis) < 0) c.axis = 'auto';
    if (['l', 'r', 'free'].indexOf(c.side) < 0) c.side = 'l';
    if (c.snap !== false) c.snap = true;
    return c;
  }
  function mdList(k, create) {
    var p = page(); if (!p) return [];
    if (!p.manual_dims) { if (!create) return []; p.manual_dims = {}; }
    if (!p.manual_dims[k]) { if (!create) return []; p.manual_dims[k] = []; }
    return p.manual_dims[k];
  }
  function mdFind(k, id) { return mdList(k).filter(function (d) { return d.id === id; })[0]; }
  // Hình học bắt điểm (v2.16): không còn gửi kèm mỗi lần dựng; xin Ruby 1 lần cho mỗi hình khi cần (công cụ DIM,
  // chỉnh DIM) và giữ lại cho tới khi chữ ký hình học (sig) đổi. Lưới chỉ mục dựng 1 lần, dùng lại mọi lần rê chuột.
  function snapSegs(k) {
    var m = S.info && S.info.snap && S.info.snap[k]; if (!m) return null;
    var dd = S.snapData && S.snapData[k];
    if (dd && dd.sig === m.sig) return dd.segs;
    snapRequest(k); return null;
  }
  function snapRequest(k) {
    var m = S.info && S.info.snap && S.info.snap[k]; if (!m || !S.cur) return;
    S.snapReq = S.snapReq || {};
    if (S.snapReq[k] === m.sig) return;
    S.snapReq[k] = m.sig; call('snap', { page_id: S.cur, key: k });
  }
  function snapPrefetch() { Object.keys((S.info && S.info.snap) || {}).forEach(function (k) { snapSegs(k); }); }
  function mdIndex(k) {
    S.mdIdx = S.mdIdx || {};
    if (S.mdIdx[k]) return S.mdIdx[k];
    var m = S.info && S.info.snap && S.info.snap[k], segs = snapSegs(k);
    if (!segs) return null;
    return (S.mdIdx[k] = new MDIM.Index(segs, m.w, m.h));
  }
  function mdToV(k, pt) { var f = frameOf(k); return [(pt[0] - f[0]) * f[2], (pt[1] - f[1]) * f[2]]; }
  function mdToP(k, q) { var f = frameOf(k); return [f[0] + q[0] / f[2], f[1] + q[1] / f[2]]; }
  // hình tại điểm bấm: vùng vẽ (nới 2.5 mm giấy để bắt được cạnh ngoài cùng của hình)
  function mdViewAt(pt) {
    var k = viewAtPaper(pt); if (k && k !== 'iso') return k;
    var fr = (S.info && S.info.frames) || {}, best = null;
    Object.keys(fr).forEach(function (kk) {
      if (kk === 'iso' || !(S.info.snap || {})[kk]) return;
      var f = fr[kk], w = f[3] / f[2], h = f[4] / f[2], m = 2.5;
      if (pt[0] >= f[0] - m && pt[0] <= f[0] + w + m && pt[1] >= f[1] - m && pt[1] <= f[1] + h + m && (!best || w * h < best.a)) best = { k: kk, a: w * h };
    });
    return best && best.k;
  }
  // Bắt điểm: bán kính 7 px màn hình đổi ra mm thật của hình -> đúng ở mọi mức zoom / tỉ lệ
  function mdSnap(k, pt) {
    var q = mdToV(k, pt), f = frameOf(k);
    if (!mdCfg().snap) return { p: [Math.round(q[0] * 10) / 10, Math.round(q[1] * 10) / 10], type: 'free' };
    var s = MDIM.snap(mdIndex(k), q, 7 / S.k * f[2]);
    return s || { p: [Math.round(q[0] * 10) / 10, Math.round(q[1] * 10) / 10], type: 'free' };
  }
  // vị trí các DIM khác cùng hình (để không chồng, nối chuỗi thẳng hàng) + hàng Auto DIM
  function mdOthers(k, axis, skipId) {
    var out = [];
    mdList(k).forEach(function (d) {
      if (d.id === skipId || d.hidden || d.axis !== axis || d.side === 'in') return;
      var c = axis === 'h' ? 0 : 1;
      out.push({ side: d.side, off: d.off, lo: Math.min(d.a[c], d.b[c]), hi: Math.max(d.a[c], d.b[c]) });
    });
    var p = page();
    if (p && p.dims !== false && k !== 'iso') {
      var o = (p.dimoff || {})[k] || {};
      if (axis === 'v') { out.push({ side: 'l', off: 9.5 - (o.left || 0) }); out.push({ side: 'r', off: 6 + (o.right || 0) }); }
      if (axis === 'h') { out.push({ side: 't', off: 5.5 - (o.top || 0) }); out.push({ side: 't', off: 11.5 - (o.top || 0) }); }
    }
    return out;
  }
  function mdSpan(a, b, axis) { var c = axis === 'h' ? 0 : 1; return [Math.min(a[c], b[c]), Math.max(a[c], b[c])]; }
  function mdLabel(v) { var r = (page() && page().round) || 1; var x = Math.round(v / r) * r; return x === Math.round(x) ? String(Math.round(x)) : x.toFixed(1); }
  // hình học giấy của 1 DIM (như Ruby ManualDim.draw_one) – để xem trước
  function mdGeom(k, d) {
    var f = frameOf(k), s = f[2], ox = f[0], oy = f[1], vw = f[3] / s, vh = f[4] / s;
    var a = mdToP(k, d.a), b = mdToP(k, d.b), off = +d.off || 0, lp;
    if (d.axis === 'a') {
      var l = Math.hypot(b[0] - a[0], b[1] - a[1]) || 1, nx = -(b[1] - a[1]) / l, ny = (b[0] - a[0]) / l;
      var pa = [a[0] + nx * off, a[1] + ny * off], pb = [b[0] + nx * off, b[1] + ny * off];
      return { ext: [[a, pa], [b, pb]], line: [pa, pb], mid: [(pa[0] + pb[0]) / 2, (pa[1] + pb[1]) / 2] };
    }
    if (d.axis === 'h') lp = d.side === 'b' ? oy + vh + off : d.side === 'in' ? oy + off / s : oy - off;
    else lp = d.side === 'r' ? ox + vw + off : d.side === 'in' ? ox + off / s : ox - off;
    var kk = d.axis === 'h' ? 1 : 0, qa = a.slice(), qb = b.slice(); qa[kk] = qb[kk] = lp;
    return { ext: [[a, qa], [b, qb]], line: [qa, qb], mid: [(qa[0] + qb[0]) / 2, (qa[1] + qb[1]) / 2], vert: kk === 0 };
  }
  function svgEl(tag, attrs, parent) {
    var e = document.createElementNS('http://www.w3.org/2000/svg', tag);
    Object.keys(attrs).forEach(function (n) { e.setAttribute(n, attrs[n]); }); if (parent) parent.appendChild(e); return e;
  }
  function mdPrevGroup() {
    var svg = $('paper').querySelector('svg'); if (!svg) return null;
    var g = svg.querySelector('g.mdprev'); if (g) g.remove();
    return svgEl('g', { 'class': 'mdprev edonly', 'pointer-events': 'none' }, svg);
  }
  function mdMarker(g, k, sn) {
    if (!sn || sn.type === 'free') return;
    var c = mdToP(k, sn.p), r = 1.1 / Math.max(0.6, S.k / 3), col = '#E8590C';
    if (sn.type === 'end') svgEl('rect', { x: c[0] - r, y: c[1] - r, width: 2 * r, height: 2 * r, fill: 'none', stroke: col, 'stroke-width': r / 3 }, g);
    else if (sn.type === 'int') { svgEl('path', { d: 'M' + (c[0] - r) + ' ' + (c[1] - r) + 'L' + (c[0] + r) + ' ' + (c[1] + r) + 'M' + (c[0] + r) + ' ' + (c[1] - r) + 'L' + (c[0] - r) + ' ' + (c[1] + r), stroke: col, 'stroke-width': r / 3 }, g); }
    else svgEl('path', { d: 'M' + c[0] + ' ' + (c[1] - r) + 'L' + (c[0] + r) + ' ' + (c[1] + r * 0.8) + 'L' + (c[0] - r) + ' ' + (c[1] + r * 0.8) + 'Z', fill: 'none', stroke: col, 'stroke-width': r / 3 }, g);
    if (sn.seg) { var s1 = mdToP(k, [sn.seg[0], sn.seg[1]]), s2 = mdToP(k, [sn.seg[2], sn.seg[3]]); svgEl('path', { d: 'M' + s1[0] + ' ' + s1[1] + 'L' + s2[0] + ' ' + s2[1], stroke: col, 'stroke-width': 0.35, opacity: 0.45 }, g); }
  }
  function mdDrawDim(g, k, d, col) {
    var G = mdGeom(k, d), w = 0.18;
    G.ext.forEach(function (e) { svgEl('path', { d: 'M' + e[0][0] + ' ' + e[0][1] + 'L' + e[1][0] + ' ' + e[1][1], stroke: col, 'stroke-width': 0.13 }, g); });
    svgEl('path', { d: 'M' + G.line[0][0] + ' ' + G.line[0][1] + 'L' + G.line[1][0] + ' ' + G.line[1][1], stroke: col, 'stroke-width': w }, g);
    G.line.forEach(function (p) { svgEl('path', { d: 'M' + (p[0] - 0.8) + ' ' + (p[1] + 0.8) + 'L' + (p[0] + 0.8) + ' ' + (p[1] - 0.8), stroke: col, 'stroke-width': 0.3 }, g); });
    var t = svgEl('text', { x: G.mid[0] + (G.vert ? -1.5 : 0), y: G.mid[1] + (G.vert ? 0 : -1.5), 'font-size': 2.4, fill: col, 'text-anchor': 'middle', 'font-weight': 'bold' }, g);
    if (G.vert) t.setAttribute('transform', 'rotate(-90 ' + (G.mid[0] - 1.5) + ' ' + G.mid[1] + ')');
    t.textContent = mdLabel(MDIM.value(d.a, d.b, d.axis));
  }
  function mdStatus(t) { msg(t, ''); }
  function mdStart(gap) {
    if (!S.cur || !S.info) return;
    S.mdGap = !!gap; S.md = { step: 0 }; setTool('mdim'); S.mdGap = !!gap;
    mdStatus(gap ? 'ĐO THÔNG THỦY: bấm vào khoảng trống giữa hai tấm (vd. giữa hai đợt kệ). ESC để hủy.'
                 : 'THÊM DIM: bấm điểm đầu (vd. mặt dưới đợt phía trên). Smart Snap ' + (mdCfg().snap ? 'BẬT' : 'TẮT') + ' · ESC để hủy.');
  }
  function mdCancel() { S.md = null; S.mdEdit = null; var g = mdPrevGroup(); if (g) g.remove(); }
  function mdMove(e) {
    var pt = toPaper(e), md = S.md; if (!md || !S.info) return;
    var g = mdPrevGroup(); if (!g) return;
    if (md.step === 0) {
      var k = mdViewAt(pt); if (!k) { md.hover = null; return; }
      md.hover = { k: k, sn: S.mdGap ? null : mdSnap(k, pt) };
      mdMarker(g, k, md.hover.sn);
      if (md.hover.sn) $('stInfo').textContent = 'Bắt: ' + MD_TYPES[md.hover.sn.type];
    } else if (md.step === 1) {
      var sn = mdSnap(md.key, pt); md.sn = sn; mdMarker(g, md.key, sn);
      var pa = mdToP(md.key, md.a), pb = mdToP(md.key, sn.p);
      svgEl('path', { d: 'M' + pa[0] + ' ' + pa[1] + 'L' + pb[0] + ' ' + pb[1], stroke: '#E8590C', 'stroke-width': 0.2, 'stroke-dasharray': '1 0.6' }, g);
      svgEl('circle', { cx: pa[0], cy: pa[1], r: 0.6, fill: '#E8590C' }, g);
      var ax = MDIM.axisOf(md.a, sn.p, mdCfg().axis, md.aSeg, sn.seg);
      $('stInfo').textContent = 'Bắt: ' + MD_TYPES[sn.type] + ' · ' + MD_AXES[ax] + ' ' + mdLabel(MDIM.value(md.a, sn.p, ax));
    } else if (md.step === 2) {
      var f = null, pl = MDIM.placeLine(md.axis, frameOf(md.key), pt, md.sideCfg || mdCfg().side, mdOthers(md.key, md.axis, md.editId), mdSpan(md.a, md.b, md.axis));
      md.side = pl.side; md.off = pl.off;
      if (md.axis === 'a') { var A = mdToP(md.key, md.a), B = mdToP(md.key, md.b), L = Math.hypot(B[0] - A[0], B[1] - A[1]) || 1;
        md.side = 'in'; md.off = Math.round(((pt[0] - A[0]) * -(B[1] - A[1]) / L + (pt[1] - A[1]) * (B[0] - A[0]) / L) * 10) / 10; }
      mdDrawDim(g, md.key, md, '#E8590C');
      $('stInfo').textContent = 'DIM ' + MD_AXES[md.axis] + ' = ' + mdLabel(MDIM.value(md.a, md.b, md.axis)) + ' mm · bấm để xác nhận vị trí';
    }
  }
  function mdClick(e) {
    var pt = toPaper(e), md = S.md || (S.md = { step: 0 }), cfg = mdCfg();
    if (md.step === 0) {
      var k = mdViewAt(pt);
      if (!k) { msg('Bấm vào phần hình vẽ của một hình chiếu / mặt cắt.', 'err'); return; }
      if (!(S.info.snap || {})[k]) { msg('Hình này không hỗ trợ DIM thủ công (trục đo).', 'err'); return; }
      if (S.mdGap) {
        var segs = snapSegs(k) || [], q = mdToV(k, pt), ax0 = cfg.axis === 'h' ? 'h' : 'v';
        var gp = MDIM.gapAt(segs, q, ax0);
        if (!gp) { msg('Không tìm thấy hai cạnh bao quanh điểm bấm – bấm vào khoảng trống giữa hai tấm.', 'err'); return; }
        S.md = { step: 2, key: k, a: gp[0], b: gp[1], axis: ax0, kind: 'clear' };
        msg('Thông thủy = ' + mdLabel(MDIM.value(gp[0], gp[1], ax0)) + ' mm. Di chuột để đặt đường DIM, bấm để xác nhận.', 'ok');
        mdMove(e); return;
      }
      var sn = mdSnap(k, pt);
      S.md = { step: 1, key: k, a: sn.p, aType: sn.type, aSeg: sn.seg };
      msg('Điểm đầu: ' + MD_TYPES[sn.type] + '. Bấm điểm cuối (vd. mặt trên đợt phía dưới).', ''); return;
    }
    if (md.step === 1) {
      var sb = mdSnap(md.key, pt);
      if (Math.hypot(sb.p[0] - md.a[0], sb.p[1] - md.a[1]) < 0.5) { msg('Điểm cuối trùng điểm đầu – chọn điểm khác.', 'err'); return; }
      var axis = MDIM.axisOf(md.a, sb.p, cfg.axis, md.aSeg, sb.seg), a = md.a, b = sb.p;
      if (cfg.kind === 'clear') { var rf = MDIM.refineClear(snapSegs(md.key) || [], a, b, axis); a = rf[0]; b = rf[1]; }
      S.md = { step: 2, key: md.key, a: a, b: b, axis: axis, kind: cfg.kind };
      msg((cfg.kind === 'clear' ? 'Thông thủy ' : '') + MD_AXES[axis] + ' = ' + mdLabel(MDIM.value(a, b, axis)) + ' mm. Di chuột để đặt đường DIM (' +
          (axis === 'v' ? { l: 'bên trái', r: 'bên phải', free: 'tự chọn' }[cfg.side] : 'trên/dưới') + '), bấm để xác nhận.', 'ok');
      mdMove(e); return;
    }
    if (md.step === 2) {
      if (md.side == null) mdMove(e);
      var list = mdList(md.key, true);
      var sig = function (d) { return d.axis + '|' + [d.a, d.b].map(function (p) { return p.map(function (x) { return Math.round(x * 10) / 10; }).join(','); }).sort().join('|'); };
      var nd = { id: newId('md'), a: md.a, b: md.b, axis: md.axis, kind: md.kind || cfg.kind, side: md.side, off: md.off, ra: null, rb: null, hidden: false };
      if (list.some(function (d) { return sig(d) === sig(nd); })) { msg('Đã có DIM thủ công đo đúng hai điểm này – không tạo trùng.', 'warn'); S.md = { step: 0 }; mdPrevGroup(); return; }
      snapshot(); list.push(nd);
      S.selDims = [{ key: md.key, id: nd.id, origin: 'manual' }]; S.md = { step: 0 };
      changed(); requestRender(true); renderMd();
      msg('Đã thêm DIM ' + mdLabel(MDIM.value(nd.a, nd.b, nd.axis)) + ' mm trên ' + viewName(md.key) + '. Bấm tiếp để thêm DIM khác, ESC để thoát.', 'ok');
      if (S.mdGap) { S.mdGap = false; setTool('select'); }
    }
  }
  function mdEdit(k, id, fn, note) {
    var d = mdFind(k, id); if (!d) return;
    snapshot(); fn(d); changed(); requestRender(true); renderMd(); if (note) msg(note, 'ok');
  }
  function mdDelete(k, id) {
    var p = page(); if (!p || !p.manual_dims || !p.manual_dims[k]) return;
    snapshot(); p.manual_dims[k] = p.manual_dims[k].filter(function (d) { return d.id !== id; });
    if (!p.manual_dims[k].length) delete p.manual_dims[k];
    S.selDims = (S.selDims || []).filter(function (x) { return x.id !== id; });
    changed(); requestRender(true); renderMd(); msg('Đã xóa DIM thủ công (↶ để hoàn tác).', 'ok');
  }
  // tay nắm 2 đầu DIM đang chọn (kéo để đổi điểm bám)
  function mdHandles() { dimGrips(); }

  // nhận lại DIM đã bám theo model (điểm, liên kết, trạng thái) – không tạo bước hoàn tác
  function mdSync(info) {
    var p = page(); if (!p || !info.manual_dims) return;
    var dirty = false;
    Object.keys(info.manual_dims).forEach(function (k) {
      info.manual_dims[k].forEach(function (r) {
        var d = mdFind(k, r.id); if (!d) return;
        ['a', 'b', 'ra', 'rb'].forEach(function (f) { if (JSON.stringify(d[f]) !== JSON.stringify(r[f])) { d[f] = r[f]; dirty = true; } });
      });
    });
    if (dirty) markDirty();
  }
  function mdResult(k, id) { var l = (S.info && S.info.manual_dims && S.info.manual_dims[k]) || []; return l.filter(function (r) { return r.id === id; })[0]; }
  function renderMd() {
    var box = $('mdList'); if (!box) return;
    var c = mdCfg(), p = page();
    $('mdKind').value = c.kind; $('mdAxis').value = c.axis; $('mdSide').value = c.side; $('mdSnap').checked = c.snap;
    var keys = (S.info && S.info.view_keys) || [], rows = [], selk = (S.selDims || []).map(function (x) { return x.key + '|' + x.id; });
    keys.forEach(function (k) {
      // DIM tự động đã chỉnh (đã sửa / ẩn / xóa / khóa) + DIM thủ công
      dimsOf(k).forEach(function (d) {
        if (d.origin === 'auto' && !d.user_modified) return;
        var on = selk.indexOf(k + '|' + d.id) >= 0, bad = d.status === 'broken';
        var tags = [d.origin === 'auto' ? 'tự động đã sửa' : 'thủ công', MD_AXES[d.axis]];
        if (d.origin === 'manual' && mdFind(k, d.id) && mdFind(k, d.id).kind === 'clear') tags.push('thông thủy');
        if (d.text_override) tags.push('chữ riêng'); if (d.deleted) tags.push('ĐÃ XÓA'); else if (d.hidden) tags.push('ẩn'); if (d.locked) tags.push('khóa');
        rows.push('<div class="it mdrow' + (on ? ' on' : '') + (bad ? ' bad' : '') + (d.deleted ? ' gone' : '') + '" data-k="' + esc(k) + '" data-id="' + esc(d.id) + '" data-o="' + d.origin + '">' +
          '<span class="nm">' + esc(mdLabel(d.value)) + ' mm</span><span class="auto">' + esc(tags.join(' · ')) + ' · ' + esc(viewName(k)) + (bad ? ' · <b>MẤT LIÊN KẾT</b>' : '') + '</span>' +
          (d.deleted ? '<button class="mdundel" title="Khôi phục DIM đã xóa">↺</button>' : '<button class="mdhide" title="' + (d.hidden ? 'Hiện' : 'Ẩn') + ' DIM">' + (d.hidden ? '◌' : '◉') + '</button>') +
          (d.origin === 'auto' ? '<button class="mdrestore" title="Khôi phục tự động">⟲</button>' : '<button class="mddel" title="Xóa DIM">✕</button>') + '</div>');
      });
      ((S.info && S.info.dim_orphans && S.info.dim_orphans[k]) || []).forEach(function (id) {
        rows.push('<div class="it mdrow bad" data-k="' + esc(k) + '" data-id="' + esc(id) + '" data-o="orphan"><span class="nm">?</span><span class="auto">DIM tự động đã sửa không còn khớp hình học mới (' + esc(id) + ') · ' + esc(viewName(k)) +
          '</span><button class="mdrestore" title="Bỏ chỉnh sửa cũ">✕</button></div>');
      });
    });
    box.innerHTML = rows.length ? rows.join('') : '<p class="hint">Chưa có DIM thủ công hay DIM tự động đã chỉnh trên tờ này. Bấm vào một DIM trên giấy để chọn & sửa.</p>';
    if (p) dimGrips();
  }

  ['mdKind', 'mdAxis', 'mdSide'].forEach(function (id) {
    $(id).addEventListener('change', function () { var c = mdCfg(); c[{ mdKind: 'kind', mdAxis: 'axis', mdSide: 'side' }[id]] = this.value; markDirty(); });
  });
  $('mdSnap').addEventListener('change', function () { mdCfg().snap = this.checked; markDirty(); msg('Smart Snap ' + (this.checked ? 'BẬT' : 'TẮT') + '.', ''); });
  $('mdAdd').onclick = function () { mdStart(false); };
  $('mdGapBtn').onclick = function () { mdStart(true); };
  $('mdList').addEventListener('click', function (e) {
    var row = e.target.closest('.mdrow'); if (!row) return;
    var k = row.dataset.k, id = row.dataset.id, org = row.dataset.o, sl = { key: k, id: id, origin: org === 'manual' ? 'manual' : 'auto' };
    if (org === 'orphan' || e.target.classList.contains('mdrestore')) { dimRestore(sl); return; }
    if (e.target.classList.contains('mddel')) { mdDelete(k, id); return; }
    if (e.target.classList.contains('mdundel')) { dimChange(sl, function (o) { o.deleted = null; }, 'Đã khôi phục DIM đã xóa.'); return; }
    if (e.target.classList.contains('mdhide')) { var di = dimInfo(k, id); dimChange(sl, function (o) { o.hidden = !(di && di.hidden) || null; if (sl.origin === 'manual') o.hidden = !!o.hidden; }); return; }
    selectDim(sl, e.shiftKey);
  });


  // ---------------- CHỈNH DIM & CHỮ (v2.15) ----------------
  // DIM tự động: mỗi đoạn là 1 đối tượng (info.dims[key][i], id ổn định "chuỗi:đầu-cuối"); chỉnh sửa lưu ở
  // page.dim_over[key][id] và Ruby áp lại sau mỗi lần dựng. DIM thủ công: page.manual_dims. Hai loại dùng chung
  // công cụ: chọn, grip điểm đầu/cuối, grip đường DIM, grip chữ, bảng thuộc tính, menu chuột phải, Undo/Redo.
  // Chữ: tên hình (page.captions[key]) và chú thích (page.notes) – nhấp đúp để sửa, kéo để dời, khóa được.
  var SIDE_OF = { top: 't', left: 'l', right: 'r' };
  function dimsOf(k) { return (S.info && S.info.dims && S.info.dims[k]) || []; }
  function dimInfo(k, id) { return dimsOf(k).filter(function (d) { return d.id === id; })[0]; }
  function dimSel() { return S.selDims && S.selDims.length ? S.selDims[S.selDims.length - 1] : null; }
  function selOf(g) { return { key: g.getAttribute('data-key'), id: g.getAttribute('data-id'), origin: g.classList.contains('mdim') ? 'manual' : 'auto' }; }
  function overOf(k, id, create) {
    var p = page(); if (!p) return null;
    if (!p.dim_over) { if (!create) return null; p.dim_over = {}; }
    if (!p.dim_over[k]) { if (!create) return null; p.dim_over[k] = {}; }
    if (!p.dim_over[k][id]) { if (!create) return null; p.dim_over[k][id] = {}; }
    return p.dim_over[k][id];
  }
  function dimObj(sel, create) { return sel.origin === 'manual' ? mdFind(sel.key, sel.id) : overOf(sel.key, sel.id, create); }
  function tidyOver(k, id) {
    var p = page(), o = p && p.dim_over && p.dim_over[k] && p.dim_over[k][id]; if (!o) return;
    Object.keys(o).forEach(function (f) { if (o[f] == null || o[f] === false || o[f] === '') delete o[f]; });
    if (!Object.keys(o).length) delete p.dim_over[k][id];
    if (!Object.keys(p.dim_over[k]).length) delete p.dim_over[k];
  }
  function dimLocked(sel) { var d = dimInfo(sel.key, sel.id); return !!(d && d.locked); }
  function dimChange(sel, fn, note) {
    snapshot();
    var o = dimObj(sel, true); if (!o) { S.undo.pop(); return; }
    fn(o, dimInfo(sel.key, sel.id) || {});
    if (sel.origin === 'auto') tidyOver(sel.key, sel.id);
    changed(); requestRender(true); renderMd(); if (note) msg(note, 'ok');
  }
  function dimName(d) { return (d && (d.text || d.label || mdLabel(d.value || 0))) + ' mm'; }
  function selectDim(sel, add) {
    snapSegs(sel.key);
    S.selNote = null; S.selCap = null;
    if (!add) S.selDims = [sel];
    else {
      S.selDims = S.selDims || [];
      var i = S.selDims.map(function (x) { return x.key + '|' + x.id; }).indexOf(sel.key + '|' + sel.id);
      if (i >= 0) S.selDims.splice(i, 1); else S.selDims.push(sel);
    }
    renderMd();
  }
  function clearDimSel() { if (S.selDims && S.selDims.length) { S.selDims = []; renderMd(); } }
  // grip: điểm đầu/cuối (tròn), đường DIM (vuông), chữ (thoi). DIM khóa: grip xám, không kéo được.
  function dimGrips() {
    var svg = $('paper').querySelector('svg'); if (!svg) return;
    svg.querySelectorAll('g.dimgrips').forEach(function (x) { x.remove(); });
    var keys = (S.selDims || []).map(function (x) { return x.key + '|' + x.id; });
    svg.querySelectorAll('g.dim, g.mdim').forEach(function (x) { x.classList.toggle('sel', keys.indexOf(x.getAttribute('data-key') + '|' + x.getAttribute('data-id')) >= 0); });
    var sel = dimSel(), d = sel && dimInfo(sel.key, sel.id); if (!d || !d.geo || d.hidden || d.deleted || (S.selDims || []).length > 1) return;
    var G = d.geo, g = svgEl('g', { 'class': 'dimgrips' }, svg), col = d.locked ? '#9AA09C' : '#E8590C', r = 0.9;
    [['a', G.pa], ['b', G.pb]].forEach(function (x) { if (x[1]) svgEl('circle', { cx: x[1][0], cy: x[1][1], r: r, 'class': 'grip', 'data-g': x[0], fill: '#FFF', stroke: col, 'stroke-width': 0.35 }, g); });
    if (G.la && G.lb) { var m = [(G.la[0] + G.lb[0]) / 2, (G.la[1] + G.lb[1]) / 2]; svgEl('rect', { x: m[0] - r, y: m[1] - r, width: 2 * r, height: 2 * r, 'class': 'grip', 'data-g': 'line', fill: '#FFF', stroke: col, 'stroke-width': 0.35 }, g); }
    if (G.tc) svgEl('path', { d: 'M' + G.tc[0] + ' ' + (G.tc[1] - 1.2) + 'l1.2 1.2l-1.2 1.2l-1.2 -1.2z', 'class': 'grip', 'data-g': 'text', fill: '#FFF', stroke: col, 'stroke-width': 0.3 }, g);
  }
  // kéo grip (hoặc chọn từ menu rồi nhấp): start = điểm giấy bắt đầu; xem trước bằng dịch nhóm SVG / nét cam
  function gripStart(sel, gk, start, pick) {
    if (dimLocked(sel)) { msg('DIM đang khóa – chuột phải → Mở khóa DIM để chỉnh.', 'warn'); return null; }
    var d = dimInfo(sel.key, sel.id); if (!d) return null;
    return { mode: 'grip', sel: sel, g: gk, start: start, pick: !!pick, d: d, alt: false };
  }
  function gripEls(dr) {
    var svg = $('paper').querySelector('svg'), d = dr.d, sel = dr.sel, q = '[data-key="' + sel.key + '"][data-id="' + sel.id + '"]';
    if (dr.g === 'text') return Array.prototype.slice.call(svg.querySelectorAll('g.dim' + q + ' text, g.mdim' + q + ' text'));
    if (sel.origin === 'auto' && !d.detached && !d.custom_anchor && !dr.alt)
      return Array.prototype.slice.call(svg.querySelectorAll('g.dimset[data-key="' + sel.key + '"][data-chain="' + d.chain + '"]'));
    return Array.prototype.slice.call(svg.querySelectorAll('g.dim' + q + ', g.mdim' + q));
  }
  function gripMove(dr, e) {
    var pt = toPaper(e), dx = pt[0] - dr.start[0], dy = pt[1] - dr.start[1], d = dr.d; dr.alt = e.altKey;
    dr.pt = pt; dr.moved = dr.moved || Math.abs(dx) + Math.abs(dy) > 0.3;
    var gp = mdPrevGroup(); if (!gp) return;
    if (dr.g === 'a' || dr.g === 'b') {
      var sn = mdSnap(dr.sel.key, pt); dr.sn = sn; mdMarker(gp, dr.sel.key, sn);
      var na = dr.g === 'a' ? sn.p : d.a, nb = dr.g === 'b' ? sn.p : d.b, A = mdToP(dr.sel.key, na), B = mdToP(dr.sel.key, nb);
      svgEl('path', { d: 'M' + A[0] + ' ' + A[1] + 'L' + B[0] + ' ' + B[1], stroke: '#E8590C', 'stroke-width': 0.25, 'stroke-dasharray': '1 0.6' }, gp);
      $('stInfo').textContent = 'Bắt: ' + MD_TYPES[sn.type] + ' · số đo mới ' + mdLabel(MDIM.value(na, nb, d.axis)) + ' mm';
      return;
    }
    var tx = dr.g === 'text' ? [dx, dy] : (d.axis === 'h' ? [0, dy] : [dx, 0]);
    gripEls(dr).forEach(function (el) { el.setAttribute('transform', 'translate(' + tx[0] + ' ' + tx[1] + ')'); });
    $('stInfo').textContent = dr.g === 'text' ? 'Dời chữ DIM – số đo không đổi' : (dr.sel.origin === 'auto' && !d.detached && !d.custom_anchor && !dr.alt ? 'Kéo CẢ CHUỖI DIM (giữ Alt để chỉ kéo đoạn này)' : 'Dời đường DIM – số đo không đổi');
  }
  function gripCommit(dr) {
    var pg0 = mdPrevGroup(); if (pg0) pg0.remove();
    var d = dr.d, sel = dr.sel, p = page();
    if (!dr.moved && !dr.pick) { gripEls(dr).forEach(function (el) { el.removeAttribute('transform'); }); return; }
    var dx = dr.pt[0] - dr.start[0], dy = dr.pt[1] - dr.start[1];
    if (dr.g === 'a' || dr.g === 'b') {
      if (!dr.sn) return;
      var np = dr.sn.p, other = dr.g === 'a' ? 'b' : 'a', mo = sel.origin === 'manual' && mdFind(sel.key, sel.id);
      if (mo && mo.kind === 'clear' && snapSegs(sel.key)) { // DIM thông thủy: điểm mới tự về mặt tấm hướng vào khoảng hở
        var pr = dr.g === 'a' ? MDIM.refineClear(snapSegs(sel.key), np, d.b, d.axis) : MDIM.refineClear(snapSegs(sel.key), d.a, np, d.axis);
        np = dr.g === 'a' ? pr[0] : pr[1];
      }
      if (Math.hypot(np[0] - d[other][0], np[1] - d[other][1]) < 0.5) { msg('Hai điểm bám trùng nhau – giữ nguyên.', 'err'); requestRender(true); return; }
      dimChange(sel, function (o) {
        if (sel.origin === 'auto' && !o.a) { o.a = d.a; o.b = d.b; }
        o[dr.g] = np; o['r' + dr.g] = null; // điểm bám mới: gắn lại liên kết bộ phận; đầu kia giữ nguyên
      }, 'Đã đổi điểm ' + (dr.g === 'a' ? 'đầu' : 'cuối') + ' – số đo mới ' + mdLabel(MDIM.value(dr.g === 'a' ? np : d.a, dr.g === 'b' ? np : d.b, d.axis)) + ' mm (các DIM khác không đổi).');
      return;
    }
    if (dr.g === 'text') {
      var base = [d.tdx || 0, d.tdy || 0];
      if (sel.origin === 'auto' && d.tdx == null && d.tdy == null && d.tid && p.dimtext && p.dimtext[sel.key + '|' + d.tid]) base = p.dimtext[sel.key + '|' + d.tid].slice();
      dimChange(sel, function (o) { o.tdx = Math.round((base[0] + dx) * 100) / 100; o.tdy = Math.round((base[1] + dy) * 100) / 100; }, 'Đã dời chữ DIM – số đo không đổi.');
      return;
    }
    var dl = d.axis === 'h' ? dy : dx;
    if (sel.origin === 'auto' && !d.detached && !d.custom_anchor && !dr.alt) { // cả chuỗi: dời bằng offset chuỗi (như bản cũ)
      snapshot(); p.dimoff = p.dimoff || {}; p.dimoff[sel.key] = p.dimoff[sel.key] || {};
      p.dimoff[sel.key][d.side] = Math.max(-400, Math.min(400, Math.round(((p.dimoff[sel.key][d.side] || 0) + dl) * 100) / 100));
      changed(); requestRender(true); msg('Đã dời cả chuỗi DIM – số đo không đổi, hình không đổi.', 'ok'); return;
    }
    var side = sel.origin === 'auto' ? SIDE_OF[d.side] : d.side, f = frameOf(sel.key);
    var sg = side === 'l' || side === 't' ? -1 : 1;
    dimChange(sel, function (o) {
      if (side === 'in') o.off = Math.round(((+d.off || 0) + dl * f[2]) * 10) / 10;
      else if (d.axis === 'a') o.off = Math.round(((+d.off || 0) + dl) * 10) / 10;
      else o.off = Math.round(((+d.off || 0) + sg * dl) * 100) / 100;
    }, sel.origin === 'auto' ? 'Đã tách & dời riêng đoạn DIM này khỏi chuỗi – số đo không đổi.' : 'Đã dời đường DIM – số đo không đổi.');
  }
  function dimRestore(sel) {
    if (sel.origin === 'auto') {
      snapshot(); var p = page();
      if (p.dim_over && p.dim_over[sel.key]) { delete p.dim_over[sel.key][sel.id]; if (!Object.keys(p.dim_over[sel.key]).length) delete p.dim_over[sel.key]; }
      changed(); requestRender(true); renderMd(); msg('Đã khôi phục DIM tự động (điểm bám, vị trí, nội dung).', 'ok');
    } else dimChange(sel, function (o) { ['text', 'tdx', 'tdy', 'size', 'bold'].forEach(function (f) { delete o[f]; }); }, 'Đã khôi phục chữ DIM về số đo thật.');
  }
  function dimDelete(sel) {
    if (sel.origin === 'manual') { mdDelete(sel.key, sel.id); return; }
    if (dimLocked(sel)) { msg('DIM đang khóa.', 'warn'); return; }
    dimChange(sel, function (o) { o.deleted = true; }, 'Đã xóa đoạn DIM tự động – dựng lại không tạo lại (khôi phục ở bảng DIM & CHỮ, hoặc ↶).');
    S.selDims = [];
  }
  function dimDialog(sel) {
    var d = dimInfo(sel.key, sel.id); if (!d) return;
    dialog('DIM ' + (sel.origin === 'auto' ? 'tự động' : 'thủ công') + ' – ' + viewName(sel.key),
      '<label>Giá trị đo thật (chỉ đọc)</label><input type="text" value="' + esc(mdLabel(d.value)) + ' mm" readonly>' +
      '<label>Nội dung hiển thị <small>(để trống = số đo thật; &lt;&gt; = chèn số đo thật, vd. "&lt;&gt; TT")</small></label><input id="ddText" type="text" value="' + esc(d.text_override || '') + '">' +
      '<div class="row"><div><label>Cỡ chữ (mm)</label><input id="ddSize" type="number" min="1" max="12" step="0.1" value="' + (d.size || 2.2) + '"></div>' +
      '<div><label>Dời chữ X</label><input id="ddTx" type="number" step="0.5" value="' + (d.tdx || 0) + '"></div><div><label>Dời chữ Y</label><input id="ddTy" type="number" step="0.5" value="' + (d.tdy || 0) + '"></div></div>' +
      '<div class="checks"><label><input id="ddBold" type="checkbox"' + (d.bold ? ' checked' : '') + '> Chữ đậm</label><label><input id="ddHide" type="checkbox"' + (d.hidden ? ' checked' : '') + '> Ẩn DIM</label><label><input id="ddLock" type="checkbox"' + (d.locked ? ' checked' : '') + '> Khóa DIM</label></div>' +
      '<p class="hint">Phương đo: ' + MD_AXES[d.axis] + ' · ' + (d.origin === 'auto' ? (d.user_modified ? 'đã chỉnh tay' : 'tự động') + (d.detached ? ' · đã tách khỏi chuỗi' : '') : 'thủ công') +
      (d.status === 'broken' ? ' · <b style="color:#C0392B">MẤT LIÊN KẾT</b>' : '') + '. Font: Noto Sans (nhúng PDF, đủ dấu tiếng Việt).</p>',
      [['Khôi phục tự động', function () { dimRestore(sel); }], ['Hủy'], ['Lưu', function () {
        var t = $('ddText').value.trim(), sz = parseFloat($('ddSize').value), tx = parseFloat($('ddTx').value) || 0, ty = parseFloat($('ddTy').value) || 0;
        var bold = $('ddBold').checked, hide = $('ddHide').checked, lock = $('ddLock').checked;
        dimChange(sel, function (o) {
          o.text = t || null; o.size = sz && Math.abs(sz - 2.2) > 0.01 ? Math.max(1, Math.min(12, sz)) : null;
          o.tdx = tx || null; o.tdy = ty || null; o.bold = bold || null; o.hidden = hide || null; o.locked = lock || null;
          if (sel.origin === 'manual') { o.hidden = hide; o.locked = lock; o.bold = bold; }
        }, 'Đã lưu DIM – số đo thật vẫn là ' + mdLabel(d.value) + ' mm.');
      }, 'gold']]);
    setTimeout(function () { var i = $('ddText'); if (i) { i.focus(); i.onkeydown = function (ev) { if (ev.key === 'Enter') $('dlgBtns').lastChild.click(); }; } }, 30);
  }
  function showDimCtx(x, y, sel) {
    var m = $('ctxMenu'), d = dimInfo(sel.key, sel.id); if (!d) return;
    var h = [], it = function (act, label, on) { h.push('<div class="it' + (on ? ' on' : '') + '" data-act="' + act + '">' + esc(label) + '</div>'); };
    var multi = (S.selDims || []).length > 1;
    h.push('<div class="hd">DIM ' + (d.origin === 'auto' ? 'tự động' : 'thủ công') + ' ' + esc(dimName(d)) + '<small>' + esc(viewName(sel.key)) + (d.locked ? ' · đã khóa' : '') + (d.status === 'broken' ? ' · MẤT LIÊN KẾT' : '') + '</small></div>');
    it('prop', 'Chỉnh DIM… (thuộc tính)');
    if (!d.locked) { it('pa', 'Sửa điểm đầu'); it('pb', 'Sửa điểm cuối'); it('pline', 'Di chuyển đường DIM'); it('ptext', 'Chỉnh vị trí chữ'); }
    it('ptxt', 'Sửa nội dung chữ…');
    if (d.origin === 'auto') {
      if (d.detached) it('attach', 'Đưa về chuỗi DIM'); else if (!d.locked) it('detach', 'Tách khỏi chuỗi (dời riêng đoạn này)');
    }
    if (multi) it('merge', 'Gộp ' + S.selDims.length + ' DIM đã chọn thành 1 chuỗi thẳng hàng');
    it('restore', 'Khôi phục tự động');
    h.push('<div class="sep"></div>');
    it('hide', d.hidden ? 'Hiện DIM' : 'Ẩn DIM'); it('del', 'Xóa DIM'); it('lock', d.locked ? 'Mở khóa DIM' : 'Khóa DIM');
    h.push('<div class="sep"></div>'); it('mdadd', 'Thêm đoạn DIM bị thiếu (2 điểm)'); it('viewmenu', 'Menu hình chiếu…');
    m.innerHTML = h.join(''); m.hidden = false;
    m.style.left = Math.max(4, Math.min(x, window.innerWidth - m.offsetWidth - 4)) + 'px';
    m.style.top = Math.max(4, Math.min(y, window.innerHeight - m.offsetHeight - 4)) + 'px';
    m.onclick = function (e) {
      var a = e.target.closest('[data-act]'); if (!a) return; var act = a.dataset.act; hideCtx();
      var G = d.geo || {};
      if (act === 'prop' || act === 'ptxt') dimDialog(sel);
      else if (act === 'pa' || act === 'pb') { S.pickGrip = gripStart(sel, act.slice(1), [0, 0], true); msg('Nhấp vào cạnh / điểm mới cho điểm ' + (act === 'pa' ? 'đầu' : 'cuối') + ' (Smart Snap). ESC để hủy.', ''); }
      else if (act === 'pline' && G.la) { S.pickGrip = gripStart(sel, 'line', [(G.la[0] + G.lb[0]) / 2, (G.la[1] + G.lb[1]) / 2], true); msg('Nhấp vị trí mới của đường DIM. ESC để hủy.', ''); }
      else if (act === 'ptext' && G.tc) { S.pickGrip = gripStart(sel, 'text', G.tc.slice(), true); msg('Nhấp vị trí mới của chữ DIM. ESC để hủy.', ''); }
      else if (act === 'detach') dimChange(sel, function (o) { o.off = d.off; }, 'Đã tách đoạn khỏi chuỗi – kéo grip vuông để dời riêng.');
      else if (act === 'attach') dimChange(sel, function (o) { delete o.off; }, 'Đã đưa đoạn về chuỗi DIM.');
      else if (act === 'merge') dimMerge();
      else if (act === 'restore') dimRestore(sel);
      else if (act === 'hide') dimChange(sel, function (o) { o.hidden = !d.hidden; }, d.hidden ? 'Đã hiện DIM.' : 'Đã ẩn DIM – hiện lại ở bảng DIM & CHỮ.');
      else if (act === 'del') dimDelete(sel);
      else if (act === 'lock') dimChange(sel, function (o) { o.locked = !d.locked; }, d.locked ? 'Đã mở khóa DIM.' : 'Đã khóa DIM – không kéo/sửa được cho tới khi mở khóa.');
      else if (act === 'mdadd') mdStart(false);
      else if (act === 'viewmenu') { S.ctxParts = []; showCtx(x, y, sel.key, null); }
    };
  }
  // Gộp các DIM đã chọn (cùng phương, cùng phía) về 1 hàng thẳng: lấy vị trí của DIM chọn đầu tiên.
  function dimMerge() {
    var list = (S.selDims || []).map(function (s) { return { s: s, d: dimInfo(s.key, s.id) }; }).filter(function (x) { return x.d; });
    if (list.length < 2) return;
    var t = list[0], side = function (x) { return x.s.origin === 'auto' ? SIDE_OF[x.d.side] : x.d.side; };
    if (list.some(function (x) { return x.s.key !== t.s.key || x.d.axis !== t.d.axis || side(x) !== side(t); })) { msg('Chỉ gộp được các DIM cùng hình, cùng phương đo và cùng phía.', 'err'); return; }
    if (list.some(function (x) { return x.d.locked; })) { msg('Có DIM đang khóa trong nhóm chọn.', 'warn'); return; }
    snapshot();
    list.forEach(function (x) {
      if (x === t) return;
      var o = dimObj(x.s, true); o.off = t.d.off; if (x.s.origin === 'manual') o.side = side(t);
      if (x.s.origin === 'auto') tidyOver(x.s.key, x.s.id);
    });
    changed(); requestRender(true); msg('Đã gộp ' + list.length + ' DIM thành 1 chuỗi thẳng hàng (cách mép ' + mdLabel(t.d.off) + ' mm giấy).', 'ok');
  }
  // nhận lại liên kết bộ phận Ruby vừa gắn cho đoạn tự động đã đổi điểm bám (không tạo bước hoàn tác)
  function dimSync(info) {
    var p = page(); if (!p || !p.dim_over || !info.dims) return;
    var dirty = false;
    Object.keys(info.dims).forEach(function (k) {
      info.dims[k].forEach(function (d) {
        if (d.origin !== 'auto' || !d.custom_anchor) return;
        var o = p.dim_over[k] && p.dim_over[k][d.id]; if (!o) return;
        ['a', 'b', 'ra', 'rb'].forEach(function (f) { if (d[f] !== undefined && JSON.stringify(o[f]) !== JSON.stringify(d[f])) { o[f] = d[f]; dirty = true; } });
      });
    });
    if (dirty) markDirty();
  }

  // ---- chữ: tên hình & chú thích ----
  function capObj(k, create) {
    var p = page(); if (!p) return null;
    if (!p.captions) { if (!create) return null; p.captions = {}; }
    if (!p.captions[k]) { if (!create) return null; p.captions[k] = {}; }
    return p.captions[k];
  }
  function capChange(k, fn, note) {
    snapshot(); var c = capObj(k, true); fn(c);
    Object.keys(c).forEach(function (f) { if (c[f] == null || c[f] === false || c[f] === '') delete c[f]; });
    if (!Object.keys(c).length) delete page().captions[k];
    changed(); requestRender(true); if (note) msg(note, 'ok');
  }
  function noteChange(n, fn, note) { snapshot(); fn(n); renderNotes(); changed(); requestRender(true); if (note) msg(note, 'ok'); }
  // Ô sửa chữ ngay trên bản vẽ: Enter / ✓ lưu, ESC hủy (nhiều dòng: Shift+Enter xuống dòng)
  function inlineEdit(rect, value, multi, done) {
    closeInline();
    var w = document.createElement('div'); w.className = 'inl'; w.id = 'inlEdit';
    var inp = document.createElement(multi ? 'textarea' : 'input'); if (!multi) inp.type = 'text';
    inp.value = value; var ok = document.createElement('button'); ok.textContent = '✓'; ok.title = 'Lưu (Enter)';
    var no = document.createElement('button'); no.textContent = '✕'; no.title = 'Hủy (ESC)';
    w.appendChild(inp); w.appendChild(ok); w.appendChild(no);
    Object.assign(w.style, { left: Math.max(4, rect.left - 4) + 'px', top: Math.max(4, rect.top - 6) + 'px' });
    inp.style.width = Math.max(160, rect.width + 40) + 'px'; if (multi) inp.style.height = Math.max(40, rect.height + 16) + 'px';
    document.body.appendChild(w); inp.focus(); inp.select();
    var fin = function (save) { var v = inp.value; closeInline(); if (save) done(v); };
    ok.onmousedown = function (e) { e.preventDefault(); fin(true); };
    no.onmousedown = function (e) { e.preventDefault(); fin(false); };
    inp.onkeydown = function (e) {
      if (e.key === 'Enter' && !(multi && e.shiftKey)) { e.preventDefault(); fin(true); }
      else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); fin(false); }
    };
  }
  function closeInline() { var w = $('inlEdit'); if (w) w.remove(); }
  function capRect(k) { var g = $('paper').querySelector('g.vcap[data-key="' + k + '"] text'); return g ? g.getBoundingClientRect() : { left: 200, top: 200, width: 100, height: 20 }; }
  function editCaption(k) {
    var c = capObj(k) || {};
    if (c.locked) { msg('Tên hình đang khóa – chuột phải → Mở khóa.', 'warn'); return; }
    inlineEdit(capRect(k), c.text || viewName(k), false, function (v) {
      v = v.trim();
      capChange(k, function (cc) { cc.text = v && v !== viewName(k) ? v : null; }, v && v !== viewName(k) ? 'Đã đổi tên hiển thị "' + v + '" (loại hình nội bộ giữ nguyên: ' + viewName(k) + ').' : 'Đã trả tên hình về mặc định.');
    });
  }
  function editScaleLine(k) {
    var c = capObj(k) || {};
    dialog('Dòng tỷ lệ – ' + viewName(k), '<label>Nội dung <small>({TL} = tỷ lệ thật của hình, vd. "TỶ LỆ {TL}")</small></label><input id="slText" type="text" value="' + esc(c.scale_text || 'TL {TL}') + '">' +
      '<p class="hint">Tỷ lệ in luôn lấy từ tỷ lệ thật (hiện 1:' + effScale(k) + '). Gõ cứng tỷ lệ khác (vd. 1:50) sẽ tự được thay bằng tỷ lệ thật – không in sai tỷ lệ bản vẽ.</p>',
      [['Mặc định', function () { capChange(k, function (cc) { cc.scale_text = null; }); }], ['Hủy'], ['Lưu', function () {
        var v = $('slText').value.trim(); capChange(k, function (cc) { cc.scale_text = v && v !== 'TL {TL}' ? v : null; }, 'Đã sửa dòng tỷ lệ (vẫn bám tỷ lệ thật).');
      }, 'gold']]);
  }
  function editNoteInline(n) {
    if (n.locked) { msg('Chú thích đang khóa – chuột phải → Mở khóa.', 'warn'); return; }
    var g = $('paper').querySelector('g.note[data-id="' + n.id + '"]'), r = g ? g.getBoundingClientRect() : { left: 200, top: 200, width: 100, height: 20 };
    inlineEdit(r, n.text, n.type !== 'text', function (v) { noteChange(n, function (x) { x.text = v; }, 'Đã sửa nội dung chú thích.'); });
  }
  function colorDialog(cur, done) {
    dialog('Màu chữ', '<input id="clr" type="color" value="' + (cur || '#1E1E1E') + '">', [['Hủy'], ['Lưu', function () { done($('clr').value); }, 'gold']]);
  }
  function textCtx(x, y, kind, ref) {
    var m = $('ctxMenu'), h = [], it = function (act, label, on) { h.push('<div class="it' + (on ? ' on' : '') + '" data-act="' + act + '">' + esc(label) + '</div>'); };
    var c = kind === 'cap' ? (capObj(ref) || {}) : ref, size = kind === 'cap' ? (c.size || 3.6) : c.size;
    var align = c.align || (kind === 'cap' ? 'center' : 'left');
    h.push('<div class="hd">' + (kind === 'cap' ? 'Tên hình – ' + esc(viewName(ref)) : 'Chú thích') + '<small>' + (c.locked ? 'đã khóa' : (kind === 'cap' && (c.text || c.dx || c.dy) ? 'đã tùy chỉnh' : '')) + '</small></div>');
    it('edit', 'Sửa nội dung'); if (kind === 'cap') it('scale', 'Sửa dòng tỷ lệ…');
    it('move', 'Di chuyển (nhấp vị trí mới)');
    h.push('<div class="lb">Cỡ chữ (mm)</div><div class="grid">' + [2, 2.5, 3, 3.6, 4.5, 5, 6, 8].map(function (n) { return '<span data-act="sz:' + n + '" class="' + (Math.abs(n - size) < 0.01 ? 'on' : '') + '">' + n + '</span>'; }).join('') + '</div>');
    h.push('<div class="lb">Căn lề</div><div class="grid">' + [['left', 'Trái'], ['center', 'Giữa'], ['right', 'Phải']].map(function (a) { return '<span data-act="al:' + a[0] + '" class="' + (align === a[0] ? 'on' : '') + '">' + a[1] + '</span>'; }).join('') + '</div>');
    it('color', 'Màu…'); it('bold', 'Chữ đậm', !!c.bold); it('font', 'Font: Noto Sans (nhúng PDF, tiếng Việt)');
    h.push('<div class="sep"></div>'); it('lock', c.locked ? 'Mở khóa vị trí chữ' : 'Khóa vị trí chữ'); it('reset', 'Khôi phục mặc định');
    m.innerHTML = h.join(''); m.hidden = false;
    m.style.left = Math.max(4, Math.min(x, window.innerWidth - m.offsetWidth - 4)) + 'px';
    m.style.top = Math.max(4, Math.min(y, window.innerHeight - m.offsetHeight - 4)) + 'px';
    m.onclick = function (e) {
      var a = e.target.closest('[data-act]'); if (!a) return; var act = a.dataset.act; hideCtx();
      var ch = function (fn, note) { if (kind === 'cap') capChange(ref, fn, note); else noteChange(ref, fn, note); };
      if (act === 'font') return;
      if (act === 'edit') { if (kind === 'cap') editCaption(ref); else editNoteInline(ref); }
      else if (act === 'scale') editScaleLine(ref);
      else if (act === 'move') { if (c.locked) { msg('Chữ đang khóa.', 'warn'); return; } S.pickText = { kind: kind, ref: ref }; msg('Nhấp vị trí mới cho chữ. ESC để hủy.', ''); }
      else if (act.indexOf('sz:') === 0) ch(function (o) { o.size = +act.slice(3); });
      else if (act.indexOf('al:') === 0) ch(function (o) { o.align = act.slice(3) === (kind === 'cap' ? 'center' : 'left') ? null : act.slice(3); });
      else if (act === 'color') colorDialog(c.color, function (v) { ch(function (o) { o.color = v; }); });
      else if (act === 'bold') ch(function (o) { o.bold = !o.bold || null; });
      else if (act === 'lock') ch(function (o) { o.locked = !o.locked || null; }, c.locked ? 'Đã mở khóa vị trí chữ.' : 'Đã khóa vị trí chữ.');
      else if (act === 'reset') {
        if (kind === 'cap') capChange(ref, function (o) { Object.keys(o).forEach(function (f) { delete o[f]; }); }, 'Đã trả tên hình, dòng tỷ lệ và vị trí về mặc định.');
        else noteChange(ref, function (o) { o.size = 2.5; o.color = '#1E1E1E'; delete o.align; delete o.bold; delete o.locked; }, 'Đã trả kiểu chữ chú thích về mặc định.');
      }
    };
  }
  function capPaperPos(k) { var b = S.info && S.info.captions && S.info.captions[k]; return b ? [(b[0] + b[2]) / 2, b[1]] : null; }

  // ---------------- ĐO HIỆU NĂNG (v2.16) ----------------
  // Ruby đo model + quét + dựng + vẽ; giao diện đo tiếp FPS zoom / pan / rê chuột Smart Snap trên tờ vừa dựng,
  // rồi ghép báo cáo, hiện bảng và lưu %TEMP%\mt_auto_layout_perf.txt. Chỉ đo, không đổi dự án.
  $('perfBtn').onclick = function () {
    var p = page(); if (!p) return;
    S.perfRun = true;
    msg('Đang đo hiệu năng: đọc lại model từ đầu và dựng lại trang (không sửa model)…', '');
    call('perf', { project: S.project, page_id: p.id, sheet: S.sheet || 0 });
  };
  function raf() { return new Promise(function (r) { requestAnimationFrame(r); }); }
  function frameStats(ts) {
    var a = ts.slice().sort(function (x, y) { return x - y; }), n = a.length, avg = a.reduce(function (x, y) { return x + y; }, 0) / n;
    return { avg: +avg.toFixed(1), p95: +a[Math.max(0, Math.ceil(n * 0.95) - 1)].toFixed(1), max: +a[n - 1].toFixed(1), fps: +(1000 / avg).toFixed(1) };
  }
  async function perfZoom(n) {
    var st = $('stage'), r = st.getBoundingClientRect(), ts = [];
    await raf(); var last = performance.now();
    for (var i = 0; i < n; i++) {
      st.dispatchEvent(new WheelEvent('wheel', { deltaY: i < n / 2 ? -100 : 100, clientX: r.left + r.width * 0.45, clientY: r.top + r.height * 0.5, bubbles: true, cancelable: true }));
      await raf(); var t = performance.now(); ts.push(t - last); last = t;
    }
    var sg = [], s0 = performance.now(), sl = s0;
    while (performance.now() - s0 < 450) { await raf(); var t2 = performance.now(); sg.push(t2 - sl); sl = t2; }
    var o = frameStats(ts); o.commit_max = Math.round(Math.max.apply(null, sg)); return o;
  }
  async function perfPan(n) {
    var ts = [], k0 = [S.panX, S.panY]; await raf(); var last = performance.now();
    for (var i = 0; i < n; i++) { S.panX += 6; S.panY += 2; applyView(); await raf(); var t = performance.now(); ts.push(t - last); last = t; }
    S.panX = k0[0]; S.panY = k0[1]; applyView(true); return frameStats(ts);
  }
  async function perfSnap(n) {
    var keys = Object.keys((S.info && S.info.snap) || {}); if (!keys.length) return null;
    var k = keys[0], t0 = performance.now();
    while (!mdIndex(k) && performance.now() - t0 < 4000) await raf(); // chờ Ruby gửi hình học bắt điểm
    var load = Math.round(performance.now() - t0), f = frameOf(k); if (!f || !mdIndex(k)) return { view: k, load_ms: load };
    var hs = [], ts = []; await raf(); var last = performance.now();
    for (var i = 0; i < n; i++) {
      var pt = [f[0] + (f[3] / f[2]) * (0.1 + 0.8 * i / n), f[1] + (f[4] / f[2]) * (0.2 + 0.6 * ((i * 7) % n) / n)];
      var h0 = performance.now(); mdSnap(k, pt); hs.push(performance.now() - h0);
      await raf(); var t = performance.now(); ts.push(t - last); last = t;
    }
    var o = frameStats(ts), hsa = hs.slice().sort(function (x, y) { return x - y; });
    o.view = k; o.load_ms = load; o.snap_avg_ms = +(hs.reduce(function (x, y) { return x + y; }, 0) / n).toFixed(2); o.snap_max_ms = +hsa[n - 1].toFixed(2);
    return o;
  }
  function pad(x, n) { x = String(x); while (x.length < n) x += ' '; return x; }
  async function perfUi(rep) {
    if (!S.perfRun) return; S.perfRun = false;
    await new Promise(function (r) { setTimeout(r, 300); }); // chờ tờ mới hiển thị xong
    var z = await perfZoom(30), pn = await perfPan(30), sn = await perfSnap(40), m = rep.model || {}, L = [];
    L.push('ĐO HIỆU NĂNG AUTO LAYOUT PRO v' + rep.plugin + ' – SketchUp ' + rep.sketchup + ' (Ruby ' + rep.ruby + ') – ' + new Date().toLocaleString('vi-VN'));
    L.push('Model: ' + rep.name);
    L.push('  Faces ' + m.faces + ' · Edges ' + m.edges + ' (mềm/mịn ' + (m.edges_soft || 0) + ', ẩn ' + (m.edges_hidden || 0) + ') · Groups ' + (m.groups || 0) +
           ' · ComponentInstances ' + (m.components || 0) + ' · Definitions ' + m.definitions + ' · lồng ' + (m.depth || 0) + ' cấp · đếm ' + m.count_ms + ' ms');
    L.push('Thời gian dựng (đọc lại từ đầu): tổng ' + rep.wall_ms + ' ms (CPU ' + rep.cpu_ms + ' ms)');
    Object.keys(rep.timings_ms).forEach(function (k) { if (rep.timings_ms[k] >= 1) L.push('  ' + pad(k, 34) + rep.timings_ms[k] + ' ms'); });
    if (rep.warm_ms != null) {
      L.push('Dựng lại khi model KHÔNG đổi (dùng cache – như sửa DIM/chữ, dời hình, chuyển tờ, mở lại cửa sổ): ' + rep.warm_ms + ' ms');
      Object.keys(rep.warm_timings_ms || {}).forEach(function (k) { L.push('  ' + pad(k, 34) + rep.warm_timings_ms[k] + ' ms'); });
    }
    L.push('Hình chiếu (nét thấy / chuỗi nét / mảng tô / nét cắt / mức khử nét):');
    rep.views.forEach(function (v) { L.push('  ' + pad(v.name, 26) + pad(v.lines, 8) + pad(v.chains, 7) + pad(v.fills, 8) + pad(v.cut, 6) + 'mức ' + v.level); });
    L.push('Tờ (SVG KB / số <path> / tổng phần tử / gói gửi giao diện KB / hình học bắt điểm KB – chỉ gửi khi cần):');
    rep.sheets.forEach(function (x) { L.push('  tờ ' + (x.sheet + 1) + ': ' + x.svg_kb + ' KB · ' + x.paths + ' path · ' + x.elements + ' phần tử · ' + x.info_kb + ' KB · ' + x.snap_kb + ' KB'); });
    L.push('Giao diện (đo trong cửa sổ plugin): phần tử trên giấy ' + document.querySelectorAll('#paper *').length);
    L.push('  Zoom liên tục 30 nấc: ' + z.fps + ' FPS (khung TB ' + z.avg + ' ms, p95 ' + z.p95 + ', max ' + z.max + ' ms; khung chốt nét sau khi dừng ' + z.commit_max + ' ms)');
    L.push('  Pan 30 bước: ' + pn.fps + ' FPS (TB ' + pn.avg + ' ms, max ' + pn.max + ' ms)');
    if (sn && sn.fps) L.push('  Smart Snap rê chuột 40 bước (' + viewName(sn.view) + '): ' + sn.fps + ' FPS · tính bắt điểm TB ' + sn.snap_avg_ms + ' ms, max ' + sn.snap_max_ms + ' ms · tải hình học ' + sn.load_ms + ' ms');
    var text = L.join('\n');
    dialog('Đo hiệu năng – ' + rep.name, '<textarea id="perfTxt" readonly style="width:100%;height:340px;font:12px Consolas,monospace;white-space:pre">' + esc(text) + '</textarea>',
      [['Sao chép', function () { var t = $('perfTxt'); t.select(); document.execCommand('copy'); msg('Đã sao chép báo cáo.', 'ok'); return false; }], ['Đóng', null, 'gold']]);
    call('perf_save', { text: text });
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
    S.info = info; S.mdIdx = {};
    if (S.openedPage !== S.cur) { S.snapData = {}; S.snapReq = {}; S.openedPage = S.cur; } // đổi trang: bỏ dữ liệu bắt điểm cũ
    if (S.tool === 'mdim' || S.tool === 'edit' || (S.selDims && S.selDims.length)) setTimeout(snapPrefetch, 0);
    mdSync(info); dimSync(info);
    if (S.selDims) S.selDims = S.selDims.filter(function (x) { return !!dimInfo(x.key, x.id); });
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
    // KHÔNG ghi đè p.offsets từ kết quả dựng: kết quả chỉ chứa hình của tờ đang xem (lỗi cũ: chuyển tờ làm mất vị trí).
    // CHỐT bố cục: hình chưa có toạ độ lưu -> ghi vị trí plugin vừa đặt (trạng thái "Tự động"). Từ đó không tính lại
    // khi chuyển tờ, chuyển model, thêm model, mở lại hay xuất PDF – chỉ "Dàn trang lại" mới đổi.
    if (p && info.layout) {
      var froze = 0;
      Object.keys(info.layout).forEach(function (k) {
        var cur = vprops(k);
        if (cur && cur.x_mm != null) {
          if (cur.sheet !== info.layout[k][2]) { cur.sheet = info.layout[k][2]; froze++; } // đồng bộ số tờ khi tờ trống bị gộp
          if (!cur.scale_override && !cur.base_scale && info.layout[k][5]) { cur.base_scale = info.layout[k][5]; froze++; } // chốt tỉ lệ theo trang
          return;
        }
        var v = vprops(k, true), L = info.layout[k];
        v.placement_mode = 'auto'; v.x_mm = L[0]; v.y_mm = L[1]; v.sheet = L[2]; froze++;
        if (!v.scale_override && L[5]) v.base_scale = L[5];
      });
      if (froze) markDirty();
    }
    if (S.pendingPlace && info.no_room && info.no_room.indexOf(S.pendingPlace) >= 0) noRoomDialog(S.pendingPlace);
    else if (S.pendingCheck) conflictCheck(S.pendingCheck, info);
    S.pendingPlace = null; S.pendingCheck = null;
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
    // vùng bấm rộng cho DIM thủ công (nét DIM rất mảnh)
    svgEl.querySelectorAll('g.mdim, g.dim').forEach(function (g) {
      try {
        var bb = g.getBBox(), hr = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
        hr.setAttribute('x', bb.x - 0.8); hr.setAttribute('y', bb.y - 0.8); hr.setAttribute('width', bb.width + 1.6); hr.setAttribute('height', bb.height + 1.6);
        hr.setAttribute('fill', 'transparent'); hr.setAttribute('class', 'mdhit'); g.insertBefore(hr, g.firstChild);
      } catch (er) { /* getBBox lỗi khi SVG chưa hiển thị – bỏ qua */ }
    });
    if (!S.fitted) { fit(); S.fitted = true; } else applyView(true);
    overlay(); renderSyms();
    highlight(); renderMd();
    var paperName = S.project.paper;
    $('stInfo').textContent = paperName + ' ngang · TL ' + (info.scale_label || '1:' + info.scale) + ' · ' + (info.ms || 0) + ' ms';
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
  // ZOOM/PAN BẰNG VIEWPORT TRANSFORM (v2.16). Lỗi cũ: mỗi nấc lăn chuột đổi width/height của tờ giấy -> trình duyệt
  // dàn lại & vẽ lại TOÀN BỘ SVG (hàng chục nghìn nét/mảng tô) ngay trong sự kiện -> giật, ~2 khung/giây trên model cong.
  // Nay: trong lúc zoom/pan chỉ đổi CSS transform (GPU ghép lớp, không vẽ lại, gộp theo requestAnimationFrame);
  // dừng tay 160 ms mới "chốt" kích thước thật 1 lần để nét sắc lại. Không dựng lại model, không gọi Ruby.
  function frameMove(fn, e) {
    S.mvFn = fn; S.mvEvt = e;
    if (!S.mvRaf) S.mvRaf = requestAnimationFrame(function () { S.mvRaf = 0; var f = S.mvFn; S.mvFn = null; if (f) f(S.mvEvt); });
  }
  function applyView(now) {
    if (now) { commitView(); return; }
    if (!S.viewRaf) S.viewRaf = requestAnimationFrame(paintView);
    clearTimeout(S.viewIdle); S.viewIdle = setTimeout(commitView, 160);
  }
  function paintView() {
    S.viewRaf = 0;
    if (!S.kc) { commitView(); return; }
    var el = $('paper');
    el.style.transform = 'translate(' + S.panX + 'px,' + S.panY + 'px) scale(' + (S.k / S.kc) + ')';
  }
  function commitView() {
    clearTimeout(S.viewIdle); if (S.viewRaf) { cancelAnimationFrame(S.viewRaf); S.viewRaf = 0; }
    var ps = paperSize(), el = $('paper');
    if (S.kc !== S.k || el.dataset.w !== String(ps[0])) {
      el.style.width = (ps[0] * S.k) + 'px'; el.style.height = (ps[1] * S.k) + 'px'; S.kc = S.k; el.dataset.w = String(ps[0]);
    }
    el.style.left = '0px'; el.style.top = '0px';
    el.style.transform = 'translate(' + S.panX + 'px,' + S.panY + 'px)';
    var svg = el.querySelector('svg'); if (svg) { svg.style.width = '100%'; svg.style.height = '100%'; }
  }
  function fit() {
    var st = $('stage'), ps = paperSize();
    S.k = Math.max(0.3, Math.min((st.clientWidth - 40) / ps[0], (st.clientHeight - 40) / ps[1]));
    S.panX = (st.clientWidth - ps[0] * S.k) / 2; S.panY = (st.clientHeight - ps[1] * S.k) / 2;
    applyView(true);
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
    if (e.button === 0 && !spaceDown && S.cur && S.tool === 'mdim') { mdClick(e); e.preventDefault(); return; }
    if (e.button === 0 && S.pickGrip) { // "Sửa điểm đầu/cuối", "Di chuyển đường DIM", "Chỉnh vị trí chữ" từ menu
      var pk = S.pickGrip; S.pickGrip = null; pk.pt = toPaper(e); pk.moved = true;
      if (pk.g === 'a' || pk.g === 'b') pk.sn = mdSnap(pk.sel.key, pk.pt);
      gripCommit(pk); e.preventDefault(); return;
    }
    if (e.button === 0 && S.pickText) {
      var pt3 = toPaper(e), tk = S.pickText; S.pickText = null;
      if (tk.kind === 'cap') { var cp0 = capPaperPos(tk.ref); if (cp0) capChange(tk.ref, function (c) { c.dx = Math.round(((c.dx || 0) + pt3[0] - cp0[0]) * 100) / 100; c.dy = Math.round(((c.dy || 0) + pt3[1] - cp0[1]) * 100) / 100; }, 'Đã dời tên hình.'); }
      else noteChange(tk.ref, function (n) { n.x = pt3[0]; n.y = pt3[1]; }, 'Đã dời chú thích.');
      e.preventDefault(); return;
    }
    if (e.button === 0 && !spaceDown && S.cur && /^(text|mtext|leader|material|detail)$/.test(S.tool)) {
      var pt = toPaper(e);
      if (S.tool === 'text' || S.tool === 'mtext') { addNote(S.tool, pt); setTool('select'); }
      else if (S.tool === 'leader' || S.tool === 'material') {
        if (!place) { place = { tip: pt, el: ghost('tip-dot', { left: e.clientX - $('stage').getBoundingClientRect().left + 'px', top: e.clientY - $('stage').getBoundingClientRect().top + 'px' }) }; msg('Bấm vị trí đặt chữ.', ''); }
        else { place.el.remove(); var tool = S.tool; var tip = place.tip; place = null; addNote(tool, pt, tip); setTool('select'); }
      } else if (S.tool === 'detail') {
        // hình nguồn = hình có VÙNG VẼ chứa điểm bấm (không theo khung DIM của hình bên cạnh)
        var vk = viewAtPaper(pt);
        if (!vk) { msg('Kéo khung bắt đầu từ bên trong phần hình vẽ của một hình chiếu hoặc mặt cắt.', 'err'); return; }
        var r = $('stage').getBoundingClientRect();
        drag = { mode: 'detail', key: vk, a: pt, b: pt, x: e.clientX, y: e.clientY,
                 el: ghost('ghost-rect', { left: (e.clientX - r.left) + 'px', top: (e.clientY - r.top) + 'px', width: '0', height: '0' }) };
      }
      e.preventDefault(); return;
    }
    if (e.button === 0 && S.pickCut) { // đặt lại vị trí đường cắt của chi tiết cấu tạo
      var pd = (page().details || []).filter(function (x) { return x.n === S.pickCut; })[0], pf = pd && S.info.frames[pd.src];
      S.pickCut = null;
      if (pf) {
        var pp = toPaper(e), pu = (pp[0] - pf[0]) * pf[2], pv = (pp[1] - pf[1]) * pf[2], R0 = pd.rect, o = (pd.cut || {}).orient || 'v';
        var at = o === 'v' ? Math.max(R0[0], Math.min(R0[2], pu)) : Math.max(R0[1], Math.min(R0[3], pv));
        editDetail(pd.n, function (d) { d.cut = Object.assign({}, d.cut || {}, { at: Math.round(at * 10) / 10 }); });
        msg('Đã đặt lại đường cắt.', 'ok');
      }
      e.preventDefault(); return;
    }
    var dh = e.button === 0 && e.target.classList && e.target.classList.contains('dh');
    if (dh) {
      drag = { mode: 'dethandle', c: +e.target.getAttribute('data-c'), el: e.target, x: e.clientX, y: e.clientY, n: S.selDet };
      e.preventDefault(); e.stopPropagation(); return;
    }
    var dmk = e.button === 0 && S.tool === 'select' && !spaceDown && e.target.closest && e.target.closest('g.detmark');
    if (dmk) { S.selDet = +dmk.getAttribute('data-det'); overlay(); msg('Kéo các ô vuông ở góc để chỉnh lại vùng trích (vùng lưu theo toạ độ của hình nguồn).', ''); e.preventDefault(); return; }
    if (e.button === 0 && S.selDet && !(e.target.closest && e.target.closest('g.edhandles'))) { S.selDet = null; overlay(); }
    var grip = e.button === 0 && e.target.classList && e.target.classList.contains('grip');
    if (grip && dimSel()) {
      var gd0 = gripStart(dimSel(), e.target.getAttribute('data-g'), toPaper(e), false); if (gd0) drag = gd0;
      e.preventDefault(); e.stopPropagation(); return;
    }
    var gdim = e.button === 0 && (S.tool === 'select' || S.tool === 'edit') && !spaceDown && e.target.closest && e.target.closest('g.dim, g.mdim');
    if (gdim) {
      var sl = selOf(gdim); selectDim(sl, e.shiftKey); S.sel = null; highlight();
      if (!e.shiftKey) {
        var onTxt = e.target.tagName === 'text' || !!(e.target.closest && e.target.closest('g.dimtxt'));
        var gd1 = gripStart(sl, onTxt ? 'text' : 'line', toPaper(e), false); if (gd1) drag = gd1;
      }
      msg('DIM ' + (sl.origin === 'auto' ? 'tự động' : 'thủ công') + ' đã chọn: kéo grip ○ để đổi điểm bám, □ để dời đường DIM' + (sl.origin === 'auto' ? ' (cả chuỗi; giữ Alt = riêng đoạn)' : '') +
          ', ◇ để dời chữ. Nhấp đúp = thuộc tính, Delete = xóa, chuột phải = menu. Shift+nhấp để chọn nhiều.', '');
      e.preventDefault(); e.stopPropagation(); return;
    }
    if (e.button === 0 && S.selDims && S.selDims.length && !(e.target.closest && e.target.closest('g.dimgrips'))) clearDimSel();
    var gcap = e.button === 0 && S.tool === 'edit' && !spaceDown && e.target.closest && e.target.closest('g.vcap');
    if (gcap) {
      var ck = gcap.getAttribute('data-key'); S.selCap = ck;
      if ((capObj(ck) || {}).locked) { msg('Tên hình đang khóa vị trí – chuột phải → Mở khóa.', 'warn'); e.preventDefault(); return; }
      drag = { mode: 'cap', key: ck, g: gcap, x: e.clientX, y: e.clientY, dx: 0, dy: 0 };
      msg('Kéo để dời tên hình (chỉ chữ di chuyển). Nhấp đúp để sửa nội dung.', ''); e.preventDefault(); e.stopPropagation(); return;
    }
    var gn = e.button === 0 && (S.tool === 'select' || S.tool === 'edit') && !spaceDown && e.target.closest && e.target.closest('g.note');
    if (gn) {
      S.selNote = gn.getAttribute('data-id'); S.sel = null; highlight(); renderNotes();
      var n = selNote(), pt2 = toPaper(e);
      if (n && n.locked) { msg('Chú thích đang khóa vị trí – chuột phải → Mở khóa.', 'warn'); e.preventDefault(); return; }
      var nearTip = n && (n.type === 'leader' || n.type === 'material') && Math.hypot(pt2[0] - n.tx, pt2[1] - n.ty) < 2.5;
      drag = { mode: nearTip ? 'tip' : 'note', g: gn, x: e.clientX, y: e.clientY, dx: 0, dy: 0 };
      e.preventDefault(); return;
    }
    var ds = e.button === 0 && (S.tool === 'select' || S.tool === 'edit') && !spaceDown && e.target.closest && e.target.closest('g.dimset');
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
    if (S.tool === 'edit') { e.preventDefault(); return; } // chế độ CHỈNH DIM & CHỮ: không kéo hình chiếu
    if (posLocked(S.sel)) { msg(viewName(S.sel) + ' đang khóa vị trí (chuột phải để mở khóa).', 'warn'); e.preventDefault(); return; }
    drag = { mode: 'move', g: g, x: e.clientX, y: e.clientY, dx: 0, dy: 0 };
    e.preventDefault();
  });
  window.addEventListener('mousemove', function (e) {
    window.__lastX = e.clientX; window.__lastY = e.clientY;
    // Smart Snap / kéo grip: tối đa 1 lần tính mỗi khung hình (sự kiện chuột dồn dập chỉ lấy sự kiện cuối)
    if (!drag && S.tool === 'mdim' && S.md) { frameMove(function (ev) { if (S.tool === 'mdim' && S.md) mdMove(ev); }, e); return; }
    if (!drag && S.pickGrip) { frameMove(function (ev) { if (S.pickGrip) gripMove(S.pickGrip, ev); }, e); return; }
    if (!drag) return;
    if (drag.mode === 'grip') { var dg = drag; frameMove(function (ev) { if (drag === dg) gripMove(dg, ev); }, e); return; }
    if (drag.mode === 'cap') {
      drag.dx = (e.clientX - drag.x) / S.k; drag.dy = (e.clientY - drag.y) / S.k;
      drag.g.setAttribute('transform', 'translate(' + drag.dx + ' ' + drag.dy + ')'); return;
    }
    if (drag.mode === 'pan') {
      S.panX = drag.px + e.clientX - drag.x; S.panY = drag.py + e.clientY - drag.y; applyView();
    } else if (drag.mode === 'dethandle') {
      var pp = toPaper(e); drag.p = pp;
      drag.el.setAttribute('x', pp[0] - 1.2); drag.el.setAttribute('y', pp[1] - 1.2);
    } else if (drag.mode === 'detail') {
      drag.b = toPaper(e); // điểm cuối tính đúng như điểm đầu (zoom/pan/CSS) – không cộng dồn pixel
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
    if (S.mvFn) { var mf = S.mvFn; S.mvFn = null; mf(S.mvEvt); } // xử lý nốt lần di chuột cuối trước khi chốt
    var d = drag; drag = null; $('stage').classList.remove('panning');
    if (d.mode === 'grip') { gripCommit(d); return; }
    if (d.mode === 'cap') {
      if (Math.abs(d.dx) < 0.2 && Math.abs(d.dy) < 0.2) { d.g.removeAttribute('transform'); return; }
      capChange(d.key, function (c) { c.dx = Math.round(((c.dx || 0) + d.dx) * 100) / 100; c.dy = Math.round(((c.dy || 0) + d.dy) * 100) / 100; }, 'Đã dời tên hình – hình chiếu và DIM không đổi.');
      return;
    }
    if (d.mode === 'dethandle') {
      if (!d.p) return;
      var dd = (page().details || []).filter(function (x) { return x.n === d.n; })[0], ff = dd && S.info.frames[dd.src]; if (!ff) return;
      var u = Math.max(0, Math.min(ff[3], (d.p[0] - ff[0]) * ff[2])), w2 = Math.max(0, Math.min(ff[4], (d.p[1] - ff[1]) * ff[2]));
      var R = dd.rect.slice();
      if (d.c === 0) { R[0] = u; R[1] = w2; } else if (d.c === 1) { R[2] = u; R[1] = w2; } else if (d.c === 2) { R[2] = u; R[3] = w2; } else { R[0] = u; R[3] = w2; }
      var nr = [Math.min(R[0], R[2]), Math.min(R[1], R[3]), Math.max(R[0], R[2]), Math.max(R[1], R[3])].map(function (x) { return Math.round(x * 10) / 10; });
      if (nr[2] - nr[0] < 2 || nr[3] - nr[1] < 2) { overlay(); return; }
      snapshot(); dd.rect = nr; changed(); requestRender(true);
      msg('Đã chỉnh vùng trích ' + viewName('det:' + dd.n) + ' (tỷ lệ chi tiết giữ nguyên).', 'ok');
      return;
    }
    if (d.mode === 'detail') {
      d.el.remove(); setTool('select');
      addDetail(d.key, d.a, d.b);
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
      var gv = d.g.closest('g.view'), fv = gv && frameOf(gv.getAttribute('data-key'));
      var ks = fv ? fv[2] : S.info.scale; // tỉ lệ in thật của hình chứa đường cắt
      sc.pos = Math.round((sc.pos + (d.axis === 'x' ? d.dx : -d.dy) * ks) * 10) / 10;
      sc.auto = false; renderSections(); changed(); requestRender(true);
      return;
    }
    if (d.mode === 'move' && (Math.abs(d.dx) > 0.3 || Math.abs(d.dy) > 0.3)) {
      snapshot();
      var b0 = S.info.boxes[S.sel];
      if (b0) placeManual(S.sel, b0[0] + d.dx, b0[1] + d.dy);
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
    if (e.key === 'Escape') {
      // ESC lần lượt: đóng menu / hủy thao tác đang chọn điểm -> rồi mới thoát công cụ về Chọn
      if (Date.now() - (S.ctxClosed || 0) < 80) return;
      if (S.pickGrip || S.pickText) { S.pickGrip = null; S.pickText = null; var pg1 = mdPrevGroup(); if (pg1) pg1.remove(); msg('Đã hủy.', ''); return; }
      setTool('select');
    }
    if (e.key === 'PageDown') { e.preventDefault(); gotoRow(curRowIndex(sheetRows()) + 1); }
    if (e.key === 'PageUp') { e.preventDefault(); gotoRow(curRowIndex(sheetRows()) - 1); }
    if ((e.key === 'Delete' || e.key === 'Backspace') && S.selNote) { e.preventDefault(); deleteNote(); return; }
    if ((e.key === 'Delete' || e.key === 'Backspace') && S.selDims && S.selDims.length) {
      e.preventDefault(); var dl0 = S.selDims.slice(); dl0.forEach(function (x) { dimDelete(x); }); S.selDims = []; return;
    }
    if (e.key === 'e' || e.key === 'E') setTool('edit');
    if (e.key === 'm' || e.key === 'M') mdStart(false);
    if (S.sel && /^Arrow/.test(e.key)) {
      e.preventDefault();
      if (posLocked(S.sel)) { msg(viewName(S.sel) + ' đang khóa vị trí.', 'warn'); return; }
      var bk = S.info && S.info.boxes[S.sel]; if (!bk) return;
      snapshot();
      var st = e.shiftKey ? 10 : 1;
      var dx = e.key === 'ArrowLeft' ? -st : e.key === 'ArrowRight' ? st : 0;
      var dy = e.key === 'ArrowUp' ? -st : e.key === 'ArrowDown' ? st : 0;
      var v0 = vprops(S.sel);
      placeManual(S.sel, (isManual(S.sel) ? v0.x_mm : bk[0]) + dx, (isManual(S.sel) ? v0.y_mm : bk[1]) + dy);
      S.info.boxes[S.sel] = [bk[0] + dx, bk[1] + dy, bk[2], bk[3]]; changed();
    }
  });
  document.addEventListener('keyup', function (e) {
    if (e.key === ' ') { spaceDown = false; if (S.tool !== 'pan') $('stage').classList.remove('pan'); }
  });
  function setTool(t) {
    if (place) { place.el.remove(); place = null; }
    if (t === 'mdim') { S.md = { step: 0 }; S.mdGap = false; } else if (S.md) { mdCancel(); }
    if (t === 'mdim' || t === 'edit') snapPrefetch();
    if (S.pickGrip || S.pickText) { S.pickGrip = null; S.pickText = null; var pgx = mdPrevGroup(); if (pgx) pgx.remove(); }
    closeInline();
    $('stage').classList.toggle('editmode', t === 'edit');
    S.tool = t;
    $('stage').classList.toggle('place', /^(text|mtext|leader|material|detail|mdim)$/.test(t));
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

  $('refresh').onclick = function () { if (!S.cur) return; busy(true); call('refresh', { project: S.project, page_id: S.cur, sheet: S.sheet || 0 }); };
  $('save').onclick = save;
  $('pdfPage').onclick = function () { if (S.cur) call('export_pdf', { project: S.project, page_ids: [S.cur], sheet: S.sheet || 0 }); };
  $('pdfAll').onclick = function () { call('export_pdf', { project: S.project, page_ids: [] }); };
  $('svgPage').onclick = function () { if (S.cur) call('export_svg', { project: S.project, page_id: S.cur, sheet: S.sheet || 0 }); };
  $('openJson').onclick = function () { call('open_json', null); };
  $('saveJson').onclick = function () { call('save_json', S.project); };
  window.addEventListener('resize', function () { if (S.cur) applyView(true); });

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
    busy(true); call('add_models', { project: S.project, pids: pids });
  };
  // ＋ Thêm model (thanh công cụ): đọc selection hiện tại rồi thêm ngay các model mới
  $('addModels').onclick = function () { S.pendingAdd = true; call('scan', S.project); };
  $('relayoutBtn').onclick = relayoutDialog;

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
    var before = JSON.stringify([p.scale, p.front, p.views]);
    snapshot();
    p.name = $('pgName').value;
    if ($('pgNo').value !== curCode()) { p.sheet_no = $('pgNo').value; p.auto_no = false; }
    p.scale = parseInt($('pgScale').value, 10);
    p.front = $('pgFront').value; p.views = getChecks($('pgViews'));
    p.front_dims = $('pgFrontDims').value;
    p.min_gap = parseFloat($('pgGap').value) || 0; p.round = parseFloat($('pgRound').value) || 1;
    p.fill = $('pgFill').checked; p.dims = $('pgDims').checked;
    p.iso_mode = $('pgIsoMode').value; p.iso_hidden = $('pgIsoHidden').checked;
    // Đổi tỉ lệ / hình chiếu / hướng của CHÍNH trang này: hỏi có dàn lại các hình tự động không (hình chỉnh tay & khóa giữ nguyên)
    if (before !== JSON.stringify([p.scale, p.front, p.views])) {
      // Tỉ lệ trang mới chỉ áp cho hình THEO TRANG (không có tỉ lệ riêng / không khóa); vị trí giữ nguyên,
      // dựng xong kiểm tra chồng hình / tràn giấy và hỏi cách xử lý – không tự ép tỉ lệ cho vừa.
      Object.keys(p.view_props || {}).forEach(function (k) { var v = p.view_props[k]; if (!v.scale_override) v.base_scale = null; });
      S.pendingCheck = { kind: 'page' };
    }
    renderPages(); changed();
  }
  ['pgName', 'pgNo', 'pgScale', 'pgFront', 'pgFrontDims', 'pgViews', 'pgGap', 'pgRound', 'pgFill', 'pgDims', 'pgIsoMode', 'pgIsoHidden'].forEach(function (id) {
    $(id).addEventListener('change', readPage);
  });
  $('pgPick').onclick = function () { var p = page(); if (p) call('pick', String(p.pid)); };
  $('pgReset').onclick = function () { relayoutDialog(); };

  // Khung tên
  $('tbForm').addEventListener('change', function (e) {
    var k = e.target.dataset.tb; if (!k) return;
    snapshot(); S.project.tb[k] = e.target.value; changed();
  });

  window.addEventListener('beforeunload', function (e) { if (S.dirty) { e.returnValue = 'Dự án chưa lưu chính thức (đã có bản nháp tự động).'; } });
  window.onload = function () { call('ready', null); };
})();
