"""Config flow for OpenWrt MQTT integration."""
import logging
from typing import Any, Dict, Optional
import voluptuous as vol
from homeassistant import config_entries
from homeassistant.core import HomeAssistant, callback
from homeassistant.data_entry_flow import FlowResult
from .const import DOMAIN, DEFAULT_TOPIC_PREFIX, DEFAULT_TEMPERATURE_UNIT, TEMPERATURE_UNITS

_LOGGER = logging.getLogger(__name__)

class OpenWrtMQTTConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """Handle a config flow for OpenWrt MQTT."""

    VERSION = 1

    async def async_step_user(
        self, user_input: Optional[Dict[str, Any]] = None
    ) -> FlowResult:
        """Handle the initial step."""
        if user_input is None:
            return self.async_show_form(
                step_id="user",
                data_schema=vol.Schema(
                    {
                        vol.Required("topic_prefix", default=DEFAULT_TOPIC_PREFIX): str,
                        vol.Required("temperature_unit", default=DEFAULT_TEMPERATURE_UNIT): vol.In(TEMPERATURE_UNITS),
                    }
                ),
            )

        return self.async_create_entry(
            title=f"OpenWrt MQTT ({user_input['topic_prefix']})",
            data=user_input,
        )

    @staticmethod
    @callback
    def async_get_options_flow(config_entry: config_entries.ConfigEntry):
        """Get the options flow for this handler."""
        return OpenWrtMQTTOptionsFlow(config_entry)

class OpenWrtMQTTOptionsFlow(config_entries.OptionsFlow):
    """Handle options flow for OpenWrt MQTT."""

    def __init__(self, config_entry: config_entries.ConfigEntry) -> None:
        """Initialize options flow."""
        self._config_entry = config_entry

    async def async_step_init(self, user_input: Optional[Dict[str, Any]] = None) -> FlowResult:
        """Manage the options."""
        errors = {}
        if user_input is not None:
            return self.async_create_entry(title="", data=user_input)

        return self.async_show_form(
            step_id="init",
            data_schema=vol.Schema(
                {
                    vol.Required(
                        "topic_prefix",
                        default=self._config_entry.data.get("topic_prefix", DEFAULT_TOPIC_PREFIX),
                    ): str,
                    vol.Required(
                        "temperature_unit",
                        default=self._config_entry.data.get("temperature_unit", DEFAULT_TEMPERATURE_UNIT),
                    ): vol.In(TEMPERATURE_UNITS),
                }
            ),
            errors=errors,
        )
