"""The OpenWrt MQTT integration."""
import logging
import re
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.typing import ConfigType
from homeassistant.components import mqtt
from .const import DOMAIN, DEFAULT_TOPIC_PREFIX, DISCOVERY_TOPICS, DEFAULT_TEMPERATURE_UNIT

_LOGGER = logging.getLogger(__name__)


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    """Set up the OpenWrt MQTT integration."""
    # Initialise le namespace du domaine. Chaque config entry gérera
    # son propre sous-dictionnaire sous hass.data[DOMAIN][entry.entry_id].
    hass.data.setdefault(DOMAIN, {})
    return True


async def async_setup_entry(hass: HomeAssistant, entry: ConfigType) -> bool:
    """Set up OpenWrt MQTT from a config entry."""

    # ---------------------------------------------------------------
    # FIX : données ISOLÉES par entry.entry_id.
    #
    # Avant : un seul dict global partagé entre toutes les entries,
    # ce qui causait des doublons quand deux intégrations coexistaient
    # (ex. "openwrt/+/" et "windows/+/") : add_entities_callback était
    # écrasé par la 2e entry, setup_entities était partagé, et les
    # devices/sensors d'une entry polluaient l'autre.
    # ---------------------------------------------------------------
    hass.data.setdefault(DOMAIN, {})
    hass.data[DOMAIN][entry.entry_id] = {
        "devices": {},
        "setup_entities": set(),
        "add_entities_callback": None,
        "entities_by_topic": {},
    }

    topic_prefix = entry.data.get("topic_prefix", DEFAULT_TOPIC_PREFIX)

    @callback
    def discover_devices(topic: str, payload: str, qos: int) -> None:
        """Handle MQTT discovery messages."""
        _LOGGER.debug("Discovered topic: %s, payload: %s", topic, payload)

        parts = topic.split("/")
        if len(parts) < 3:
            return

        hostname = parts[1]
        metric_type = "/".join(parts[2:])

        # Référence locale à l'espace de données de CETTE entry uniquement
        entry_data = hass.data[DOMAIN][entry.entry_id]

        # Initialize device if necessary
        if hostname not in entry_data["devices"]:
            entry_data["devices"][hostname] = {
                # L'identifiant inclut entry_id pour éviter les collisions
                # entre deux entries qui superviseraient les mêmes hostnames.
                "identifiers": {(DOMAIN, f"{entry.entry_id}_{hostname}")},
                "name": hostname,
                "manufacturer": "OpenWrt",
                "model": "Router",
                "sw_version": "Unknown",
                "entities": {},
            }
            _LOGGER.info(
                "Discovered new OpenWrt device: %s (entry: %s)", hostname, entry.entry_id
            )

        # Update device information if it's system info
        if metric_type == "system/model":
            entry_data["devices"][hostname]["model"] = payload
            _LOGGER.debug("Updated device model for %s: %s", hostname, payload)
        elif metric_type == "system/version":
            entry_data["devices"][hostname]["sw_version"] = payload
            _LOGGER.debug("Updated device version for %s: %s", hostname, payload)

        # Check if this topic matches a discovery topic
        should_create_entity = False
        for discovery_topic in DISCOVERY_TOPICS:
            pattern = discovery_topic.replace("+", "[^/]+")
            pattern = f"^{pattern}$"
            if re.match(pattern, metric_type):
                should_create_entity = True
                _LOGGER.debug(
                    "Topic %s matches discovery pattern %s", metric_type, discovery_topic
                )
                break

        if should_create_entity:
            # unique_ids incluent entry_id → garantit l'unicité globale
            unique_ids = generate_unique_ids_for_metric(
                entry.entry_id, hostname, metric_type
            )

            new_sensors_needed = any(
                uid not in entry_data["setup_entities"] for uid in unique_ids
            )

            if new_sensors_needed:
                base_unique_id = (
                    f"{entry.entry_id}_{hostname}_"
                    f"{metric_type.replace('/', '_').replace('-', '_')}"
                )
                entity_id = f"sensor.{base_unique_id}"

                entry_data["devices"][hostname]["entities"][base_unique_id] = {
                    "topic": topic,
                    "metric_type": metric_type,
                    "unique_id": base_unique_id,
                    "entity_id": entity_id,
                    "hostname": hostname,
                    "entry_id": entry.entry_id,
                    "temperature_unit": entry.data.get("temperature_unit", DEFAULT_TEMPERATURE_UNIT),
                }

                for uid in unique_ids:
                    entry_data["setup_entities"].add(uid)

                _LOGGER.info(
                    "Discovered new sensor(s) for topic %s (%d entities)",
                    topic,
                    len(unique_ids),
                )

                # If the add_entities callback is available, create entities immediately
                if entry_data["add_entities_callback"] is not None:
                    from homeassistant.helpers.device_registry import DeviceInfo
                    from .sensor import create_sensors_for_metric

                    device_info = entry_data["devices"][hostname]
                    device_info_obj = DeviceInfo(
                        identifiers=device_info["identifiers"],
                        name=device_info["name"],
                        manufacturer=device_info["manufacturer"],
                        model=device_info["model"],
                        sw_version=device_info["sw_version"],
                    )

                    data = entry_data["devices"][hostname]["entities"][base_unique_id]
                    new_sensors = create_sensors_for_metric(hass, data, device_info_obj)
                    entry_data["add_entities_callback"](new_sensors, True)
                    # Register entities for central MQTT updates
                    entry_data.setdefault("entities_by_topic", {}).setdefault(topic, []).extend(new_sensors)
                    _LOGGER.info(
                        "Added %d sensor(s) dynamically for %s",
                        len(new_sensors),
                        metric_type,
                    )

    async def mqtt_message_received(msg):
        """Handle new MQTT messages."""
        discover_devices(msg.topic, msg.payload, msg.qos)
        # Update existing entities for this topic
        entry_data = hass.data[DOMAIN][entry.entry_id]
        entities = entry_data.get("entities_by_topic", {}).get(msg.topic, [])
        for entity in entities:
            try:
                entity.handle_mqtt_message(msg.payload)
            except Exception as e:
                _LOGGER.error("Error updating entity for topic %s: %s", msg.topic, e)

    # Subscribe to MQTT topic for THIS entry only
    await mqtt.async_subscribe(hass, f"{topic_prefix}#", mqtt_message_received, qos=0)
    _LOGGER.info("Subscribed to MQTT topic: %s# (entry: %s)", topic_prefix, entry.entry_id)

    # Initial sensor configuration
    await hass.config_entries.async_forward_entry_setups(entry, ["sensor"])

    return True


def generate_unique_ids_for_metric(entry_id: str, hostname: str, metric_type: str) -> list:
    """Generate all unique_ids that will be created for a given metric type.

    Le entry_id est inclus dans chaque unique_id pour garantir l'unicité
    même si deux entries surveillent les mêmes hostnames.
    """
    prefix = f"{entry_id}_{hostname}"
    unique_ids = []

    # CPU Load: 3 sensors
    if metric_type == "cpu/load":
        for load_type in ["1min", "5min", "15min"]:
            unique_ids.append(f"{prefix}_cpu_load_{load_type}")

    # Network interfaces: 2 total + 2 rate sensors (RX and TX)
    elif metric_type.startswith("interface-") and metric_type.endswith(
        ("/if_octets", "/if_packets", "/if_errors", "/if_dropped")
    ):
        base_id = metric_type.replace("/", "_").replace("-", "_")
        for direction in ["rx", "tx"]:
            unique_ids.append(f"{prefix}_{base_id}_{direction}")
            unique_ids.append(f"{prefix}_{base_id}_{direction}_rate")

    # Others: 1 single sensor
    else:
        unique_ids.append(f"{prefix}_{metric_type.replace('/', '_').replace('-', '_')}")

    return unique_ids


async def async_unload_entry(hass: HomeAssistant, entry: ConfigType) -> bool:
    """Unload a config entry."""
    unload_ok = await hass.config_entries.async_forward_entry_unload(entry, "sensor")

    if unload_ok:
        # Supprime uniquement les données de CETTE entry, pas celles des autres.
        hass.data[DOMAIN].pop(entry.entry_id, None)
        _LOGGER.info("Unloaded entry %s", entry.entry_id)

    return unload_ok
