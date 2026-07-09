# i2c-hid-touchpad-fixer

Automatically revive an **I2C-HID touchpad that fails to bind to its driver at
boot**.

On a number of laptops — notably **ASUS Zenbooks** (e.g. UX3402ZA), but also
various Lenovo and AMD Ryzen machines — the I2C-HID touchpad occasionally fails
to bind to the `i2c_hid_acpi` driver during boot. It's a reset/init timing
issue on the I2C bus, not a hardware fault. When it happens, the touchpad
disappears *completely*: nothing in `xinput`, `libinput list-devices`, or
`/proc/bus/input/devices` — even though the device is still sitting on the I2C
bus, just with no driver attached.

This project detects any such unbound I2C-HID device and re-binds it, and
installs a tiny systemd service so the fix runs automatically on every boot.

> **Scope / honesty:** this is a **userspace workaround**, not a root-cause
> fix. The real fix is a kernel-side quirk (a delay/retry matched to the
> affected board). This just recovers the device after the fact. It's reliable
> and safe, but if you can, please also report your machine upstream (see
> [Reporting upstream](#reporting-upstream)) so it eventually gets fixed for
> everyone.

## Symptoms

- The touchpad does nothing; only an external mouse works.
- `xinput list` shows no touchpad.
- `libinput list-devices` shows no touchpad.
- `grep -i touchpad /proc/bus/input/devices` returns nothing.

## Diagnose

Check whether an I2C-HID device exists but has no driver bound:

```bash
./setup.sh --status
```

Example output on an affected machine:

```
=== I2C-HID device bind state ===
  i2c-ASUE120C:00 : NOT BOUND
```

`NOT BOUND` = the driver never attached. That's exactly the case this tool
fixes. (`ASUE120C` is the ASUS/ELAN touchpad; yours may differ — the tool
auto-detects it by the I2C-HID ACPI id `PNP0C50` / `MSFT0001`.)

## Install

```bash
git clone https://github.com/<your-username>/i2c-hid-touchpad-fixer.git
cd i2c-hid-touchpad-fixer
sudo ./setup.sh --install
```

`--install` does three things, all idempotent:

1. Generates and enables a `touchpad-fixer.service` systemd unit that runs on
   every boot (after `multi-user.target`, so the I2C stack is up).
2. Points the service at wherever you cloned the repo.
3. Runs the fixer once immediately, so your touchpad comes back now.

## Usage

```
sudo ./setup.sh --install     Install + enable the boot service (default)
sudo ./setup.sh --uninstall   Disable + remove the boot service
sudo ./setup.sh --run         Run the fixer once, now
     ./setup.sh --status      Show service + touchpad bind state (no root)
     ./setup.sh --help        Help
```

You can also run the fixer directly without the service:

```bash
sudo ./touchpad-fixer.sh          # bind any unbound I2C-HID device
sudo ./touchpad-fixer.sh -v       # verbose
```

## How it works

`touchpad-fixer.sh`:

1. Scans `/sys/bus/i2c/devices/` for devices whose `modalias` advertises the
   I2C-HID ACPI compatible id (`PNP0C50` or `MSFT0001`).
2. Filters to those with **no `driver` symlink** (i.e. unbound).
3. Writes the device name to `/sys/bus/i2c/drivers/i2c_hid_acpi/bind`.
4. If a direct bind fails, falls back to reloading the `i2c_hid` /
   `i2c_hid_acpi` kernel modules.
5. Exits cleanly and does nothing if every touchpad is already bound
   (idempotent — safe to run repeatedly and on every boot).

The systemd unit uses `SuccessExitStatus=0 1` so a boot is never marked
degraded if the touchpad genuinely can't be recovered that cycle.

## Uninstall

```bash
sudo ./setup.sh --uninstall
```

## Tested on

- ASUS Zenbook UX3402ZA (ELAN touchpad, ACPI id `ASUE120C`), Arch/Garuda,
  `linux-zen`.

If it works (or doesn't) on your machine, please open an issue with your
laptop model, the `./setup.sh --status` output, and your kernel version — it
helps build a list of affected hardware for the upstream report.

## Reporting upstream

A userspace rebind is a stopgap. The durable fix is a kernel quirk. If you
hit this, consider reporting your board so it can be fixed for everyone:

- The [asus-linux.org](https://asus-linux.org) community (for ASUS laptops).
- The kernel bug tracker / `linux-input` mailing list, with `dmesg` output
  around the bind failure.

## License

[MIT](LICENSE)

---

*The scripts and docs in this repo were drafted with AI assistance and then
tested by a human on real affected hardware before publishing.*
