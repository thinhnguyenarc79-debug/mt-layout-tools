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
    else if (vprops(k)) { vprops(k).scale_override = null; tidyProps(k); }
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
  function renderSyms() {
    var p = page(), box = $('symList'); if (!box) return;
    var list = p ? doorList() : [];
    var ds = (p && p.door_symbols) || {};
    box.innerHTML = list.length ? list.map(function (d) {
      var cur = ds[d.path] || {}, t = cur.type || 'none';
      return '<div class="it" data-path="' + esc(d.path) + '"><span class="nm" title="' + esc(d.path) + '">' + esc(d.name) + '</span>' +
        '<select class="sym">' + Object.keys(DOOR_TYPES).map(function (x) { return '<option value="' + x + '"' + (x === t ? ' selected' : '') + '>' + DOOR_TYPES[x] + '</option>'; }).join('') + '</select>' +
        '<input class="vis" type="checkbox" title="Hiện ký hiệu"' + (cur.visible === false ? '' : ' checked') + '></div>';
    }).join('') : '<p class="hint">Chưa có cánh trên trang này (gán vai trò "Cánh" ở mục CẤU TẠO TỦ).</p>';
  }
  $('symList').addEventListener('change', function (e) {
    var it = e.target.closest('.it'); if (!it) return;
    if (e.target.classList.contains('sym')) setDoorSym(it.dataset.path, { type: e.target.value });
    if (e.target.classList.contains('vis')) setDoorSym(it.dataset.path, { visible: e.target.checked });
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
  function hideCtx() { var m = $('ctxMenu'); m.hidden = true; m.innerHTML = ''; }
  function showCtx(x, y, k, door) {
    var m = $('ctxMenu'), lk = scaleLocked(k), v = vprops(k) || {}, eff = effScale(k), h = [];
    var it = function (act, label, opts) {
      opts = opts || {};
      h.push('<div class="it' + (opts.off ? ' off' : '') + (opts.on ? ' on' : '') + '" data-act="' + act + '"' + (opts.title ? ' title="' + esc(opts.title) + '"' : '') + '>' + esc(label) + '</div>');
    };
    h.push('<div class="hd">' + esc(viewName(k)) + '<small>TL 1:' + eff + (lk ? ' · đã khóa' : v.scale_override ? ' · riêng' : '') + '</small></div>');
    if (door) {
      var cur = ((page().door_symbols || {})[door.path] || {}).type || 'none';
      h.push('<div class="lb">Ký hiệu cánh – ' + esc(door.name) + '</div>');
      Object.keys(DOOR_TYPES).forEach(function (t) { it('door:' + t, DOOR_TYPES[t], { on: t === cur }); });
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
      h.push('<div class="sep"></div>');
      it('drename', 'Đổi tên chi tiết…'); it('dreselect', 'Chọn lại vùng trích chi tiết');
    }
    h.push('<div class="lb">' + (isDet ? 'Chuyển chi tiết sang trang' : 'Chuyển sang trang khác') + '</div>' + sheetGrid('mv:', S.sheet || 0));
    h.push('<div class="lb">' + (isDet ? 'Tạo bản sao chi tiết sang trang' : 'Tạo bản sao sang trang khác') + '</div>' + sheetGrid('cp:', null));
    it('copyhere', 'Tạo bản sao tại trang này');
    it('clip', 'Sao chép (để dán ở trang khác)');
    if (!isDet) { it('refreshv', 'Cập nhật hình chiếu'); it('mkdet', 'Tạo chi tiết phóng to từ hình này'); }
    it('delv', isDet ? 'Xóa chi tiết' : 'Xóa hình chiếu');
    h.push('<div class="sep"></div>');
    it('relayout', 'Dàn trang lại…');
    m.innerHTML = h.join(''); m.hidden = false;
    var w = m.offsetWidth, hh = m.offsetHeight;
    m.style.left = Math.max(4, Math.min(x, window.innerWidth - w - 4)) + 'px';
    m.style.top = Math.max(4, Math.min(y, window.innerHeight - hh - 4)) + 'px';
    m.onclick = function (e) {
      var a = e.target.closest('[data-act]'); if (!a || a.classList.contains('off') || a.parentNode.classList.contains('off')) return;
      var act = a.dataset.act; hideCtx();
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
      else if (act === 'mkdet') { setTool('detail'); msg('Kéo khung quanh vị trí cần phóng to trên ' + viewName(k) + '.', ''); }
      else if (act === 'delv') deleteView(k);
      else if (act.indexOf('dsc:') === 0) editDetail(dn, function (d) { d.scale = +act.slice(4); });
      else if (act.indexOf('dmk:') === 0) editDetail(dn, function (d) { d.marker = Object.assign({}, d.marker || {}, { shape: act.slice(4) }); });
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
    var v = vprops(nk, true);
    if (at) { v.placement_mode = 'manual'; v.x_mm = at[0]; v.y_mm = at[1]; } else { v.placement_mode = 'auto'; v.x_mm = v.y_mm = null; }
    v.sheet = j;
    var sc0 = vprops(k); if (sc0 && sc0.scale_override) v.scale_override = sc0.scale_override;
    S.pendingPlace = at ? null : nk;
    changed();
    if (j !== (S.sheet || 0)) { S.sheet = j; renderPages(); }
    requestRender(true);
    msg('Đã TẠO BẢN SAO ' + viewName(k) + ' ở ' + sheetCode(j) + ' – bản gốc VẪN Ở ' + sheetCode(sheetOf(k) || 0) + '. ↶ để hoàn tác.', 'ok');
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
       ['Chuyển sang trang khác', function () { moveView(k, sheetCount()); }],
       ['Tự bố trí lại trang này', function () { snapshot(); relayoutPages([page()], S.sheet || 0, false); changed(); requestRender(true); }, 'gold']]);
  }

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
      '<label class="opt"><input type="radio" name="am" value="copy"> <b>TẠO THÊM BẢN SAO</b> – bản gốc vẫn giữ ở tờ cũ, thêm 1 bản ở tờ này</label>';
    dialog('Thêm hình chiếu vào trang này', body, [['Hủy', null], ['Thêm', function () {
      var r = rows[+document.querySelector('input[name=av]:checked').value], mode = document.querySelector('input[name=am]:checked').value;
      if (!r[2]) { // hình chưa bật: thêm mới vào trang, đặt tại điểm bấm
        snapshot(); p.views = (p.views || []).concat([r[0]]);
        var v = vprops(r[0], true); v.placement_mode = 'manual'; v.x_mm = pt[0]; v.y_mm = pt[1]; v.sheet = here;
        renderPageProps(); changed(); requestRender(true);
        msg('Đã thêm ' + r[1] + ' vào tờ ' + sheetCode(here) + ' (hình mới, không có bản gốc ở tờ khác).', 'ok'); return;
      }
      if (mode === 'move') {
        if (sheetOf(r[0]) === here) { msg(r[1] + ' đã ở tờ này – chọn "Tạo thêm bản sao" nếu muốn có 2 hình.', 'warn'); return false; }
        moveView(r[0], here, pt);
      } else copyView(r[0], here, pt);
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
    var mk = e.target.closest && e.target.closest('g.detmark');
    if (mk) { showCtx(e.clientX, e.clientY, 'det:' + mk.getAttribute('data-det'), null); return; }
    var g = e.target.closest && e.target.closest('g.view');
    if (!g) {
      if (e.target.closest && e.target.closest('#paper svg')) showPaperCtx(e.clientX, e.clientY, toPaper(e));
      else hideCtx();
      return;
    }
    var k = g.getAttribute('data-key');
    S.sel = k; S.selNote = null; highlight();
    showCtx(e.clientX, e.clientY, k, doorAt(k, toPaper(e)));
  });
  $('stage').addEventListener('dblclick', function (e) {
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
      return '<div class="sec" data-i="' + i + '"><div class="hd"><span class="lb">' + esc(viewName('det:' + d.n)) + '</span><span class="auto">từ ' +
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
    p.details.push({ n: n, src: key, rect: rect, scale: scale, src_sheet: S.sheet || 0, sheet: S.sheet || 0,
                     marker: st, label: null });
    vprops('det:' + n, true).sheet = S.sheet || 0;
    S.pendingPlace = 'det:' + n;
    renderDetails(); changed(); requestRender(true);
    msg('Đã tạo CHI TIẾT ' + n + ' (TL 1:' + scale + ') trên tờ ' + sheetCode(S.sheet || 0) + '.', 'ok');
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
    // KHÔNG ghi đè p.offsets từ kết quả dựng: kết quả chỉ chứa hình của tờ đang xem (lỗi cũ: chuyển tờ làm mất vị trí).
    // CHỐT bố cục: hình chưa có toạ độ lưu -> ghi vị trí plugin vừa đặt (trạng thái "Tự động"). Từ đó không tính lại
    // khi chuyển tờ, chuyển model, thêm model, mở lại hay xuất PDF – chỉ "Dàn trang lại" mới đổi.
    if (p && info.layout) {
      var froze = 0;
      Object.keys(info.layout).forEach(function (k) {
        var cur = vprops(k);
        if (cur && cur.x_mm != null) { if (cur.sheet !== info.layout[k][2]) { cur.sheet = info.layout[k][2]; froze++; } return; } // đồng bộ số tờ khi tờ trống bị gộp
        var v = vprops(k, true), L = info.layout[k];
        v.placement_mode = 'auto'; v.x_mm = L[0]; v.y_mm = L[1]; v.sheet = L[2]; froze++;
      });
      if (froze) markDirty();
    }
    if (S.pendingPlace && info.no_room && info.no_room.indexOf(S.pendingPlace) >= 0) noRoomDialog(S.pendingPlace);
    S.pendingPlace = null;
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
    overlay(); renderSyms();
    highlight();
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
    if (posLocked(S.sel)) { msg(viewName(S.sel) + ' đang khóa vị trí (chuột phải để mở khóa).', 'warn'); e.preventDefault(); return; }
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
    if (e.key === 'Escape') setTool('select');
    if (e.key === 'PageDown') { e.preventDefault(); gotoRow(curRowIndex(sheetRows()) + 1); }
    if (e.key === 'PageUp') { e.preventDefault(); gotoRow(curRowIndex(sheetRows()) - 1); }
    if ((e.key === 'Delete' || e.key === 'Backspace') && S.selNote) { e.preventDefault(); deleteNote(); return; }
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
      var autoN = Object.keys(p.view_props || {}).filter(function (k) { var v = p.view_props[k]; return v.x_mm != null && v.placement_mode !== 'manual' && !v.position_locked; }).length;
      if (autoN && window.confirm('Dàn lại ' + autoN + ' hình TỰ ĐỘNG của trang này theo cài đặt mới?\n(Hình đã chỉnh tay và đã khóa giữ nguyên. Chọn Cancel để giữ mọi vị trí hiện tại.)')) {
        relayoutPages([p], null, false);
      }
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
