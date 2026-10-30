# Solis Battery Controller — ESPHome Implementatie Spec

## Doel

Een ESP32 die via Modbus RTU (RS-485) de Solis S6-EH3P hybrid omvormer aanstuurt als batterijcontroller. De gebruiker of Home Assistant stelt via ESPHome-entiteiten een mode en doelstellingen in. De ESP voert die autonoom uit met een eigen controlloop.

---

## Hardware & verbinding

- **Hardware**: ESP32 (esp32dev), esp-idf framework
- **Verbinding Solis**: Modbus RTU via RS-485, UART GPIO16 (RX) / GPIO17 (TX), 9600 baud 8N1, slave ID 1
- **Verbinding HA**: ESPHome native API (WiFi)
- **Meter data**: gelezen uit Solis Modbus registers (Solis leest SDM630 zelf via Meter poort)

---

## Tekenconventie

De **Solis** gebruikt een inverter-centrische conventie:

| Richting | Solis teken |
|---|---|
| Export naar net / discharge batterij | positief |
| Import van net / charge batterij | negatief |

De **ESP / HA interface** (meter_power sensor, target_grid_number) gebruikt **huis-conventie**:

| Richting | Huis teken |
|---|---|
| Import van net | positief |
| Export naar net | negatief |

Omrekening: register 33263 heeft `multiply: -1` zodat de sensor huis-conventie volgt.
Setpoint in register 43133: `sp = -(int16_t)(tgt_w / 10)` (huis → Solis conventie).

> **Uitzondering — batterijvermogen (33149-33150)**: dit register documenteert de spec als
> signed S32 (`+`=charge/`−`=discharge), maar in de praktijk levert het altijd een **positieve
> magnitude**, ongeacht richting — empirisch bevestigd doordat `battery_soc_hires` bij ontladen
> juist opliep i.p.v. afliep. De echte richting komt uit het losse register **33135**
> (`0`=charge, `1`=discharge). Zie [Hoge-resolutie SOC](#hoge-resolutie-soc--coulomb-counting-tussen-bms-updates).

---

## Solis Modbus Registers

### Read registers (function code 0x04)

Gelezen als één FC04-request over het blok 33133–33152 (sinds 28-10; daarvoor 33135–33152).

> **Range-opbouw (ESPHome 2026.8)**: de modbus_controller voegt sensoren alleen samen tot één
> request als hun registers **exact aansluiten** — elk gat, hoe klein ook, geeft een eigen request.
> Het vroegere bridge-register 33143 loste dat niet op: het blok viel uiteen in vier requests
> (33135, 33139, 33143, 33147–33152) en de fasestromen in drie. De bus raakte daardoor verzadigd
> en `grid_metric_samples` haalde ~245 per kwartier i.p.v. ~450. Nu overbrugt `register_count` op
> de sensor vóór een gat de tussenliggende registers (33135: 4, 33139: 10, 33252/33254: 2, 33161: 4).

| Register | Type | Eenheid | Naam | Noot |
|---|---|---|---|---|
| 33133 | U16 | 0.1V | Battery voltage | Voor de ampère-telling van `battery_soc_hires` (I = P/V); `register_count: 2` |
| 33135 | U16 | — | Battery current direction | `0`=charge, `1`=discharge — autoritatieve richting voor 33149 (zie hierboven); `register_count: 4` |
| 33139 | U16 | 1% | Battery SOC | 0–100%; `on_value` her-ankert de coulomb-counting bij een echte wijziging; `register_count: 10` (t/m 33148) |
| 33147 | U16 | 1W | House load power | **Niet gebruikt** — U16, blijft op 0 bij PV-overschot (Omnik). Vervangen door `residual_power` |
| 33149 | S32 | 1W | Battery power | Alleen betrouwbaar als **magnitude** (2 registers); richting via 33135 |
| 33151 | S32 | 1W | Inverter AC Grid Port Power | + = export, − = import (2 registers) |
| 33263 | S32 | 1W | Meter total active power | Na `multiply:-1`: + = import, − = export (2 registers); `skip_updates: 1` (elke 2s, zie [Schrijftiming](#schrijftiming--modbus-protocol)) |

Apart FC04-request per blok, elke 60s (`skip_updates: 59`), voor `residual_energy` — zie
[Residual power en energie](#residual-power-en-energie):

| Register | Type | Eenheid | Naam | Noot |
|---|---|---|---|---|
| 33161 | U32 | 0.01kWh | Total battery charge energy | Solis-teller; `register_count: 4` sluit aan op 33165 |
| 33165 | U32 | 0.01kWh | Total battery discharge energy | Solis-teller |
| 33283 | U32 | 0.01kWh | Meter total active energy from grid | SDM630-teller via de Solis |
| 33285 | U32 | 0.01kWh | Meter total active energy to grid | idem |

Apart FC04-request (buiten bovenstaand blok, span 5, geen bridge nodig) voor de netstroom per fase — zie
[Netstroom per fase](#netstroom-per-fase-grid_current_ab_c):

| Register | Type | Eenheid | Naam | Noot |
|---|---|---|---|---|
| 33252 | U16 | 0.01A | Meter AC current A | Op de "Grid"-locatie geconfigureerde meter (43140=0x0105) |
| 33254 | U16 | 0.01A | Meter AC current B | idem |
| 33256 | U16 | 0.01A | Meter AC current C | idem |

Apart FC04-request (los register, elke 15 min) voor de overdischarge-ondergrens — zie
[Energieboekhouding](#energieboekhouding--capaciteit-baseremainingusabletarget_usable):

| Register | Type | Eenheid | Naam | Noot |
|---|---|---|---|---|
| 33213 | U16 | 1% | Overdischarge SOC Mirror | De MIRROR, niet de instelling (43011) — wat de omvormer werkelijk toepast als ondergrens; verandert vrijwel nooit, vandaar laagfrequent (skip_updates 900 @ 1s = 15 min) |

### Write/holding registers (function code 0x06, individueel per register)

| Register | Type | Eenheid | Naam | Waarde(n) | Schrijfcadans |
|---|---|---|---|---|---|
| 43029 | U16 | — | CT direction | **1** = Reversed | elke 5 min, alleen bij afwijking |
| 43110 | U16 | — | Storage control switch | **33** = Self-Use + Allow Grid Charge | elke 5 min, alleen bij afwijking |
| 43132 | U16 | — | RC Grid Adjustment ON/OFF | 0=OFF, **1=ON** | elke 30s, **alleen** als `\|adjusted_w\| > RC_THRESHOLD_W` (100W) — zie [apply_mode](#modi) |
| 43133 | S16 | 10W | RC Grid Active Power setpoint | Solis-conv: + = export, − = import | elke 30s, **onvoorwaardelijk** (alle modes behalve hold) |
| 43135 | U16 | — | RC Force Charge/Discharge | 0=OFF, **1**=Force Charge | `hold` (→1) en force charge (→1 elke 30s, →0 bij verlaten), zie [Force charge](#force-charge-boven-8-kw-pbi-058-28-10-2026) |
| 43136 | U16 | 10W | RC Force Charge Power | — | `hold` (→0) en force charge (→ force_w/10) |
| 43118 | U16 | 0.1A | Battery max discharge current | 0 of 500 (50 A) | alleen bij afwijking van het gelezen register (gelezen elke 5 min) — zie [Ontladen blokkeren in charge](#ontladen-blokkeren-in-charge-30-10-2026) |
| 43140 | U16 | — | Meter1 type & location | **0x0105** = Standard Eastron 3Ph, Grid | elke 5 min, alleen bij afwijking |
| 43282 | U16 | 1min | RC Timeout | Geldig bereik 2–30; **schrijf 2** (minimum) | elke 5 min, onvoorwaardelijk |

> **Niet gebruikt door deze firmware**: de Solis-appendix kent ook toegewijde Force Charge/Discharge-registers (43129 RC Force Discharge Power, 43130/43131 Charge/Discharge Limit, 43134 RC Reactive Power). Deze worden niet aangestuurd — `charge`/`discharge` lopen volledig via de RC Grid Adjustment-route (43132/43133), net als `level`.
>
> **Niet gebruiken**: register 43128 (RC Inverter AC Grid Port Power, S16) — schrijven van 0 stuurt de Solis actief naar grid=0W.

### Register 43110 — Storage Control Switch

Wordt als vaste waarde **33** geschreven (geen read-modify-write):

| BIT | Naam | Gewenste waarde |
|---|---|---|
| BIT00 | Self-Use mode | **1** (aan) |
| BIT01 | Time of Use mode | 0 (uit) |
| BIT05 | Allow Grid Charging | **1** (aan) |
| BIT06 | Feed-in Priority | 0 (uit) |
| BIT11 | Peak Shaving | 0 (uit) |

`BIT00=1, BIT05=1` → `0x0021 = 33`

> BIT00, BIT01 en BIT06 zijn wederzijds exclusief (modes).

---

## ESPHome entiteiten (HA interface)

| Entiteit | Type | Beschrijving |
|---|---|---|
| `select.control_mode` | select | Mode: hold / level / charge / discharge, `optimistic`; **geen** `restore_value`: na een (her)start altijd `level` (safe mode) |
| `number.target_grid_power` | number | Doelvermogen in W (huis-conv), −10000…10000, stap 100; na een (her)start 0 (safe mode) |
| `sensor.command_timer` | sensor | Resterende seconden van het opdrachtvenster (10s); 0 = safe mode — zie [Opdrachtvenster](#opdrachtvenster-15-min-en-safe-mode-pbi-046). Het bestaan van de sensor vertelt de EMS-strategie dat de firmware kwartier-opdrachten verwacht |
| `number.target_soc` | number | Doel-SOC in %, 7…100, stap 0,1 (EMS rekent met 1 decimaal), default 80 — alleen relevant in charge/discharge |
| `sensor.battery_capacity` | sensor | Accucapaciteit in kWh — **vaste** waarde (20.48) uit `substitutions`, alleen gepubliceerd ter inzage; geen HA-input meer, zie [Energieboekhouding](#energieboekhouding--capaciteit-baseremainingusabletarget_usable) |
| `sensor.battery_soc` | sensor | SOC %, ruwe BMS-waarde (1%-resolutie, onregelmatige update) |
| `sensor.battery_soc_hires` | sensor | Hoger-resolutie SOC-schatting (2 decimalen, 10s): ampère-telling (P/V) los van de BMS; telling staat uit bij SOC 100 en ≤ 7 (daartussen 7,1 … 99,9), zie [Hoge-resolutie SOC](#hoge-resolutie-soc--coulomb-counting-tussen-bms-updates) |
| `sensor.battery_soc_offset` | sensor | Diagnose: hires − BMS in pp |
| `binary_sensor.bms_stalled` | binary | Diagnose: aan tijdens een BMS-stilstand (> 1,5pp energie sinds de laatste BMS-stap) |
| `binary_sensor.soc_hires_deviation` | binary | Diagnose: aan bij \|hires − BMS\| > 10pp |
| `sensor.base_energy` | sensor | Energie onder de overdischarge-ondergrens (kWh), niet bruikbaar — zie [Energieboekhouding](#energieboekhouding--capaciteit-baseremainingusabletarget_usable) |
| `sensor.remaining_energy` | sensor | Totale accu-inhoud in kWh, afgeleid van `battery_soc_hires` — zie [Energieboekhouding](#energieboekhouding--capaciteit-baseremainingusabletarget_usable) |
| `sensor.usable_energy` | sensor | `remaining_energy − base_energy` (kWh) — zie [Energieboekhouding](#energieboekhouding--capaciteit-baseremainingusabletarget_usable) |
| `sensor.target_usable_energy` | sensor | `target_soc` uitgedrukt in kWh boven de ondergrens; observationeel, nog niet in `apply_mode` verwerkt — zie [Energieboekhouding](#energieboekhouding--capaciteit-baseremainingusabletarget_usable) |
| `sensor.grid_power` | sensor | Netmeter W (huis-conv: + = import), 5s, HA-visible |
| `sensor.inverter_power` | sensor | AC grid port W (Solis-conv: + = export) |
| `sensor.residual_power` | sensor | Huislast + omvormerverlies minus PV (W), = grid − accu-DC; negatief bij PV-overschot, 5s — zie [Residual power en energie](#residual-power-en-energie) |
| `sensor.residual_energy` | sensor | Tweezijdige teller (kWh, `state_class: total`) bij `residual_power`, 60s |
| `sensor.grid_current_a/b/c` | sensor | Netstroom per fase (A), 0.01A-resolutie, ~10s, zie [Netstroom per fase](#netstroom-per-fase-grid_current_ab_c) |
| `text_sensor.inverter_status` | text | `charging` / `discharging` / `standby`, afgeleid van `inverter_power` (drempel ±150W) |
| `text_sensor.grid_status` | text | `import` / `export` / `level`, afgeleid van `grid_power` (drempel ±50W) |
| `sensor.grid_metric_*` + `text_sensor.grid_metric_histogram` | sensor/text | 15-min venstermetrics, zie [Grid Metrics](#grid-metrics--tumbling-window-15-min) |

Er is geen `binary_sensor.fault` of `binary_sensor.grid_meter_connected` — foutdetectie is niet geïmplementeerd, zie [Niet geïmplementeerd](#niet-geïmplementeerd-bewuste-keuze).

---

## Modi

Eén script, `apply_mode`, dekt alle vier de modes — geen apart `update_soc_setpoint` meer. Aangeroepen bij elke mode-/target-wijziging (`on_value`) én elke **30s** via `interval`.

### hold
Enige echte uitzondering: ander Solis-mechanisme (Force Charge i.p.v. RC Grid Adjustment), en moet **onvoorwaardelijk** herbevestigd worden — self-use is precies wat `hold` wil vóórkomen. Schrijft `43136=0` (RC Force Charge Power) en `43135=1` (Force Charge aan, op 0W), en stopt (`return`) vóór de rest van het script. Valt net als elke andere opdracht na 900s terug naar safe mode; force charge verloopt daarna via de RC-timeout (2 min). Een nieuwe opdracht die 43132 = 1 schrijft, zet force in de Solis zelf meteen uit (43135 → 0) — de firmware hoeft 43135 daarvoor niet te schrijven. `43132`/`43133` worden in `hold` niet aangeraakt.

### level / charge / discharge
Gedeeld mechanisme via RC Grid Adjustment (43132/43133). Uitzondering sinds 28-10: `charge` boven 8 kW (residual + R) loopt via RC Force Charge (43135/43136), zie [Force charge](#force-charge-boven-8-kw-pbi-058-28-10-2026).

- `level`: `adjusted_w = target_grid_w`
- `charge` / `discharge`: `adjusted_w` volgt uit de SOC-deadline-sturing hieronder (huislast-term + benodigd accuvermogen)

Vervolgens, voor alle drie de modes identiek:

1. **43133 wordt altijd geschreven**: `sp = -(adjusted_w / 10)` (huis → Solis conventie), ongeacht de grootte van `adjusted_w`. Dit kost niets en geeft direct effect zolang RC nog actief is.
2. **43132 wordt alleen herbevestigd (→1) als `|adjusted_w| > RC_THRESHOLD_W`** (100W). Onder die drempel schrijven we 43132 niet — de Solis' eigen RC-timeout (43282) laat 'm dan vanzelf verlopen naar self-use, zonder dat de firmware zelf hoeft te bepalen wanneer een waarde "stabiel genoeg" is.

`soc` is de hoger-resolutie schatting uit `battery_soc_hires`, met fallback naar de ruwe `battery_soc` zolang hires nog NAN is — zie [Hoge-resolutie SOC](#hoge-resolutie-soc--coulomb-counting-tussen-bms-updates). Zonder geldige `soc` (< 0.5%) geldt `adjusted_w = target_grid_w`.

> **RC-timeout als hardware-native fallback**: in plaats van software die expliciet beslist wanneer RC Grid Adjustment "uit" moet (met het risico op flapping zonder handmatige hysterese), laat dit ontwerp de Solis' eigen RC-timeout (43282, nu 2 minuten) het werk doen — de firmware hoeft alleen actief te *herbevestigen* zolang er een betekenisvolle aanvraag is, en anders niets te doen.

---

## SOC-deadline sturing (charge / discharge)

**Opdracht**: `target_soc` halen vóór het einde van het opdrachtvenster (15 min, zie [Opdrachtvenster](#opdrachtvenster-15-min-en-safe-mode-pbi-046)), met de waarden van nu. De firmware
voorspelt geen PV en bouwt geen buffer in: verwachte PV en reserve(kwartieren) zijn aan het EMS, dat
`target_soc` zo vaak kan bijstellen als het wil (sinds 18-10-2026, zie [Geschiedenis](#geschiedenis-pv-marge-en-anker-tot-18-10-2026)).

```
BATTERY_WH    = 20480     # substitutions.battery_capacity_kwh
MAX_GRID_W    = 10000     # |setpoint|: meer neemt de Solis via 43133 niet aan
I_LIM_A       = 25        # hoofdzekering per fase
W_PER_A       = 690       # 3 x 230V: 1W setpoint = 1/690 A extra op elke fase
RATE_FLOOR_MS = 30000     # ondergrens op de deler: één apply_mode-ronde (was 2 min tot 19-10)

not_past_target = soc <= target_soc      # charge   (discharge: soc >= target_soc)
if soc geldig and not_past_target:
    need_pct  = target_soc − soc         # charge   (discharge: soc − target_soc); 0 op het doel
    remaining = max(cmd_deadline − now, RATE_FLOOR_MS)           # int32-verschil, overloop-bestendig
    R         = need_pct/100 · BATTERY_WH / remaining          # benodigd accuvermogen
    want      = residual_power + R       # charge   (discharge: residual_power − R)
    cap       = +MAX_GRID_W              # charge   (discharge: −MAX_GRID_W)
    i_max     = max(Ia, Ib, Ic)
    phase_cap = grid_nu + 690·(25 − i_max)                     # charge   (discharge: grid_nu − …)
    cap       = min(cap, phase_cap)      # charge   (discharge: max)
    adjusted  = max(tgt_w, min(want, cap))                     # charge
    adjusted  = min(tgt_w, max(want, cap))                     # discharge
else:
    adjusted  = tgt_w
```

- **Huislast-term** (`residual_power`, zie [Residual power en energie](#residual-power-en-energie)):
  de Solis leest 43133 als totale netafname, dus zonder deze term ging huislast (EV-lader, WP) van het
  laden af. Binnen een ronde van 30s houdt de Solis het net op het setpoint: extra PV gaat naar de accu
  (**geen export** tijdens charge), extra huislast wordt de volgende ronde meegenomen. `residual` bevat
  de accu niet, dus er is geen terugkoppeling op zichzelf. Ontbreekt `residual_power` (NAN), dan telt
  hij als 0.
- **PV telt alleen mee zoals hij er nu is** (via `residual`). Bij PV-overschot groter dan R wordt
  `want` < `tgt_w` en blijft het setpoint `tgt_w`: de accu neemt al het overschot op.
- **Op het doel vasthouden** (`need_pct` = 0, dus R = 0): `adjusted = max(tgt_w, residual)` — de accu
  staat stil, het net levert huislast en EV. Dit is ook de modus tijdens een charge_deadline (charge
  met `target_soc` = huidige SOC). Bij PV-overschot laadt de accu dat overschot.
- **SOC voorbij het doel** (bv. 07-09: charge naar 17% vanaf 54%): geen huislast-term, `adjusted =
  tgt_w` — de accu levert aan het huis tot het doel, en wordt daar vastgehouden.
- **Fasegrens**: de Solis verdeelt symmetrisch, dus de ruimte op de zwaarste fase (garagegroep: EV-lader
  + WP) bepaalt hoeveel netvermogen er nog bij mag. De meter levert stroom zonder richting; een fase die
  teruglevert maakt de schatting alleen voorzichtiger. Fasestroom ververst ~11s, de som draait elke 30s —
  een overschrijding duurt hooguit één ronde. De grenzen duwen het setpoint nooit voorbij `tgt_w` terug.
- **Log**: `charge tgt=… R=… res=… adj=… sp=… soc=…/… imax=…A cap=…W rc=…` (imax/cap NAN zonder
  fasestroom, R/res 0/NAN voorbij het doel).

### Ontladen blokkeren in charge (30-10-2026)

**Opdracht** (user 30-10): `charge` naar X betekent "lever tot X, houd daarna vast", en het net gaat in
`charge` nooit onder 0. De EMS geeft de opdracht; de firmware voert hem uit.

**Probleem**: alleen met RC grid-adjustment lukte vasthouden niet. 30-10 13:15–14:05 (doel 96,4/96,5)
pendelde de accu per 5 min tussen −2,7 en +2,7 kW: het setpoint (residual) loopt 30 s achter op de
huislast, dus bij een sprong in huislast ontlaadde de accu tot de volgende ronde; en bij hires net boven
het doel gold "voorbij het doel" (setpoint 0), waarbij de accu de hele huislast leverde.

**Oplossing**: Solis-register **43118** (Battery max discharge current, 0,1 A) op 0 zet het ontladen uit, in
elke Solis-modus. Getest 30-10 17:31: 330 W ontladen → −80 W (stand-by uit het net), net +390 W, binnen 6 s;
terug op 50 A direct weer ontladen. (43131 "Battery discharge limit power" deed niets in self-use, en
Remote Dispatch 44100+ kent onze omvormerfirmware niet: 34502 bestaat niet.)

Twee regels in `apply_mode`; het register is de waarheid (user 30-10), geen eigen administratie:

```
if (mode != charge && 43118 != 50 A) 43118 = 50 A
if (mode == charge && soc <= doel && 43118 != 0) 43118 = 0
```

- **Latch**: komt `charge` binnen met de SOC boven het doel, dan mag de accu leveren tot het doel (uitstel).
  Eenmaal op 0 blijft het register 0 zolang het `charge` is, ook als hires daarna weer boven het doel komt
  (PV-overschot); alleen een andere mode zet hem terug. Geen hysterese, dus geen heen-en-weer schrijven.
  Zonder geldige SOC is `soc` −1, dus dicht.
- In `charge` kan de accu dus alleen laden of stilstaan zodra het doel bereikt is. Huislast en pieken gaan
  via het net; PV-overschot gaat de accu in (43117 laden blijft 50 A). Ook tijdens gewoon laden verdwijnen
  daarmee de korte ontlaadpieken bij een sprong in huislast.
- **Flash**: de spec zegt bij 43118 niet "Not save in Flash" (wel bij 43130/43131); aangenomen dat hij
  blijvend is. Daarom alleen schrijven bij afwijking van het gelezen register (elke 5 min gelezen; na een
  schrijfactie publiceert de number zelf de nieuwe waarde, `ModbusNumber::control`).
- **Herstel**: na een (her)start is het register nog onbekend (NAN ≠ 500), dus de eerste `apply_mode` (safe
  mode = `level`) schrijft 50 A. Safe mode en `hold` zetten 50 A. Handmatig: `number.solis_s6_eh3p_battery_max_discharge_current`.
- `discharge` laat 43117/43118 op 50/50 (user 30-10; symmetrie, laden 0 in `discharge`, kan later).
- Log: `dis=…A` in de charge-regel (gelezen registerwaarde).
- Te verifiëren: vasthouden overdag (PV-overschot gaat de accu in, geen export, geen ontladen), en een
  "lever tot X"-blok 's nachts (ontladen tot X, daarna 0 A).
- Let op: verlaagt de strategie het doel binnen `charge` nadat het eerdere doel al bereikt is, dan blijft
  ontladen dicht (latch) tot een andere mode. Zo bedoeld (user 30-10).

### Force charge boven 8 kW (PBI-058, 28-10-2026)

RC Grid Adjustment (43133) begrenst het **net** op ±10 kW. Bij een groot SOC-gat en veel huislast (WP,
EV-lader, wasmachine) gaat de huislast daardoor van het laden af, terwijl de aansluiting (3×25A) nog
ruimte heeft. Daarom laadt `charge` boven een drempel via RC Force Charge (43135 = 1, 43136 = vermogen),
waar de Solis een vast **accuvermogen** aanhoudt en het net de rest levert.

```
want    = residual + R                              # zoals hierboven
force   = want > 8000 en resttijd > 3 min   (43135 = 1: want >= 5000)    # hysterese, user 28-10
          alleen in charge, vóór het doel, en met bekende fasestroom (phase_cap ≠ NAN)
force_w = clamp(min(R, 10000, phase_cap − residual), ≥ 0)
force:  43136 = force_w/10 ; 43135 = 1 ; 43132/43133 niet schrijven ; return
geen force (ook na hold) en 43135 ≠ 0:  43135 = 0, daarna het gewone RC-pad
```

- **Fasegrens zelf bewaken**: in force begrenst de Solis het net niet. `phase_cap − residual` is het
  laadvermogen waarbij de zwaarste fase op 25 A uitkomt (net = residual + laadvermogen; `residual` bevat
  sinds PBI-012 het laadvermogen niet, dus geen terugkoppeling). Naast de 30s-ronde draait `apply_mode`
  ook direct na elke fasestroom-read (~11s) als een fase tijdens force boven 25 A zit.
- **43132/43133 niet aanraken in force**: 43132 = 1 zet force in de Solis uit (zie hold). Elke ronde
  43136 + 43135 herschrijven houdt force binnen de RC-timeout (2 min) levend; valt de firmware weg, dan
  stopt force vanzelf.
- **Uit force: 43135 = 0 expliciet.** Zonder dat liep force bij een setpoint onder `RC_THRESHOLD_W`
  (geen 43132-schrijfactie) door tot de RC-timeout. Geldt ook bij de terugval naar safe mode.
- Geen export: force alleen bij want ≥ 5 kW en force_w ≤ R, dus net = residual + force_w > 0.
- **Niet instappen in de laatste 3 min van het venster** (29-10, user): aan het eind piekt R door de
  30s-vloer (need / resttijd), terwijl de accu bovenin weinig opneemt. 29-10 01:59:21–02:00:51Z ging force
  zo 90 s aan (10 kW gevraagd, ~2 kW opgenomen bij 98 %), elk kwartiereinde vlak bij het doel. In force
  **blijven** mag wel; de volgende opdracht (nieuw venster, R zakt) haalt force eruit via de hysterese. Een
  groot gat aan het eind van een venster betekent dat de accu het niet bijhield — dan helpt force ook niet.
- **Eerste force-blok 29-10 01:15–01:45Z** (health): accu ~10,1 kW, net ~10,35 kW, zwaarste fase 15,0 A;
  wissel RC ↔ force zonder onderbreking van het laden.
- **Te verifiëren bij het eerste force-blok** (log `charge FORCE P=… R=… res=… imax=… cap=…`): accu laadt
  ~force_w, net ≈ residual + force_w, wissel RC → force zonder onderbreking van het laden, en terug.

### Simulatie (18-10-2026)

Port van oude en nieuwe rekensom, 30s-stappen, residual uit de 5-minutengemiddelden in HA, accu tot
9,7 kW en boven 89% afgeknepen zoals op 10-10 gemeten (5,5 kW bij ~90,5%, 4,5 kW bij ~92,6%):

| Casus | Oud | Nieuw | Vol vermogen |
|---|---|---|---|
| 10-10 14-15, 56,8 → 99 | 93,9 | 94,5 | 95,4 |
| 13-10 14-15, 53 → 84 | 83,5 | 83,5 | 84,8 |
| 17-10 14-15, → 94 | 93,2 | 93,4 | — |

Op deze dagen was er werkelijk ~1-2 kW PV-overschot, ongeveer wat de oude PV-marge aannam — daarom
verschillen oud en nieuw weinig. Het knelpunt is het afknijpen door de BMS boven ~89%: op 10-10 haalt
zelfs een heel uur vol vermogen de 99 niet. Zo'n doel moet het EMS eerder inplannen. Het nieuwe gedrag
wint vooral als er géén PV is (de oude marge trok dan toch 9pp af) en bij huislast op het plafond.

### Opdrachtvenster 15 min en safe mode (PBI-046)

Sinds 22-10-2026 is elke opdracht een **kwartieropdracht**, gelijk aan de EPEX-kwartierprijzen en de
strategie-run die elk kwartier draait (tot 22-10: het eerstvolgende hele wandklok-uur via `ha_time`).

- **Arm**: elke schrijfactie van `select.control_mode`, `number.target_soc` of `number.target_grid_power`
  opent een venster van `command_window_s` (900s) **vanaf nu** — ook bij een ongewijzigde waarde. In
  ESPHome 2026.8 roepen `Number::publish_state` en `Select::publish_state` de callback altijd aan, dus
  `on_value` vuurt bij elke schrijfactie. De controller herhaalt dezelfde opdracht elk kwartier om het
  venster te verlengen (de write-on-change in `ems_controller.py` moet daarvoor uit).
- **Safe mode** = `level` met `target_grid` 0, **zonder venster** (`command_timer` 0). Daarvoor was
  `apply_mode` al ingericht: setpoint 0, 43132 wordt onder `RC_THRESHOLD_W` niet herbevestigd, en de
  Solis valt via zijn RC-timeout (≤ 2 min) terug op zijn eigen self-use. `apply_mode` is voor PBI-046
  niet gewijzigd, behalve dat R met de resttijd van het venster rekent.
- **Terugval**: na 900s zonder nieuwe opdracht zet `arm_command` de Nexus-entiteiten op safe mode
  (`target_grid` 0, `control_mode` `level`) — een zichtbare state-wijziging in HA, met
  `ESP_LOGW("Command timer verlopen → returning to safe mode")`. Geldt voor `charge`, `discharge`, `hold` en `level` met
  `target_grid` ≠ 0. De Solis-kant doet `apply_mode` (via de `on_value` van die schrijfacties).
- **Geen lus**: safe mode zelf armt geen venster. Anders zou de terugval via `on_value` zichzelf opnieuw
  armen en elke 15 min herhalen — daarom de `if` in `arm_command`.
- **Na een (her)start**: altijd safe mode (`control_mode` en `target_grid` zonder `restore_value`).
- **R** rekent met de resttijd van hetzelfde venster (900s), met de vloer van 30s (`RATE_FLOOR_MS`).

Implementatie, zelfde patroon als de auto-off in `aqua-heatpump.yaml`. `arm_command` zet alleen de
Nexus-entiteiten; alles wat naar de Solis gaat doet `apply_mode`:

```
arm_command (mode: restart)          # vanuit on_value van mode / target_soc / target_grid
  safe (level, target_grid 0) → cmd_deadline_ms = 0        # geen venster, geen delay
  anders → cmd_deadline_ms = now + 900s ; delay 900s ; lambda: target_grid := 0 ; control_mode := level

apply_mode (elke 30s en bij elke on_value)   # ongewijzigd; level 0 W → Solis self-use via RC-timeout
```

De twee schrijfacties staan in **één** lambda: ze starten via `on_value` `arm_command` opnieuw
(restart), en dat annuleert de acties ná de lopende — een lambda die al loopt maakt zijn werk af.
`target_grid` wordt eerst stil op 0 gezet (`state = 0`, nog geen `on_value`), daarna de mode via een
call, en pas dan `publish_state(0)` voor HA. Zo ziet al de eerste `on_value` safe mode: geen nieuw
venster en geen tussentijdse schrijfactie naar de Solis (met `set_value(0)` eerst zou de mode nog
`charge` zijn en arm_command kort een nieuw venster openen).

**Synchronisatie met de strategie**: bestaat `sensor.nexus_control_command_timer`, dan stuurt de
strategie kwartier-tussendoelen; zo niet, dan uur-doelen. Flashen en de strategie hoeven daardoor niet
tegelijk.

> **19-10-2026: vloer van 2 min naar 30s.** Met 2 min werd in de laatste 2 minuten elke ronde het restant
> opnieuw door "nog 2 min" gedeeld: het vermogen zakte per ronde ~25% (14:58 → 15:00: 9,0 → 7,2 → 5,4 →
> 4,2 → 3,1 kW) en het gat ging nooit dicht — 81,7% om 15:00 tegen een doel van 82,3% (0,12 kWh tekort).
> Vóór 14:58 laadde de accu lineair op 7,5–9 kW. Met 30s blijft R tot de laatste ronde gelijk (~9,5 kW
> met de cijfers van 19-10) en sluit de laatste ronde het gat.

### Typisch gebruik

```
mode: charge, target_grid: 0W, target_soc: 80%    # laden tot 80% binnen 15 min, nooit export
mode: charge, target_grid: 0W, target_soc: = SOC   # accu vasthouden, EV/huis vanuit het net
```

### Geschiedenis: PV-marge en anker (tot 18-10-2026)

Tot 18-10 trok de sturing vooraf een aangenomen "gratis" PV-bijdrage af (`PV_BUDGET_WH` = 2 kWh,
`PV_RATE_W` = 2 kW, uitdovend tot 5 min vóór de deadline), ongeacht of er PV was. Daardoor startte het
laden te laag en schoof het naar het eind van het uur (10-10: start ~6,6 kW i.p.v. ~8,6 kW). Om dat
wachten veilig te maken waren er een venster-anker (`g_soc_window_anchor`), erosie-bescherming,
anker-klem en ratel (06/07-09). Zonder PV-marge is de som van `soc_gap` en `erosion_pct` altijd
`max(0, target_soc − soc)`, dus is dat allemaal vervallen. De lessen blijven gelden en zitten nu in
`not_past_target`: geen aandrijving voorbij het doel (07-09: anker 54% bij doel 17% → 0,93 kWh netstroom) en
een hold op het doel zodra het gehaald is.

---

## Hoge-resolutie SOC — coulomb counting tussen BMS-updates

`battery_soc` (33139) komt rechtstreeks van de BMS en heeft twee praktische beperkingen: 1%-resolutie
(= 200Wh bij 20kWh accucapaciteit) en een **onregelmatige** update — de BMS ververst pas zodra de waarde
echt naar een nieuwe 1%-stap springt, niet op een vaste klok. Voor een sturing die elke 30s bijstuurt is
dat te grof en te traag.

### Aanpak (v3, 28-10-2026, PBI-044): tellen in ampère, los van de BMS

```
substitutions:  hires_top_pct 100, hires_floor_pct 7, hires_ah 50.5, hires_chg_factor 1.013,
                hires_stall_pp 1.5 (diagnose), hires_deviation_pp 10 (diagnose)
globals:        g_hires (pp), g_off (hires − BMS bij de laatste stap, restore_value), g_e_step (diagnose)

battery_power_raw (33149) on_value:
  V  = 33133 (0,1V; zonder geldige waarde capaciteit/Ah = 405,5V)
  I  = |P| / V ; ontladen (33135 = 1): −I ; laden: I × 1,013
  dh = I · dt / 50,5Ah · 100 ; g_e_step += dh
  als bms >= 100 of bms <= 7: hires = bms
  anders:                     hires = clamp(hires + dh, 7.1, 99.9)

battery_soc (33139) on_value, bij een echte wijziging prev → x:
  als x >= 100 of x <= 7:          hires = x                          # herijking
  anders als geen prev (opstart):  hires = x + g_off                  # bewaard over de reboot
  anders als prev was eindpunt:    hires = x ∓ 0,5                    # 100→99: 99,5 ; 7→8: 7,5
  anders:                          hires blijft staan                 # gewone stap
  hires = clamp(hires, 7.1, 99.9) — niet na een herijking
  g_off = hires − x ; g_e_step = 0
```

Waarom (analyse EMS health 22-10, zie issue #44): over drie ijkpuntparen (BMS 7/100) 15-10..22-10 eindigde
tellen in watt +1,6..+2,5 pp naast het ijkpunt — de accuspanning ligt bij laden hoger (tot 439V) dan bij
ontladen (tot 394V), dus een vaste 204,8 Wh/pp telt laden te zwaar. P/V met laadfactor 1,013 en 50,5 Ah
kwam op ±0,1 pp (rms 0,06; 2 parameters op 3 punten — opnieuw toetsen bij meer ijkpunten). 33134
(stroom, 0,1A ≈ 41W) is bij nachtverbruik te grof; P/V geeft dezelfde ampères met 1W-resolutie. De band
rond BMS + offset (v2) kostte op 20/21-10 4,8 pp: snel laden (hires in de band rond een trage BMS),
bijtrekken na de 89%-stilstand en offset-slijtage.

- **Geen band, geen offsetcorrectie meer**: tussen de eindpunten heeft de BMS geen betere informatie dan
  de telling. `battery_soc_offset` en `bms_stalled` blijven als diagnose (entity-ID's ongewijzigd);
  `battery_soc_offset` is nu live `hires − BMS`.
- **`binary_sensor.soc_hires_deviation`** (nieuw): aan bij |hires − BMS| > 10 pp. Alleen een vlag, geen
  correctie.
- **Vloer 7,1 / plafond 99,9 blijven** (les van 05-09, zie hieronder).
- **Weg van een eindpunt** begint hires midden in de nieuwe stap: op het eindpunt telt hires niet, dus
  zonder deze regel bleef hires na 7→8 op 7 staan (en na 100→99 op 100 → 99,9).
- **API-actie `esphome.nexus_control_set_soc_hires(soc)`** (29-10): handmatige correctie, bv. na een
  stroomuitval. Zet hires (begrensd op 7,1 … 99,9) en `g_off`; genegeerd op een BMS-eindpunt of zolang
  de BMS nog niets gemeld heeft. Eerste gebruik 29-10: de reboot-sprongen van 08:42 (+0,85 pp) en van de
  flash daarna teruggedraaid.
- `g_off` (= hires − BMS) wordt bij elke telling bijgewerkt; `preferences: flash_write_interval: 15min`
  begrenst de flash-writes. Een nette herstart (OTA) schrijft altijd eerst weg, stroomuitval kost hooguit
  15 min telling. (28–29-10 werd `g_off` alleen bij een BMS-stap gezet: de reboot van 29-10 08:42 verloor
  zo de telling sinds de laatste stap, 82,19 → 82,96.)
- Spanning, richting en vermogen komen uit hetzelfde FC04-blok (33133–33152); `register_count: 2` op
  33133 sluit aan op 33135.

Verificatie na de flash: per nieuw ijkpuntpaar de eindstand van hires (zonder vloer/plafond) tegen 7/100 —
verwacht binnen ±1 pp (health-sessie).

### Vorige aanpak (v2, 07-10 t/m 28-10-2026): BMS volgen rond BMS + offset

`hires` volgde de BMS binnen een band, maar rond **BMS + offset** in plaats van rond de BMS zelf. De offset
ontstaat alleen bij een aangetoonde BMS-stilstand en verdwijnt alleen bij een herijking (BMS 100 of ≤ 7) of
als de BMS zelf bijtrekt. De band zit op de **toestand** (`g_hires`), niet alleen op de uitvoer — een
weggelopen telling kan dus niet ongemerkt bewaard blijven.

```
substitutions:  hires_top_pct 100, hires_floor_pct 7, hires_band_pct 0.9, hires_step_band_pct 0.5,
                hires_stall_pp 1.5, hires_catchup_pp 0.5, hires_offset_max 15
globals:        g_hires (pp), g_off (pp, restore_value), g_e_step (pp energie sinds laatste BMS-stap),
                g_h_step (hires direct na de laatste BMS-stap)

battery_power_raw (33149) on_value:                     # dh = energie in pp, + = laden (teken uit 33135)
  g_e_step += dh
  als bms >= 100 of bms <= 7: hires = bms ; g_off = 0
  anders:
    als |g_e_step| > 1.5:  h = g_h_step + g_e_step                    # stilstand: cumulatief vanaf laatste stap
    anders:                h = clamp(hires + dh, bms + g_off - 0.9, bms + g_off + 0.9)   # band rond bms+offset
    hires = clamp(h, 7.1, 99.9)                                       # 100 en 7 alleen via de BMS

battery_soc (33139) on_value, bij een echte wijziging prev → x:
  als x >= 100 of x <= 7:         hires = x ; g_off = 0                       # herijking
  anders als geen prev (opstart): hires = x + g_off                           # g_off is bewaard
  anders als |g_e_step| > 1.5:    g_off = clamp(hires - x, ±15)              # stilstand eindigt
  anders als g_off ≠ 0 en |g_e_step| < 0.5 en |hires - x| < |hires - prev|:
                                  g_off = hires - x ; als |g_off| < 0.9: g_off = 0   # BMS trekt bij
  anders:                         hires = clamp(hires, x + g_off - 0.5, x + g_off + 0.5)   # normale stap
  hires = clamp(hires, 7.1, 99.9)   — NIET na een herijking, anders bleef hires bij BMS 100 op 99,9
  g_h_step = hires ; g_e_step = 0
```

Afwijkingen van het handoff-voorstel (06-10), alle bewust:
- de slotklem op [7,1 … 99,9] wordt overgeslagen na een herijking — letterlijk overgenomen zou `hires` bij
  BMS 100 op 99,9 blijven staan;
- `g_off` heeft `restore_value: true`. Zonder bewaren sprong `hires` na een herstart midden in een
  offsetperiode tot ~10pp terug naar de BMS, terwijl de offset alleen bij een herijking hoort te verdwijnen;
- **tijdens een stilstand telt hires cumulatief vanaf de stand bij de laatste stap** (`g_h_step + g_e_step`).
  In het voorstel telde hij pas vrij vanaf de bandrand: tussen de band (0,9) en de stilstanddrempel (1,5) stond
  `hires` vastgepind en ging per stilstand ~0,4–0,5pp verloren — een deel van de "veilige kant"-afwijking in
  de tabel hieronder. Zichtbaar gevolg: op het moment dat de stilstand wordt herkend springt `hires` eenmalig
  ~0,5pp (de ingehouden energie wordt alsnog meegeteld); ruim binnen de maximale sprong van 1,4pp;
- **"BMS trekt bij" alleen bij een stap naar hires toe met < 0,5pp energie** (`hires_catchup_pp`). In het
  voorstel vuurde die tak bij élke stap in de richting van `hires` (bv. laden met positieve offset, of verder
  ontladen met negatieve offset). Omdat de band (0,9) krapper is dan de ~0,97pp energie per BMS-stap, sleet de
  offset dan ~0,1pp per stap — na een laadstilstand bij het volgende laden over tientallen stappen weg, zonder
  dat de BMS iets corrigeerde. Een gewone stap valt nu onder de normale-stap-tak en laat de offset gelijk.

Simulatie van deze versie (`hires_v2_sim.py`, port van de lambdas): stilstand op 89 met 6pp ongeteld geeft
offset +4,9 (was +4,5); 30 gewone laadstappen naar `hires` toe laten de offset op 4,40 (sleet voorheen);
stappen met 0,3pp energie laten hem krimpen naar 0; bij BMS 100 is `hires` 100; een reboot behoudt de offset.

De simulatie in de tabellen hieronder rekende nog met 20,55 kWh en zonder de laatste twee aanpassingen; de
firmware gebruikt 20,48 kWh.

### Waarom een offset — BMS-stilstanden 26-09 t/m 06-10

De BMS (Pylontech Force H3, firmware 0.1.0.5) blijft op twee vaste plekken hangen. BMS-stappen waarbinnen
meer dan 0,6 kWh stroomde (een normale stap is ~0,2 kWh):

| Wanneer | BMS | Richting | Niet meegeteld |
|---|---|---|---|
| 27-09 15:15 (16 min) | 89→90 | laden | 0,6 kWh |
| 28-09 11:15 (110 min) | 89→90 | laden | 1,5 kWh |
| 06-10 15:03 (98 min) | 89→88 | laden | 1,4 kWh |
| 29-09 01:13 (7 uur) | 21→19 | ontladen | 2,4 kWh |
| 01-10 23:41 (3,5 uur) | 21→20 | ontladen | 1,7 kWh |
| 02-10 03:11 (3 uur) | 20→19 | ontladen | 1,0 kWh |

Buiten die plekken telt de BMS goed (196–203 Wh/pp tegen 205,5 nominaal). De 89%-stop bij laden is bekend
Pylontech-gedrag (ook US3000C/US5000): de SOC blijft op ~89–91% tot de celspanning de volle lading bevestigt
en springt dan naar 100; Pylontech noemt 90% als startpunt van de balancering.

Na zo'n stilstand telt de BMS gewoon verder vanaf de foute stand; het verschil blijft bestaan tot een echte
herijking. Terugtrekken naar de BMS-lijn (variant "zacht bijsturen", v1) is daarom fout: de BMS heeft op dat
moment geen nieuwe informatie. De vorige firmware (lopend ±0,9 rond de BMS) maakte een stilstand bovendien
onzichtbaar — `hires` pinde op de bandrand en stond stil.

**Simulatie** (recorder 26-09 – 06-10, vermogen uit 33149):

| Variant | Sprongen >1 pp | Grootste sprong | Max. verschil met BMS |
|---|---|---|---|
| Vorige firmware (klem ±0,9) | 5 | 1,5 pp | 0,9 |
| Zacht bijsturen (v1) | 3 | 4,8 pp | 6,7 |
| **Offset (v2)** | 6 | **1,4 pp** | 10,9 (alleen tijdens en na stilstand) |

Fout ten opzichte van de werkelijke SOC, teruggerekend vanaf het moment dat de BMS zich herijkt (7% of 100%):

| Anker | Vóór anker | BMS | Vorige | Zacht (v1) | Offset (v2) |
|---|---|---|---|---|---|
| 29-09 10:46 (→7) | 3 uur | +4,5 | +3,6 | −1,5 | **+0,6** |
| 02-10 08:44 (→7) | 1 uur | +7,0 | +7,5 | +3,4 | **−1,9** |
| 02-10 08:44 (→7) | 3 uur | +7,7 | +6,8 | +1,8 | **−2,3** |
| 05-10 17:02 (→100) | 1 uur | −1,2 | −0,3 | 0,0 | +0,5 |
| 28-09 03:11 (→100) | 1–6 uur | −6,5 | −6,7 | −6,1 | −6,7 |

- v2 is even rustig als de vorige firmware (sprong maximaal 1,4 pp) en zit bij de bevriezingen binnen ~2–3 pp
  van de werkelijkheid, tegen 7–8 pp daarvoor. De resterende afwijking valt naar de veilige kant.
- 28-09: de BMS stond toen al ~6 pp te laag door een stilstand van vóór het begin van de data. De offset bouwt
  pas op vanaf een stilstand die hij zelf waarneemt.
- Voorbehoud: "werkelijk" is teruggerekend met hetzelfde vermogenssignaal en dezelfde capaciteit — geen
  onafhankelijke meting.

**Wat dit niet oplost**: de Solis stopt en begrenst op de BMS-SOC. Staat de BMS 6 pp te laag, dan blijft die
energie onbruikbaar tot de volgende herijking. v2 zorgt dat het EMS weet hoeveel er werkelijk in zit
(planning, ledger, accuprijs), niet dat de omvormer erbij kan. Daarvoor is regelmatig een volle lading nodig.

### Eindpunten en de 100%-herijking — incident 05-09-2026

Op 05-09-2026 bleef de BMS 2,5 uur op 89% hangen terwijl een ongeklemde telling doorliep tot 95%. Bij een doel
van 100% stopte de sturing toen te vroeg (de schatting haalde 100 terwijl de BMS op 99 stond), de accu bereikte
de CV-taper niet en de BMS herijkte nooit (celspanning bleef op 3,388V i.p.v. ~3,51V). Daarom geldt nog steeds:
bij BMS 100 of ≤ 7 staat de telling uit en is `hires` exact de BMS-waarde, en daartussen blijft `hires`
binnen [7,1 … 99,9]. `hires` kan 100 dus alleen aanwijzen als de BMS dat zelf meldt, zodat de sturing bij
een doel van 100 doorlaadt tot de BMS vol zegt. Een doel onder 100 (bv. 99) mag hires zelf halen.

**18-10-2026: herijking bovenin van ≥ 99 naar 100** (`hires_top_pct` 99 → 100). Met 99 was het punt
tegelijk herijking en plafond (98,9). Op 15-10 stond de BMS van 13:43 tot 15:00 op 95 terwijl er nog
~1,3 kWh in ging; `hires` liep vast op 98,9 en het EMS meldde "SOC-bron hires niet ververst". Nu telt
`hires` door tot 99,9, springt bij BMS 99 niet meer naar 99 (blijft in de band 98,1 … 99,9), en
`bms_stalled` (bovengrens TOP − 1) blijft zichtbaar tot en met BMS 99. Simulatie (port van beide
lambda's): stilstand op 95 met 6,3 pp → 99,90 (was 98,90); BMS 98→99 bij hires 98,59 → blijft 98,59
(was sprong naar 99,00); onder 94 identiek. Bijeffect: bij ontladen van 100 naar 99 wordt `hires` 99,5
(was 99,0) — dezelfde stap-band als bij elk ander niveau, en gelijk aan het gedrag aan de onderkant (7→8).

> **Blijft integreren op 33149, niet op 33161/33165**: die energietellers meten aan de omvormerzijde en
> bevatten ~100W vaste overhead, wat `hires` tijdens laden systematisch te hoog zou duwen. 33149 is de DC-zijde
> aan de accuklemmen — dat houdt bovendien het omvormerverbruik zichtbaar als load, niet als opgeslagen energie.

`apply_mode` gebruikt `battery_soc_hires` rechtstreeks als `soc`-bron, met fallback naar de ruwe
`battery_soc` zolang er nog geen BMS-melding is geweest (net opgestart — hires is dan NAN).

### Ontdekt tijdens verificatie: 33149-33150 heeft geen betrouwbaar teken

De spec documenteert 33149-33150 (`Battery power`) als signed S32 (`+`=charge, `−`=discharge). In de
praktijk bleek dat niet te kloppen: bij ontladen liep `battery_soc_hires` juist óp in plaats van af — het
register levert kennelijk altijd een positieve **magnitude**, ongeacht richting. Bevestigd doordat een
community Home Assistant-integratie ([Pho3niX90/solis_modbus](https://github.com/Pho3niX90/solis_modbus))
onafhankelijk tot dezelfde conclusie kwam: hun "Battery Charge Power"/"Battery Discharge Power"-sensoren
lezen ook gewoon 33149/33150, maar filteren op de waarde van **33135** (`0`=charge, `1`=discharge) om te
weten welke van de twee van toepassing is — in plaats van op het teken van 33149 zelf te vertrouwen. Onze
implementatie doet nu hetzelfde: `fabs()` van de magnitude, teken expliciet uit 33135.

### Gepubliceerde entiteit

| Entiteit | Type | Resolutie | Noot |
|---|---|---|---|
| `sensor.battery_soc_hires` | sensor | 0.01%, elke 10s | `NAN` zolang er nog geen BMS-melding is geweest; ampère-telling los van de BMS (v3). Bij SOC 100 en ≤ 7 exact de BMS-waarde, daartussen [7,1 … 99,9] |
| `sensor.battery_soc_offset` | sensor | 0.01pp, elke 10s | Diagnose: live `hires − BMS` |
| `binary_sensor.bms_stalled` | binary | live | Diagnose: aan zolang er sinds de laatste BMS-stap meer dan 1,5pp energie is gestroomd |
| `binary_sensor.soc_hires_deviation` | binary | live | Diagnose: aan bij \|hires − BMS\| > 10pp |

---

## Energieboekhouding — capaciteit, base/remaining/usable/target_usable

Vertaalt de coulomb-counted SOC-schatting naar kWh, met een gekalibreerde capaciteit i.p.v. de vroeger
hardcoded 20000Wh-aanname.

### Accucapaciteit — `substitutions.battery_capacity_kwh`

**Vaste waarde: 20.48 kWh** (spec van de accu; komt overeen met de remaining kWh en SOC die de BMS zelf
rapporteert). Staat als substitution bovenaan het bestand en wordt op alle plekken gebruikt die capaciteit
nodig hebben: `battery_soc_hires`, `base_energy`, `remaining_energy`, `target_usable` én `BATTERY_WH` in
`apply_mode`. Daarmee vervalt de vroegere losse 20000Wh-aanname in de sturing.

Was eerder een `number` die AppDaemon kon schrijven; dat is bewust vervallen — de waarde is statisch.
`sensor.battery_capacity` publiceert 'm nog wel naar HA, puur ter inzage. **Let op**: de entiteit is
daarmee van `number.` naar `sensor.` gegaan.

### Register 33213 — Overdischarge SOC Mirror

Losse FC04-read, elke 15 minuten (skip_updates 900 @ 1s update_interval) — bewust laagfrequent, deze
instelling verandert in de praktijk vrijwel nooit. De **MIRROR** (33213), niet de instelling (43011): de
mirror is wat de omvormer werkelijk toepast als ondergrens, de instelling zelf kan afwijken of vertragen.

### `sensor.base_energy`

Het deel van de accu-inhoud onder de overdischarge-ondergrens — niet-bruikbaar energiebudget:
`base_energy = battery_capacity × (33213 / 100)`. Herberekend via `on_value` van het 33213-register en
opgeslagen in de global `g_base_energy_kwh` ("static mem", losgekoppeld van de eigen publicatiecadans).
De sensor zelf publiceert elke 60s met een delta-filter (0.0005 kWh) — de waarde verandert vrijwel nooit.

`g_base_energy_kwh` heeft `restore_value: true`, juist omdat 33213 maar elke 15 minuten gelezen wordt:
zonder bewaren stond `base_energy` na elke (her)start tot een kwartier op 0 en was `usable_energy` in dat
venster gelijk aan `remaining_energy`. Flash-slijtage speelt hier niet — ESPHome's
`RestoringGlobalsComponent` vergelijkt de waarde (`memcmp`) en schrijft alleen weg bij een échte wijziging,
en die waarde verandert vrijwel nooit. De `initial_value: 0.0` geldt daarmee alleen nog bij de allereerste
start, vóór er ooit iets bewaard is.

### `sensor.remaining_energy`

Totale accu-inhoud in kWh: `remaining_energy = battery_soc_hires / 100 × battery_capacity`. Rechtstreeks
afgeleid van `battery_soc_hires` (niet van de onderliggende globals), zodat de band-klem daarop
automatisch meekomt — zie [Hoge-resolutie SOC](#hoge-resolutie-soc--coulomb-counting-tussen-bms-updates).
`update_interval: 10s`, gelijk aan `battery_soc_hires`.

### `sensor.usable_energy`

`usable_energy = remaining_energy − base_energy` — het deel van de accu-inhoud dat daadwerkelijk bruikbaar
is. `update_interval: 10s`.

### `sensor.target_usable_energy`

Het SOC-doel (`target_soc`, relevant in charge/discharge) uitgedrukt in kWh boven de overdischarge-
ondergrens: `target_usable = battery_capacity × (target_soc − 33213) / 100` — rechtstreeks vergelijkbaar
met `usable_energy`. **Status: observationeel, nog niet in `apply_mode` verwerkt.** `target_soc` blijft de
HA-facing %-waarde die de SOC-gap-logica in `apply_mode` aanstuurt; dit is een parallelle, kWh-equivalente
weergave voor toekomstig gebruik.

---

## Residual power en energie

`residual_power` is alles achter de meter behalve de accu zelf: huisverbruik (incl. EV-lader en
warmtepomp) plus het omvormerverlies, minus de PV. Alle PV is AC-gekoppeld (APsystems en Omnik); aan de
Solis zitten **geen** PV-strings. Daardoor daalt `residual_energy` alleen bij PV-overschot.

```
residual_power  = grid_power (+ = import) − accu-DC (+ = laden)
                = meter_power_raw ± |33149|                # + bij ontladen, − bij laden (33135)
residual_energy = import (33283) − export (33285) + discharge (33165) − charge (33161)
```

**28-10-2026 (PBI-012): DC i.p.v. AC-poort.** Tot 28-10 was `residual_power = meter_power_raw +
grid_port_power` (33151, AC-poort). Het omvormerverlies viel daardoor buiten `residual_power`, terwijl
`residual_energy` het wel bevatte: 18/19-10 12,25 kWh integraal tegen 13,98 kWh teller in 20,8 u
(~80–100 W). Wens gebruiker: het verlies is huislast. Met het DC-vermogen aan de accuklemmen telt het
mee (in stand-by bv. 0 W DC tegen −70 W AC op 28-10). Bijeffect in `apply_mode`: setpoint = residual + R
dekt het laadverlies, zodat de accu aan de DC-kant netto R krijgt. Een kleine zelfkoppeling (het verlies
hangt van het laadvermogen af) middelt binnen een ronde uit. `sensor.base_power` (HA-template, owner user)
rekent nog met `nexus_control_inverter_power` (AC) en moet apart mee.

- **Waarom niet 33147** (House load power): U16, kan niet negatief. Bij Omnik-overschot blijft hij op 0
  terwijl de werkelijke residual negatief is. De Solis ziet de Omnik niet als eigen PV.
- **`residual_energy` is tweezijdig** (`state_class: total`): hij daalt bij PV-overschot. De absolute
  waarde is betekenisloos (verschil van levensduurtellers); alleen de verandering telt.
- **Meetzijde accutellers**: 33161/33165 zitten iets boven de BMS-DC-teller (18-10: Solis 12,88 kWh
  geladen tegen Pylontech 12,735), maar niet aantoonbaar op de AC-poort. Omzettingsverlies en
  stand-by van de omvormer komen daardoor in `residual_energy` terecht, altijd aan de oplopende kant —
  **bewust**: dat verlies is huisgebruik. Sinds 28-10 bevat `residual_power` (DC-zijde) het ook.
- Per minuut niet strikt monotoon: net- en accutellers zitten in twee requests en tellen in stappen
  van 0,01 kWh. Over een kwartier middelt dat weg.
- Resolutie 0,01 kWh voor alle vier de tellers (accutellers gecontroleerd tegen de HA-integratie
  `solis_s6_eh3p`, die 14575,55 kWh toont).

## Netstroom per fase (`grid_current_a/b/c`)

Voedt de fasegrens in de [SOC-deadline sturing](#soc-deadline-sturing-charge--discharge): de omvormer stuurt symmetrisch over de 3
fases, dus de werkelijke aansluitlimiet (25A per fase) wordt bepaald door de zwaarst belaste fase — bv. een
EV-lader die asymmetrisch op één fase trekt. `grid_current_a/b/c` (registers 33252/33254/33256, op de
"Grid"-locatie geconfigureerde meter, zie `meter_type_cfg`=`0x0105`) lezen de werkelijke netstroom per fase,
rechtstreeks in Ampère — geen omrekening via vermogen/spanning nodig (dat zou bij afwijkende netspanning of
een niet-cos φ=1-belasting een systematische fout geven).

Sinds 18-10-2026 in de sturing verwerkt (I_LIM 25A, zie aldaar). De sensoren staan op een aparte
FC04-request (buiten het hoofdblok, span 5; `register_count: 2` op 33252/33254 maakt het één request) met
`skip_updates: 10` (~11s-cadans).

---

## Schrijftiming & Modbus protocol

`command_throttle: 750ms` op de modbus_controller heeft sinds ESPHome 2026.x **geen effect meer** (compile-waarschuwing; verdwijnt in 2027.2). De afstand tussen frames regelt nu `turnaround_time` op de `modbus`-component — niet gezet, dus de default van 600ms.

`skip_updates: N` bij `update_interval: 1s` betekent: eens per N+1 seconden. Een poll die nog in de
wachtrij staat wordt niet opnieuw toegevoegd (de hub ontdubbelt), dus de meter-read (33263, elke 2s)
kan de wachtrij niet verstoppen: hij vult in de praktijk de vrije bus-tijd. De grid metrics zijn niet
functioneel nodig; minder samples is acceptabel.

Requests (na het aaneensluiten van de ranges, zie [Read registers](#read-registers-function-code-0x04)):

| Request | Cadans |
|---|---|
| 33263 meter | 2s |
| 33135–33152 hoofdblok | 6s |
| 33252–33256 fasestromen | 11s |
| 33161–33166 en 33283–33286 energietellers | 60s |
| 33213 overdischarge mirror | 15 min |
| 43110–43140 holding-blok (FC03, 31 registers) | 5 min |
| 43029 CT-richting (FC03) | 5 min |
| 43282 RC-timeout (FC03) | 1 uur |
| writes 43133/43132 | 30s |

**Solis-registers zijn de waarheid** (user 30-10): de firmware houdt geen eigen kopie bij van wat er in
een Solis-register staat, maar leest het register terug. Let op: `ModbusNumber::control` publiceert de
nieuwe waarde al bij het in de wachtrij zetten (optimistisch, vóór de bevestiging van de omvormer); pas de
volgende read is echte terugkoppeling. Daarom worden de stuurregisters (43118, 43132/43133, 43135/43136)
elke 5 min teruggelezen, in één blok 43110–43140: ESPHome voegt alleen exact aansluitende registers samen,
dus de gaten (43111–43117, 43119–43131, 43134, 43137–43139) zijn gevuld met interne lees-sensoren
`holding_bridge_*` (`register_count`). Sensoren, geen numbers: een number met `register_count` > 1 schrijft
ook zoveel registers. Gecontroleerd 30-10: de Solis levert het blok van 31 registers in één read (spec: max
50 per frame). Voorheen waren dit zes losse reads (43110, 43118, 43140 elke 5 min; 43132–43133 en
43135–43136 elk uur).

- `g_force_charge` (eigen kopie van "force actief") is vervangen door `rc_force_mode_reg` (43135). Gevolg:
  ook na `hold` zet de eerste ronde in een andere mode force meteen uit (43135 = 0), in plaats van te
  wachten op de RC-timeout.

- **Direct bij wijziging**: `select.control_mode` en beide `number`-entiteiten roepen `apply_mode` synchroon aan via `on_value` (alle drie roepen bovendien eerst `arm_command` aan, zie [Opdrachtvenster](#opdrachtvenster-15-min-en-safe-mode-pbi-046)).
- **interval 30s** → `apply_mode` (setpoint + eventueel RC-herbevestiging, zie [Modi](#modi)) — dit is tevens de keepalive tegen de RC-timeout van de Solis (ingesteld op 2 minuten via 43282, dus 4× marge).
- **interval 5min** → config-registers (43029, 43110, 43140) gecontroleerd en alleen gecorrigeerd bij afwijking van de verwachte waarde; 43282 wordt elke cyclus **onvoorwaardelijk** herschreven (geen drift-check).
- **interval 15min** → `publish_grid_metrics`, zie [Grid Metrics](#grid-metrics--tumbling-window-15-min).
- **33213 (los FC04-request)** → elke 15 min (skip_updates 900), voedt `base_energy` — zie [Energieboekhouding](#energieboekhouding--capaciteit-baseremainingusabletarget_usable).
- **`battery_soc_hires`/`remaining_energy`/`usable_energy`/`target_usable_energy`** → elke 10s; **`base_energy`** → elke 60s + delta-filter (verandert vrijwel nooit).

---

## Grid Metrics — tumbling window (15 min)

De controller accumuleert bij elke meter-read statistieken over `meter_power_raw` (elke 2s, lage prioriteit — zie [Schrijftiming](#schrijftiming--modbus-protocol)) en publiceert ze elke 15 minuten als HA-sensoren. Zo hoeft de HA-recorder geen ruwe meterdata op te slaan.

### Architectuur

```
meter_power_raw (2s, internal)
  ├── on_value → stats-accumulatie (min/max/sum/count/median-buffer/histogram/crossings)
  └── [geen HA-publicatie]

meter_power (template, 5s, HA-visible)
  ├── lambda: return id(meter_power_raw).state
  └── on_value → grid_status_sensor (import / export / level, drempel ±50W)

interval: 15min → publish_grid_metrics script
  ├── berekent mediaan (sort copy van buffer)
  ├── bouwt histogram JSON
  ├── publiceert grid_metric_* sensoren naar HA
  └── reset alle accumulatoren voor volgend venster
```

### Gepubliceerde entiteiten

| Entiteit | Type | Eenheid | Beschrijving |
|---|---|---|---|
| `sensor.nexus_control_grid_metric_min` | sensor | W | Minimum gridvermogen in venster (ruwe waarde) |
| `sensor.nexus_control_grid_metric_max` | sensor | W | Maximum gridvermogen in venster (ruwe waarde) |
| `sensor.nexus_control_grid_metric_mean` | sensor | W | Rekenkundig gemiddelde (ruwe waarde) |
| `sensor.nexus_control_grid_metric_median` | sensor | W | Mediaan (gesorteerde buffer op publish-moment, ruwe waarde) |
| `sensor.nexus_control_grid_metric_samples` | sensor (total) | — | Aantal samples in venster (max ~450; minder als de bus vol zit); HA som = totaal/uur |
| `sensor.nexus_control_grid_metric_crossings` | sensor (total) | — | Zero-crossings (import↔export) in venster; HA som = totaal/uur |
| `sensor.nexus_control_grid_metric_histogram` | text | JSON | Verdeling van `grid − target_grid` over 9 buckets |

Alle numerieke sensoren hebben `state_class: measurement` (of `total` voor samples/crossings) → HA berekent automatisch uur/dag-statistieken via de recorder.

### Histogram

De histogram-buckets zitten niet op het ruwe gridvermogen, maar op de **afwijking t.o.v. het setpoint**: `delta = grid_power − target_grid`. Negen buckets, grenzen op ±20/50/100/500 W:

| Bucket-sleutel | Bereik (delta t.o.v. target_grid) |
|---|---|
| `lt-500` | < −500 W |
| `-500:-100` | −500 … −100 W |
| `-100:-50` | −100 … −50 W |
| `-50:-20` | −50 … −20 W |
| `-20:20` | −20 … +20 W (near-target zone) |
| `20:50` | +20 … +50 W |
| `50:100` | +50 … +100 W |
| `100:500` | +100 … +500 W |
| `gt500` | > +500 W |

Voorbeeld JSON-output:
```json
{"gt500":0,"100:500":3,"50:100":25,"20:50":870,"-20:20":2,"-50:-20":0,"-100:-50":0,"-500:-100":0,"lt-500":0}
```

### Zero-crossings

Detectie via drie zones op het ruwe gridvermogen, met ±20W dode band:

| Zone | Drempel |
|---|---|
| import | > +20 W |
| dead-band | −20 W … +20 W |
| export | < −20 W |

Een crossing wordt geteld bij een directe import→export of export→import overgang (dead-band passeren reset de zone **niet** — alleen een echte richting wissel telt).

### EMS-gebruik

De EMS (ems_balance / ems_strategy) leest deze sensoren om `target_grid_w` te optimaliseren:

- **`crossings`** → directe proxy voor oscillatiefrequentie; hoog = target_grid te laag
- **`median`** → structureel zwaartepunt van het gridvermogen; afwijking van target_grid zichtbaar
- **`histogram`** → diagnose van amplitude t.o.v. het setpoint; near-target bucket (`-20:20`) idealiter > 95%
- **`min` / `max`** → detectie van uitschieters (compressorstarts, PV-wisselingen)

De `sensor.nexus_control_grid_power` entiteit (5s) blijft beschikbaar voor real-time dashboard en AppDaemon-polling.

---

## Periodieke configuratie (elke 5 minuten)

1. **43029** = `1` — CT Reversed (alleen geschreven bij afwijking)
2. **43110** = `33` — Self-Use + Allow Grid Charge (alleen geschreven bij afwijking)
3. **43140** = `0x0105` — Meter type Eastron 3Ph Grid (alleen geschreven bij afwijking)
4. **43282** = `2` — RC Timeout 2 minuten, de minimumwaarde volgens spec (**onvoorwaardelijk** elke cyclus herschreven, geen drift-check)

---

## Niet geïmplementeerd (bewuste keuze)

- **Fout-detectie & watchdog**: geen `binary_sensor.fault`, geen `binary_sensor.grid_meter_connected`, geen timeout-detectie op de meter en geen automatische fallback naar `hold` bij verlies van HA- of metercommunicatie. Gepland, nog niet gebouwd in `nexus_control.yaml`.
- **Register 43128**: bewust overgeslagen — schrijven van 0 stuurt grid naar 0W.
- **Toegewijde Force Charge/Discharge-registers** (43129/43130/43131/43134): niet gebruikt — `charge`/`discharge` lopen via dezelfde RC Grid Adjustment-route als `level`.
- **Peak Shaving mode** (43110 BIT11): niet bruikbaar voor discharge-met-export.
