# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

ESPHome YAML device configurations for an EcoGrid home energy management system. Each `.yaml` file is a standalone firmware definition for one physical IoT device, compiled and flashed via the ESPHome toolchain.

## Common commands

```bash
# Compile firmware for a device
esphome compile <device>.yaml

# Compile and flash over-the-air (or via USB on first flash)
esphome run <device>.yaml

# Flash without recompiling
esphome upload <device>.yaml

# Stream logs from a running device
esphome logs <device>.yaml

# Validate YAML syntax
esphome config <device>.yaml

# Launch the ESPHome web dashboard
esphome dashboard .
```

Build artifacts land in `C:/Users/erikv/.esphome/<device_id>/` (the `build_root` secret).

## Repository structure

Every top-level `.yaml` is one device. `template.yaml` is a reference showing all available config blocks. `secrets.yaml` holds shared credentials (WiFi, API key, OTA password).

The devices fall into five groups that together form a whole-home energy management system:

| Group | Files | Purpose |
|---|---|---|
| Grid metering | `p1-reader.yaml`, `p1-sdm630.yaml`, `peak-shaver.yaml` | Read Dutch smart meter (DSMR P1) and SDM630 energy meter |
| Solar | `omnik.yaml` | Bridge between Omnik inverter WiFi module and Home Assistant |
| Battery control | `peak-shaver.yaml` | Controls Solis battery inverter via Modbus to shave import peaks |
| Appliance meters | `energy-wpboiler.yaml`, `energy-heatpump.yaml`, `energy-quooker.yaml`, `energy-dishwasher.yaml`, `energy-steamoven.yaml`, `energy-microwave.yaml` | Per-appliance energy monitoring (SONOFF with HLW8012/BL0937 chip) |
| Climate | `thermostat.yaml`, `esp32-2432S024.yaml`, `resideo-*.yaml`, `kamstrup-wp.yaml`, `floor-temp.yaml`, `outside-temp.yaml`, `climate-sensor.yaml`, `aqua-heatpump.yaml`, `intergas-boiler.yaml` | Heating system with OpenTherm control, room sensors, heat meter, pump control |
| Utilities | `water-meter.yaml`, `ev-charger.yaml`, `modbus-bridge.yaml`, `switch-evcharger.yaml` | Water metering, EV charger relay, generic Modbus TCP-RTU bridge |

## Custom external components

All components are authored under the `Pluimvee` GitHub account:

| Component | Source | Provides |
|---|---|---|
| `esphome-dsmr` | `github://Pluimvee/esphome-dsmr` | `p1_dsmr` — DSMR P1 OBIS parser |
| `esphome-omnik` | local path or `github://Pluimvee/esphome-omnik` | `omnik_bridge` — Omnik inverter WiFi bridge |
| `esphome-modbus-tcp-to-rtu` | local path | `modbus_bridge` — ModBus TCP-to-RTU gateway |
| `esphome-heating-control` | local path | `thermo_control` — custom weather-compensated heating curve controller |
| `esphome-resideo` | `github://Pluimvee/esphome-resideo` | `cht8305_sniffer`, `cm1106_sniffer` — sniff I²C bus of Resideo thermostat for temp/humidity/CO₂ |
| `esphome-kamstrup` | local path | `kamstrup` — Kamstrup Multical 430 heat meter via optical UART |

Local component paths are absolute Windows paths (`C:/Users/erikv/...`). When referencing GitHub sources, `refresh: never` or `refresh: 1min` controls caching.

## Patterns common to all devices

**Substitutions block** — every device starts with at least `device_id` and `build_root`:
```yaml
substitutions:
  device_id: my-device
  build_root: !secret build_root
```

**WiFi + fallback** — all devices connect to `ESEY-IoT` (IoT VLAN), always include a fallback AP and `captive_portal`.

**Shared secrets** — a single `api_key`, `ota_password`, `wifi_ssid`, `wifi_password`, and `wifi_ap_password` apply to every device.

**UART logging conflict** — when a device uses UART0 for a protocol (P1, Modbus, Kamstrup), always set `logger.baud_rate: 0` to release the hardware serial port.

**Energy counter pattern** — devices that track cumulative energy use a global with `restore_value: true` + `flash_write_interval: 15min` (to limit flash wear), and reset a `_today` counter at midnight via a 60-second interval lambda.

**Midnight reset** — all devices with daily-reset sensors detect day change by comparing `time.day_of_year` in a 60 s interval lambda, not by a cron trigger.

**NaN guard in lambdas** — all template sensors check `isnan()` / `!isfinite()` before arithmetic and return `NAN` rather than a bogus value.

**`update_interval: never`** — used on displays that are refreshed only on data change via `component.update:` actions; avoids unnecessary full redraws.

## Hardware boards in use

| Board | Framework | Used in |
|---|---|---|
| ESP8266 esp01_1m | Arduino | most sensors, modbus-bridge, ev-charger, omnik |
| ESP8266 esp12e | Arduino | p1-reader |
| ESP8266 esp8285 | Arduino | energy meters (SONOFF) |
| ESP32 esp32dev | Arduino | thermostat |
| ESP32 esp32dev | esp-idf | peak-shaver, esp32-2432S024 (thermostat UI) |
| ESP32-C3 esp32-c3-devkitm-1 | esp-idf | kamstrup-wp |

## Device-specific notes

- **`nexo.yaml`** — touchscreen front-end named "Nexo". Actual board is Sunton 3248S035R (ILI9488 480×320 + XPT2046 touch). Uses LVGL for a multi-page touchscreen UI (Lights / Climate / Energy / Settings). The display and touch share HSPI (`spi_main`). RGB LED is common-anode (active-low), hence `inverted: true` on each LEDC channel. Device hostname: `nexo.local`.

- **`thermostat.yaml`** — custom `thermo_control` component implements a weather-compensated heating curve with three configurable factors (A/B/C). The ST7735 display uses a static-cache render pattern to only redraw changed fields.

- **`kamstrup-wp.yaml`** — controls a Wilo pump via PWM (GPIO10). PWM duty maps inversely: 0% pump speed → 60% duty, 100% → 10% duty. Includes defrost and power-on grace periods in the flow-control script.

- **`peak-shaver.yaml`** — reads grid power from P1 DSMR and battery/SOC from Solis inverter via Modbus, then writes battery power target to Modbus register 43128 every 5 s to keep grid import near a configurable target.

- **`omnik.yaml`** — accumulates lifetime energy from daily-resetting inverter value using a `globals` float with `restore_value: true`. Sanity guard: ignores deltas > 25 kWh. Minimum total clamped to 22790 kWh (historical baseline from before HA integration).
