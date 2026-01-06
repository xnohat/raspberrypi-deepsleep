# Pi Deep Sleep

Power button (key 116) handler for Raspberry Pi that toggles aggressive power saving mode.

## Features

**On Sleep (power button press in normal state):**
- Stops non-essential services (bluetooth, avahi, triggerhappy)
- Disables HDMI output
- Sets USB to auto power management
- Sets CPU governor to powersave
- Disables activity/power LEDs
- Enables WiFi power save
- Attempts system suspend if available

**On Wake (power button press in sleep state):**
- Restores HDMI output
- Re-enables USB power
- Sets CPU governor to ondemand
- Re-enables LEDs
- Disables WiFi power save
- Restarts services

## Installation

```bash
sudo ./install.sh
```

## Uninstallation

```bash
sudo ./uninstall.sh
```

## Files

| File | Description |
|------|-------------|
| `powerbtn-deepsleep.sh` | Main handler script (→ `/usr/local/bin/`) |
| `powerbtn-custom` | ACPI event config (→ `/etc/acpi/events/`) |
| `install.sh` | Installation script |
| `uninstall.sh` | Uninstallation script |

## Logs

Check `/var/log/pi-deepsleep.log` for state transitions.

## Notes

- Raspberry Pi doesn't support true hardware suspend like x86 systems
- This implements aggressive software power saving instead
- Actual power savings depend on connected peripherals
- State tracked via `/tmp/pi-deepsleep-state`
