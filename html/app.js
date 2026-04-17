const app = document.getElementById('app');
const content = document.getElementById('content');
const tabs = Array.prototype.slice.call(document.querySelectorAll('.tabs button'));
const closeBtn = document.getElementById('closeBtn');

var state = { tab: 'dashboard' };

function safe(v, d) { return (v === undefined || v === null) ? d : v; }

async function post(action, data) {
  const res = await fetch('https://' + GetParentResourceName() + '/' + action, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data || {})
  });
  return res.json();
}

function setTab(tab) {
  state.tab = tab;
  tabs.forEach(function(t) { t.classList.toggle('active', t.dataset.tab === tab); });
  render();
}

function badge(band) {
  var b = band || 'unauffaellig';
  return '<span class="badge ' + b + '">' + b + '</span>';
}

async function renderDashboard() {
  var data = await post('getDashboard');
  var highRisk = data.highRiskCases || [];
  var privateRisk = data.private && data.private.risk ? data.private.risk : { score: 0, band: 'unauffaellig', reasons: [] };

  content.innerHTML = '' +
    '<div class="grid">' +
      '<div class="card"><h3>Privatrisiko</h3><div class="val">' + safe(privateRisk.score, 0) + '</div>' + badge(privateRisk.band) + '</div>' +
      '<div class="card"><h3>Business Hochrisiko</h3><div class="val">' + safe(data.business && data.business.highRiskCount, 0) + '</div></div>' +
      '<div class="card"><h3>Häufige Schuldner</h3><div class="val">' + safe(data.business && data.business.debtorCount, 0) + '</div></div>' +
      '<div class="card"><h3>Business-Fälle</h3><div class="val">' + safe(data.business && data.business.total, 0) + '</div></div>' +
    '</div>' +
    '<div class="detail-panel">' + ((privateRisk.reasons || []).join('\n') || 'Keine besonderen Hinweise') + '</div>' +
    '<div class="table-wrap"><table><thead><tr><th>Unternehmen</th><th>Score</th><th>Band</th><th>Restschuld</th><th>Gründe</th></tr></thead><tbody>' +
      highRisk.map(function(r) {
        var meta = r.meta || {};
        var risk = r.risk || {};
        return '<tr><td>' + (r.job_label || r.job || '-') + '</td><td>' + safe(risk.score, 0) + '</td><td>' + badge(risk.band) + '</td><td>$' + Number(safe(meta.restDebt, 0)).toFixed(2) + '</td><td>' + (risk.reasons || []).join(', ') + '</td></tr>';
      }).join('') +
    '</tbody></table></div>';
}

async function renderPrivate() {
  var data = await post('getPrivateCases', { page: 1, pageSize: 50, filters: {} });
  var rows = data.rows || [];

  content.innerHTML = '<div class="small">Gesamt: ' + safe(data.count, 0) + '</div>' +
    '<div class="table-wrap"><table><thead><tr><th>ID</th><th>Name</th><th>Status</th><th>Betrag</th><th>Due</th><th>Aktion</th></tr></thead><tbody>' +
    rows.map(function(r) {
      return '<tr><td>' + r.id + '</td><td>' + (r.receiver_name || r.receiver || '-') + '</td><td>' + (r.status || '-') + '</td><td>$' + Number(safe(r.amount,0)).toFixed(2) + '</td><td>' + (r.due_date || '-') + '</td><td><button data-detail="' + encodeURIComponent(JSON.stringify({ source_type: 'taxes', source_id: r.id })) + '">Akte</button></td></tr>';
    }).join('') +
    '</tbody></table></div><div id="detail" class="detail-panel small">Wähle einen Fall.</div>';

  bindDetailButtons();
}

async function renderBusiness() {
  var data = await post('getBusinessCases', { page: 1, pageSize: 50, filters: {} });
  var rows = data.rows || [];

  content.innerHTML = '<div class="small">Gesamt: ' + safe(data.count, 0) + '</div>' +
    '<div class="table-wrap"><table><thead><tr><th>Job</th><th>Periode</th><th>Firma</th><th>Status</th><th>Restschuld</th><th>Aktion</th></tr></thead><tbody>' +
    rows.map(function(r) {
      var sourceKey = (r.job || '') + '|' + (r.period || '');
      return '<tr><td>' + (r.job_label || r.job || '-') + '</td><td>' + (r.period || '-') + '</td><td>' + (r.business_id || '-') + '</td><td>' + (r.status || '-') + '</td><td>$' + Number(safe(r.restschuld,0)).toFixed(2) + '</td><td><button data-detail="' + encodeURIComponent(JSON.stringify({ source_type: 'taxes_business', source_key: sourceKey })) + '">Akte</button></td></tr>';
    }).join('') +
    '</tbody></table></div><div id="detail" class="detail-panel small">Wähle einen Fall.</div>';

  bindDetailButtons();
}

async function renderTransactions() {
  var data = await post('getTransactions', { page: 1, pageSize: 80, filters: {} });
  var analysis = data.analysis || { score: 0, band: 'unauffaellig', reasons: [] };
  var w = data.windows || {};
  var w7 = w[7] || { incoming: 0, outgoing: 0 };

  content.innerHTML = '' +
    '<div class="grid">' +
      '<div class="card"><h3>Analyse Score</h3><div class="val">' + safe(analysis.score,0) + '</div>' + badge(analysis.band) + '</div>' +
      '<div class="card"><h3>Offene Steuerlast</h3><div class="val">$' + Number(safe(data.openDebt,0)).toFixed(2) + '</div></div>' +
      '<div class="card"><h3>7T Eingänge</h3><div class="val">$' + Number(safe(w7.incoming,0)).toFixed(2) + '</div></div>' +
      '<div class="card"><h3>7T Ausgänge</h3><div class="val">$' + Number(safe(w7.outgoing,0)).toFixed(2) + '</div></div>' +
    '</div>' +
    '<div class="detail-panel">' + ((analysis.reasons || []).join('\n') || 'Keine Auffälligkeit erkannt') + '</div>' +
    '<div class="table-wrap"><table><thead><tr><th>ID</th><th>Typ</th><th>Betrag</th><th>Sender</th><th>Empfänger</th><th>Datum</th></tr></thead><tbody>' +
      (data.rows || []).map(function(tx) {
        return '<tr><td>' + tx.id + '</td><td>' + (tx.type || '-') + '</td><td>$' + Number(safe(tx.value,0)).toFixed(2) + '</td><td>' + (tx.sender_name || '-') + '</td><td>' + (tx.receiver_name || '-') + '</td><td>' + (tx.date || '-') + '</td></tr>';
      }).join('') +
    '</tbody></table></div>';
}

async function renderReports() {
  var list = await post('listReports', { filters: { page: 1, pageSize: 50 } });

  content.innerHTML = '<div class="input-row"><select id="reportType">' +
    '<option value="schuldnerreport">schuldnerreport</option>' +
    '<option value="hochrisikoreport">hochrisikoreport</option>' +
    '<option value="transaktionsauffaelligkeit">transaktionsauffaelligkeit</option>' +
    '<option value="zahlungsverhalten">zahlungsverhalten</option>' +
    '</select><button id="createReport">Report erstellen</button></div>' +
    '<div class="table-wrap"><table><thead><tr><th>ID</th><th>Typ</th><th>Titel</th><th>Ersteller</th><th>Datum</th></tr></thead><tbody>' +
    (list.rows || []).map(function(r) {
      return '<tr><td>' + r.id + '</td><td>' + r.report_type + '</td><td>' + r.title + '</td><td>' + r.created_by + '</td><td>' + r.created_at + '</td></tr>';
    }).join('') +
    '</tbody></table></div>';

  var createBtn = document.getElementById('createReport');
  if (createBtn) {
    createBtn.addEventListener('click', async function() {
      var select = document.getElementById('reportType');
      var reportType = select ? select.value : 'schuldnerreport';
      var created = await post('createReport', { report_type: reportType, payload: {} });
      alert(created && created.id ? ('Report erstellt: ' + created.id) : 'Report fehlgeschlagen');
      renderReports();
    });
  }
}

async function renderMapping() {
  var maps = await post('getBusinessMaps');
  content.innerHTML = '<div class="input-row">' +
    '<input id="taxJob" placeholder="tax_job" />' +
    '<input id="businessId" placeholder="business_id" />' +
    '<input id="alias" placeholder="alias (optional)" />' +
    '<button id="saveMap">Speichern</button>' +
    '</div><div class="table-wrap"><table><thead><tr><th>tax_job</th><th>business_id</th><th>alias</th></tr></thead><tbody>' +
    (maps.rows || []).map(function(m) {
      return '<tr><td>' + m.tax_job + '</td><td>' + m.business_id + '</td><td>' + (m.alias || '-') + '</td></tr>';
    }).join('') +
    '</tbody></table></div>';

  var saveBtn = document.getElementById('saveMap');
  if (saveBtn) {
    saveBtn.addEventListener('click', async function() {
      var payload = {
        tax_job: (document.getElementById('taxJob') || {}).value || '',
        business_id: (document.getElementById('businessId') || {}).value || '',
        alias: (document.getElementById('alias') || {}).value || ''
      };
      await post('upsertBusinessMap', payload);
      renderMapping();
    });
  }
}

async function render() {
  if (state.tab === 'dashboard') return renderDashboard();
  if (state.tab === 'private') return renderPrivate();
  if (state.tab === 'business') return renderBusiness();
  if (state.tab === 'transactions') return renderTransactions();
  if (state.tab === 'reports') return renderReports();
  if (state.tab === 'mapping') return renderMapping();
}

function bindDetailButtons() {
  var buttons = document.querySelectorAll('[data-detail]');
  buttons.forEach(function(btn) {
    btn.addEventListener('click', async function() {
      var raw = btn.getAttribute('data-detail');
      var payload = JSON.parse(decodeURIComponent(raw));
      var detail = await post('getCaseDetail', payload);
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
}

closeBtn.addEventListener('click', function() { post('close'); });

tabs.forEach(function(tab) {
  tab.addEventListener('click', function() { setTab(tab.dataset.tab); });
});

window.addEventListener('message', function(event) {
  var msg = event.data || {};
  if (msg.action === 'open') {
    app.classList.remove('hidden');
    setTab('dashboard');
  }
  if (msg.action === 'close') {
    app.classList.add('hidden');
  }
});
