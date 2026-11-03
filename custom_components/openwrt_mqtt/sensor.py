"""Sensor platform for OpenWrt MQTT integration."""
import logging
import re
from datetime import datetime, timedelta
from homeassistant.components.sensor import SensorEntity, SensorDeviceClass, SensorStateClass
from homeassistant.const import UnitOfInformation, UnitOfDataRate, UnitOfTemperature
from homeassistant.core import callback
from homeassistant.helpers.device_registry import DeviceInfo
from .const import DOMAIN, DEFAULT_TEMPERATURE_UNIT

_LOGGER = logging.getLogger(__name__)

async def async_setup_entry(hass, entry, async_add_entities):
    """Set up the OpenWrt MQTT sensors."""

    if DOMAIN not in hass.data or entry.entry_id not in hass.data[DOMAIN]:
        return False

    # FIX : stocke le callback dans l'espace de données isolé de CETTE entry.
    # Avant, un dict global unique causait l'écrasement du callback par la
    # dernière entry chargée, ce qui provoquait des doublons.
    entry_data = hass.data[DOMAIN][entry.entry_id]
    entry_data["add_entities_callback"] = async_add_entities

    sensors = []

    # Create sensors for already discovered entities (this entry only)
    for hostname, device_info in entry_data["devices"].items():
        if "entities" in device_info:
            for unique_id, data in device_info["entities"].items():
                if unique_id in entry_data["setup_entities"]:
                    device_info_obj = DeviceInfo(
                        identifiers=device_info["identifiers"],
                        name=device_info["name"],
                        manufacturer=device_info["manufacturer"],
                        model=device_info["model"],
                        sw_version=device_info["sw_version"],
                    )

                    new_sensors = create_sensors_for_metric(hass, data, device_info_obj)
                    sensors.extend(new_sensors)

    if sensors:
        async_add_entities(sensors, True)
        _LOGGER.info("Created %d OpenWrt MQTT sensors at startup", len(sensors))
    else:
        _LOGGER.info(
            "No sensors to create at startup - will be added dynamically as MQTT messages arrive"
        )

def create_sensors_for_metric(hass, data, device_info):
    """Create one or more sensors based on the metric type."""
    sensors = []
    metric_type = data["metric_type"]
    
    # CPU Load: create 3 separate sensors
    if metric_type == "cpu/load":
        for load_type in ["1min", "5min", "15min"]:
            sensor_data = data.copy()
            sensor_data["load_type"] = load_type
            sensors.append(OpenWrtMQTTSensor(hass, sensor_data, device_info))
    
    # Network interfaces: create 2 total sensors + 2 rate sensors (RX and TX)
    elif metric_type.startswith("interface-") and metric_type.endswith(("/if_octets", "/if_packets", "/if_errors", "/if_dropped")):
        for direction in ["rx", "tx"]:
            # Total sensor (cumulative counter)
            sensor_data = data.copy()
            sensor_data["direction"] = direction
            sensor_data["sensor_type"] = "total"
            sensors.append(OpenWrtMQTTSensor(hass, sensor_data, device_info))
            
            # Rate sensor (automatically calculated rate)
            rate_data = data.copy()
            rate_data["direction"] = direction
            rate_data["sensor_type"] = "rate"
            sensors.append(OpenWrtMQTTRateSensor(hass, rate_data, device_info))
    
    # Other sensors: 1 single sensor
    else:
        sensors.append(OpenWrtMQTTSensor(hass, data, device_info))
    
    return sensors

class OpenWrtMQTTBaseSensor(SensorEntity):
    """Base class: registers the entity for the entry's central MQTT dispatcher.

    The entity is registered only once it is actually added to Home Assistant
    (so it always has an entity_id/hass when a message is dispatched) and is
    unregistered automatically when it is removed.
    """

    async def async_added_to_hass(self):
        """Register for MQTT updates dispatched by __init__.py."""
        await super().async_added_to_hass()
        entry_data = self.hass.data[DOMAIN][self._data["entry_id"]]
        entities = entry_data["entities_by_topic"].setdefault(self._data["topic"], [])
        entities.append(self)

        @callback
        def _unregister():
            if self in entities:
                entities.remove(self)

        self.async_on_remove(_unregister)

    @callback
    def handle_mqtt_message(self, payload):
        """Handle a payload published on this entity's topic."""
        raise NotImplementedError


class OpenWrtMQTTSensor(OpenWrtMQTTBaseSensor):
    """Representation of an OpenWrt MQTT sensor."""

    def __init__(self, hass, data, device_info):
        """Initialize the sensor."""
        self.hass = hass
        self._data = data
        self._device_info = device_info
        self._state = None
        self._extra_attributes = {}
        
        metric_type = data["metric_type"]
        hostname = data.get("hostname", "unknown")
        entry_id = data.get("entry_id", "")
        # Préfixe incluant entry_id pour garantir l'unicité entre deux config entries
        prefix = f"{entry_id}_{hostname}" if entry_id else hostname

        # Generate unique_id based on type
        if "load_type" in data:
            # CPU Load: unique_id includes the type (1min, 5min, 15min)
            self._attr_unique_id = f"{prefix}_cpu_load_{data['load_type']}"
        elif "direction" in data:
            # Interface: unique_id includes direction (rx or tx) and type (total or rate)
            base_id = metric_type.replace('/', '_').replace('-', '_')
            sensor_type = data.get("sensor_type", "total")
            if sensor_type == "rate":
                self._attr_unique_id = f"{prefix}_{base_id}_{data['direction']}_rate"
            else:
                self._attr_unique_id = f"{prefix}_{base_id}_{data['direction']}"
        else:
            # Others: standard unique_id
            self._attr_unique_id = f"{prefix}_{metric_type.replace('/', '_').replace('-', '_')}"
        
        # Sensor name (prefixed with hostname)
        self._attr_name = self._generate_name(hostname, metric_type)
        
        # Configure units and device class
        self._configure_sensor_properties(metric_type)

    def _generate_name(self, hostname, metric_type):
        """Generate a friendly name from metric type, prefixed with hostname."""
        parts = metric_type.split('/')
        
        # CPU Load: specific names
        if metric_type == "cpu/load":
            if "load_type" in self._data:
                load_type = self._data["load_type"]
                if load_type == "1min":
                    return f"{hostname} CPU Load 1min"
                elif load_type == "5min":
                    return f"{hostname} CPU Load 5min"
                elif load_type == "15min":
                    return f"{hostname} CPU Load 15min"
        
        # CPU load percentage
        elif metric_type == "cpu/load_percent":
            return f"{hostname} CPU Load %"
        
        # CPU temperature
        elif metric_type == "cpu/temperature":
            return f"{hostname} CPU Temperature"
        
        # Disk space
        elif metric_type.startswith("disk/"):
            disk_type = parts[1]
            if disk_type == "total":
                return f"{hostname} Disk Total"
            elif disk_type == "used":
                return f"{hostname} Disk Used"
            elif disk_type == "free":
                return f"{hostname} Disk Free"
            elif disk_type == "percent":
                return f"{hostname} Disk Usage"
        
        # Temp disk space (tmpfs)
        elif metric_type.startswith("disk_tmp/"):
            disk_type = parts[1]
            if disk_type == "total":
                return f"{hostname} Temp Disk Total"
            elif disk_type == "used":
                return f"{hostname} Temp Disk Used"
            elif disk_type == "free":
                return f"{hostname} Temp Disk Free"
            elif disk_type == "percent":
                return f"{hostname} Temp Disk Usage"
        
        # Connection tracking
        elif metric_type == "conntrack/total":
            return f"{hostname} Active Connections"
        
        # Network interfaces
        if metric_type.startswith("interface-"):
            interface = parts[0].replace("interface-", "")
            metric = parts[1] if len(parts) > 1 else ""
            direction = self._data.get("direction", "").upper()
            sensor_type = self._data.get("sensor_type", "total")
            
            if metric == "if_octets":
                if sensor_type == "rate":
                    return f"{hostname} {interface} {direction} Rate"
                else:
                    return f"{hostname} {interface} {direction}"
            elif metric == "if_packets":
                if sensor_type == "rate":
                    return f"{hostname} {interface} Packets {direction} Rate"
                else:
                    return f"{hostname} {interface} Packets {direction}"
            elif metric == "if_errors":
                if sensor_type == "rate":
                    return f"{hostname} {interface} Errors {direction} Rate"
                else:
                    return f"{hostname} {interface} Errors {direction}"
            elif metric == "if_dropped":
                if sensor_type == "rate":
                    return f"{hostname} {interface} Dropped {direction} Rate"
                else:
                    return f"{hostname} {interface} Dropped {direction}"
        
        # Memory
        elif metric_type.startswith("memory/"):
            mem_type = parts[1].replace("memory-", "")
            if mem_type == "usage-percent":
                return f"{hostname} Memory Usage"
            else:
                return f"{hostname} Memory {mem_type.title()}"
        
        # System
        elif metric_type.startswith("system/"):
            sys_type = parts[1]
            return f"{hostname} {sys_type.replace('_', ' ').title()}"
        
        # Default
        return f"{hostname} {metric_type.replace('/', ' ').replace('-', ' ').title()}"

    def _configure_sensor_properties(self, metric_type):
        """Configure sensor properties based on metric type."""
        # Default values
        self._attr_native_unit_of_measurement = None
        self._attr_device_class = None
        self._attr_state_class = None
        self._attr_suggested_display_precision = None
        self._attr_icon = None
        
        # CPU Load
        if metric_type == "cpu/load":
            self._attr_icon = "mdi:gauge"
            self._attr_state_class = SensorStateClass.MEASUREMENT
            self._attr_suggested_display_precision = 2
        
        # CPU load percentage
        elif metric_type == "cpu/load_percent":
            self._attr_native_unit_of_measurement = "%"
            self._attr_icon = "mdi:chip"
            self._attr_state_class = SensorStateClass.MEASUREMENT
            self._attr_suggested_display_precision = 0
        
        # CPU temperature
        elif metric_type == "cpu/temperature":
            temp_unit = self._data.get("temperature_unit", DEFAULT_TEMPERATURE_UNIT)
            self._attr_native_unit_of_measurement = (
                UnitOfTemperature.CELSIUS if temp_unit == "°C" else UnitOfTemperature.FAHRENHEIT
            )
            self._attr_device_class = SensorDeviceClass.TEMPERATURE
            self._attr_state_class = SensorStateClass.MEASUREMENT
            self._attr_suggested_display_precision = 1
            self._attr_icon = "mdi:thermometer"
        
        # Memory in MB (converted from KiB) or percentage
        elif "memory" in metric_type:
            if "percent" in metric_type:
                self._attr_native_unit_of_measurement = "%"
                self._attr_state_class = SensorStateClass.MEASUREMENT
                self._attr_icon = "mdi:memory"
            else:
                self._attr_native_unit_of_measurement = UnitOfInformation.MEGABYTES
                self._attr_device_class = SensorDeviceClass.DATA_SIZE
                self._attr_state_class = SensorStateClass.MEASUREMENT
                self._attr_icon = "mdi:memory"
        
        # Disk space in MB (converted from KiB)
        elif metric_type.startswith("disk/") or metric_type.startswith("disk_tmp/"):
            if "percent" in metric_type:
                self._attr_native_unit_of_measurement = "%"
                self._attr_state_class = SensorStateClass.MEASUREMENT
                if "tmp" in metric_type:
                    self._attr_icon = "mdi:folder-clock"
                else:
                    self._attr_icon = "mdi:harddisk"
            else:
                self._attr_native_unit_of_measurement = UnitOfInformation.MEGABYTES
                self._attr_device_class = SensorDeviceClass.DATA_SIZE
                self._attr_state_class = SensorStateClass.MEASUREMENT
                if "tmp" in metric_type:
                    self._attr_icon = "mdi:folder-clock"
                else:
                    self._attr_icon = "mdi:harddisk"
        
        # Connection tracking
        elif metric_type == "conntrack/total":
            self._attr_icon = "mdi:connection"
            self._attr_state_class = SensorStateClass.MEASUREMENT
        
        # Network bytes
        elif "if_octets" in metric_type:
            sensor_type = self._data.get("sensor_type", "total")
            if sensor_type == "total":
                self._attr_native_unit_of_measurement = UnitOfInformation.BYTES
                self._attr_device_class = SensorDeviceClass.DATA_SIZE
                self._attr_state_class = SensorStateClass.TOTAL_INCREASING
            
            direction = self._data.get("direction", "rx")
            if direction == "tx":
                self._attr_icon = "mdi:upload-network"
            else:
                self._attr_icon = "mdi:download-network"
        
        # Network packets
        elif "if_packets" in metric_type:
            sensor_type = self._data.get("sensor_type", "total")
            if sensor_type == "total":
                self._attr_state_class = SensorStateClass.TOTAL_INCREASING
            self._attr_icon = "mdi:lan-connect"
        
        # Network errors
        elif "if_errors" in metric_type:
            sensor_type = self._data.get("sensor_type", "total")
            if sensor_type == "total":
                self._attr_state_class = SensorStateClass.TOTAL_INCREASING
            self._attr_icon = "mdi:lan-disconnect"
        
        # Dropped packets
        elif "if_dropped" in metric_type:
            sensor_type = self._data.get("sensor_type", "total")
            if sensor_type == "total":
                self._attr_state_class = SensorStateClass.TOTAL_INCREASING
            self._attr_icon = "mdi:lan-pending"
        
        # Uptime
        elif "uptime" in metric_type:
            self._attr_native_unit_of_measurement = "s"
            self._attr_device_class = SensorDeviceClass.DURATION
            self._attr_icon = "mdi:clock-outline"

    @property
    def device_info(self):
        """Return the device info."""
        return self._device_info

    def _parse_payload(self, payload):
        """Parse MQTT payload based on metric type."""
        metric_type = self._data["metric_type"]
        
        try:
            # CPU Load: format is "load:1.23,4.56,7.89"
            if metric_type == "cpu/load":
                match = re.search(r'load:([\d.]+),([\d.]+),([\d.]+)', payload)
                if match:
                    load_1min = float(match.group(1))
                    load_5min = float(match.group(2))
                    load_15min = float(match.group(3))
                    
                    # Return the value corresponding to the load type
                    load_type = self._data.get("load_type", "1min")
                    if load_type == "1min":
                        return load_1min
                    elif load_type == "5min":
                        return load_5min
                    elif load_type == "15min":
                        return load_15min
            
            # CPU, Memory, Disk, Conntrack: format is "value:12345"
            elif metric_type == "cpu/load_percent" or metric_type == "conntrack/total":
                match = re.search(r'value:([\d]+)', payload)
                if match:
                    return int(match.group(1))
            
            # CPU temperature: format is "value:59"
            elif metric_type == "cpu/temperature":
                match = re.search(r'value:([\d.]+)', payload)
                if match:
                    return round(float(match.group(1)), 1)
            
            # Memory: format is "value:12345" (convert KiB to MiB, or keep percentage as is)
            elif "memory" in metric_type:
                match = re.search(r'value:([\d]+)', payload)
                if match:
                    value = int(match.group(1))
                    # If it's a percentage, return as is
                    if "percent" in metric_type:
                        return value
                    # Otherwise convert KiB to MiB
                    else:
                        value_mb = value / 1024
                        return round(value_mb, 2)
            
            # Disk and Disk_tmp: format is "value:12345"
            elif metric_type.startswith("disk/") or metric_type.startswith("disk_tmp/"):
                match = re.search(r'value:([\d]+)', payload)
                if match:
                    value = int(match.group(1))
                    # If it's a percentage, return as is
                    if "percent" in metric_type:
                        return value
                    # Otherwise convert KiB to MiB
                    else:
                        value_mb = value / 1024
                        return round(value_mb, 2)
            
            # Network interfaces: format is "rx:123456,tx:789012"
            elif metric_type.startswith("interface-"):
                match = re.search(r'rx:([\d]+),tx:([\d]+)', payload)
                if match:
                    rx_value = int(match.group(1))
                    tx_value = int(match.group(2))
                    
                    # Return the value corresponding to the direction
                    direction = self._data.get("direction", "rx")
                    if direction == "rx":
                        return rx_value
                    elif direction == "tx":
                        return tx_value
            
            # System information
            elif metric_type.startswith("system/"):
                if metric_type == "system/uptime":
                    return int(payload)
                else:
                    # Raw text
                    return payload
            
            # Otherwise, try to parse as a number
            else:
                try:
                    return float(payload)
                except ValueError:
                    return payload
                    
        except (ValueError, AttributeError) as e:
            _LOGGER.error("Error parsing payload '%s' for %s: %s", payload, metric_type, e)
            return None

    @callback
    def handle_mqtt_message(self, payload):
        """Handle an MQTT message and update state."""
        parsed_value = self._parse_payload(payload)
        if parsed_value is None:
            _LOGGER.warning("Could not parse payload '%s' for %s", payload, self._attr_name)
            return

        self._state = parsed_value

        # Add extra attributes for interfaces
        metric_type = self._data["metric_type"]
        if metric_type.startswith("interface-"):
            parts = metric_type.split("/")
            self._extra_attributes = {
                "interface": parts[0].replace("interface-", ""),
                "metric": parts[1] if len(parts) > 1 else "",
            }

        self.async_write_ha_state()

    @property
    def native_value(self):
        """Return the state of the sensor."""
        return self._state
    
    @property
    def extra_state_attributes(self):
        """Return additional attributes."""
        return self._extra_attributes if self._extra_attributes else None


class OpenWrtMQTTRateSensor(OpenWrtMQTTBaseSensor):
    """Representation of an OpenWrt MQTT rate sensor (calculates derivative automatically)."""

    def __init__(self, hass, data, device_info):
        """Initialize the rate sensor."""
        self.hass = hass
        self._data = data
        self._device_info = device_info
        self._state = None
        self._last_value = None
        self._last_update = None
        
        metric_type = data["metric_type"]
        hostname = data.get("hostname", "unknown")
        entry_id = data.get("entry_id", "")
        # Préfixe incluant entry_id pour garantir l'unicité entre deux config entries
        prefix = f"{entry_id}_{hostname}" if entry_id else hostname

        # Generate unique_id for the rate sensor
        base_id = metric_type.replace('/', '_').replace('-', '_')
        self._attr_unique_id = f"{prefix}_{base_id}_{data['direction']}_rate"
        
        # Sensor name (prefixed with hostname)
        self._attr_name = self._generate_name(hostname, metric_type)
        
        # Configure units and device class
        self._configure_sensor_properties(metric_type)

    def _generate_name(self, hostname, metric_type):
        """Generate a friendly name from metric type, prefixed with hostname."""
        parts = metric_type.split('/')
        
        # Network interfaces
        if metric_type.startswith("interface-"):
            interface = parts[0].replace("interface-", "")
            metric = parts[1] if len(parts) > 1 else ""
            direction = self._data.get("direction", "").upper()
            
            if metric == "if_octets":
                return f"{hostname} {interface} {direction} Rate"
            elif metric == "if_packets":
                return f"{hostname} {interface} Packets {direction} Rate"
            elif metric == "if_errors":
                return f"{hostname} {interface} Errors {direction} Rate"
            elif metric == "if_dropped":
                return f"{hostname} {interface} Dropped {direction} Rate"
        
        # Default
        return f"{hostname} {metric_type.replace('/', ' ').replace('-', ' ').title()} Rate"

    def _configure_sensor_properties(self, metric_type):
        """Configure sensor properties based on metric type."""
        # Default values
        self._attr_native_unit_of_measurement = None
        self._attr_device_class = None
        self._attr_state_class = SensorStateClass.MEASUREMENT
        self._attr_suggested_display_precision = None
        self._attr_icon = None
        
        # Network bytes
        if "if_octets" in metric_type:
            self._attr_native_unit_of_measurement = "B/s"
            
            direction = self._data.get("direction", "rx")
            if direction == "tx":
                self._attr_icon = "mdi:upload-network"
            else:
                self._attr_icon = "mdi:download-network"
        
        # Network packets
        elif "if_packets" in metric_type:
            self._attr_native_unit_of_measurement = "packets/s"
            self._attr_icon = "mdi:lan-connect"
        
        # Network errors
        elif "if_errors" in metric_type:
            self._attr_native_unit_of_measurement = "errors/s"
            self._attr_icon = "mdi:lan-disconnect"
        
        # Dropped packets
        elif "if_dropped" in metric_type:
            self._attr_native_unit_of_measurement = "packets/s"
            self._attr_icon = "mdi:lan-pending"

    @property
    def device_info(self):
        """Return the device info."""
        return self._device_info

    def _parse_payload(self, payload):
        """Parse MQTT payload based on metric type."""
        metric_type = self._data["metric_type"]
        
        try:
            # Network interfaces: extract RX or TX based on direction
            if metric_type.startswith("interface-"):
                match = re.search(r'rx:([\d]+),tx:([\d]+)', payload)
                if match:
                    rx_value = int(match.group(1))
                    tx_value = int(match.group(2))
                    
                    direction = self._data.get("direction", "rx")
                    if direction == "rx":
                        return rx_value
                    elif direction == "tx":
                        return tx_value
                    
        except (ValueError, AttributeError) as e:
            _LOGGER.error("Error parsing payload '%s' for %s: %s", payload, metric_type, e)
            return None

    @callback
    def handle_mqtt_message(self, payload):
        """Handle an MQTT message and compute the rate since the previous one."""
        parsed_value = self._parse_payload(payload)
        if parsed_value is None:
            _LOGGER.warning("Could not parse payload '%s' for %s", payload, self._attr_name)
            return

        now = datetime.now()

        # First value: just store it, no rate yet
        if self._last_value is None or self._last_update is None:
            self._last_value = parsed_value
            self._last_update = now
            return

        time_delta = (now - self._last_update).total_seconds()
        if time_delta <= 0:
            return

        value_delta = parsed_value - self._last_value

        # Counter reset (router reboot): re-baseline, no rate
        if value_delta < 0:
            _LOGGER.warning("Counter reset detected for %s, skipping rate calculation", self._attr_name)
            self._last_value = parsed_value
            self._last_update = now
            return

        self._state = round(value_delta / time_delta, 2)
        self._last_value = parsed_value
        self._last_update = now
        self.async_write_ha_state()

    @property
    def native_value(self):
        """Return the state of the sensor."""
        return self._state
