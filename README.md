# OpenWrt MQTT — Home Assistant Integration

[![Works with Home Assistant](https://img.shields.io/badge/Works%20with-Home%20Assistant-41BDF5?logo=homeassistant&logoColor=white)](https://www.home-assistant.io/)
[![hacs_badge](https://img.shields.io/badge/HACS-Custom-orange.svg?logo=homeassistantcommunitystore&logoColor=white)](https://hacs.xyz/docs/publishing/include)
[![Latest Version](https://img.shields.io/github/v/tag/aldweb/ha-openwrt-mqtt?label=Latest%20Version&logo=github&color=blue)](https://github.com/aldweb/ha-openwrt-mqtt/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

<img src="https://raw.githubusercontent.com/aldweb/ha-openwrt-mqtt/master/images/openwrt-one-router.png" align="left" width="300" style="margin-right: 20px; margin-bottom: 20px;">

A Home Assistant integration that pulls metrics from your devices via MQTT, with automatic sensor discovery.
<br clear="all" />

## How it works

Two components work together:

1. **A script on the device** collects metrics and publishes them to an MQTT broker
2. **The Home Assistant integration** auto-discovers sensors from incoming MQTT messages

> **Security note**: Home Assistant never connects directly to your devices. Communication is one-way: device → MQTT broker ← Home Assistant. No credentials are stored in HA, no ports need to be exposed.

## Supported devices

The project started with OpenWrt, but the scripting approach works with any device that can publish to MQTT. The devices below are **included examples** — contributions for other devices and use cases are very welcome (see [Contributing](#contributing)).

| Device | Script | Transport |
|---|---|---|
| OpenWrt ≤ 24.10 | `setup_metrics_owrt_24.10.sh` | Native MQTT or HTTP/HA |
| OpenWrt ≥ 25.12 | `setup_metrics_owrt_25.12.sh` | Native MQTT or HTTP/HA |
| Asus router (Asuswrt-Merlin) | `setup_metrics_asus.sh` | HTTP/HA |
| LG HomBot robot vacuum | `setup_metrics_lghombot.sh` | HTTP/HA |
| Windows machine | `WindowsMetrics.exe` + `WindowsMetrics.ini` | HTTP/HA |

## Collected metrics (OpenWrt)

- **System**: hostname, model, firmware version, uptime, architecture
- **CPU**: load (1/5/15 min), usage percentage, temperature
- **Memory**: free, used, cached
- **Disk**: total/used/free space, percentage (disk and tmpfs)
- **Network**: active connections, and per interface: bytes, packets, errors, drops (total + calculated throughput)

## Publishing methods

Two methods are available depending on your setup:

**`mqtt`** *(recommended)* — publishes directly to the broker via `mosquitto_pub`. Requires the broker to be reachable from the device.

**`http`** — publishes via the Home Assistant REST API, which relays to the MQTT broker. Useful when the broker is not directly accessible from the device.

## Installation

### 1. Device-side script

Connect to your device (SSH or equivalent), download the matching script, and set the variables at the top of the file:

```bash
# Example for OpenWrt
wget https://github.com/aldweb/ha-openwrt-mqtt/raw/refs/heads/main/devices_scripts/setup_metrics_owrt_24.10.sh -O /tmp/setup_metrics.sh
chmod +x /tmp/setup_metrics.sh
vi /tmp/setup_metrics.sh   # set MQTT_BROKER, MQTT_USER, MQTT_PASSWORD...
/tmp/setup_metrics.sh
```

The script installs required dependencies and adds a cron job (every 5 minutes by default).

To verify: run `publish_metrics.sh` manually and check that messages appear in your MQTT broker.

### 2. Home Assistant integration

**Via HACS (recommended)**

1. HACS → Integrations → ⋮ → Custom repositories
2. Add `https://github.com/aldweb/ha-openwrt-mqtt`, category *Integration*
3. Install *OpenWrt MQTT Auto-Discovery* and restart HA

**Manual install**

Copy the `custom_components/openwrt_mqtt/` folder into your `custom_components/` directory, then restart HA.

**Configuration**

Settings → Devices & services → + Add integration → *OpenWrt MQTT Auto-Discovery*

Set the MQTT topic prefix:
- `openwrt/+/` — all devices (wildcard)
- `openwrt/my-hostname/` — a specific device

Sensors are created automatically when the first messages arrive.

## MQTT topic structure

```
<prefix>/<hostname>/<type>/<metric>

Examples:
  openwrt/myrouter/cpu/load_percent
  openwrt/myrouter/memory/memory-free
  openwrt/myrouter/interface-eth0/if_octets
```

## Customization

**Publishing frequency**: edit the crontab on the device (`*/5 * * * *` by default).

**Adding a metric**: in the publish script, call `publish_metric "custom/my-metric" "value:123"`, then declare the topic in `const.py` of the HA integration.

## Troubleshooting

**No sensors in HA**: check MQTT messages with MQTT Explorer, then HA logs (Settings → System → Logs, filter `openwrt_mqtt`).

**Sensors showing "Unknown"**: wait for the next cycle (5 min), verify broker connectivity, and ensure the topic prefix matches on both sides.

**Script not running on OpenWrt**:
```bash
/etc/init.d/cron status && crontab -l && ls -l /usr/bin/publish_metrics.sh
```

## Requirements

- OpenWrt 19.07+ (or any device with a shell and `/proc` access)
- Home Assistant 2023.1+, MQTT integration configured
- MQTT broker (e.g. Mosquitto)

## Contributing

The included device scripts are just examples. If you've written a script for another device or use case — a NAS, a smart appliance, a different router firmware, a Windows or Linux machine — feel free to open a pull request or share it via an [issue](https://github.com/aldweb/ha-openwrt-mqtt/issues). Contributions are very welcome.

## License

MIT — Developed by @aldweb

