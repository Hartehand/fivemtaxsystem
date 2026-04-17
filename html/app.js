var app = document.getElementById('app');
var content = document.getElementById('content');
var tabs = Array.prototype.slice.call(document.querySelectorAll('.tabs button'));
var closeBtn = document.getElementById('closeBtn');
var state = { tab: 'dashboard' };

function safe(v, d) { return (v === undefined || v === null) ? d : v; }

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

function badge(band) {
  var b = band || 'unauffaellig';
  return '<span class="badge ' + b + '">' + b + '</span>';
}

function setTab(tab) {
  state.tab = tab;
  tabs.forEach(function(t) { t.classList.toggle('active', t.dataset.tab === tab); });
  try {
    render();
  } catch (e) {
    console.error('[doj_finance_suite][nui] render error', e);
  }
}

function renderDashboard() {
  post('getDashboard', {}).then(function(data) {
    var risk = (data.private && data.private.risk) || { score: 0, band: 'unauffaellig', reasons: [] };
    var high = data.highRiskCases || [];
    var rows = high.map(function(r) {
      var meta = r.meta || {};
      var rr = r.risk || {};
      return '<tr><td>' + (r.job_label || r.job || '-') + '</td><td>' + safe(rr.score, 0) + '</td><td>' + badge(rr.band) + '</td><td>$' + Number(safe(meta.restDebt, 0)).toFixed(2) + '</td><td>' + (rr.reasons || []).join(', ') + '</td></tr>';
    }).join('');

    content.innerHTML = '' +
      '<div class="grid">' +
      '<div class="card"><h3>Privatrisiko</h3><div class="val">' + safe(risk.score, 0) + '</div>' + badge(risk.band) + '</div>' +
      '<div class="card"><h3>Business Hochrisiko</h3><div class="val">' + safe(data.business && data.business.highRiskCount, 0) + '</div></div>' +
      '<div class="card"><h3>Häufige Schuldner</h3><div class="val">' + safe(data.business && data.business.debtorCount, 0) + '</div></div>' +
      '<div class="card"><h3>Business-Fälle</h3><div class="val">' + safe(data.business && data.business.total, 0) + '</div></div>' +
      '</div>' +
      '<div class="detail-panel">' + ((risk.reasons || []).join('\n') || 'Keine besonderen Hinweise') + '</div>' +
      '<div class="table-wrap"><table><thead><tr><th>Unternehmen</th><th>Score</th><th>Band</th><th>Restschuld</th><th>Gründe</th></tr></thead><tbody>' + rows + '</tbody></table></div>';
  });
}

function bindDetailButtons() {
  var buttons = document.querySelectorAll('[data-detail]');
  buttons.forEach(function(btn) {
    btn.addEventListener('click', function() {
      var raw = btn.getAttribute('data-detail');
      var payload = JSON.parse(decodeURIComponent(raw));
      post('getCaseDetail', payload).then(function(detail) {
        var bundle = detail.bundle || {};
        var lines = [];
        lines.push('Status: ' + ((bundle.review && bundle.review.status) || 'neu'));
        lines.push('Bearbeiter: ' + ((bundle.review && bundle.review.assigned_to) || '-'));
        lines.push('Deadline: ' + ((bundle.deadline && bundle.deadline.due_date) || 'Standard'));
        lines.push('--- Notizen ---');
        (bundle.notes || []).slice(0, 8).forEach(function(n) { lines.push((n.author_identifier || '-') + ': ' + (n.note || '-')); });
        lines.push('--- Audit ---');
        (bundle.audit || []).slice(0, 8).forEach(function(a) { lines.push((a.created_at || '-') + ': ' + (a.action || '-')); });
        var panel = document.getElementById('detail');
        if (panel) panel.textContent = lines.join('\n');
      });
    });
  });
}

function renderPrivate() {
  post('getPrivateCases', { page: 1, pageSize: 50, filters: {} }).then(function(data) {
    var rows = (data.rows || []).map(function(r) {
      var payload = encodeURIComponent(JSON.stringify({ source_type: 'taxes', source_id: r.id }));
      return '<tr><td>' + r.id + '</td><td>' + (r.receiver_name || r.receiver || '-') + '</td><td>' + (r.status || '-') + '</td><td>$' + Number(safe(r.amount,0)).toFixed(2) + '</td><td>' + (r.due_date || '-') + '</td><td><button data-detail="' + payload + '">Akte</button></td></tr>';
    }).join('');

    content.innerHTML = '<div class="small">Gesamt: ' + safe(data.count, 0) + '</div><div class="table-wrap"><table><thead><tr><th>ID</th><th>Name</th><th>Status</th><th>Betrag</th><th>Due</th><th>Aktion</th></tr></thead><tbody>' + rows + '</tbody></table></div><div id="detail" class="detail-panel small">Wähle einen Fall.</div>';
    bindDetailButtons();
  });
}

function renderBusiness() {
  post('getBusinessCases', { page: 1, pageSize: 50, filters: {} }).then(function(data) {
    var rows = (data.rows || []).map(function(r) {
      var payload = encodeURIComponent(JSON.stringify({ source_type: 'taxes_business', source_key: (r.job || '') + '|' + (r.period || '') }));
      return '<tr><td>' + (r.job_label || r.job || '-') + '</td><td>' + (r.period || '-') + '</td><td>' + (r.business_id || '-') + '</td><td>' + (r.status || '-') + '</td><td>$' + Number(safe(r.restschuld,0)).toFixed(2) + '</td><td><button data-detail="' + payload + '">Akte</button></td></tr>';
    }).join('');

    content.innerHTML = '<div class="small">Gesamt: ' + safe(data.count, 0) + '</div><div class="table-wrap"><table><thead><tr><th>Job</th><th>Periode</th><th>Firma</th><th>Status</th><th>Restschuld</th><th>Aktion</th></tr></thead><tbody>' + rows + '</tbody></table></div><div id="detail" class="detail-panel small">Wähle einen Fall.</div>';
    bindDetailButtons();
  });
}

function renderTransactions() {
  post('getTransactions', { page: 1, pageSize: 80, filters: {} }).then(function(data) {
    var analysis = data.analysis || { score: 0, band: 'unauffaellig', reasons: [] };
    var w = data.windows || {};
    var w7 = w[7] || { incoming: 0, outgoing: 0 };
    var rows = (data.rows || []).map(function(tx) {
      return '<tr><td>' + tx.id + '</td><td>' + (tx.type || '-') + '</td><td>$' + Number(safe(tx.value,0)).toFixed(2) + '</td><td>' + (tx.sender_name || '-') + '</td><td>' + (tx.receiver_name || '-') + '</td><td>' + (tx.date || '-') + '</td></tr>';
    }).join('');

    content.innerHTML = '<div class="grid"><div class="card"><h3>Analyse Score</h3><div class="val">' + safe(analysis.score,0) + '</div>' + badge(analysis.band) + '</div><div class="card"><h3>Offene Steuerlast</h3><div class="val">$' + Number(safe(data.openDebt,0)).toFixed(2) + '</div></div><div class="card"><h3>7T Eingänge</h3><div class="val">$' + Number(safe(w7.incoming,0)).toFixed(2) + '</div></div><div class="card"><h3>7T Ausgänge</h3><div class="val">$' + Number(safe(w7.outgoing,0)).toFixed(2) + '</div></div></div><div class="detail-panel">' + ((analysis.reasons || []).join('\n') || 'Keine Auffälligkeit erkannt') + '</div><div class="table-wrap"><table><thead><tr><th>ID</th><th>Typ</th><th>Betrag</th><th>Sender</th><th>Empfänger</th><th>Datum</th></tr></thead><tbody>' + rows + '</tbody></table></div>';
  });
}

function renderReports() {
  post('listReports', { filters: { page: 1, pageSize: 50 } }).then(function(list) {
    var rows = (list.rows || []).map(function(r) {
      return '<tr><td>' + r.id + '</td><td>' + r.report_type + '</td><td>' + r.title + '</td><td>' + r.created_by + '</td><td>' + r.created_at + '</td></tr>';
    }).join('');

    content.innerHTML = '<div class="input-row"><select id="reportType"><option value="schuldnerreport">schuldnerreport</option><option value="hochrisikoreport">hochrisikoreport</option><option value="transaktionsauffaelligkeit">transaktionsauffaelligkeit</option><option value="zahlungsverhalten">zahlungsverhalten</option></select><button id="createReport">Report erstellen</button></div><div class="table-wrap"><table><thead><tr><th>ID</th><th>Typ</th><th>Titel</th><th>Ersteller</th><th>Datum</th></tr></thead><tbody>' + rows + '</tbody></table></div>';

    var createBtn = document.getElementById('createReport');
    if (createBtn) {
      createBtn.addEventListener('click', function() {
        var select = document.getElementById('reportType');
        var reportType = select ? select.value : 'schuldnerreport';
        post('createReport', { report_type: reportType, payload: {} }).then(function(created) {
          alert(created && created.id ? ('Report erstellt: ' + created.id) : 'Report fehlgeschlagen');
          renderReports();
        });
      });
    }
  });
}

function renderMapping() {
  post('getBusinessMaps', {}).then(function(maps) {
    var rows = (maps.rows || []).map(function(m) {
      return '<tr><td>' + m.tax_job + '</td><td>' + m.business_id + '</td><td>' + (m.alias || '-') + '</td></tr>';
    }).join('');

    content.innerHTML = '<div class="input-row"><input id="taxJob" placeholder="tax_job" /><input id="businessId" placeholder="business_id" /><input id="alias" placeholder="alias (optional)" /><button id="saveMap">Speichern</button></div><div class="table-wrap"><table><thead><tr><th>tax_job</th><th>business_id</th><th>alias</th></tr></thead><tbody>' + rows + '</tbody></table></div>';

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
  if (state.tab === 'transactions') return renderTransactions();
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
    console.log('[doj_finance_suite][nui] open message received', msg);
    app.classList.remove('hidden');
    content.innerHTML = '<div class=\"card\"><h3>Tablet wird geladen...</h3><div class=\"small\">Falls Datenzugriff eingeschränkt ist, bleibt die Ansicht trotzdem geöffnet.</div></div>';
    try {
      setTab('dashboard');
    } catch (e) {
      console.error('[doj_finance_suite][nui] open->setTab failed', e);
    }
    return;
  }

  if (msg.action === 'hydrate') {
    console.log('[doj_finance_suite][nui] hydrate message received', msg);
    return;
  }

  if (msg.action === 'close') {
    console.log('[doj_finance_suite][nui] close message received');
    app.classList.add('hidden');
  }
});

window.addEventListener('load', function() {
  console.log('[doj_finance_suite][nui] window loaded, sending uiReady');
  post('uiReady', {}).catch(function() {});
});

window.addEventListener('keydown', function(e) {
  if (e.key === 'Escape') {
    post('close', {}).catch(function() {});
  }
});
