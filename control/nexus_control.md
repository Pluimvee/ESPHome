# Solis Battery Controller — ESPHome Implementatie Spec

## Doel

Een ESP32 die via Modbus RTU (RS-485) de Solis S6-EH3P hybrid omvormer aanstuurt als batterijcontroller. De gebruiker of Home Assistant stelt via ESPHome-entiteiten een mode en doelstellingen in. De ESP voert die autonoom uit met een eigen controlloop.

---

## Hardware & verbinding

- **Hardware**: ESP32 (esp32dev)
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

---

## Solis Modbus Registers

### Read registers (function code 0x04)

| Register | Type | Eenheid | Naam | Noot |
|---|---|---|---|---|
| 33122 | U16 | — | Operating Mode | Appendix 8 bitmask: BIT01=self-use, BIT07=RC (43135/43136), BIT08=passive. Eén bit tegelijk actief. |
| 33139 | U16 | 1% | Battery SOC | 0–100% |
| 33143 | U16 | — | Bridge register | Dummy, sluit gap zodat 33139–33152 één FC04-request is |
| 33147 | U16 | 1W | House load power | Totaal, altijd positief |
| 33151 | S32 | 1W | Inverter AC Grid Port Power | + = export, − = import (2 registers) |
| 33263 | S32 | 1W | Meter total active power | Na multiply:-1: + = import, − = export (2 registers) |

### Write registers (function code 0x06 tenzij anders)

| Register | Type | Eenheid | Naam | Waarde(n) |
|---|---|---|---|---|
| 43029 | U16 | — | CT direction | **1** = Reversed |
| 43110 | U16 | — | Storage control switch | **33** = Self-Use + Allow Grid Charge |
| 43129 | U16 | 10W | RC Force Discharge Power | Actief als 43135=2 |
| 43132 | U16 | — | RC Grid Adjustment ON/OFF | 0=OFF, **1=ON** (system grid point) |
| 43133 | S16 | 10W | RC Grid Active Power setpoint | Solis-conv: + = export, − = import |
| 43135 | U16 | — | RC Force Charge/Discharge | 0=OFF, **1=Force Charge**, **2=Force Discharge** |
| 43136 | U16 | 10W | RC Force Charge Power | Actief als 43135=1 |
| 43140 | U16 | — | Meter1 type & location | **0x0105** = Standard Eastron 3Ph, Grid |
| 43282 | U16 | 1min | RC Timeout | Geldig bereik 2–30; **schrijf 5** (5 minuten) |

> **Niet gebruiken**: register 43128 (RC Inverter AC Grid Port Power, S16) — schrijven van 0 stuurt de Solis actief naar grid=0W. Niet in de FC16 block opnemen.

### FC16 schrijfmatrix per modusfunctie

| Register | Beschrijving | Waarden | `set_hold()` | `set_charge(pwr)` | `set_discharge(pwr)` | `set_self_use()` | `set_level(pwr)` |
|---|---|---|---|---|---|---|---|
| 43129 | RC Force Battery Discharge Power | ×10W | n/a | n/a | **pwr** | n/a | n/a |
| 43130 | Battery Charge Limit Power | 0=invalid | 0 | 0 | **0** | 0 | 0 |
| 43131 | Battery Discharge Limit Power | 0=invalid | 0 | 0 | **0** | 0 | 0 |
| 43132 | RC Grid Adjustment | 0=uit, 1=aan | 0 | 0 | **0** | **0** | **1** |
| 43133 | RC Active Power on System Grid | +=export, −=import | n/a | n/a | **0** | **0** | **pwr** |
| 43134 | RC Reactive Power on System Grid | ×10W | n/a | n/a | **0** | **0** | n/a |
| 43135 | RC Force Battery Charge/Discharge | 0=uit, 1=charge, 2=discharge | **1** | **1** | **2** | **0** | 0 |
| 43136 | RC Force Battery Charge Power | ×10W | **0** | **pwr** | n/a | n/a | n/a |

Vetgedrukt = geschreven door die functie. `n/a` = niet geraakt. `0` (normaal) = register valt buiten het FC16-frame van die functie maar de gewenste waarde is 0.

FC16-frames per functie:
- `set_hold()`: schrijft 43135..43136 (2 registers)
- `set_charge(pwr)`: schrijft 43135..43136 (2 registers)
- `set_discharge(pwr)`: schrijft 43129..43135 (7 registers)
- `set_self_use()`: schrijft 43132..43135 (4 registers)
- `set_level(pwr)`: schrijft 43132..43133 (2 registers)

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
| `select.control_mode` | select | Mode: hold / level / charge / discharge |
| `number.target_grid_power` | number | Doelvermogen in W (huis-conv); floor bij charge, plafond bij discharge |
| `number.target_soc` | number | SOC-aggressiviteitsknop (−100…200%); zie uitleg onder PI-regelaar |
| `sensor.battery_soc` | sensor | SOC % |
| `sensor.grid_power` | sensor | Netmeter W (huis-conv: + = import) |
| `sensor.inverter_power` | sensor | AC grid port W (Solis-conv: + = export) |
| `sensor.house_load` | sensor | Huislast W |
| `binary_sensor.fault` | binary | Fout actief |
| `binary_sensor.grid_meter_connected` | binary | Meter levert data |
| `text_sensor.inverter_status` | text | Actieve Solis-mode of foutmelding |
| `text_sensor.grid_status` | text | import / export / level |

---

## Modi

### hold
FC16 schrijft `43135=1` (Force Charge) + `43136=0` (0W) in één frame. Batterij-SOC wordt bevroren. Geen regelloop.

### level
FC16 schrijft `43132..43135` in één frame: `[grid_adj, setpoint, 0, 0]`. Solis regelt zelf op het setpoint.

- `target_grid ≠ 0`: `grid_adj=1`, `setpoint = -(target_grid_w / 10)` (huis → Solis conventie)
- `target_grid = 0`: `grid_adj=0`, `setpoint=0` — RC Grid Adjustment uit, Solis valt terug op self-use

Het abrupt uitschakelen van RC via `43135=0` (als losse FC06) kan de Solis destabiliseren. De FC16 schrijft 43135 altijd als onderdeel van hetzelfde frame.

### charge
Force Charge met PI-regelaar. Doel: grid op of boven `target_grid_w` houden (floor, anti-export).
- `43135=1` geschreven op `dirty` (mode wissel of 60s keepalive)
- `43136` geschreven als de 10W-stap verandert

### discharge
Force Discharge met PI-regelaar. Doel: grid op of onder `target_grid_w` houden (plafond, peak shaving).
- `43135=2` geschreven op `dirty`
- `43129` geschreven als de 10W-stap verandert

---

## Schrijftiming & Modbus protocol

`command_throttle: 750ms` op de modbus_controller zorgt voor minimaal 750ms tussen frames op de bus, ongeacht de diepte van de queue. De controlloop (interval: 2s) en de config-check (elke 5 min) mogen meerdere writes in één cyclus queuen — de throttle handelt de timing af.

- **`dirty` flag** triggert een mode-write; wordt gezet door:
  - Mode wissel (`on_value` select)
  - Target grid wijziging (`on_value` number)
  - 60s interval (keepalive)
- **Power register** (43136 / 43129): geschreven als de 10W-stap verandert, onafhankelijk van `dirty`
- **Config block** (43029, 43110, 43140, 43282): elke 5 minuten, alleen schrijven bij afwijking van verwachte waarde

---

## PI-regelaar

### Charge mode (floor)
```
meter_w = sensor_33263  # huis-conv: + = import

if meter_w < target_grid_w:                         # onder de floor (te veel export)
    cpw += (target_grid_w - meter_w) * 0.5          # agressief omhoog
elif meter_w > target_grid_w + 100:                 # ruim boven floor
    cpw -= (meter_w - (target_grid_w + 100)) * 0.1  # gedempt omlaag

cpw = clamp(cpw, max(0, soc_floor_w), 10000)
write_register(43136, int(cpw / 10))
```

### Discharge mode (plafond)
```
if meter_w > target_grid_w:                          # boven het plafond (te veel import)
    dpw += (meter_w - target_grid_w) * 0.5           # agressief omhoog
elif meter_w < target_grid_w - 100:                  # ruim onder plafond
    dpw -= ((target_grid_w - 100) - meter_w) * 0.1   # gedempt omlaag

dpw = clamp(dpw, max(0, soc_floor_w), 10000)
write_register(43129, int(dpw / 10))
```

| Parameter | Waarde | Toelichting |
|---|---|---|
| GAIN_AGGRESSIVE | 0.5 | 50% van afwijking per stap |
| GAIN_RELAXED | 0.1 | 10% van afwijking per stap |
| DEAD_ZONE | 100W | Dode zone aan de rustige kant |
| MIN_W | 0W | Minimaal vermogen |
| MAX_W | 10000W | Maximaal vermogen |

### target_soc als ondergrens op laad-/ontlaadpower

In charge en discharge wordt een SOC-gedreven minimumvermogen berekend:

```
# Charge: alleen actief als soc < target_soc
soc_floor_w = (target_soc - soc) * 200W   # 200W per % = 20kWh / 1h

# Discharge: alleen actief als soc > target_soc
soc_floor_w = (soc - target_soc) * 200W

cpw / dpw = clamp(pi_result, max(0, soc_floor_w), MAX_W)
```

De effectieve power is dus `max(power_obv_grid, power_obv_soc)` — de strengste van beide ondergrenzen wint.

#### Moving window van 1 uur — en waarom target_soc buiten 0–100% mag

De 200W per % is afgeleid van `20kWh / 1h` — de formule gaat ervan uit dat het doel over **1 uur** wordt behaald. Wil de EMS een kortere horizon, dan moet `target_soc` worden opgehoogd (charge) of verlaagd (discharge) voorbij de werkelijke batterijgrenzen:

```
adjusted_target_soc = (60 / horizon_min) * (desired_soc - current_soc) + current_soc
```

Voorbeeld charge, horizon=30 min, current=50%, desired=70%:
```
adjusted_target_soc = (60/30) * (70-50) + 50 = 90%   → boven 70%, maar < 100%
soc_floor_w = (90-50) * 200 = 8000W
In 30 min: 8000W * 0.5h = 4kWh = 20% SOC ✓
```

Voorbeeld charge, horizon=15 min, current=80%, desired=95%:
```
adjusted_target_soc = (60/15) * (95-80) + 80 = 140%  → boven 100%
soc_floor_w = (140-80) * 200 = 12000W → geclamped op MAX_W = 10000W
```

Voorbeeld discharge, horizon=30 min, current=40%, desired=10%:
```
adjusted_target_soc = (60/30) * (10-40) + 40 = -20%  → onder 0%
soc_floor_w = (40-(-20)) * 200 = 12000W → geclamped op MAX_W = 10000W
```

**Waarom −100 tot 200 als range?**

`target_soc` is hier geen echte SOC-waarde maar een **aggressiviteitsknop** voor het laad- of ontlaadvermogen. De EMS stelt de adjusted waarde in en de code berekent `soc_floor_w = gap * 200W`. Waarden buiten [−100, 200] hebben geen extra effect — de clamp vangt alles op.

**Vuistregel voor de EMS:**

| Gebruik | Instelling |
|---|---|
| Vangnet, geen tijdsdruk | `target_soc = desired_soc` (1-uurs horizon) |
| Doel binnen 30 min halen | `adjusted = (60/30) * gap + current_soc` |
| Max agressief (zo snel mogelijk) | `target_soc = 200` (charge) of `−100` (discharge) |

#### Zachte landing

Naarmate de SOC de `target_soc` nadert, daalt `soc_floor_w` asymptotisch naar 0. De laatste procenten worden met steeds minder geforceerd vermogen geladen/ontladen.

- **Conservatief instellen** (bijv. `target_soc = 80%` terwijl 75% volstaat): werkt als vangnet, doel bijna zeker gehaald.
- **Agressief instellen** (bijv. `target_soc = 95%`): zet `target_soc` hoger dan het werkelijke doel als zekerheid gewenst is.

#### Relatie tussen target_grid en target_soc

| Situatie | Dominant |
|---|---|
| PV valt mee, grid daalt richting floor | `target_grid` → PI drijft cpw omhoog |
| PV valt tegen, grid al boven floor | `target_soc` → soc_floor voorkomt dat cpw te ver daalt |
| Beide actief | max van beide — ze spreken elkaar nooit tegen |

#### Typisch gebruik: export voorkomen + SOC garanderen bij lage SPOT-prijs

```
mode:        charge
target_grid: 0W       # floor op 0: geen export, grid mag positief worden
target_soc:  80%      # garandeert SOC-doel ook als er geen PV surplus is
```

Met `target_grid = 0` laadt de batterij alleen als er surplus PV is. `target_soc` garandeert dat de batterij alsnog wordt volgeladen als het PV tegenvalt.

---

## Periodieke configuratie (elke 5 minuten)

Alle vier registers worden alleen geschreven bij afwijking van de verwachte waarde (inclusief 43282 — de waarde wordt gelezen via `skip_updates: 3600` en pas geschreven als die afwijkt):

1. **43029** = `1` — CT Reversed
2. **43110** = `33` — Self-Use + Allow Grid Charge
3. **43140** = `0x0105` — Meter type Eastron 3Ph Grid
4. **43282** = `5` — RC Timeout 5 minuten

---

## Validatie & foutafhandeling

Bij validatiefouten: schakel over naar **hold mode** (FC16: `43135=1` + `43136=0`), publiceer fout naar HA. Hold bevriest de batterij-SOC — voorspelbaarder dan RC uit (waarbij de Solis autonoom beslist). `write_hold()` wordt alleen bij het **betreden** van de fout geschreven, niet elke cyclus (om de Modbus-queue niet verder te belasten).

| Scenario | Detectie | Foutmelding |
|---|---|---|
| Meter geen data | `meter_power` heeft geen state | `Grid meter modbus connection failure` |
| Meter verouderd | Laatste update > 10s geleden | `Grid meter data timeout` |
| SOC onbetrouwbaar | SOC < 0.5% | `SOC unavailable` |

Bij clearing van fout: hervat actieve mode automatisch.

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
| `sensor.nexus_control_grid_metric_min` | sensor | W | Minimum gridvermogen in venster |
| `sensor.nexus_control_grid_metric_max` | sensor | W | Maximum gridvermogen in venster |
| `sensor.nexus_control_grid_metric_mean` | sensor | W | Rekenkundig gemiddelde |
| `sensor.nexus_control_grid_metric_median` | sensor | W | Mediaan (gesorteerde buffer op publish-moment) |
| `sensor.nexus_control_grid_metric_samples` | sensor (total) | — | Aantal samples in venster (~900 bij normaal bedrijf); HA som = totaal/uur |
| `sensor.nexus_control_grid_metric_crossings` | sensor (total) | — | Zero-crossings (import↔export) in venster; HA som = totaal/uur |
| `sensor.nexus_control_grid_metric_histogram` | text | JSON | Verdeling over 9 vermogensbuckets |

Alle numerieke sensoren hebben `state_class: measurement` → HA berekent automatisch uur/dag-statistieken (min/mean/max) via de recorder.

### Histogram

Negen buckets, grenzen in W:

| Bucket-sleutel | Bereik |
|---|---|
| `lt-1000` | < −1000 W |
| `-1000:-500` | −1000 … −500 W |
| `-500:-300` | −500 … −300 W |
| `-300:-100` | −300 … −100 W |
| `-100:100` | −100 … +100 W (near-zero zone) |
| `100:300` | +100 … +300 W |
| `300:500` | +300 … +500 W |
| `500:1000` | +500 … +1000 W |
| `gt1000` | > +1000 W |

Voorbeeld JSON-output:
```json
{"lt-1000":0,"-1000:-500":0,"-500:-300":0,"-300:-100":2,"-100:100":870,"100:300":25,"300:500":3,"500:1000":0,"gt1000":0}
```

### Zero-crossings

Detectie via drie zones met ±20W dode band:

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
- **`histogram`** → diagnose van amplitude; near-zero bucket (`-100:100`) idealiter > 95%
- **`min` / `max`** → detectie van uitschieters (compressorstarts, PV-wisselingen)

De `sensor.nexus_control_grid_power` entiteit (5s) blijft beschikbaar voor real-time dashboard en AppDaemon-polling.

---

## Niet geïmplementeerd (bewuste keuze)

- **HA watchdog**: nog niet geïmplementeerd; gepland als fallback naar hold bij uitblijven HA update
- **Register 43128**: bewust overgeslagen — schrijven van 0 stuurt grid naar 0W
- **Peak Shaving mode** (43110 BIT11): niet bruikbaar voor discharge-met-export
