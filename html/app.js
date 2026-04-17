const app = document.getElementById('app');
const content = document.getElementById('content');
const tabs = Array.from(document.querySelectorAll('.tabs button'));
const closeBtn = document.getElementById('closeBtn');

let state = { tab: 'dashboard' };

const post = async (action, data = {}) => {
  const res = await fetch(`https://${GetParentResourceName()}/${action}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data)
  });
  return res.json();
};

const setTab = (tab) => {
  state.tab = tab;
  tabs.forEach(t => t.classList.toggle('active', t.dataset.tab === tab));
  render();
};

const badge = (band) => `<span class="badge ${band || 'unauffaellig'}">${band || 'unauffaellig'}</span>`;

const renderDashboard = async () => {
  const data = await post('getDashboard');
  content.innerHTML = `
    <div class="grid">
      <div class="card"><h3>Privatrisiko</h3><div class="val">${data.private?.risk?.score ?? 0}</div>${badge(data.private?.risk?.band)}</div>
      <div class="card"><h3>Business Hochrisiko</h3><div class="val">${data.business?.highRiskCount ?? 0}</div></div>
      <div class="card"><h3>Häufige Schuldner</h3><div class="val">${data.business?.debtorCount ?? 0}</div></div>
      <div class="card"><h3>Business-Fälle</h3><div class="val">${data.business?.total ?? 0}</div></div>
    </div>
    <div class="detail-panel">${(data.private?.risk?.reasons || []).join('\n') || 'Keine besonderen Hinweise'}</div>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Unternehmen</th><th>Score</th><th>Band</th><th>Restschuld</th><th>Gründe</th></tr></thead>
        <tbody>
          ${(data.highRiskCases || []).map(r => `<tr><td>${r.job_label || r.job}</td><td>${r.risk?.score ?? 0}</td><td>${badge(r.risk?.band)}</td><td>$${(r.meta?.restDebt || 0).toFixed(2)}</td><td>${(r.risk?.reasons || []).join(', ')}</td></tr>`).join('')}
        </tbody>
      </table>
    </div>
  `;
};

const renderPrivate = async () => {
  const data = await post('getPrivateCases', { page: 1, pageSize: 50, filters: {} });
  content.innerHTML = `
    <div class="small">Gesamt: ${data.count || 0}</div>
    <div class="table-wrap"><table>
      <thead><tr><th>ID</th><th>Name</th><th>Status</th><th>Betrag</th><th>Due</th><th>Aktion</th></tr></thead>
      <tbody>
        ${(data.rows || []).map(r => `<tr>
          <td>${r.id}</td><td>${r.receiver_name || r.receiver}</td><td>${r.status}</td><td>$${(+r.amount).toFixed(2)}</td><td>${r.due_date || '-'}</td>
          <td><button data-detail='${JSON.stringify({ source_type: 'taxes', source_id: r.id })}'>Akte</button></td>
        </tr>`).join('')}
      </tbody></table></div>
    <div id="detail" class="detail-panel small">Wähle einen Fall.</div>
  `;
  bindDetailButtons();
};

const renderBusiness = async () => {
  const data = await post('getBusinessCases', { page: 1, pageSize: 50, filters: {} });
  content.innerHTML = `
    <div class="small">Gesamt: ${data.count || 0}</div>
    <div class="table-wrap"><table>
      <thead><tr><th>Job</th><th>Periode</th><th>Firma</th><th>Status</th><th>Restschuld</th><th>Aktion</th></tr></thead>
      <tbody>
        ${(data.rows || []).map(r => {
          const sourceKey = `${r.job}|${r.period}`;
          return `<tr>
          <td>${r.job_label || r.job}</td><td>${r.period}</td><td>${r.business_id || '-'}</td><td>${r.status}</td><td>$${(+r.restschuld).toFixed(2)}</td>
          <td><button data-detail='${JSON.stringify({ source_type: 'taxes_business', source_key: sourceKey })}'>Akte</button></td>
        </tr>`
        }).join('')}
      </tbody></table></div>
    <div id="detail" class="detail-panel small">Wähle einen Fall.</div>
  `;
  bindDetailButtons();
};

const renderTransactions = async () => {
  const data = await post('getTransactions', { page: 1, pageSize: 80, filters: {} });
  content.innerHTML = `
    <div class="grid">
      <div class="card"><h3>Analyse Score</h3><div class="val">${data.analysis?.score ?? 0}</div>${badge(data.analysis?.band)}</div>
      <div class="card"><h3>Offene Steuerlast</h3><div class="val">$${(data.openDebt || 0).toFixed(2)}</div></div>
      <div class="card"><h3>7T Eingänge</h3><div class="val">$${(data.windows?.[7]?.incoming || 0).toFixed(2)}</div></div>
      <div class="card"><h3>7T Ausgänge</h3><div class="val">$${(data.windows?.[7]?.outgoing || 0).toFixed(2)}</div></div>
    </div>
    <div class="detail-panel">${(data.analysis?.reasons || []).join('\n') || 'Keine Auffälligkeit erkannt'}</div>
    <div class="table-wrap"><table>
      <thead><tr><th>ID</th><th>Typ</th><th>Betrag</th><th>Sender</th><th>Empfänger</th><th>Datum</th></tr></thead>
      <tbody>
        ${(data.rows || []).map(tx => `<tr><td>${tx.id}</td><td>${tx.type || '-'}</td><td>$${(+tx.value).toFixed(2)}</td><td>${tx.sender_name || '-'}</td><td>${tx.receiver_name || '-'}</td><td>${tx.date || '-'}</td></tr>`).join('')}
      </tbody></table></div>
  `;
};

const renderReports = async () => {
  const list = await post('listReports', { filters: { page: 1, pageSize: 50 } });
  content.innerHTML = `
    <div class="input-row">
      <select id="reportType">
        <option value="schuldnerreport">schuldnerreport</option>
        <option value="hochrisikoreport">hochrisikoreport</option>
        <option value="transaktionsauffaelligkeit">transaktionsauffaelligkeit</option>
        <option value="zahlungsverhalten">zahlungsverhalten</option>
      </select>
      <button id="createReport">Report erstellen</button>
    </div>
    <div class="table-wrap"><table>
      <thead><tr><th>ID</th><th>Typ</th><th>Titel</th><th>Ersteller</th><th>Datum</th></tr></thead>
      <tbody>${(list.rows || []).map(r => `<tr><td>${r.id}</td><td>${r.report_type}</td><td>${r.title}</td><td>${r.created_by}</td><td>${r.created_at}</td></tr>`).join('')}</tbody>
    </table></div>
  `;

  document.getElementById('createReport')?.addEventListener('click', async () => {
    const report_type = document.getElementById('reportType').value;
    const created = await post('createReport', { report_type, payload: {} });
    alert(created?.id ? `Report erstellt: ${created.id}` : 'Report fehlgeschlagen');
    renderReports();
  });
};

const renderMapping = async () => {
  const maps = await post('getBusinessMaps');
  content.innerHTML = `
    <div class="input-row">
      <input id="taxJob" placeholder="tax_job" />
      <input id="businessId" placeholder="business_id" />
      <input id="alias" placeholder="alias (optional)" />
      <button id="saveMap">Speichern</button>
    </div>
    <div class="table-wrap"><table>
      <thead><tr><th>tax_job</th><th>business_id</th><th>alias</th></tr></thead>
      <tbody>${(maps.rows || []).map(m => `<tr><td>${m.tax_job}</td><td>${m.business_id}</td><td>${m.alias || '-'}</td></tr>`).join('')}</tbody>
    </table></div>
  `;

  document.getElementById('saveMap')?.addEventListener('click', async () => {
    const payload = {
      tax_job: document.getElementById('taxJob').value,
      business_id: document.getElementById('businessId').value,
      alias: document.getElementById('alias').value
    };
    await post('upsertBusinessMap', payload);
    renderMapping();
  });
};

const render = async () => {
  if (state.tab === 'dashboard') return renderDashboard();
  if (state.tab === 'private') return renderPrivate();
  if (state.tab === 'business') return renderBusiness();
  if (state.tab === 'transactions') return renderTransactions();
  if (state.tab === 'reports') return renderReports();
  if (state.tab === 'mapping') return renderMapping();
};

const bindDetailButtons = () => {
  document.querySelectorAll('[data-detail]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const payload = JSON.parse(btn.getAttribute('data-detail'));
      const detail = await post('getCaseDetail', payload);
      const bundle = detail.bundle || {};
      const lines = [];
      lines.push(`Status: ${bundle.review?.status || 'neu'}`);
      lines.push(`Bearbeiter: ${bundle.review?.assigned_to || '-'}`);
      lines.push(`Deadline: ${bundle.deadline?.due_date || 'Standard'}`);
      lines.push('--- Notizen ---');
      (bundle.notes || []).slice(0, 8).forEach(n => lines.push(`${n.author_identifier}: ${n.note}`));
      lines.push('--- Audit ---');
      (bundle.audit || []).slice(0, 8).forEach(a => lines.push(`${a.created_at}: ${a.action}`));
      document.getElementById('detail').textContent = lines.join('\n');
    });
  });
};

closeBtn.addEventListener('click', () => post('close'));
tabs.forEach(tab => tab.addEventListener('click', () => setTab(tab.dataset.tab)));

window.addEventListener('message', (event) => {
  const msg = event.data;
  if (msg.action === 'open') {
    app.classList.remove('hidden');
    setTab('dashboard');
  }
  if (msg.action === 'close') {
    app.classList.add('hidden');
  }
});
