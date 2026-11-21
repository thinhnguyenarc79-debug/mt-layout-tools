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
  function busy(on) { $('busy').style.display = on ? 'block' : 'none'; }
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
    var ps = S.project.pages;
    $('pgCount').textContent = ps.length;
    $('pgList').innerHTML = ps.length ? ps.map(function (p) {
      return '<div class="it' + (p.id === S.cur ? ' cur' : '') + '" data-id="' + p.id + '">' +
        '<span class="no">' + esc(p.sheet_no) + '</span><span class="nm">' + esc(p.name) + '</span>' +
        '<span class="sz">' + p.views.length + ' hình' + badge(p) + '</span></div>';
    }).join('') : '<div class="empty">Chưa có trang.</div>';
    var bad = badPages().length;
    $('pgClean').style.display = bad ? 'block' : 'none';
    $('pgClean').textContent = '🧹 Dọn ' + bad + ' trang lỗi (bộ phận con / đã xoá)';
    $('empty').style.display = ps.length ? 'none' : 'flex';
    $('paper').style.display = ps.length ? 'block' : 'none';
  }

  var STATUS = { nested: '⚠ bộ phận con', deleted: '⚠ đã xoá' };
  function badge(p) { var st = (S.status || {})[p.id]; return STATUS[st] ? ' · <b style="color:#b3261e">' + STATUS[st] + '</b>' : ''; }
  function badPages() { return S.project.pages.filter(function (p) { return STATUS[(S.status || {})[p.id]]; }); }

  function renderPageProps() {
    var p = page(), box = $('propPage');
    box.querySelectorAll('input,select,button').forEach(function (e) { e.disabled = !p; });
    if (!p) return;
    $('pgName').value = p.name; $('pgNo').value = p.sheet_no; $('pgScale').value = String(p.scale);
    $('pgFront').value = p.front; setChecks($('pgViews'), p.views);
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

  // ---------------- trang & dựng ----------------
  function openPage(id) {
    S.cur = id || null; S.sel = null; S.info = null;
    renderPages(); renderPageProps(); renderViewProps();
    $('paper').innerHTML = '';
    if (S.cur) requestRender(true);
  }
  function requestRender(now) {
    if (!S.cur) return;
    clearTimeout(S.timer);
    S.timer = setTimeout(function () {
      busy(true); call('render', { project: S.project, page_id: S.cur });
    }, now ? 0 : 350);
  }
  function showSvg(svg, info) {
    S.info = info;
    var paper = $('paper');
    paper.innerHTML = svg;
    var p = page();
    if (p && info.offsets) p.offsets = info.offsets; // đồng bộ vị trí đã kẹp trong vùng vẽ
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
    var g = e.target.closest && e.target.closest('g.view');
    if (e.button === 1 || S.tool === 'pan' || spaceDown || !g) {
      if (e.button === 1 || S.tool === 'pan' || spaceDown) {
        drag = { mode: 'pan', x: e.clientX, y: e.clientY, px: S.panX, py: S.panY };
        $('stage').classList.add('panning');
      } else if (S.sel) { S.sel = null; highlight(); }
      e.preventDefault(); return;
    }
    if (e.button !== 0) return;
    S.sel = g.getAttribute('data-key'); highlight();
    drag = { mode: 'move', g: g, x: e.clientX, y: e.clientY, dx: 0, dy: 0 };
    e.preventDefault();
  });
  window.addEventListener('mousemove', function (e) {
    if (!drag) return;
    if (drag.mode === 'pan') {
      S.panX = drag.px + e.clientX - drag.x; S.panY = drag.py + e.clientY - drag.y; applyView();
    } else {
      drag.dx = (e.clientX - drag.x) / S.k; drag.dy = (e.clientY - drag.y) / S.k;
      drag.g.setAttribute('transform', 'translate(' + drag.dx + ' ' + drag.dy + ')');
    }
  });
  window.addEventListener('mouseup', function () {
    if (!drag) return;
    var d = drag; drag = null; $('stage').classList.remove('panning');
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
    S.tool = t;
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
  $('refresh').onclick = function () { if (!S.cur) return; busy(true); call('refresh', { project: S.project, page_id: S.cur }); };
  $('save').onclick = save;
  $('pdfPage').onclick = function () { if (S.cur) call('export_pdf', { project: S.project, page_ids: [S.cur] }); };
  $('pdfAll').onclick = function () { call('export_pdf', { project: S.project, page_ids: [] }); };
  $('svgPage').onclick = function () { if (S.cur) call('export_svg', { project: S.project, page_id: S.cur }); };
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
  $('pgList').onclick = function (e) { var it = e.target.closest('.it'); if (it) openPage(it.dataset.id); };
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
    if (!window.confirm('Xoá trang ' + p.sheet_no + ' – ' + p.name + '? (Hoàn tác được bằng Ctrl+Z)')) return;
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
    p.name = $('pgName').value; p.sheet_no = $('pgNo').value; p.scale = parseInt($('pgScale').value, 10);
    p.front = $('pgFront').value; p.views = getChecks($('pgViews'));
    p.min_gap = parseFloat($('pgGap').value) || 0; p.round = parseFloat($('pgRound').value) || 1;
    p.fill = $('pgFill').checked; p.dims = $('pgDims').checked;
    renderPages(); changed();
  }
  ['pgName', 'pgNo', 'pgScale', 'pgFront', 'pgViews', 'pgGap', 'pgRound', 'pgFill', 'pgDims'].forEach(function (id) {
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
