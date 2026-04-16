# doj_finance_suite

`doj_finance_suite` ist eine produktionsreife FiveM-Resource für **ESX + oxmysql + ox_lib**, die bestehende Steuer-/Finanzdaten als Finanzamt-Backoffice visualisiert und um Prüf-Workflow-Metadaten ergänzt.

## Zielbild

Die Resource baut **kein neues Steuersystem** auf, sondern arbeitet als Finanzsoftware-Dashboard auf bestehenden Tabellen:

- `taxes` (Privatsteuerfälle)
- `taxes_business` (Business-Steuerperioden)
- `vms_business` (Business-Stammdaten / Kennzahlen im JSON-Feld `data`)
- `okokbanking_societies` (Gesellschaftskonten)
- `okokbanking_transactions` (Transaktionshistorie)

Diese Tabellen bleiben **Source of Truth**. Es werden nur zusätzliche Hilfstabellen für Workflow/Review/Reporting angelegt.

---

## Features (Überblick)

- **Dashboard** mit Kennzahlen zu offenen/bezahlten/stornierten Privatsteuern, offenen Business-Perioden, Verzug, Zuschlägen, Firmenlage und letzten Transaktionen.
- **Privatsteuern-Ansicht** aus `taxes` inkl. Suche/Filter und Fälligkeitslogik.
- **Business-Steuern-Ansicht** aus `taxes_business` inkl. Restschuld, Status (offen/teilweise/bezahlt), periodischer Auswertung.
- **Business-Profile** aus `vms_business` inkl. defensivem JSON-Parsing von `data` (`balance`, `totalEarned`, `totalOrders`, `totalVehicles`, `totalSales`).
- **Banking-Ansicht** aus `okokbanking_societies` + `okokbanking_transactions` inkl. Zuordnungsqualität `eindeutig | wahrscheinlich | manuell_pruefen`.
- **Prüf- und Sachbearbeitungslogik** über neue Hilfstabellen (Status, Notizen, Audit).
- **Report-Funktion** (Schuldnerreport / Periodenreport + Erweiterungsbasis).
- **Berechtigungen** über Jobs und Admin-Gruppen.
- **Caching + Pagination** zur Performance-Stabilisierung.

---

## Dateistruktur

- `fxmanifest.lua`
- `config.lua`
- `shared/utils.lua`
- `server/db.lua`
- `server/analytics.lua`
- `server/reviews.lua`
- `server/reports.lua`
- `server/main.lua`
- `client/main.lua`
- `sql/doj_finance_suite.sql`

---

## Installation

1. Ordner `doj_finance_suite` in deinen `resources`-Pfad legen.
2. SQL aus `sql/doj_finance_suite.sql` auf deine Datenbank anwenden.
3. In `server.cfg` sicherstellen:
   - `ensure oxmysql`
   - `ensure ox_lib`
   - `ensure es_extended`
   - `ensure doj_finance_suite`
4. Optional: `ox_target` starten, falls die Target-Interaktion genutzt werden soll.

---

## Konfiguration

### `config.lua`

Wichtige Punkte:

- `Config.DueDays`
  - Due-Date-Berechnung für Privatsteuern:
  - **`due_date = received_date + Config.DueDays`**
- `Config.AllowedJobs`
  - Erlaubte Backoffice-Jobs (standardmäßig `doj`, `government`, `taxoffice`, `clerk`)
- `Config.AllowedGroups`
  - Admin-Gruppen mit Zugriff
- `Config.CacheTtlSeconds`, `Config.DefaultPageSize`, `Config.MaxPageSize`
  - Performance und Pagination
- `Config.Resolver`
  - Optionaler Namens-/Identifier-Resolver

---

## Bestehende Tabellen als Source of Truth

### 1) `taxes`
Verwendung:
- Privatfälle lesen
- Status ermitteln (`offen`, `bezahlt`, `storniert`, `fällig`, `überfällig`)
- Summen/Counts fürs Dashboard

### 2) `taxes_business`
Verwendung:
- Periodische Unternehmenssteuern
- Restschuld-Berechnung:
  - `restschuld = amount - paid_amount + delayed_amount`
- Verzugsanalyse (`delayed_amount`) und Zuschläge (`late_fee_applied`)

### 3) `vms_business`
Verwendung:
- Unternehmensprofil und Finanzkennzahlen
- Feld `data` wird defensiv als JSON geparsed
- Extrahierte Kennzahlen u. a.:
  - `balance`
  - `totalEarned`
  - `totalOrders`
  - `totalVehicles`
  - `totalSales`

### 4) `okokbanking_societies`
Verwendung:
- Society-Kontenübersicht
- Kontostand-/Liquidity-Analysen

### 5) `okokbanking_transactions`
Verwendung:
- Zahlungsbewegungen / Historie
- Zeitraumfilter + Suche
- logische Zuordnung zu Unternehmen/Steuerfällen mit Qualitätsstufe

---

## Hilfstabellen (neu)

Die SQL in `sql/doj_finance_suite.sql` erstellt nur ergänzende Workflow-/Meta-Tabellen:

- `doj_finance_reviews` (Bearbeitungsstatus pro Fall)
- `doj_finance_notes` (interne Prüfernotizen)
- `doj_finance_reports` (Report-Metadaten)
- `doj_finance_report_entries` (Report-Zeilen)
- `doj_finance_deadlines` (optional manuelle Frist-Overrides)
- `doj_finance_auditlog` (Audit-Trail)
- `doj_finance_links` (optionale manuelle Verknüpfung von Zahlungen/Fällen)

Wichtig: Keine Duplikation der Steuer-Source-Daten.

---

## Business-Fall-Identifikation

- Primärschlüssel für `taxes_business`-Fälle in der Resource:
  - **`source_key = job .. '|' .. period`**
- Damit können periodische Business-Fälle eindeutig in Review/Notiz/Audit referenziert werden, auch ohne numerische ID.

---

## Due-Date-Logik für Privatsteuern

Da `taxes` kein eigenes Due-Date-Feld enthält:

- Default-Logik: `due_date = received_date + Config.DueDays`
- Zustandsermittlung:
  - `storniert`, wenn `canceled = 1`
  - `bezahlt`, wenn `is_paid = 1`
  - `ueberfaellig`, wenn offen und aktuelles Datum > Due-Date
  - sonst `faellig`/`offen`

Optional kann über `doj_finance_deadlines` ein Override gepflegt werden.

---

## Namens-/Identifier-Auflösung (ohne harte User-Tabellenannahme)

Es gibt absichtlich **keine harte Abhängigkeit** auf unbekannte `users`-/Character-Schemata.

Auflösung erfolgt in Reihenfolge:

1. vorhandene Felder aus Source-Tabellen (`receiver`, `receiver_name`, `sender_identifier`, `sender_name`, etc.)
2. optional online über ESX `xPlayer` (`Config.Resolver.preferOnlinePlayerName`)
3. optionaler Adapter via `Config.Resolver.userAdapter`

Damit bleibt die Resource schema-agnostisch und erweiterbar.

---

## Commands

- `/finance`
- `/taxoffice`
- `/finance_report [schuldnerreport|periodenreport] [YYYY-MM]`
- `/finance_debug_refresh`

Nur für berechtigte Jobs/Gruppen.

---

## UI/UX

Deutschsprachige Backoffice-Menüs via `ox_lib`:

- Dashboard
- Privatsteuern
- Unternehmenssteuern
- Unternehmen
- Zahlungseingänge
- Reports

Aus den Listen heraus können Fälle geöffnet, Status gesetzt und Notizen erfasst werden.

---

## Performance-Hinweise

- Serverseitige Pagination (`LIMIT/OFFSET`)
- Caching von Aggregationen (Dashboard, Society-Listen)
- Defensives JSON-Parsing
- Indexierte Hilfstabellen
- Cache-Invalidierung bei Review-Änderungen/Debug-Refresh

---

## Erweiterungsideen

- NUI-Frontend statt Kontextmenüs für große Datenmengen
- zusätzliche Reporttypen (Monat, Auffälligkeit, Zahlungsverhalten)
- automatische Deadline-Override-Pipelines
- rollenbasierte feinere Rechte-Matrix pro Aktion
