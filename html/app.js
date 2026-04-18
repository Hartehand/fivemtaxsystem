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
        var lines = [];
        lines.push('Status: ' + ((bundle.review && bundle.review.status) || 'neu'));
        lines.push('Bearbeiter: ' + ((bundle.review && bundle.review.assigned_to) || '-'));
        lines.push('Deadline: ' + ((bundle.deadline && bundle.deadline.due_date) || 'Standard'));
        lines.push('--- Notizen ---');
        (bundle.notes || []).slice(0, 8).forEach(function(n) { lines.push((n.author_identifier || '-') + ': ' + (n.note || '-')); });
        lines.push('--- Audit ---');
        (bundle.audit || []).slice(0, 8).forEach(function(a) { lines.push((a.created_at || '-') + ': ' + (a.action || '-')); });

        var panel = document.getElementById('detail');
        if (!panel) return;
        panel.innerHTML = lines.join('<br/>') +
          '<div class="input-row" style="margin-top:10px;">' +
          '<button id="caseStartReview">Prüfverfahren starten</button>' +
          '<input id="casePriority" placeholder="Priorität (low/normal/high)" />' +
          '<input id="caseDojCase" placeholder="DOJ Case ID" />' +
          '<input id="caseNote" placeholder="Notiztext" />' +
          '<button id="caseSaveNote">Notiz speichern</button>' +
          '<button id="caseSaveMeta">Meta speichern</button>' +
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
            var dojCase = Number((document.getElementById('caseDojCase') || {}).value || 0);
            post('setCaseMeta', {
              source_type: detail.source_type,
              source_id: detail.source_id || null,
              source_key: detail.source_key || null,
              priority: priority,
              doj_case_id: dojCase > 0 ? dojCase : null,
              evidence: { reason_snapshot: lines.slice(0, 6) }
            });
          });
        }

        post('getCaseTimeline', {
          source_type: detail.source_type,
          source_id: detail.source_id || null,
          source_key: detail.source_key || null
        }).then(function(tl) {
          var rows = (tl.rows || []).slice(0, 15).map(function(e) {
            return (e.created_at || '-') + ' | ' + (e.kind || '-') + ' | ' + (e.title || '-');
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
  if (state.tab === 'companies') return renderCompanies();
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
