# Waveshare 5.83 inch V2 wiring

The initial hardware profile matches the panel validated by the neighboring
InkyPi checkout:

| Signal | Raspberry Pi BCM | Physical role |
|---|---:|---|
| RST | 17 | panel reset |
| DC | 25 | data/command |
| BUSY | 24 | busy input, active low |
| PWR | 18 | display power enable |
| CS | 8 / CE0 | SPI chip select |
| MOSI | 10 | SPI0 MOSI |
| SCLK | 11 | SPI0 clock |

The driver uses SPI bus 0, device 0, mode 0 at 4 MHz and a 60-second BUSY
timeout. Confirm the exact panel revision and cable orientation before enabling
the hardware driver. Start with `driver = "mock"`; inspect `last-frame.png`,
then switch to `waveshare_5in83_v2` and request one full refresh.

Partial refresh is a full-frame transfer using the panel's faster waveform. If
ghosting is unacceptable, set `full_every = 1` to disable partial refresh.

## Validation record

On 2026-07-13 the adapter was exercised on the connected Raspberry Pi and
648×480 panel with the neighboring InkyPi service stopped. A full dashboard
refresh, a Claude-only partial refresh, and a final full dashboard refresh all
completed without BUSY timeout. SPI0 ran at 4 MHz and the system reported
`throttled=0x0`. Long-running ghosting behavior still needs the documented
24-hour soak test before reducing the conservative refresh limits.
