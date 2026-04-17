# doj_finance_suite

## Überblick

`doj_finance_suite` ist eine ESX-Finanzsoftware für DOJ/TaxOffice-Backoffice auf Basis deiner bestehenden Tabellen (`taxes`, `taxes_business`, `vms_business`, `okokbanking_societies`, `okokbanking_transactions`).

Die Resource ergänzt nur Workflow-/Metadaten (Reviews, Deadlines, Audit, Reports, Links, Business-Mapping) und lässt die Source-of-Truth-Daten unangetastet.

## Kernverbesserungen gegenüber der Beta

- **Regelbasierte Risk Engine (0-100)** mit erklärbaren Gründen, kein Blackbox-System.
- **Korrigiertes Business-Matching**: primär über Mapping (`doj_finance_business_map`, `Config.BusinessJobMap`), fallback case-insensitive job↔business_id.
- **Echte Fallakten** im Client:
  - Privatfall (`taxes.id`)
  - Business-Fall (`job|period`)
  - Business-Profil (`vms_business.id`)
- **Deadlines produktiv integriert** (`doj_finance_deadlines` lesen/setzen/löschen).
- **Links produktiv integriert** (`doj_finance_links` für manuelle/automatische Zahlungszuordnung).
- **Erweitertes Reportcenter** mit mehreren Reporttypen und Filtern.
- **Interaktion korrigiert**: fester Point/NPC statt globalem Player-Target.
- **Aktive okokbanking_transactions-Auswertung** für Zahlungsanalyse, Verlauf, Matching und Risikoerkennung (inkl. robustem Date-Parsing trotz `varchar`).

---

## Verwendete Source-of-Truth-Tabellen

- `taxes`
- `taxes_business`
- `vms_business` (inkl. JSON-Feld `data`)
- `okokbanking_societies`
- `okokbanking_transactions`

## Neue Hilfstabellen

- `doj_finance_reviews`
- `doj_finance_notes`
- `doj_finance_reports`
- `doj_finance_report_entries`
- `doj_finance_deadlines`
- `doj_finance_auditlog`
- `doj_finance_links`
- `doj_finance_business_map` (neu für robustes Job↔Business-Mapping)

SQL: `sql/doj_finance_suite.sql`

---

## Risk Engine (regelbasiert, nachvollziehbar)

### Scoreband

- 0–24: unauffällig
- 25–49: beobachten
- 50–74: auffällig
- 75–100: hochrisiko

### Bewertete Faktoren (Auszug)

- offene/überfällige Fälle
- wiederkehrend offene Perioden
- Teilzahlungen
- delayed_amount / late_fee_applied
- Restschuld vs. Kontostand
- Restschuld vs. totalEarned
- ausreichende Liquidität trotz offener Steuerlast
- auffällige Transaktionsspikes (7/30/90 Tage)
- hohe Eingänge ohne erkennbare Steuerbegleichung
- manuelle Prüf-/Mahnmarker
- withdraw/deposit/transfer-Verteilung pro Zeitraum

Alle Gewichte/Schwellenwerte sind in `config.lua -> Config.RiskEngine` konfigurierbar.

---

## Business-Matching (fachlich korrekt)

Reihenfolge:
1. DB-Mapping `doj_finance_business_map`
2. Konfigurations-Mapping `Config.BusinessJobMap`
3. Alias-Auflösung `Config.BusinessJobAliases`
4. Fallback job als business_id (case-insensitive Lookup)

**Wichtig:** `vms_business.type` dient nur als Sekundärinfo und nicht als Primär-Join-Key.

---

## Deadlines

`doj_finance_deadlines` wird aktiv verwendet:

- Override für Privatfälle (`source_type=taxes`, `source_id=taxes.id`)
- Override für Business-Fälle (`source_type=taxes_business`, `source_key=job|period`)

Wenn kein Override vorhanden ist:
- Privat: `received_date + Config.DueDays`
- Business: `period_end + Config.DueDays`

---

## Links / Zahlungszuordnung

`doj_finance_links` wird aktiv verwendet:

- manuelle Verknüpfung einer TX zu einem Steuerfall
- Verknüpfung lösen
- Qualitätsstufen: `eindeutig`, `wahrscheinlich`, `manuell_pruefen`
- Auto-Vorschläge anhand:
  - Mapping/Identifier
  - Society-Namen
  - Betrag vs. Restschuld
  - Zeitraum-Nähe zur Steuerperiode
  - Transaktionstyp (`withdraw`, `deposit`, `transfer`) und Richtung

### Hinweis zu `okokbanking_transactions.date` (varchar)

Die Resource behandelt `date` robust und unterstützt mehrere Formate (z. B. `YYYY-MM-DD`, `YYYY-MM-DD HH:MM:SS`, `DD.MM.YYYY`, `DD/MM/YYYY`) für:

- Zeitraumfilter
- 7/30/90-Tage-Verläufe
- Trend-/Spike-Erkennung
- Report-Auswertung

---

## UI-Struktur (ox_lib)

- Dashboard / Risikoanalyse
- Privatsteuer-Fälle
- Business-Steuerfälle
- Businessprofil
- Reportcenter
- Business-Mapping
- Fallaktionen:
  - Status ändern
  - Notiz hinzufügen
  - Frist überschreiben/löschen
  - Transaktion verknüpfen/lösen
  - Aktenansicht mit Review/Notizen/Audit/Links

---

## Reports

Unterstützte Typen:

- `schuldnerreport`
- `hochrisikoreport`
- `privat_fall`
- `business_fall`
- `zahlungsreport`
- `unternehmens_risiko`
- `transaktionsauffaelligkeit`
- `zahlungsverhalten`

Reportcenter bietet Listen-/Detailansicht und Filter nach Typ/Zeitraum.

---

## Commands

- `/finance`
- `/taxoffice`
- `/finance_report <typ> [args]`
- `/finance_debug_refresh`

Beispiele:
- `/finance_report schuldnerreport`
- `/finance_report hochrisikoreport`
- `/finance_report privat_fall 123`
- `/finance_report business_fall pdm 2026-04`
- `/finance_report zahlungsreport 2026-04-01 2026-04-30`

---

## Interaktion (kein globales Player-Target)

`config.lua -> Config.Interaction`

- optionaler NPC mit ox_target
- fixer Interaktionspunkt mit Marker + TextUI
- Command-Fallback bleibt erhalten

---

## Installation

1. SQL aus `sql/doj_finance_suite.sql` einspielen.
2. Resource in `resources` legen.
3. Sicherstellen:
   - `ensure oxmysql`
   - `ensure ox_lib`
   - `ensure es_extended`
   - `ensure doj_finance_suite`
4. Interaktionspunkt/NPC in `config.lua` anpassen.

---

## Hinweise

- Kein QBCore, reine ESX-Implementierung.
- Keine harte Abhängigkeit auf unbekannte Users-Tabellen.
- Name-Resolver nutzt bestehende Felder + optional Online-ESX + optional Adapter.
- Performance: Pagination, Caching, serverseitige Berechnung.
