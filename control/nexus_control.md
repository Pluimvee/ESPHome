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

Gelezen als één FC04-request over het blok 33135–33152 (bridge-register 33143 sluit de gap, intern, geen HA-entiteit).

| Register | Type | Eenheid | Naam | Noot |
|---|---|---|---|---|
| 33135 | U16 | — | Battery current direction | `0`=charge, `1`=discharge — autoritatieve richting voor 33149 (zie hierboven) |
| 33139 | U16 | 1% | Battery SOC | 0–100%; `on_value` her-ankert de coulomb-counting bij een echte wijziging |
| 33143 | U16 | — | Bridge register | Dummy, sluit gap zodat 33135–33152 één FC04-request is |
| 33147 | U16 | 1W | House load power | Totaal, altijd positief |
| 33149 | S32 | 1W | Battery power | Alleen betrouwbaar als **magnitude** (2 registers); richting via 33135 |
| 33151 | S32 | 1W | Inverter AC Grid Port Power | + = export, − = import (2 registers) |
| 33263 | S32 | 1W | Meter total active power | Na `multiply:-1`: + = import, − = export (2 registers); intern 1Hz-gelezen |

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
| 43135 | U16 | — | RC Force Charge/Discharge | 0=OFF, **1**=Force Charge | alleen geschreven in `hold` (→1) |
| 43136 | U16 | 10W | RC Force Charge Power | — | alleen geschreven in `hold` (→0) |
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
| `select.control_mode` | select | Mode: hold / level / charge / discharge, `optimistic`, `restore_value` |
| `number.target_grid_power` | number | Doelvermogen in W (huis-conv), −10000…10000, stap 100 |
| `number.target_soc` | number | Doel-SOC in %, 7…100, stap 1, default 80 — alleen relevant in charge/discharge |
| `sensor.battery_capacity` | sensor | Accucapaciteit in kWh — **vaste** waarde (20.48) uit `substitutions`, alleen gepubliceerd ter inzage; geen HA-input meer, zie [Energieboekhouding](#energieboekhouding--capaciteit-baseremainingusabletarget_usable) |
| `sensor.battery_soc` | sensor | SOC %, ruwe BMS-waarde (1%-resolutie, onregelmatige update) |
| `sensor.battery_soc_hires` | sensor | Hoger-resolutie SOC-schatting (2 decimalen, 10s), lopend geklemd op ±0,9pp t.o.v. de laatste echte BMS-waarde; telling staat uit bij SOC ≥ 99 en ≤ 7, zie [Hoge-resolutie SOC](#hoge-resolutie-soc--coulomb-counting-tussen-bms-updates) |
| `sensor.base_energy` | sensor | Energie onder de overdischarge-ondergrens (kWh), niet bruikbaar — zie [Energieboekhouding](#energieboekhouding--capaciteit-baseremainingusabletarget_usable) |
| `sensor.remaining_energy` | sensor | Totale accu-inhoud in kWh, afgeleid van `battery_soc_hires` — zie [Energieboekhouding](#energieboekhouding--capaciteit-baseremainingusabletarget_usable) |
| `sensor.usable_energy` | sensor | `remaining_energy − base_energy` (kWh) — zie [Energieboekhouding](#energieboekhouding--capaciteit-baseremainingusabletarget_usable) |
| `sensor.target_usable_energy` | sensor | `target_soc` uitgedrukt in kWh boven de ondergrens; observationeel, nog niet in `apply_mode` verwerkt — zie [Energieboekhouding](#energieboekhouding--capaciteit-baseremainingusabletarget_usable) |
| `sensor.grid_power` | sensor | Netmeter W (huis-conv: + = import), 5s, HA-visible |
| `sensor.inverter_power` | sensor | AC grid port W (Solis-conv: + = export) |
| `sensor.house_load` | sensor | Huislast W |
| `sensor.grid_current_a/b/c` | sensor | Netstroom per fase (A), 0.01A-resolutie, ~10s, zie [Netstroom per fase](#netstroom-per-fase-grid_current_ab_c) |
| `text_sensor.inverter_status` | text | `charging` / `discharging` / `standby`, afgeleid van `inverter_power` (drempel ±150W) |
| `text_sensor.grid_status` | text | `import` / `export` / `level`, afgeleid van `grid_power` (drempel ±50W) |
| `sensor.grid_metric_*` + `text_sensor.grid_metric_histogram` | sensor/text | 15-min venstermetrics, zie [Grid Metrics](#grid-metrics--tumbling-window-15-min) |

Er is geen `binary_sensor.fault` of `binary_sensor.grid_meter_connected` — foutdetectie is niet geïmplementeerd, zie [Niet geïmplementeerd](#niet-geïmplementeerd-bewuste-keuze).

---

## Modi

Eén script, `apply_mode`, dekt alle vier de modes — geen apart `update_soc_setpoint` meer. Aangeroepen bij elke mode-/target-wijziging (`on_value`) én elke **30s** via `interval`.

### hold
Enige echte uitzondering: ander Solis-mechanisme (Force Charge i.p.v. RC Grid Adjustment), en moet **onvoorwaardelijk** herbevestigd worden — self-use is precies wat `hold` wil vóórkomen. Schrijft `43136=0` (RC Force Charge Power) en `43135=1` (Force Charge aan, op 0W), zet `target_soc_deadline_ms` op 0, en stopt (`return`) vóór de rest van het script. `43132`/`43133` worden in `hold` niet aangeraakt.

### level / charge / discharge
Gedeeld mechanisme via RC Grid Adjustment (43132/43133) — er is **geen** apart Force Charge/Discharge-pad voor `charge`/`discharge`. `43135`/`43136` worden hier nooit geschreven.

- `level`: `adjusted_w = target_grid_w` (geen extra-term)
- `charge`: `adjusted_w = target_grid_w + extra_w` (meer import toegestaan om te laden) — `extra_w` volgt uit de SOC-deadline-sturing hieronder
- `discharge`: `adjusted_w = target_grid_w − extra_w` (meer export toegestaan om te ontladen)

Vervolgens, voor alle drie de modes identiek:

1. **43133 wordt altijd geschreven**: `sp = -(adjusted_w / 10)` (huis → Solis conventie), ongeacht de grootte van `adjusted_w`. Dit kost niets en geeft direct effect zolang RC nog actief is.
2. **43132 wordt alleen herbevestigd (→1) als `|adjusted_w| > RC_THRESHOLD_W`** (100W). Onder die drempel schrijven we 43132 niet — de Solis' eigen RC-timeout (43282) laat 'm dan vanzelf verlopen naar self-use, zonder dat de firmware zelf hoeft te bepalen wanneer een waarde "stabiel genoeg" is. Dit vervangt de oude aparte `target_grid=0`-speciale-geval-logica in `level`: hetzelfde drempelmechanisme dekt dat geval nu vanzelf mee.

Als `soc` geen geldige waarde heeft (< 0.5%) of het SOC-doel gehaald is (het anker is dan naar `target_soc` geratelde, dus `soc_gap` en `erosion_pct` beide 0), vervalt `extra_w` en wordt gewoon `sp = -(target_grid_w / 10)` geschreven — functioneel identiek aan `level`. `soc` is hier de hoger-resolutie schatting uit `battery_soc_hires`, met fallback naar de ruwe `battery_soc` zolang er nog geen anchor is geweest — zie [Hoge-resolutie SOC](#hoge-resolutie-soc--coulomb-counting-tussen-bms-updates).

> **RC-timeout als hardware-native fallback**: in plaats van software die expliciet beslist wanneer RC Grid Adjustment "uit" moet (met het risico op flapping zonder handmatige hysterese), laat dit ontwerp de Solis' eigen RC-timeout (43282, nu 2 minuten) het werk doen — de firmware hoeft alleen actief te *herbevestigen* zolang er een betekenisvolle aanvraag is, en anders niets te doen. Dit wordt momenteel empirisch getest door `rc_grid_adj_reg` (43132) tijdelijk zichtbaar te maken in HA (zie entiteitentabel) en te observeren of hij vanzelf naar 0 zakt.

---

## SOC-deadline sturing (charge / discharge)

Geen klassieke PI-regelaar op de gemeten grid-power, maar een **energie-budget over een aftellende deadline**, met een **PV-marge** die de sturing tijdelijk terughoudt zolang PV het gat mogelijk gratis kan dichten:

```
BATTERY_WH      = 20480    # accucapaciteit, uit substitutions.battery_capacity_kwh
MAX_GRID_W      = 10000    # plafond op |target_grid_w + extra_w| (de totale grid-aanvraag)
RATE_FLOOR_MS   = 120000   # 2 min: ondergrens op de deler in de extra_w-rekensom
MARGIN_LEAD_MS  = 300000   # 5 min: PV-marge is hier al 0, vóór de rate-vloer intreedt
PV_BUDGET_WH    = 2000     # aanname: max 2 kWh "gratis" PV-bijdrage binnen het venster
PV_RATE_W       = 2000     # aangenomen gemiddeld PV-surplusvermogen

anchor_soc = (g_soc_window_anchor is geldig) ? g_soc_window_anchor : soc   # zie hieronder
anchor_soc = max(anchor_soc, soc)               # charge     — ratel: schuift alleen omhoog mee
anchor_soc = min(anchor_soc, soc)               # discharge  — ratel: schuift alleen omlaag mee
anchor_soc = min(anchor_soc, target_soc)        # charge     — klem: nooit voorbij het doel
anchor_soc = max(anchor_soc, target_soc)        # discharge
g_soc_window_anchor = anchor_soc                # terugschrijven, anders geen ratel

soc_gap     = max(0, target_soc − anchor_soc)   # charge     — wat er nog te gaan is
soc_gap     = max(0, anchor_soc − target_soc)   # discharge
erosion_pct = max(0, anchor_soc − soc)          # charge     — terugval sinds venster-start
erosion_pct = max(0, soc − anchor_soc)          # discharge
# (soc_gap/erosion_pct blijven 0 als soc ongeldig is, want soc dan op -1 gezet)
# soc = battery_soc_hires (coulomb-counted, zie eigen sectie), fallback naar ruwe battery_soc

if soc_gap <= 0 and erosion_pct <= 0:
    sp = -(target_grid_w / 10)                              # neutraal, doel al gehaald, geen terugval
else:
    margin_deadline_ms   = max(target_soc_deadline_ms, now_ms + MARGIN_LEAD_MS)
    margin_effective_h   = (margin_deadline_ms − now_ms) / 3600000 − MARGIN_LEAD_MS / 3600000
    margin_wh            = min(PV_BUDGET_WH, PV_RATE_W * margin_effective_h)
    margin_pct           = margin_wh / BATTERY_WH * 100
    if mode != "charge": margin_pct = 0                     # PV-marge geldt ALLEEN bij laden
    need_pct             = erosion_pct + max(0, soc_gap − margin_pct)   # marge kort NOOIT op erosion_pct

    if need_pct <= 0:
        sp = -(target_grid_w / 10)                          # PV-marge dekt het gat, geen duw nodig
    else:
        rate_deadline_ms = max(target_soc_deadline_ms, now_ms + RATE_FLOOR_MS)
        remaining_h      = (rate_deadline_ms − now_ms) / 3600000
        extra_w_max      = MAX_GRID_W − target_grid_w        # charge
        extra_w_max      = MAX_GRID_W + target_grid_w        # discharge
        extra_w          = min(need_pct / 100 * BATTERY_WH / remaining_h, max(0, extra_w_max))
        adjusted_w       = target_grid_w + extra_w           # charge
        adjusted_w       = target_grid_w − extra_w           # discharge
        sp = -(adjusted_w / 10)

write_register(43133, sp)
```

Uitgevoerd elke **30s** via `interval`, en direct bij mode-/target-wijziging — beide via hetzelfde `apply_mode`-script (zie [Modi](#modi)).

> **`MAX_GRID_W` is geen omvormer-vermogensgrens**: 43133 is een target voor de gemeten grid-flow, niet voor het omvormervermogen zelf — de Solis probeert dat setpoint te halen door batterijvermogen bij te schakelen (`grid = huislast − PV + batterijvermogen`), en dát batterijvermogen is wat door het omvormer-vermogen begrensd wordt. Een aanvraag van 15kW bleek in de praktijk niet gehaald te worden; `MAX_GRID_W = 10000` is een pragmatische, vaste bovengrens (geen theoretisch afgeleide waarde).
>
> **TODO — vaste `MAX_GRID_W` per fase**: de omvormer stuurt symmetrisch over de 3 fases, dus bij een asymmetrische huislast (bv. een EV-lader op één fase) kan een enkele fase al over de 25A-grens gaan ruim vóór `MAX_GRID_W` in totaal bereikt is. De benodigde stroom-per-fase is inmiddels wél uitgelezen (`grid_current_a/b/c`, zie [Netstroom per fase](#netstroom-per-fase-grid_current_ab_c)) — alleen de koppeling naar een dynamische, per-fase-bewuste `MAX_GRID_W` in `apply_mode` ontbreekt nog.

De vroegere TODO over SOC-resolutie is opgelost: zie [Hoge-resolutie SOC](#hoge-resolutie-soc--coulomb-counting-tussen-bms-updates).

### Erosion-bescherming: nooit onder het venster-startpunt terugzakken

**Aanleiding (06-09-2026)**: bij `mode=charge`, `soc=47%`, `target_soc=49%` en nog 24 minuten tot de
eerstvolgende klok-uur-deadline, was de PV-marge (~3pp) groter dan de gap (2pp) → `need_pct=0` →
`adjusted_w = target_grid_w` (doorgaans 0: "laad alleen op PV-surplus"). Met `|adjusted_w| ≤
RC_THRESHOLD_W` herbevestigt `apply_mode` 43132 niet, dus de Solis valt terug op self-use. Zowel via een
RC-setpoint van 0 als via self-use geldt dezelfde natuurkunde: als huislast > PV, is de **enige** manier om
de meter op 0 te houden dat de batterij het verschil bijlegt — dus ontladen. Precies het tegenovergestelde
van wat `charge`-mode zou moeten doen terwijl hij op zijn PV-kans wacht.

De kern: `target_grid=0` is een *symmetrisch* doel (geen import, geen export), maar de bedoeling van de
PV-wachtfase is impliciet *asymmetrisch* — laad graag op PV-surplus, ontlaad nooit. Die twee vallen alleen
samen zolang PV ≥ load.

**Oplossing**: `g_soc_window_anchor` — een snapshot van `soc` op hetzelfde arm-moment als
`target_soc_deadline_ms` (dus gezet in `arm_soc_deadline`, bij elke mode- of target_soc-wijziging en bij
opstarten). `apply_mode` splitst de gap vervolgens in twee delen met elk hun eigen behandeling:

- **`soc_gap`** — het deel van de gap dat al bestond bij venster-start (`target_soc` t.o.v. de anchor). Hier
  mag de PV-marge op korten, zoals voorheen.
- **`erosion_pct`** — hoeveel `soc` sinds de anchor is *teruggezakt* (charge) of *opgelopen* (discharge).
  Dit krijgt **geen** marge-korting: `need_pct = erosion_pct + max(0, soc_gap − margin_pct)`. Zodra `soc`
  onder de anchor zakt (charge) wordt dat bedrag onmiddellijk en volledig met `extra_w` gecompenseerd —
  ongeacht de oorzaak, self-use-ontlading incluis. **Maar alleen zolang de anchor niet voorbij het doel
  ligt**, zie de anchor-klem hieronder.

Effect: een hold-op-SOC zolang er niets misgaat, een geduldige groei naar `target_soc` met PV-marge, én een
directe correctie zodra er ongewenst wordt teruggezakt — zonder dat er een aparte feedback-lus op de rauwe
batterijrichting (33135) nodig is. Omdat de correctie loopt via de al bestaande `battery_soc_hires` (10s-
resolutie) en de al bestaande `RC_THRESHOLD_W`-drempel (100W) als natuurlijke ruisonderdrukking fungeert,
blijft het ontwerp volledig feedforward — geen nieuw hysterese-/slinger-risico.

`erosion_pct` is zichtbaar in de log (`ESP_LOGI`) naast `soc`/`margin`/`extra`/`adj`, voor observeerbaarheid.

### Anchor-klem: het anker mag het doel niet passeren — incident 07-09-2026

De erosion-bescherming hierboven compenseert alles onder de anchor. Dat is alleen gewenst tot aan
`target_soc`. Ligt de anchor bóven het doel, dan wordt een daling *richting* dat doel als erosie behandeld
en meteen weggewerkt — precies het tegenovergestelde van wat de strategie vroeg.

**Waargenomen 07-09-2026 02:00–05:00**: `mode=charge`, anchor ~54%, `target_soc=17%`. `soc_gap` werd correct
0 (doel ligt onder de anchor), maar `erosion_pct` wordt daar BUITEN bij opgeteld en wekte de aandrijving
weer tot leven. Elke dip onder 54% werd bijgevuld: de accu bleef geplakt en het huis liep **0,93 kWh op
netstroom à ~31 ct**. De strategie vroeg om ontladen en kreeg een hold — plan en uitvoering liepen uiteen,
wat de hele planningslus onderuit haalt.

**Oplossing** — één regel per modus, vóór de gap/erosion-splitsing:

```
if mode == "charge":     anchor_soc = min(anchor_soc, target_soc)
if mode == "discharge":  anchor_soc = max(anchor_soc, target_soc)
```

Daarmee geldt altijd: alles ONDER de anchor is erosie (direct bijladen, geen PV-korting), alles TUSSEN
anchor en `target_soc` is de gap (PV-marge mag korten). In het geval hierboven wordt de anchor 17%: erosie
geldt pas onder 17%, en tussen 17% en 17% is geen gap — dus geen aandrijving, en de accu levert gewoon aan
het huis.

Als bijvangst kan `need_pct` niet meer voorbij het doel schieten: de som is per constructie begrensd door
`target_soc`.

### Ratel: het anker schuift mee met echte voortgang — 07-09-2026

`soc_gap` werd alleen uit anker en `target_soc` berekend, en het anker stond vast vanaf het arm-moment.
Daardoor kromp de gap **niet** als de accu daadwerkelijk richting het doel bewoog, en `erosion_pct` reageert
per definitie alleen op beweging de verkeerde kant op — dus succes kon de aandrijving niet uitzetten. Bij een
dump van 46% naar `target_soc=40,1%` bleef `need_pct` 5,9pp staan terwijl `remaining_h` naar de
2-minutenvloer kromp, met vol doorduwen dwars door het doel heen tot gevolg. Bij laden idem: haalde PV het
doel vroeg, dan forceerde de sturing bij het uitdoven van de marge alsnog netstroom-import.

De fix is een ratel op het anker: elke cyclus schuift het anker mee met de echte `soc` — bij `charge` alleen
omhoog, bij `discharge` alleen omlaag — en wordt teruggeschreven naar `g_soc_window_anchor`. Samen met de
anchor-klem hierboven convergeert het anker naar `target_soc`; vanaf dat punt is `soc_gap` 0 en resteert een
zuivere hold-op-doel, met directe correctie zodra `soc` de verkeerde kant op wegloopt.

Gedragsgevolg om bewust van te zijn: de ratel verdedigt óók tussentijdse winst. Bij wisselend bewolkt weer
wordt een gewonnen halve procent bij het wegzakken direct hersteld in plaats van op de volgende zonnige
periode te wachten.

### PV-marge geldt alleen bij laden — 07-09-2026

`margin_pct` werd onvoorwaardelijk afgetrokken, ook in `discharge`. Dat is averechts: de marge betekent "er
komt gratis PV bij, dus dat deel hoef ik niet zelf te sturen" — een LAAD-aanname. Bij ontladen vult die
verwachte PV juist de accu die je aan het legen bent, dus hij zou een dump *urgenter* moeten maken in plaats
van erop te korten.

Met `PV_BUDGET_WH=2000` op `BATTERY_WH=20000` loopt de marge op tot **10pp**. Gemeten 07-09 bij
`target_soc=40,1%` / `soc=46%` (gap ~5,9pp): om 07:05 was de marge 8,3pp → `need_pct=0` → **geen ontlading**;
om 07:30 nog 4,2pp → 29% van de gevraagde snelheid. De dump kwam pas op gang in de laatste minuten vóór de
deadline; wat er in die uren zakte was self-use voor de huislast, niet de gevraagde ontlading.

Fix: `if (mode != "charge") margin_pct = 0.0f;` — op 0 zetten in plaats van de aftrekking overslaan, zodat
de `ESP_LOGI`-regel ook echt 0 toont.

### De deadline: eerstvolgend wandklok-uur, geen relatieve reset

`target_soc_deadline_ms` wordt gearmd via het `arm_soc_deadline` script, dat het **eerstvolgende hele wandklok-uur** pakt (via de `time:`-component `ha_time`, gevoed door de HA-API — geen extra hardware/NTP nodig). Is er nog geen geldige kloktijd (bv. net opgestart), dan valt de firmware terug op het oude gedrag (now + 1 uur). Op hetzelfde moment wordt ook `g_soc_window_anchor` gezet (snapshot van `soc`) — zie [Erosion-bescherming](#erosion-bescherming-nooit-onder-het-venster-startpunt-terugzakken) hierboven.

`arm_soc_deadline` wordt uitgevoerd zodra:
- de mode wijzigt (`select.control_mode` `on_value`) — geldt voor élke gekozen mode, ook `hold`/`level` (waar `target_soc_deadline_ms` vervolgens meteen weer op 0 wordt gezet door `apply_mode`)
- `target_soc` wijzigt (`number.target_soc` `on_value`)

Daarna telt de deadline af in kloktijd; de 30s-interval (`apply_mode`) reset hem niet, en dankzij de write-on-change fix in `ems_controller.py` vuurt `on_value` alleen nog bij een echte wijziging — dus `remaining_h` telt daadwerkelijk af richting het klok-uur in plaats van telkens te resetten. Effect:
- Vlak na een wijziging is de PV-marge maximaal (10% van de accucapaciteit) → `extra_w` blijft 0 zolang PV het gat binnen die marge kan dichten.
- Zodra nog maar 5 minuten resteren (`MARGIN_LEAD_MS`) is de marge uitgedoofd naar 0 — vanaf dat punt moet de sturing het volledige resterende gat zelf dichten, ongeacht PV.
- Zodra de deadline binnen 2 minuten ligt (`RATE_FLOOR_MS`), klemt de deler vast op 2 minuten resterend — de sturing blijft daarna maximaal duwen totdat de gebruiker `target_soc` opnieuw instelt, van mode wisselt, of het volgende klok-uur aanbreekt (waarna een nieuwe `arm_soc_deadline`-aanroep nodig is om verder te tellen — dat gebeurt pas bij de eerstvolgende mode- of target_soc-wijziging).

`target_soc` is dus een echte SOC-waarde (7–100%): hoe lang geleden hij (of de mode) voor het laatst is aangepast, bepaalt hoe dicht de eerstvolgende klok-uur-deadline is genaderd, hoeveel van de PV-marge al is uitgedoofd, en dus hoe agressief de sturing intussen is geworden.

### Typisch gebruik: export voorkomen + SOC garanderen bij lage spotprijs

```
mode:        charge
target_grid: 0W       # geen export toegestaan; batterij laadt alleen op PV-surplus
target_soc:  80%       # garandeert het SOC-doel ook als er geen PV-surplus is
```

Met `target_grid = 0` laadt de batterij in eerste instantie alleen op PV-surplus. Naarmate de deadline verstrijkt zonder dat `target_soc` gehaald wordt, duwt `extra_w` het setpoint steeds verder richting import om het doel alsnog te halen.

---

## Hoge-resolutie SOC — coulomb counting tussen BMS-updates

`battery_soc` (33139) komt rechtstreeks van de BMS en heeft twee praktische beperkingen: 1%-resolutie
(= 200Wh bij 20kWh accucapaciteit) en een **onregelmatige** update — de BMS ververst pas zodra de waarde
echt naar een nieuwe 1%-stap springt, niet op een vaste klok. Voor een sturing die elke 30s bijstuurt is
dat te grof en te traag.

### Aanpak: doorlopende telling, twee klemmen

De stapgrens van de BMS ligt **niet** op een vaste plek. Waargenomen 07-09-2026: lang wachten op de
overgang 47 → 48, en vlak daarna meteen 48 → 49. De SOC en de eigen kWh-teller van de BMS lopen dus
niet synchroon. Daarom wordt de telling *niet* naar de stap toe getrokken — dat zou de betere
informatie juist weggooien — maar krijgt hij twee verschillende klemmen:

- **lopend ±0,9pp** rond de BMS-melding: ruimte om vooruit te lopen op een achterblijvende stap;
- **±0,5pp op het moment van een stap**: alleen als de telling daarbuiten ligt wordt hij bijgetrokken.

```
battery_soc (33139) on_value:
  als waarde écht gewijzigd is (niet elke poll, want vaak dezelfde waarde):
    als geen vorige waarde OF nieuwe_soc >= 99 OF <= 7:      # opstart / eindpuntzone
      anchor = nieuwe_soc                                    # BMS exact overnemen
    anders:
      # h = exact wat battery_soc_hires publiceerde: GEKLEMD, niet de rauwe telling
      als vorige_soc >= 99 of <= 7: h = vorige_soc
      anders:
        h = g_batt_hires_anchor + (g_batt_energy_wh - g_batt_energy_anchor_wh) / capaciteit_wh * 100
        h = clamp(h, vorige_soc - 0.9, vorige_soc + 0.9)
      anchor = clamp(h, nieuwe_soc - 0.5, nieuwe_soc + 0.5)

    g_batt_hires_anchor     = anchor
    g_batt_energy_anchor_wh = g_batt_energy_wh               # ALTIJD verversen
    g_batt_soc_last_raw     = nieuwe_soc

battery_power_raw (33149-33150) on_value:
  dt_h = (now - g_batt_energy_last_ms) / 3600000
  p = abs(battery_power_raw)                                  # zie hieronder: alleen magnitude betrouwbaar
  als battery_direction_raw (33135) == 1 (discharge): p = -p
  g_batt_energy_wh += p * dt_h                                # loopt continu door, wordt nooit gereset
  g_batt_energy_last_ms = now

battery_soc_hires (elke 10s):
  als bms >= 99 of bms <= 7:  return bms                      # telling UIT, BMS is autoritatief
  delta_wh = g_batt_energy_wh - g_batt_energy_anchor_wh       # CUMULATIEF sinds anchor
  hires    = g_batt_hires_anchor + delta_wh / (battery_capacity_kwh * 1000) * 100
  return clamp(hires, bms - 0.9, bms + 0.9)
```

**Her-anker op de geklemde stand, en altijd** — dit is de subtiliteit die het makkelijkst misgaat. De
lopende klem zit op de *uitvoer*, niet op de *toestand*: intern loopt `anchor + energie sinds anchor`
ongeklemd door. Bij een achterlopende BMS liep die rauwe waarde naar bv. 49,2 terwijl de sensor op de
bandrand 47,9 vastgepind stond. Her-ankerde je dan op die 49,2, dan gaf de stap naar 48 een sprong naar
48,5 — de opgebouwde fout werd bewaard in plaats van weggegooid. Daarom wordt her-ankerd op `h`, de
waarde zoals *gepubliceerd* (dus geklemd), en wordt het energie-snapshot bij **elke** stap ververst.

**Continuïteit**: concreet voor het 47 → 48-geval parkeert de telling vóór de late stap op de bandrand
47,9. Die valt binnen [47,5 … 48,5], dus 47,9 wordt het nieuwe anker en de telling loopt daar zonder
sprong vanaf verder — nu met band [47,1 … 48,9]. Loopt de telling juist áchter (47,2 terwijl de BMS al
48 meldt), dan trekt de ±0,5-klem hem op naar 47,5: daar wint de BMS, want de stap zegt dat we minstens
zover zijn.

**Prijs**: met ±0,9 kan `hires` een ánder heel procent aanwijzen dan de BMS. Dat is bewust
geaccepteerd toen bleek dat de stapgrens van de BMS zelf verschuift — de BMS-melding is op korte
termijn dus juist niet de betrouwbaardere van de twee.

De **eindpunten** worden exact overgenomen: zou je daar ook een marge toepassen, dan zou `hires` de
100 nooit kunnen aanwijzen.

**Telling uit bij de eindpunten** (SOC ≥ 99 of ≤ 7): daar is de stroom te klein voor de shunt
(CV-taper bovenin, bijna-leeg onderin) en is het juist de BMS die zelf herijkt. Gevolg: `hires` kan
alleen 99/100 aanwijzen als de BMS dat zelf meldt, en zakt niet onder de vloer. Het bereik van de
schatting is dus `{7} ∪ [7,1 … 98,9] ∪ {99, 100}` — met opzet een gat vlak vóór de eindpunten.
De drempels 99 en 7 staan als `hires_top_pct`/`hires_floor_pct` in `substitutions`, zodat de
ankering en de berekening niet uit elkaar kunnen lopen.

`apply_mode` gebruikt `battery_soc_hires` rechtstreeks als `soc`-bron (geen eigen herberekening meer), met
fallback naar de ruwe `battery_soc` zolang er nog geen anchor is geweest (net opgestart — hires is dan NAN).

### Waarom geklemd — incident 05-09-2026

Zonder klem liep de coulomb-telling ongemerkt weg tijdens een BMS-plateau: op 05-09-2026 bleef de BMS-SOC
2,5 uur op 89% hangen (LFP-plateau — geen bruikbare spanningsreferentie rond dat punt, en de shunt kan
~0,5A niet betrouwbaar resolveren), terwijl `battery_soc_hires` ondertussen doortelde tot 95% — 6pp naast
de werkelijkheid. Erger: bij een doel van 100% stopte de sturing te vroeg, omdat déze schatting al 100
haalde terwijl de BMS zelf nog op 99% stond. Daardoor bereikte de accu de CV-taper niet en herijkte de BMS
zijn SOC nooit (de celspanning bleef op 3.388V hangen i.p.v. de ~3.51V die een echte volle lading geeft).

Gevolg van de klem: `hires` kan 100 alleen aanwijzen als de BMS zelf 100 meldt. De sturing moet dus
doorladen tot de BMS vol zegt, wat de herijking afdwingt. Prijs: een échte BMS-stilstand wordt hiermee
onzichtbaar — `hires` pint op de bandrand en staat stil zolang de BMS niet update. Bewuste ruil voor een
harde bovengrens op de fout.

**Herzien 07-09-2026, in twee stappen.** Eerst van ±0,99pp naar een smalle band, omdat `hires` anders een
vol procentpunt van de BMS kon afwijken. Een tussenversie met `[−0,50 … +0,49]` bleek bovendien twee gaten
te houden: bij `bms == 100` liet de band `hires` tot 100,49 oplopen (de telling loopt tijdens de CV-taper
gewoon door), waardoor `remaining_energy` boven de capaciteit uitkwam; onderaan werd `usable_energy` op
dezelfde manier negatief. Dat is opgelost door de telling bij de eindpunten helemaal uit te zetten.

Daarna weer verruimd naar ±0,9 toen bleek dat de stapgrens van de BMS zelf verschuift (zie hierboven). De
smalle band ging er impliciet van uit dat een BMS-stap een betrouwbare waarneming van een vaste drempel is;
dat blijkt niet zo. Eindstand:

```
lopend:      bms − 0,9  ≤  hires  ≤  bms + 0,9
bij stap:    alleen bijtrekken als hires buiten [bms − 0,5 .. bms + 0,5] ligt
eindpunten:  bms ≥ 99 of ≤ 7  →  hires = bms
```

> **Implementatiedetail — cumulatief, niet incrementeel**: `delta_wh` wordt altijd gemeten als
> `g_batt_energy_wh − anchor-snapshot` (het totaal sinds de anchor), nooit incrementeel per cyclus
> opgeteld. Zou je per 10s-cyclus een geklemde increment optellen, dan is er geen echte begrenzing: 360
> stappen van 10s (1 uur) zouden elk voor zich binnen de band kunnen vallen en toch onbeperkt blijven
> oplopen.
>
> **Blijft integreren op 33149, niet op 33161/33165**: die laatste energietellers meten aan de
> omvormerzijde en bevatten ~100W vaste overhead, wat `battery_soc_hires` tijdens laden systematisch te
> hoog zou duwen (en de band-klem te vroeg zou laten aanslaan). 33149 is de DC-zijde aan de accuklemmen
> — dat houdt bovendien het omvormerverbruik verderop in de keten zichtbaar als load, niet als opgeslagen
> energie.

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
| `sensor.battery_soc_hires` | sensor | 0.01%, elke 10s | `NAN` zolang er nog geen anchor is geweest; anders lopend geklemd op ±0,9pp t.o.v. `g_batt_soc_last_raw`. Telling staat uit bij SOC ≥ 99 en ≤ 7 (dan exact de BMS-waarde), dus bereik `{7} ∪ [7,1 … 98,9] ∪ {99, 100}` |

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

## Netstroom per fase (`grid_current_a/b/c`)

Voorbereidende stap voor de per-fase-`MAX_GRID_W`-TODO hierboven: de omvormer stuurt symmetrisch over de 3
fases, dus de werkelijke aansluitlimiet (25A per fase) wordt bepaald door de zwaarst belaste fase — bv. een
EV-lader die asymmetrisch op één fase trekt. `grid_current_a/b/c` (registers 33252/33254/33256, op de
"Grid"-locatie geconfigureerde meter, zie `meter_type_cfg`=`0x0105`) lezen de werkelijke netstroom per fase,
rechtstreeks in Ampère — geen omrekening via vermogen/spanning nodig (dat zou bij afwijkende netspanning of
een niet-cos φ=1-belasting een systematische fout geven).

**Status: alleen uitlezen, nog niet in de sturing verwerkt.** De sensoren staan op een aparte FC04-request
(buiten het hoofdblok, span 5, geen bridge nodig) met `skip_updates: 10` (~10s-cadans). De koppeling naar een
dynamische `MAX_GRID_W` in `apply_mode` — met een aan te bepalen omgang met kortstondige piekstromen
(~10s tolerantie is acceptabel) — is nog niet geïmplementeerd.

---

## Schrijftiming & Modbus protocol

`command_throttle: 750ms` op de modbus_controller zorgt voor minimaal 750ms tussen frames op de bus, ongeacht de diepte van de queue.

- **Direct bij wijziging**: `select.control_mode` en beide `number`-entiteiten roepen `apply_mode` synchroon aan via `on_value` (mode- en target_soc-wijziging roepen bovendien eerst `arm_soc_deadline` aan).
- **interval 30s** → `apply_mode` (setpoint + eventueel RC-herbevestiging, zie [Modi](#modi)) — dit is tevens de keepalive tegen de RC-timeout van de Solis (ingesteld op 2 minuten via 43282, dus 4× marge).
- **interval 5min** → config-registers (43029, 43110, 43140) gecontroleerd en alleen gecorrigeerd bij afwijking van de verwachte waarde; 43282 wordt elke cyclus **onvoorwaardelijk** herschreven (geen drift-check).
- **interval 15min** → `publish_grid_metrics`, zie [Grid Metrics](#grid-metrics--tumbling-window-15-min).
- **33213 (los FC04-request)** → elke 15 min (skip_updates 900), voedt `base_energy` — zie [Energieboekhouding](#energieboekhouding--capaciteit-baseremainingusabletarget_usable).
- **`battery_soc_hires`/`remaining_energy`/`usable_energy`/`target_usable_energy`** → elke 10s; **`base_energy`** → elke 60s + delta-filter (verandert vrijwel nooit).

---

## Grid Metrics — tumbling window (15 min)

De controller accumuleert elke seconde statistieken over `meter_power_raw` (1Hz intern) en publiceert ze elke 15 minuten als HA-sensoren. Zo hoeft de HA-recorder geen ruwe 1Hz-data op te slaan.

### Architectuur

```
meter_power_raw (1Hz, internal)
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
| `sensor.nexus_control_grid_metric_samples` | sensor (total) | — | Aantal samples in venster (~900 bij normaal bedrijf); HA som = totaal/uur |
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
