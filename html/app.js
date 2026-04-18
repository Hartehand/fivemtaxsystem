var app = document.getElementById('app');
var content = document.getElementById('content');
var tabs = Array.prototype.slice.call(document.querySelectorAll('.tabs button'));
var closeBtn = document.getElementById('closeBtn');
var state = { tab: 'dashboard' };

function safe(v, d) { return (v === undefined || v === null) ? d : v; }
function money(v) { return '$' + Number(safe(v, 0)).toFixed(2); }

function post(action, data) {
  return fetch('https://' + GetParentResourceName() + '/' + action, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data || {})
  }).then(function(res) { return res.json(); }).catch(function(err) {
    console.error('[doj_finance_suite][nui] post failed', action, err);
    return {};
  });
}

function debounce(fn, wait) {
  var t = null;
  return function() {
    var args = arguments;
    clearTimeout(t);
    t = setTimeout(function() { fn.apply(null, args); }, wait || 220);
  };
}

var STANDARD_REASONS = [
  'Nichtzahlung trotz Liquidität',
  'Wiederholte verspätete Zahlung',
  'hohe offene Restschuld',
  'unklare Transaktionsherkunft',
  'private und geschäftliche Mittel vermischt',
  'Bußgeld-/Charge-Bezug',
  'Vermögensauffälligkeit',
  'Mapping manuell bestätigt',
  'weitere Nachprüfung erforderlich'
];

function reasonOptions(selected) {
  return STANDARD_REASONS.map(function(r) {
    return '<option value="' + r + '"' + (r === selected ? ' selected' : '') + '>' + r + '</option>';
  }).join('');
}

function openEditModal(title, fields, onSave) {
  var existing = document.getElementById('modalOverlay');
  if (existing) existing.remove();
  var overlay = document.createElement('div');
  overlay.id = 'modalOverlay';
  overlay.style.position = 'fixed';
  overlay.style.inset = '0';
  overlay.style.background = 'rgba(0,0,0,.55)';
  overlay.style.display = 'grid';
  overlay.style.placeItems = 'center';
  overlay.style.zIndex = '9999';
  var form = fields.map(function(f) {
    var value = (f.value === undefined || f.value === null) ? '' : String(f.value);
    return '<label style="display:block;margin-bottom:8px;"><div class="small">' + f.label + '</div><input data-modal-field="' + f.key + '" value="' + value.replace(/"/g, '&quot;') + '" /></label>';
  }).join('');
  overlay.innerHTML = '<div style="width:min(720px,92vw);background:#10192b;border:1px solid #35598f;border-radius:12px;padding:14px;"><h3 style="margin-top:0;">' + title + '</h3>' + form + '<div class="input-row"><button id="modalCancel">Abbrechen</button><button id="modalSave">Speichern</button></div></div>';
  document.body.appendChild(overlay);
  document.getElementById('modalCancel').addEventListener('click', function() { overlay.remove(); });
  document.getElementById('modalSave').addEventListener('click', function() {
    var out = {};
    fields.forEach(function(f) {
      var el = document.querySelector('[data-modal-field="' + f.key + '"]');
      out[f.key] = el ? el.value : '';
    });
    onSave(out);
    overlay.remove();
  });
}

function buildCaseContext(detail) {
  var record = detail.record || {};
  var amount = Number(record.restschuld || record.amount || 0);
  var subjectName = record.receiver_name || record.receiver || record.job_label || record.job || record.owner || record.id || detail.source_key || '-';
  return {
    source_type: detail.source_type,
    source_id: detail.source_id || null,
    source_key: detail.source_key || null,
    subject_name: subjectName,
    subject_identifier: record.receiver || record.job || detail.source_key || detail.source_id || '',
    amount: amount,
    risk_score: Number((record.risk && record.risk.score) || record.score || 0),
    risk_band: (record.risk && record.risk.band) || record.risk_band || 'unauffaellig',
    due_date: record.due_date || record.next_due_date || null
  };
}

function recommendAction(ctx) {
  if (ctx.amount > 25000) return { action: 'doj_handoff', reason: 'Hohe offene Forderung', priority: 'hoch', due: ctx.due_date || '7 Tage' };
  if (ctx.amount > 10000) return { action: 'mahnung', reason: 'Erhöhte Restschuld', priority: 'hoch', due: ctx.due_date || '5 Tage' };
  if (ctx.amount > 0) return { action: 'erinnerung', reason: 'Offene Forderung vorhanden', priority: 'normal', due: ctx.due_date || '14 Tage' };
  return { action: 'fall_schliessen', reason: 'Keine Restschuld', priority: 'niedrig', due: '-' };
}

function attachLookup(inputId, kind, onSelect) {
  var input = document.getElementById(inputId);
  if (!input) return;
  var listId = inputId + '_lookup';
  var list = document.createElement('div');
  list.id = listId;
  list.style.position = 'absolute';
  list.style.background = '#0f1a2c';
  list.style.border = '1px solid #35598f';
  list.style.zIndex = '1000';
  list.style.maxHeight = '220px';
  list.style.overflow = 'auto';
  input.parentElement.style.position = 'relative';
  input.parentElement.appendChild(list);
  input.addEventListener('input', function() {
    var q = input.value || '';
    if (q.length < 3) { list.innerHTML = ''; return; }
    post('searchLookup', { kind: kind, query: q }).then(function(data) {
      var rows = data.rows || [];
      list.innerHTML = rows.map(function(r) {
        return '<div data-value="' + r.value + '" style="padding:6px 8px;cursor:pointer;">' + (r.label || r.value) + ' <span class="small">(' + r.value + ')</span></div>';
      }).join('');
      Array.prototype.slice.call(list.querySelectorAll('[data-value]')).forEach(function(el) {
        el.addEventListener('click', function() {
          var value = el.getAttribute('data-value');
          input.value = value;
          list.innerHTML = '';
          onSelect && onSelect(value);
        });
      });
    });
  });
}

function badge(band) {
  var b = band || 'unauffaellig';
  return '<span class="badge ' + b + '">' + b + '</span>';
}

function setTab(tab) {
  state.tab = tab;
  tabs.forEach(function(t) { t.classList.toggle('active', t.dataset.tab === tab); });
  render();
}

function renderDashboard() {
  post('getDashboard', {}).then(function(data) {
    var risk = (data.private && data.private.risk) || { score: 0, band: 'unauffaellig', reasons: [] };
    var high = data.highRiskCases || [];
    var work = data.worklists || {};
    var billing = data.billing || {};
    var suspiciousPeople = data.suspiciousPeople || [];

    var rows = high.map(function(r) {
      return '<tr><td>' + (r.job_label || r.job || '-') + '</td><td>' + safe(r.risk && r.risk.score, 0) + '</td><td>' + badge(r.risk && r.risk.band) + '</td><td>' + money(r.meta && r.meta.restDebt) + '</td><td>' + ((r.risk && r.risk.reasons) ? r.risk.reasons.join(', ') : '-') + '</td></tr>';
    }).join('');

    var peopleRows = suspiciousPeople.slice(0, 10).map(function(p) {
      return '<tr><td>' + (p.name || p.identifier || '-') + '</td><td>' + safe(p.job, '-') + '</td><td>' + safe(p.score, 0) + '</td><td>' + ((p.reasons || []).join(', ') || '-') + '</td></tr>';
    }).join('');

    var workHtml = '<div class="grid">' +
      '<div class="card"><h3>Heute prüfen</h3><div class="val">' + safe((work.heute_pruefen || []).length, 0) + '</div></div>' +
      '<div class="card"><h3>Bald fällig (14T)</h3><div class="val">' + safe((work.bald_faellig || []).length, 0) + '</div></div>' +
      '<div class="card"><h3>Mahnen</h3><div class="val">' + safe((work.mahnen || []).length, 0) + '</div></div>' +
      '<div class="card"><h3>Ungeklärte Zahlungen</h3><div class="val">' + safe((work.ungeklaerte_zahlung || []).length, 0) + '</div></div>' +
      '</div>';

    content.innerHTML = '<div class="grid">' +
      '<div class="card"><h3>Privatrisiko</h3><div class="val">' + safe(risk.score, 0) + '</div>' + badge(risk.band) + '</div>' +
      '<div class="card"><h3>Offen Privat</h3><div class="val">' + safe(data.private && data.private.openCount, 0) + '</div><div class="small">' + money(data.private && data.private.openAmount) + '</div></div>' +
      '<div class="card"><h3>Offen Business</h3><div class="val">' + safe(data.business && data.business.openCount, 0) + '</div><div class="small">' + money(data.business && data.business.openAmount) + '</div></div>' +
      '<div class="card"><h3>Offene Billing</h3><div class="val">' + safe(billing.count, 0) + '</div><div class="small">' + money(billing.total) + '</div></div>' +
      '</div>' +
      workHtml +
      '<div class="detail-panel">' + ((risk.reasons || []).join('\n') || 'Keine besonderen Hinweise') + '</div>' +
      '<div class="table-wrap"><table><thead><tr><th>Unternehmen</th><th>Score</th><th>Band</th><th>Restschuld</th><th>Gründe</th></tr></thead><tbody>' + rows + '</tbody></table></div>' +
      '<div class="table-wrap"><table><thead><tr><th>Auffällige Person</th><th>Job</th><th>Score</th><th>Trigger</th></tr></thead><tbody>' + peopleRows + '</tbody></table></div>';
  });
}

function bindCaseDetailButtons() {
  var buttons = document.querySelectorAll('[data-detail]');
  buttons.forEach(function(btn) {
    btn.addEventListener('click', function() {
      var payload = JSON.parse(decodeURIComponent(btn.getAttribute('data-detail')));
      post('getCaseDetail', payload).then(function(detail) {
        var bundle = detail.bundle || {};
        var ctx = buildCaseContext(detail);
        var recommendation = recommendAction(ctx);
        var lines = [];
        lines.push('Status: ' + ((bundle.review && bundle.review.status) || 'neu'));
        lines.push('Bearbeiter: ' + ((bundle.review && bundle.review.assigned_to) || '-'));
        lines.push('Deadline: ' + ((bundle.deadline && bundle.deadline.due_date) || 'Standard'));
        lines.push('Empfohlene Maßnahme: ' + recommendation.action + ' | Grund: ' + recommendation.reason + ' | Priorität: ' + recommendation.priority + ' | Frist: ' + recommendation.due);
        lines.push('--- Letzte Notizen ---');
        (bundle.notes || []).slice(0, 8).forEach(function(n) { lines.push((n.author_identifier || '-') + ': ' + (n.note || '-')); });
        lines.push('--- Letzte Aktenaktionen ---');
        (bundle.audit || []).slice(0, 8).forEach(function(a) { lines.push((a.created_at || '-') + ': ' + (a.action || '-')); });

        var panel = document.getElementById('detail');
        if (!panel) return;
        panel.innerHTML = lines.join('<br/>') +
          '<div class="input-row" style="margin-top:10px;">' +
          '<button id="caseStartReview">Prüfverfahren starten</button>' +
          '<select id="casePriority"><option value="normal">normal</option><option value="high">high</option><option value="low">low</option></select>' +
          '<input id="caseDojCase" placeholder="DOJ Case ID / Nummer" />' +
          '<input id="caseNote" placeholder="Notiztext" />' +
          '<button id="caseSaveNote">Notiz speichern</button>' +
          '<button id="caseSaveMeta">Meta speichern</button>' +
          '</div><div class="input-row">' +
          '<button id="caseQuickEnforcement">Mahnung starten</button>' +
          '<button id="caseQuickPlan">Ratenplan anlegen</button>' +
          '<button id="caseQuickHandoff">DOJ-Handoff anlegen</button>' +
          '<button id="caseQuickDocument">Dokument erzeugen</button>' +
          '<button id="caseQuickDeadline">Frist setzen</button>' +
          '</div>';

        var startBtn = document.getElementById('caseStartReview');
        if (startBtn) {
          startBtn.addEventListener('click', function() {
            post('setStatus', {
              source_type: detail.source_type,
              source_id: detail.source_id || null,
              source_key: detail.source_key || null,
              status: 'in_pruefung',
              assigned_to: 'nui_operator'
            });
          });
        }

        var noteBtn = document.getElementById('caseSaveNote');
        if (noteBtn) {
          noteBtn.addEventListener('click', function() {
            var text = (document.getElementById('caseNote') || {}).value || '';
            if (!text) return;
            post('addNote', {
              source_type: detail.source_type,
              source_id: detail.source_id || null,
              source_key: detail.source_key || null,
              note: text,
              is_internal: true
            });
          });
        }

        var metaBtn = document.getElementById('caseSaveMeta');
        if (metaBtn) {
          metaBtn.addEventListener('click', function() {
            var priority = (document.getElementById('casePriority') || {}).value || 'normal';
            var dojInput = (document.getElementById('caseDojCase') || {}).value || '';
            var dojCase = Number(dojInput || 0);
            post('setCaseMeta', {
              source_type: detail.source_type,
              source_id: detail.source_id || null,
              source_key: detail.source_key || null,
              priority: priority,
              doj_case_id: dojCase > 0 ? dojCase : null,
              doj_case_number: dojCase > 0 ? null : (dojInput || null),
              evidence: { reason_snapshot: lines.slice(0, 6) }
            });
          });
        }

        var quickEnf = document.getElementById('caseQuickEnforcement');
        if (quickEnf) quickEnf.addEventListener('click', function() {
          openEditModal('Mahnfall aus Akte', [
            { key: 'status', label: 'Status', value: 'mahnung' },
            { key: 'reason', label: 'Grund', value: 'hohe offene Restschuld' },
            { key: 'next_due_date', label: 'Frist (YYYY-MM-DD)', value: ctx.due_date || '' }
          ], function(v) {
            post('upsertEnforcement', {
              source_type: ctx.source_type,
              source_id: ctx.source_id,
              source_key: ctx.source_key,
              subject_type: 'case',
              subject_identifier: ctx.subject_identifier,
              status: v.status || 'mahnung',
              next_due_date: v.next_due_date || null,
              reason: v.reason || 'weitere Nachprüfung erforderlich'
            });
          });
        });

        var quickPlan = document.getElementById('caseQuickPlan');
        if (quickPlan) quickPlan.addEventListener('click', function() {
          var total = Number(ctx.amount || 0);
          var count = total > 12000 ? 6 : 3;
          var installment = count > 0 ? (total / count) : total;
          openEditModal('Ratenplan aus Akte', [
            { key: 'total_amount', label: 'Gesamtschuld', value: total.toFixed(2) },
            { key: 'down_payment', label: 'Anzahlung', value: '0.00' },
            { key: 'installment_count', label: 'Ratenanzahl', value: String(count) },
            { key: 'installment_amount', label: 'Ratenhöhe', value: installment.toFixed(2) },
            { key: 'start_date', label: 'Start (YYYY-MM-DD)', value: ctx.due_date || '' }
          ], function(v) {
            post('createInstallmentPlan', {
              source_type: ctx.source_type,
              source_id: ctx.source_id,
              source_key: ctx.source_key,
              subject_identifier: ctx.subject_identifier,
              total_amount: Number(v.total_amount || 0),
              down_payment: Number(v.down_payment || 0),
              installment_count: Number(v.installment_count || 1),
              installment_amount: Number(v.installment_amount || 0),
              start_date: v.start_date || null,
              next_due_date: v.start_date || null,
              status: 'aktiv'
            });
          });
        });

        var quickHandoff = document.getElementById('caseQuickHandoff');
        if (quickHandoff) quickHandoff.addEventListener('click', function() {
          openEditModal('DOJ-Handoff aus Akte', [
            { key: 'target_case_number', label: 'Zielakte (optional)', value: '' },
            { key: 'risk_band', label: 'Risk Band', value: ctx.risk_band || 'mittelrisiko' },
            { key: 'risk_score', label: 'Risk Score', value: String(ctx.risk_score || 0) },
            { key: 'note', label: 'Grund', value: recommendation.reason }
          ], function(v) {
            post('createCaseHandoff', {
              source_type: ctx.source_type,
              source_id: ctx.source_id,
              source_key: ctx.source_key,
              target_case_number: v.target_case_number || null,
              target_case_id: null,
              risk_band: v.risk_band || 'mittelrisiko',
              risk_score: Number(v.risk_score || 0),
              note: v.note || recommendation.reason
            });
          });
        });

        var quickDoc = document.getElementById('caseQuickDocument');
        if (quickDoc) quickDoc.addEventListener('click', function() {
          openEditModal('Dokument aus Akte', [
            { key: 'doc_type', label: 'Dokumenttyp', value: recommendation.action === 'mahnung' ? 'mahnung' : 'zahlungsaufforderung' },
            { key: 'due_date', label: 'Frist (YYYY-MM-DD)', value: ctx.due_date || '' },
            { key: 'subject', label: 'Betreff', value: 'Vorgang zu Akte ' + (ctx.source_key || ctx.source_id || '-') },
            { key: 'body', label: 'Inhalt', value: 'Begründung: ' + recommendation.reason }
          ], function(v) {
            post('createDocument', {
              doc_type: v.doc_type || 'zahlungsaufforderung',
              source_type: ctx.source_type,
              source_id: ctx.source_id,
              source_key: ctx.source_key,
              subject_identifier: ctx.subject_identifier,
              subject_name: ctx.subject_name,
              due_date: v.due_date || null,
              subject: v.subject || 'Amtlicher Bescheid',
              body: v.body || recommendation.reason,
              status: 'entwurf',
              meta_json: { amount: ctx.amount, recommendation: recommendation.action }
            });
          });
        });

        var quickDeadline = document.getElementById('caseQuickDeadline');
        if (quickDeadline) quickDeadline.addEventListener('click', function() {
          var options = '<select id="deadlineReasonSelect">' + reasonOptions('weitere Nachprüfung erforderlich') + '</select>';
          openEditModal('Frist aus Akte setzen', [
            { key: 'due_date', label: 'Fristdatum (YYYY-MM-DD)', value: ctx.due_date || '' }
          ], function(v) {
            var reason = ((document.getElementById('deadlineReasonSelect') || {}).value || 'weitere Nachprüfung erforderlich');
            post('setDeadline', {
              source_type: ctx.source_type,
              source_id: ctx.source_id,
              source_key: ctx.source_key,
              due_date: v.due_date || null,
              reason: reason
            });
          });
          var modalSave = document.getElementById('modalSave');
          if (modalSave) {
            var wrapper = document.createElement('div');
            wrapper.className = 'input-row';
            wrapper.innerHTML = options;
            modalSave.parentElement.insertBefore(wrapper, modalSave);
          }
        });

        post('getCaseTimeline', {
          source_type: detail.source_type,
          source_id: detail.source_id || null,
          source_key: detail.source_key || null
        }).then(function(tl) {
          var rows = (tl.rows || []).slice(0, 15).map(function(e) {
            var title = e.title || '-';
            if (e.kind === 'audit' && title === 'enforcement_updated') title = 'Mahnstatus geändert';
            if (e.kind === 'audit' && title === 'installment_created') title = 'Ratenplan angelegt';
            if (e.kind === 'audit' && title === 'case_handoff_created') title = 'DOJ-Handoff erstellt';
            if (e.kind === 'audit' && title === 'document_created') title = 'Dokument erzeugt';
            return (e.created_at || '-') + ' | ' + title;
          }).join('<br/>');
          panel.innerHTML += '<div class="detail-panel small" style="margin-top:10px;">' + (rows || 'Keine Timeline-Einträge') + '</div>';
        });
      });
    });
  });
}

function renderPrivate() {
  post('getPrivateCases', { page: 1, pageSize: 50, filters: {} }).then(function(data) {
    var rows = (data.rows || []).map(function(r) {
      var payload = encodeURIComponent(JSON.stringify({ source_type: 'taxes', source_id: r.id }));
      return '<tr><td>' + r.id + '</td><td>' + (r.receiver_name || r.receiver || '-') + '</td><td>' + (r.status || '-') + '</td><td>' + money(r.amount) + '</td><td>' + (r.due_date || '-') + '</td><td><button data-detail="' + payload + '">Akte</button></td></tr>';
    }).join('');

    content.innerHTML = '<div class="small">Gesamt: ' + safe(data.count, 0) + '</div><div class="table-wrap"><table><thead><tr><th>ID</th><th>Name</th><th>Status</th><th>Betrag</th><th>Due</th><th>Aktion</th></tr></thead><tbody>' + rows + '</tbody></table></div><div id="detail" class="detail-panel small">Wähle einen Fall.</div>';
    bindCaseDetailButtons();
  });
}

function renderBusiness() {
  post('getBusinessCases', { page: 1, pageSize: 50, filters: {} }).then(function(data) {
    var rows = (data.rows || []).map(function(r) {
      var payload = encodeURIComponent(JSON.stringify({ source_type: 'taxes_business', source_key: (r.job || '') + '|' + (r.period || '') }));
      return '<tr><td>' + (r.job_label || r.job || '-') + '</td><td>' + (r.period || '-') + '</td><td>' + (r.business_id || '-') + '</td><td>' + (r.status || '-') + '</td><td>' + money(r.restschuld) + '</td><td><button data-detail="' + payload + '">Akte</button></td></tr>';
    }).join('');

    content.innerHTML = '<div class="small">Gesamt: ' + safe(data.count, 0) + '</div><div class="table-wrap"><table><thead><tr><th>Job</th><th>Periode</th><th>Firma</th><th>Status</th><th>Restschuld</th><th>Aktion</th></tr></thead><tbody>' + rows + '</tbody></table></div><div id="detail" class="detail-panel small">Wähle einen Fall.</div>';
    bindCaseDetailButtons();
  });
}

function renderTransactions() {
  content.innerHTML = '<div class="input-row"><input id="txSearch" placeholder="Suche Name/Identifier" /><input id="txEntity" placeholder="Person/Firma" /><input id="txFrom" placeholder="Von (YYYY-MM-DD)" /><input id="txTo" placeholder="Bis (YYYY-MM-DD)" /><input id="txMinAmount" placeholder="Min Betrag" /><input id="txMaxAmount" placeholder="Max Betrag" /><select id="txType"><option value="">Alle Typen</option><option value="deposit">deposit</option><option value="withdraw">withdraw</option><option value="transfer">transfer</option></select><select id="txSource"><option value="">Alle Quellen</option><option value="okokbanking_transactions">Okokbanking</option><option value="bossmenu_transactions">Bossmenu</option></select><button id="applyTxFilter">Filter anwenden</button></div><div id="txResult"></div>';

  function loadTransactions() {
    var filters = {
      search: (document.getElementById('txSearch') || {}).value || '',
      entity: (document.getElementById('txEntity') || {}).value || '',
      from: (document.getElementById('txFrom') || {}).value || '',
      to: (document.getElementById('txTo') || {}).value || '',
      min_amount: (document.getElementById('txMinAmount') || {}).value || '',
      max_amount: (document.getElementById('txMaxAmount') || {}).value || '',
      source: (document.getElementById('txSource') || {}).value || ''
    };

    post('getTransactions', { page: 1, pageSize: 120, filters: filters }).then(function(data) {
      var selectedType = ((document.getElementById('txType') || {}).value || '').toLowerCase();
      var mappings = data.mappings || [];
      var rows = (data.rows || []).filter(function(tx) {
        if (!selectedType) return true;
        return ((tx.type || '').toLowerCase() === selectedType);
      });

      var analysis = data.analysis || { score: 0, band: 'unauffaellig', reasons: [] };
      var w = data.windows || {};
      var w7 = w[7] || { incoming: 0, outgoing: 0 };
      var txRows = rows.map(function(tx) {
        var assignment = tx.assigned_business_id || '-';
        var source = tx.source_label || tx.source_table || '-';
        var selector = '<select data-assign-select="' + (tx.source_table || 'okokbanking_transactions') + ':' + tx.id + '"><option value="">Unternehmen wählen</option>' + mappings.map(function(m) {
          var selected = (m.business_id === tx.assigned_business_id) ? ' selected' : '';
          return '<option value="' + m.business_id + '"' + selected + '>' + m.business_id + ' (' + m.tax_job + ')</option>';
        }).join('') + '</select>';
        var info = tx.business_inference && tx.business_inference.confidence ? ('Auto: ' + safe(tx.business_inference.business_id, '-') + ' (' + tx.business_inference.confidence + '%)') : 'Auto: -';
        return '<tr><td>' + tx.id + '</td><td>' + source + '</td><td>' + (tx.type || '-') + '</td><td>' + money(tx.value) + '</td><td>' + (tx.sender_name || tx.actor_name || '-') + '</td><td>' + (tx.receiver_name || tx.business_job || '-') + '</td><td>' + (tx.date || '-') + '</td><td>' + assignment + '</td><td>' + safe(tx.assignment_mode, '-') + '<br/><span class="small">' + info + '</span></td><td>' + selector + '<button data-assign="' + (tx.source_table || 'okokbanking_transactions') + ':' + tx.id + '">Zuordnen</button></td></tr>';
      }).join('');

      var result = document.getElementById('txResult');
      if (!result) return;
      result.innerHTML = '<div class="grid"><div class="card"><h3>Analyse Score</h3><div class="val">' + safe(analysis.score, 0) + '</div>' + badge(analysis.band) + '</div><div class="card"><h3>7T Eingänge</h3><div class="val">' + money(w7.incoming) + '</div></div><div class="card"><h3>7T Ausgänge</h3><div class="val">' + money(w7.outgoing) + '</div></div><div class="card"><h3>Gefilterte TX</h3><div class="val">' + rows.length + '</div></div></div><div class="detail-panel">' + ((analysis.reasons || []).join('\n') || 'Keine Auffälligkeit erkannt') + '</div><div class="table-wrap"><table><thead><tr><th>ID</th><th>Quelle</th><th>Typ</th><th>Betrag</th><th>Sender</th><th>Empfänger/Job</th><th>Datum</th><th>Unternehmen</th><th>Modus</th><th>Aktion</th></tr></thead><tbody>' + txRows + '</tbody></table></div>';

      var assignButtons = document.querySelectorAll('[data-assign]');
      assignButtons.forEach(function(btn) {
        btn.addEventListener('click', function() {
          var ref = btn.getAttribute('data-assign') || '';
          var parts = ref.split(':');
          var table = parts[0] || 'okokbanking_transactions';
          var txId = Number(parts[1] || 0);
          var selector = document.querySelector('[data-assign-select="' + ref + '"]');
          var businessId = selector ? selector.value : '';
          if (!businessId || !txId) return;

          post('assignTransactionBusiness', {
            transaction_table: table,
            transaction_id: txId,
            business_id: businessId,
            comment: 'Manuelle Zuweisung aus Transaktions-Tab'
          }).then(function() {
            loadTransactions();
          });
        });
      });
    });
  }

  var btn = document.getElementById('applyTxFilter');
  if (btn) btn.addEventListener('click', loadTransactions);
  loadTransactions();
}

function renderCompanies() {
  post('getBusinesses', { page: 1, pageSize: 100 }).then(function(data) {
    var rows = (data.rows || []).map(function(b) {
      var p = b.data || {};
      var kpi = b.kpi || {};
      var payload = encodeURIComponent(JSON.stringify({ business_id: b.id }));
      return '<tr><td>' + (b.id || '-') + '</td><td>' + (b.type || '-') + '</td><td>' + (b.owner || '-') + '</td><td>' + money(p.balance) + '</td><td>' + money(p.totalEarned) + '</td><td>' + safe(p.totalOrders, 0) + '</td><td>' + safe(p.totalSales, 0) + '</td><td>' + safe(kpi.score, 0) + ' ' + badge(kpi.band) + '</td><td>' + safe(kpi.open_tax_cases, 0) + '</td><td><button data-company="' + payload + '">Details</button></td></tr>';
    }).join('');

    content.innerHTML = '<div class="small">Unternehmen gesamt: ' + safe(data.count, 0) + '</div><div class="table-wrap"><table><thead><tr><th>ID</th><th>Typ</th><th>Owner</th><th>Balance</th><th>TotalEarned</th><th>Orders</th><th>Sales</th><th>Score</th><th>Offene Steuerfälle</th><th>Aktion</th></tr></thead><tbody>' + rows + '</tbody></table></div><div id="companyDetail" class="detail-panel small">Wähle ein Unternehmen für Detailansicht.</div>';

    var buttons = document.querySelectorAll('[data-company]');
    buttons.forEach(function(btn) {
      btn.addEventListener('click', function() {
        var payload = JSON.parse(decodeURIComponent(btn.getAttribute('data-company')));
        post('getBusinessProfile', payload).then(function(detail) {
          var panel = document.getElementById('companyDetail');
          if (!panel) return;

          if (!detail || !detail.business) {
            panel.textContent = 'Keine Profildaten verfügbar.';
            return;
          }

          var lines = [];
          lines.push('Unternehmen: ' + (detail.business.id || '-'));
          lines.push('Owner: ' + (detail.business.owner || '-'));
          lines.push('Risk Score: ' + safe(detail.risk && detail.risk.score, 0) + ' (' + safe(detail.risk && detail.risk.band, 'unauffaellig') + ')');
          lines.push('Risk Gründe: ' + ((detail.risk && detail.risk.reasons) ? detail.risk.reasons.join(', ') : '-'));
          lines.push('--- Letzte relevante Transaktionen ---');
          (detail.transactions || []).slice(0, 8).forEach(function(tx) {
            lines.push('#' + tx.id + ' | ' + (tx.type || '-') + ' | ' + money(tx.value) + ' | ' + (tx.date || '-'));
          });

          panel.innerHTML = lines.join('<br/>') + '<div class="input-row" style="margin-top:10px;"><button id="startReview">Prüfverfahren starten</button><input id="companyNote" placeholder="Notiztext" /><button id="saveCompanyNote">Notiz speichern</button><button id="companyLinkProfile">Link-Profil</button></div><div id="companyLinkPanel" class="detail-panel small"></div>';

          var businessId = detail.business.id;
          var startBtn = document.getElementById('startReview');
          if (startBtn) {
            startBtn.addEventListener('click', function() {
              post('setStatus', {
                source_type: 'vms_business',
                source_id: null,
                source_key: businessId,
                status: 'in_pruefung',
                assigned_to: 'nui_operator'
              });
            });
          }

          var noteBtn = document.getElementById('saveCompanyNote');
          if (noteBtn) {
            noteBtn.addEventListener('click', function() {
              var text = (document.getElementById('companyNote') || {}).value || '';
              if (!text) return;
              post('addNote', {
                source_type: 'vms_business',
                source_id: null,
                source_key: businessId,
                note: text,
                is_internal: true
              });
            });
          }

          var linkBtn = document.getElementById('companyLinkProfile');
          if (linkBtn) {
            linkBtn.addEventListener('click', function() {
              post('getBusinessLinkProfile', { business_id: businessId }).then(function(linkProfile) {
                var p = document.getElementById('companyLinkPanel');
                if (!p) return;
                if (!linkProfile || !linkProfile.business) {
                  p.textContent = 'Kein Link-Profil verfügbar.';
                  return;
                }
                var out = [];
                out.push('Owners: ' + (linkProfile.owners || []).join(', '));
                out.push('Employees: ' + (linkProfile.employees || []).slice(0, 10).join(', '));
                out.push('Users verknüpft: ' + safe((linkProfile.users || []).length, 0));
                out.push('Fahrzeuge verknüpft: ' + safe((linkProfile.vehicles || []).length, 0));
                out.push('DOJ Cases verknüpft: ' + safe((linkProfile.doj_cases || []).length, 0));
                out.push('Societies/IBAN Hits: ' + safe((linkProfile.societies || []).length, 0));
                p.textContent = out.join('\n');
              });
            });
          }
        });
      });
    });
  });
}

function renderReports(selectedReportId) {
  function fillReportDetail(reportId) {
    post('getReport', { report_id: reportId }).then(function(detail) {
      var panel = document.getElementById('reportDetail');
      if (!panel) return;
      if (!detail || !detail.report) {
        panel.textContent = 'Report konnte nicht geladen werden.';
        return;
      }
      var lines = [];
      lines.push('Report: ' + (detail.report.title || '-'));
      lines.push('Typ: ' + (detail.report.report_type || '-'));
      lines.push('Erstellt: ' + (detail.report.created_at || '-'));
      lines.push('--- Einträge ---');
      (detail.entries || []).slice(0, 80).forEach(function(e) {
        lines.push('#' + e.line_no + ' | ' + e.label + ' | ' + money(e.amount));
      });
      panel.textContent = lines.join('\n');
    });
  }

  post('listReports', { filters: { page: 1, pageSize: 50 } }).then(function(list) {
    var rows = (list.rows || []).map(function(r) {
      return '<tr><td>' + r.id + '</td><td>' + r.report_type + '</td><td>' + r.title + '</td><td>' + r.created_by + '</td><td>' + r.created_at + '</td><td><button data-report="' + r.id + '">Ansehen</button></td></tr>';
    }).join('');

    content.innerHTML = '<div class="input-row"><select id="reportType"><option value="schuldnerreport">schuldnerreport</option><option value="hochrisikoreport">hochrisikoreport</option><option value="transaktionsauffaelligkeit">transaktionsauffaelligkeit</option><option value="zahlungsverhalten">zahlungsverhalten</option><option value="debtor_master_report">debtor_master_report</option><option value="person_risk_report">person_risk_report</option><option value="asset_mismatch_report">asset_mismatch_report</option><option value="cityhall_charge_finance_report">cityhall_charge_finance_report</option><option value="business_person_link_report">business_person_link_report</option></select><button id="createReport">Report erstellen</button></div><div class="table-wrap"><table><thead><tr><th>ID</th><th>Typ</th><th>Titel</th><th>Ersteller</th><th>Datum</th><th>Aktion</th></tr></thead><tbody>' + rows + '</tbody></table></div><div id="reportDetail" class="detail-panel small">Wähle einen Report zum Anzeigen.</div>';

    var createBtn = document.getElementById('createReport');
    if (createBtn) {
      createBtn.addEventListener('click', function() {
        var reportType = (document.getElementById('reportType') || {}).value || 'schuldnerreport';
        var panel = document.getElementById('reportDetail');
        createBtn.disabled = true;
        if (panel) panel.textContent = 'Report wird erstellt...';

        post('createReport', { report_type: reportType, payload: {} }).then(function(created) {
          createBtn.disabled = false;
          if (created && created.id) {
            renderReports(created.id);
          } else if (panel) {
            panel.textContent = 'Report fehlgeschlagen';
          }
        });
      });
    }

    var reportButtons = document.querySelectorAll('[data-report]');
    reportButtons.forEach(function(btn) {
      btn.addEventListener('click', function() {
        var reportId = Number(btn.getAttribute('data-report'));
        fillReportDetail(reportId);
      });
    });

    if (selectedReportId) {
      fillReportDetail(Number(selectedReportId));
    }
  });
}

function renderEnforcement() {
  post('listEnforcement', { filters: { page: 1, pageSize: 80 } }).then(function(data) {
    var rows = (data.rows || []).map(function(r) {
      return '<tr><td>' + r.id + '</td><td>' + (r.source_type || '-') + '</td><td>' + (r.source_key || r.source_id || '-') + '</td><td>' + (r.status || '-') + '</td><td>' + (r.next_due_date || '-') + '</td><td>' + (r.reason || '-') + '</td><td><button data-edit-enf="' + r.id + '">Bearbeiten</button></td></tr>';
    }).join('');
    content.innerHTML = '<div class="input-row"><input id="enfCaseSearch" placeholder="Bezugsfall suchen (ab 3 Zeichen)" /><select id="enfCaseSelect"><option value="">Fall wählen</option></select><select id="enfStatus"><option value="offen">offen</option><option value="erinnerung">erinnerung</option><option value="mahnung">mahnung</option><option value="letzte_frist">letzte_frist</option><option value="vollstreckung_empfohlen">vollstreckung_empfohlen</option><option value="erledigt">erledigt</option><option value="ausgesetzt">ausgesetzt</option></select><input id="enfDue" placeholder="next_due_date YYYY-MM-DD" /><select id="enfReason"><option value="">Grund wählen</option>' + reasonOptions('hohe offene Restschuld') + '</select><button id="saveEnforcement">Speichern</button></div><div class="table-wrap"><table><thead><tr><th>ID</th><th>Quelle</th><th>Fall</th><th>Status</th><th>Nächste Frist</th><th>Grund</th><th>Aktion</th></tr></thead><tbody>' + rows + '</tbody></table></div>';
    var caseMap = {};
    var caseSearch = document.getElementById('enfCaseSearch');
    var caseSelect = document.getElementById('enfCaseSelect');
    if (caseSearch && caseSelect) {
      caseSearch.addEventListener('input', debounce(function() {
        var q = caseSearch.value || '';
        if (q.length < 3) { caseSelect.innerHTML = '<option value="">Fall wählen</option>'; return; }
        post('searchCases', { query: q }).then(function(res) {
          caseMap = {};
          var options = ['<option value="">Fall wählen</option>'];
          (res.rows || []).forEach(function(r) {
            caseMap[r.value] = r;
            options.push('<option value="' + r.value + '">' + r.label + '</option>');
          });
          caseSelect.innerHTML = options.join('');
        });
      }, 240));
    }
    var btn = document.getElementById('saveEnforcement');
    if (btn) {
      btn.addEventListener('click', function() {
        var selected = caseMap[(document.getElementById('enfCaseSelect') || {}).value || ''] || {};
        post('upsertEnforcement', {
          source_type: selected.source_type || '',
          source_id: selected.source_id || null,
          source_key: selected.source_key || null,
          subject_type: 'case',
          subject_identifier: selected.value || '',
          status: (document.getElementById('enfStatus') || {}).value || 'offen',
          next_due_date: (document.getElementById('enfDue') || {}).value || null,
          reason: (document.getElementById('enfReason') || {}).value || 'weitere Nachprüfung erforderlich'
        }).then(function() { renderEnforcement(); });
      });
    }
    Array.prototype.slice.call(document.querySelectorAll('[data-edit-enf]')).forEach(function(el) {
      el.addEventListener('click', function() {
        var id = Number(el.getAttribute('data-edit-enf'));
        var row = (data.rows || []).find(function(r) { return Number(r.id) === id; });
        if (!row) return;
        openEditModal('Mahnfall bearbeiten #' + id, [
          { key: 'status', label: 'Status', value: row.status },
          { key: 'next_due_date', label: 'Nächste Frist', value: row.next_due_date },
          { key: 'reason', label: 'Grund', value: row.reason }
        ], function(values) {
          post('upsertEnforcement', {
            id: id,
            source_type: row.source_type,
            source_id: row.source_id,
            source_key: row.source_key,
            subject_type: row.subject_type,
            subject_identifier: row.subject_identifier,
            status: values.status,
            next_due_date: values.next_due_date,
            reason: values.reason
          }).then(function() { renderEnforcement(); });
        });
      });
    });
  });
}

function renderInstallments() {
  post('listInstallmentPlans', { filters: { page: 1, pageSize: 80 } }).then(function(data) {
    var rows = (data.rows || []).map(function(r) {
      return '<tr><td>' + r.id + '</td><td>' + (r.source_type || '-') + '</td><td>' + (r.source_key || '-') + '</td><td>' + money(r.total_amount) + '</td><td>' + safe(r.installment_count, 0) + '</td><td>' + money(r.installment_amount) + '</td><td>' + (r.status || '-') + '</td><td>' + (r.next_due_date || '-') + '</td></tr>';
    }).join('');
    content.innerHTML = '<div class="input-row"><input id="plCaseSearch" placeholder="Bezugsfall suchen (ab 3 Zeichen)" /><select id="plCaseSelect"><option value="">Fall wählen</option></select><input id="plTotal" placeholder="Gesamtschuld" /><input id="plDown" placeholder="Anzahlung" /><input id="plCount" placeholder="Ratenanzahl" /><input id="plAmount" placeholder="Ratenhöhe" /><input id="plStart" placeholder="Start YYYY-MM-DD" /><button id="savePlan">Plan erstellen</button></div><div class="table-wrap"><table><thead><tr><th>ID</th><th>Quelle</th><th>Fall</th><th>Gesamt</th><th>Raten</th><th>Rate</th><th>Status</th><th>Nächste Fälligkeit</th></tr></thead><tbody>' + rows + '</tbody></table></div>';
    var caseMap = {};
    var caseSearch = document.getElementById('plCaseSearch');
    var caseSelect = document.getElementById('plCaseSelect');
    if (caseSearch && caseSelect) {
      caseSearch.addEventListener('input', debounce(function() {
        var q = caseSearch.value || '';
        if (q.length < 3) { caseSelect.innerHTML = '<option value="">Fall wählen</option>'; return; }
        post('searchCases', { query: q }).then(function(res) {
          caseMap = {};
          var options = ['<option value="">Fall wählen</option>'];
          (res.rows || []).forEach(function(r) {
            caseMap[r.value] = r;
            options.push('<option value="' + r.value + '">' + r.label + '</option>');
          });
          caseSelect.innerHTML = options.join('');
        });
      }, 240));
      caseSelect.addEventListener('change', function() {
        var selected = caseMap[caseSelect.value || ''];
        if (!selected) return;
        var total = Number(selected.amount || 0);
        var count = total > 12000 ? 6 : 3;
        var amount = count > 0 ? total / count : total;
        (document.getElementById('plTotal') || {}).value = total.toFixed(2);
        (document.getElementById('plCount') || {}).value = String(count);
        (document.getElementById('plAmount') || {}).value = amount.toFixed(2);
      });
    }
    var btn = document.getElementById('savePlan');
    if (btn) {
      btn.addEventListener('click', function() {
        var selected = caseMap[(document.getElementById('plCaseSelect') || {}).value || ''] || {};
        post('createInstallmentPlan', {
          source_type: selected.source_type || '',
          source_id: selected.source_id || null,
          source_key: selected.source_key || null,
          subject_identifier: selected.value || '',
          total_amount: Number((document.getElementById('plTotal') || {}).value || 0),
          down_payment: Number((document.getElementById('plDown') || {}).value || 0),
          installment_count: Number((document.getElementById('plCount') || {}).value || 1),
          installment_amount: Number((document.getElementById('plAmount') || {}).value || 0),
          start_date: (document.getElementById('plStart') || {}).value || '',
          next_due_date: (document.getElementById('plStart') || {}).value || '',
          status: 'aktiv'
        }).then(function() { renderInstallments(); });
      });
    }
  });
}

function renderHandoffs() {
  post('listCaseHandoffs', { filters: { page: 1, pageSize: 80 } }).then(function(data) {
    var rows = (data.rows || []).map(function(r) {
      return '<tr><td>' + r.id + '</td><td>' + (r.source_type || '-') + '</td><td>' + (r.source_key || '-') + '</td><td>' + (r.target_case_number || r.target_case_id || '-') + '</td><td>' + (r.risk_band || '-') + '</td><td>' + safe(r.risk_score, 0) + '</td><td>' + (r.status || '-') + '</td></tr>';
    }).join('');
    content.innerHTML = '<div class="input-row"><input id="hoCaseSearch" placeholder="Bezugsfall suchen (ab 3 Zeichen)" /><select id="hoCaseSelect"><option value="">Fall wählen</option></select><input id="hoCaseNo" placeholder="DOJ-Akte (optional)" /><select id="hoRiskBand"><option value="unauffaellig">unauffaellig</option><option value="mittelrisiko">mittelrisiko</option><option value="hochrisiko">hochrisiko</option></select><input id="hoRiskScore" placeholder="risk_score" /><select id="hoNote"><option value="">Grund wählen</option>' + reasonOptions('weitere Nachprüfung erforderlich') + '</select><button id="saveHandoff">Handoff erstellen</button></div><div class="table-wrap"><table><thead><tr><th>ID</th><th>Quelle</th><th>Fall</th><th>DOJ Case</th><th>Band</th><th>Score</th><th>Status</th></tr></thead><tbody>' + rows + '</tbody></table></div>';
    var caseMap = {};
    var caseSearch = document.getElementById('hoCaseSearch');
    var caseSelect = document.getElementById('hoCaseSelect');
    if (caseSearch && caseSelect) {
      caseSearch.addEventListener('input', debounce(function() {
        var q = caseSearch.value || '';
        if (q.length < 3) { caseSelect.innerHTML = '<option value="">Fall wählen</option>'; return; }
        post('searchCases', { query: q }).then(function(res) {
          caseMap = {};
          var options = ['<option value="">Fall wählen</option>'];
          (res.rows || []).forEach(function(r) {
            caseMap[r.value] = r;
            options.push('<option value="' + r.value + '">' + r.label + '</option>');
          });
          caseSelect.innerHTML = options.join('');
        });
      }, 240));
    }
    var btn = document.getElementById('saveHandoff');
    if (btn) btn.addEventListener('click', function() {
      var selected = caseMap[(document.getElementById('hoCaseSelect') || {}).value || ''] || {};
      post('createCaseHandoff', {
        source_type: selected.source_type || '',
        source_id: selected.source_id || null,
        source_key: selected.source_key || null,
        target_case_id: null,
        target_case_number: (document.getElementById('hoCaseNo') || {}).value || null,
        risk_band: (document.getElementById('hoRiskBand') || {}).value || null,
        risk_score: Number((document.getElementById('hoRiskScore') || {}).value || 0) || null,
        note: (document.getElementById('hoNote') || {}).value || 'weitere Nachprüfung erforderlich'
      }).then(function() { renderHandoffs(); });
    });
  });
}

function renderNetwork() {
  content.innerHTML = '<div class="input-row"><select id="nwMode"><option value="business">Firma</option><option value="person">Person</option><option value="iban">IBAN</option><option value="plate">Kennzeichen</option><option value="identifier">Identifier</option></select><input id="nwSearch" placeholder="Sucheingabe (ab 3 Zeichen)" /><button id="loadNetwork">Suchen</button></div><div id="networkResults" class="table-wrap"></div><div id="networkPanel" class="detail-panel small">Suchmodus wählen und suchen.</div>';
  var btn = document.getElementById('loadNetwork');
  if (btn) btn.addEventListener('click', function() {
    var mode = (document.getElementById('nwMode') || {}).value || 'business';
    var query = (document.getElementById('nwSearch') || {}).value || '';
    if (query.length < 3) return;
    post('searchRegister', { mode: mode, query: query }).then(function(result) {
      var rows = result.rows || [];
      var html = rows.map(function(r) {
        return '<tr><td>' + (r.value || '-') + '</td><td>' + (r.label || '-') + '</td><td><button data-nw-open="' + (r.value || '') + '">öffnen</button></td></tr>';
      }).join('');
      var resultPanel = document.getElementById('networkResults');
      if (resultPanel) {
        resultPanel.innerHTML = '<table><thead><tr><th>Treffer</th><th>Erklärung</th><th>Aktion</th></tr></thead><tbody>' + html + '</tbody></table>';
      }
      Array.prototype.slice.call(document.querySelectorAll('[data-nw-open]')).forEach(function(openBtn) {
        openBtn.addEventListener('click', function() {
          var businessId = openBtn.getAttribute('data-nw-open') || '';
          if (!businessId || mode !== 'business') {
            var panel = document.getElementById('networkPanel');
            if (panel) panel.textContent = 'Detailansicht ist aktuell für Firmenmodus verfügbar.';
            return;
          }
          post('getNetworkProfile', { business_id: businessId }).then(function(data) {
            var panel = document.getElementById('networkPanel');
            if (!panel) return;
            if (!data || !data.business) {
              panel.textContent = 'Kein Netzwerkprofil gefunden.';
              return;
            }
            var lines = [];
            lines.push('Business: ' + (data.business.id || '-'));
            lines.push('Owners: ' + (data.owners || []).join(', '));
            lines.push('Employees: ' + (data.employees || []).slice(0, 20).join(', '));
            lines.push('Users: ' + safe((data.users || []).length, 0));
            lines.push('Vehicles: ' + safe((data.vehicles || []).length, 0));
            lines.push('DOJ Cases: ' + safe((data.doj_cases || []).length, 0));
            lines.push('Societies: ' + safe((data.societies || []).length, 0));
            panel.textContent = lines.join('\n');
          });
        });
      });
    });
  });
}

function renderDocuments() {
  post('listDocuments', { filters: { page: 1, pageSize: 100 } }).then(function(data) {
    var rows = (data.rows || []).map(function(d) {
      return '<tr><td>' + d.doc_no + '</td><td>' + d.doc_type + '</td><td>' + (d.subject_name || d.subject_identifier || '-') + '</td><td>' + d.subject + '</td><td>' + (d.status || '-') + '</td><td>' + (d.due_date || '-') + '</td><td><button data-edit-doc="' + d.id + '">Bearbeiten</button></td></tr>';
    }).join('');
    content.innerHTML = '<div class="input-row"><select id="docType"><option value="zahlungsaufforderung">zahlungsaufforderung</option><option value="erinnerung">erinnerung</option><option value="mahnung">mahnung</option><option value="letzte_frist">letzte_frist</option><option value="ratenzahlungsvereinbarung">ratenzahlungsvereinbarung</option><option value="pruefankuendigung">pruefankuendigung</option><option value="uebergabevermerk_doj">uebergabevermerk_doj</option><option value="abschlussvermerk">abschlussvermerk</option></select><input id="docCaseSearch" placeholder="Bezugsfall suchen (ab 3 Zeichen)" /><select id="docCaseSelect"><option value=\"\">Fall wählen</option></select><input id="docSubjectName" placeholder="Betroffene Person/Firma" /><input id="docSubject" placeholder="Betreff" /><input id="docDue" placeholder="Frist YYYY-MM-DD" /><input id="docBody" placeholder="Inhalt" /><select id="docStatus"><option value="entwurf">Entwurf</option><option value="erstellt">erstellt</option><option value="archiviert">archiviert</option></select><button id="previewDoc">Vorschau</button><button id="createDoc">Dokument erstellen</button></div><div id="docPreview" class="detail-panel small">Vorschau wird hier angezeigt.</div><div class="table-wrap"><table><thead><tr><th>Doc-No</th><th>Typ</th><th>Betroffen</th><th>Betreff</th><th>Status</th><th>Frist</th><th>Aktion</th></tr></thead><tbody>' + rows + '</tbody></table></div>';
    var caseMap = {};
    var caseSearch = document.getElementById('docCaseSearch');
    var caseSelect = document.getElementById('docCaseSelect');
    if (caseSearch && caseSelect) {
      caseSearch.addEventListener('input', debounce(function() {
        var q = caseSearch.value || '';
        if (q.length < 3) { caseSelect.innerHTML = '<option value="">Fall wählen</option>'; return; }
        post('searchCases', { query: q }).then(function(res) {
          caseMap = {};
          var options = ['<option value="">Fall wählen</option>'];
          (res.rows || []).forEach(function(r) {
            caseMap[r.value] = r;
            options.push('<option value="' + r.value + '">' + r.label + '</option>');
          });
          caseSelect.innerHTML = options.join('');
        });
      }, 240));
      caseSelect.addEventListener('change', function() {
        var selected = caseMap[caseSelect.value || ''];
        if (!selected) return;
        if (selected.label) (document.getElementById('docSubject') || {}).value = 'Vorgang: ' + selected.label;
      });
    }
    var previewBtn = document.getElementById('previewDoc');
    if (previewBtn) previewBtn.addEventListener('click', function() {
      var selected = caseMap[(document.getElementById('docCaseSelect') || {}).value || ''] || {};
      var preview = document.getElementById('docPreview');
      if (!preview) return;
      preview.textContent = [
        'Typ: ' + ((document.getElementById('docType') || {}).value || '-'),
        'Bezugsfall: ' + (selected.label || '-'),
        'Partei: ' + ((document.getElementById('docSubjectName') || {}).value || '-'),
        'Frist: ' + ((document.getElementById('docDue') || {}).value || '-'),
        'Betreff: ' + ((document.getElementById('docSubject') || {}).value || '-'),
        'Text: ' + ((document.getElementById('docBody') || {}).value || '-')
      ].join('\n');
    });
    var btn = document.getElementById('createDoc');
    if (btn) btn.addEventListener('click', function() {
      var selected = caseMap[(document.getElementById('docCaseSelect') || {}).value || ''] || {};
      post('createDocument', {
        doc_type: (document.getElementById('docType') || {}).value || 'zahlungsaufforderung',
        source_type: selected.source_type || '',
        source_id: selected.source_id || null,
        source_key: selected.source_key || null,
        subject_name: (document.getElementById('docSubjectName') || {}).value || '',
        subject_identifier: selected.value || '',
        subject: (document.getElementById('docSubject') || {}).value || 'Finanzbescheid',
        due_date: (document.getElementById('docDue') || {}).value || null,
        body: (document.getElementById('docBody') || {}).value || 'Amtlicher Bescheid',
        status: (document.getElementById('docStatus') || {}).value || 'entwurf'
      }).then(function() { renderDocuments(); });
    });
    Array.prototype.slice.call(document.querySelectorAll('[data-edit-doc]')).forEach(function(el) {
      el.addEventListener('click', function() {
        var id = Number(el.getAttribute('data-edit-doc'));
        var doc = (data.rows || []).find(function(r) { return Number(r.id) === id; });
        if (!doc) return;
        openEditModal('Dokument bearbeiten ' + (doc.doc_no || id), [
          { key: 'status', label: 'Status', value: doc.status },
          { key: 'due_date', label: 'Frist', value: doc.due_date },
          { key: 'subject', label: 'Betreff', value: doc.subject },
          { key: 'body', label: 'Inhalt', value: doc.body }
        ], function(values) {
          post('updateDocument', {
            id: id,
            status: values.status,
            due_date: values.due_date,
            subject: values.subject,
            body: values.body
          }).then(function() { renderDocuments(); });
        });
      });
    });
  });
}

function renderCitizens() {
  content.innerHTML = '<div class="input-row"><input id="citizenSearch" placeholder="Suche Bürger" /><button id="citizenApply">Suchen</button></div><div id="citizenResult"></div>';
  function load() {
    post('listCitizens', { filters: { page: 1, pageSize: 80, search: (document.getElementById('citizenSearch') || {}).value || '' } }).then(function(data) {
      var rows = (data.rows || []).map(function(c) {
        var flag = c.flag === 'cash_diff_high' ? '<span class="badge hochrisiko">Diff hoch</span>' : '<span class="badge unauffaellig">ok</span>';
        return '<tr><td>' + (c.name || c.identifier) + '</td><td>' + c.identifier + '</td><td>' + money(c.incoming) + '</td><td>' + money(c.outgoing) + '</td><td>' + money(c.billing_open) + '</td><td>' + money(c.declared_cash) + '</td><td>' + money(c.expected_cash) + '</td><td>' + money(c.cash_diff) + '</td><td>' + c.score + '</td><td>' + flag + '</td></tr>';
      }).join('');
      var result = document.getElementById('citizenResult');
      if (result) result.innerHTML = '<div class="table-wrap"><table><thead><tr><th>Name</th><th>Identifier</th><th>Ein</th><th>Aus</th><th>Offen Billing</th><th>Declared Cash</th><th>Expected Cash</th><th>Differenz</th><th>Score</th><th>Flag</th></tr></thead><tbody>' + rows + '</tbody></table></div>';
    });
  }
  var btn = document.getElementById('citizenApply');
  if (btn) btn.addEventListener('click', load);
  load();
}

function renderMapping() {
  post('getBusinessMaps', {}).then(function(maps) {
    var rows = (maps.rows || []).map(function(m) {
      return '<tr><td>' + m.tax_job + '</td><td>' + m.business_id + '</td><td>' + (m.alias || '-') + '</td></tr>';
    }).join('');

    content.innerHTML = '<div class="input-row"><input id="taxJob" placeholder="tax_job (ab 3 Zeichen)" /><input id="businessId" placeholder="business_id (ab 3 Zeichen)" /><input id="alias" placeholder="alias (optional)" /><button id="mapSearch">Suchen</button><button id="saveMap">Speichern</button></div><div class="table-wrap"><table><thead><tr><th>tax_job</th><th>business_id</th><th>alias</th></tr></thead><tbody>' + rows + '</tbody></table></div>';
    attachLookup('businessId', 'business');
    attachLookup('taxJob', 'business');

    var searchBtn = document.getElementById('mapSearch');
    if (searchBtn) searchBtn.addEventListener('click', function() {
      renderMapping();
    });

    var saveBtn = document.getElementById('saveMap');
    if (saveBtn) {
      saveBtn.addEventListener('click', function() {
        var payload = {
          tax_job: (document.getElementById('taxJob') || {}).value || '',
          business_id: (document.getElementById('businessId') || {}).value || '',
          alias: (document.getElementById('alias') || {}).value || ''
        };
        post('upsertBusinessMap', payload).then(function() { renderMapping(); });
      });
    }
  });
}

function render() {
  if (state.tab === 'dashboard') return renderDashboard();
  if (state.tab === 'private') return renderPrivate();
  if (state.tab === 'business') return renderBusiness();
  if (state.tab === 'companies') return renderCompanies();
  if (state.tab === 'transactions') return renderTransactions();
  if (state.tab === 'enforcement') return renderEnforcement();
  if (state.tab === 'installments') return renderInstallments();
  if (state.tab === 'handoffs') return renderHandoffs();
  if (state.tab === 'network') return renderNetwork();
  if (state.tab === 'documents') return renderDocuments();
  if (state.tab === 'citizens') return renderCitizens();
  if (state.tab === 'reports') return renderReports();
  if (state.tab === 'mapping') return renderMapping();
}

closeBtn.addEventListener('click', function() { post('close', {}); });

tabs.forEach(function(tab) {
  tab.addEventListener('click', function() { setTab(tab.dataset.tab); });
});

window.addEventListener('message', function(event) {
  var msg = event.data || {};
  if (msg.action === 'open') {
    app.classList.remove('hidden');
    content.innerHTML = '<div class="card"><h3>Tablet wird geladen...</h3><div class="small">Lade Dashboard...</div></div>';
    setTab('dashboard');
    return;
  }

  if (msg.action === 'close') {
    app.classList.add('hidden');
  }
});

window.addEventListener('load', function() {
  post('uiReady', {}).catch(function() {});
});

window.addEventListener('keydown', function(e) {
  if (e.key === 'Escape') {
    post('close', {}).catch(function() {});
  }
});
