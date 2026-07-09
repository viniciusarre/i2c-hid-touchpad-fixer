# i2c-hid-touchpad-fixer

Fix a flaky **I2C-HID touchpad** on Linux — the kind found on ASUS Zenbooks
(e.g. UX3402ZA) and various other Intel/AMD laptops. It handles two related
failure modes:

1. **Dead touchpad** — the device fails to bind to the `i2c_hid_acpi` driver at
   boot, or drops after suspend/resume. It disappears entirely from `xinput`,
   `libinput list-devices`, and `/proc/bus/input/devices`, even though it's
   still present on the I2C bus. → **fix: (re)bind the driver.**
2. **Motion freeze** — clicks still register but sliding/scrolling freezes
   intermittently. Caused by runtime power management (autosuspend) putting the
   device to sleep and dropping the high-frequency motion packets, while a click
   still wakes it. → **fix: disable runtime PM on the device.**

Both are timing/power quirks, not hardware faults.

> **This is a userspace workaround, not a root-cause fix** — and that's fine for
> day-to-day use. The "real" fix would be a kernel-side quirk for the affected
> boards; this recovers the device after the fact and keeps it awake. It's safe
> and reliable (the only cost of disabling autosuspend is marginally higher idle
> power).

## Symptoms

- Touchpad does nothing, only an external mouse works, **or**
- clicks work but the cursor/scroll freezes while moving.
- `xinput list` / `libinput list-devices` show no touchpad (dead case).

## Diagnose

```bash
./setup.sh --status
```

Example on an affected machine:

```
=== I2C-HID device state (bind + runtime PM) ===
  i2c-ASUE120C:00      bind=BOUND      power/control=auto
```

- `bind=NOT BOUND` → the dead-touchpad case.
- `power/control=auto` → autosuspend is on, the motion-freeze cause.
  (`on` = autosuspend disabled = good.)

`ASUE120C` is the ASUS/ELAN touchpad; yours may differ — everything here
auto-detects the device by the I2C-HID ACPI id (`PNP0C50` / `MSFT0001`).

### Is it software or hardware?

If the touchpad keeps misbehaving in *different* ways (dead, freezing,
phantom/stuck input), run the diagnostics — ideally **with `sudo`, right after
a failure**, so it can read the kernel log:

```bash
sudo ./touchpad-diagnose.sh
```

It reports your model/BIOS, bind + power state, the input layer, and counts
I2C/HID error lines (reset/timeout/CRC/incomplete-report) *in touchpad
context*. A non-zero error count points to a signal/hardware/firmware problem
(loose FPC connector, failing module, or an old BIOS) rather than something the
rebind workaround can durably fix.

## Install

```bash
git clone https://github.com/viniciusarre/i2c-hid-touchpad-fixer.git
cd i2c-hid-touchpad-fixer
sudo ./setup.sh --install
```

`--install` sets up three things (all idempotent) and runs the fix once
immediately:

- `touchpad-fixer.service` — runs at **boot**, rebinds the touchpad if needed.
- `touchpad-fixer-resume.service` — runs after **resume from suspend**, force
  re-probing the device (which can be stuck-but-bound on wake).
- `99-i2c-hid-touchpad-fixer.rules` — a udev rule that **disables autosuspend**
  on the touchpad whenever it appears, preventing the motion freeze.

## Usage

```
sudo ./setup.sh --install     Install services + udev rule (default)
sudo ./setup.sh --uninstall   Remove everything
sudo ./setup.sh --run         Run the fixer once, now
     ./setup.sh --status      Show service / udev / device state (no root)
     ./setup.sh --help        Help
```

Run the fixer directly, without the services:

```bash
sudo ./touchpad-fixer.sh          # bind unbound devices + disable autosuspend
sudo ./touchpad-fixer.sh --reset  # force unbind+rebind (use after a freeze)
sudo ./touchpad-fixer.sh -v       # verbose
```

## How it works

`touchpad-fixer.sh`:

1. Scans `/sys/bus/i2c/devices/` for I2C-HID devices (`modalias` contains
   `PNP0C50` or `MSFT0001`).
2. Binds any that have no driver (or, with `--reset`, unbinds+rebinds all of
   them to force a fresh probe).
3. Falls back to reloading the `i2c_hid` / `i2c_hid_acpi` modules if a direct
   bind fails.
4. Writes `on` to each device's `power/control` (and its HID child), disabling
   runtime autosuspend so motion packets aren't dropped. This runs every time,
   because a freshly (re)bound device resets back to `auto`.

It's idempotent — safe to run repeatedly, on boot, and on resume.

## Uninstall

```bash
sudo ./setup.sh --uninstall
```

## Tested on

- ASUS Zenbook UX3402ZA (ELAN touchpad, ACPI id `ASUE120C`), Arch/Garuda,
  `linux-zen`.

## License

[MIT](LICENSE)
