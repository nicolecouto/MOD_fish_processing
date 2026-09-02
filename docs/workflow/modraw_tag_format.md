# `.modraw` tag reference: how to read every `$TAG`

**Status:** reference doc, reverse-engineered from `mod_som_read_epsi_files_v4.m` (the version actually used by the current pipeline) in the `MOD_fish_lib` repo. Companion to [.modraw → L0 conversion](modraw_to_L0_conversion.md) - that page says *what* gets parsed and returned; this page says *how the bytes are laid out* for each tag.

!!! note "Which version this documents"
    Earlier acquisition firmware (`mod_som_read_epsi_files_v1.m`/`v2.m`, in `read_epsi_files_old_versions/`) used different, inconsistent per-tag byte offsets that changed 2-3 times between 2021 and 2023. This page documents only the **current, unified frame format** (in use since ~May 2021, read by `v3.m`/`v4.m`) - the one you'll actually see in any recent deployment.

## The big picture: two frame families, plus two one-off metadata blocks

Every `.modraw` file is one long stream of blocks. Almost all of them start with `$` and end with `*XX\r\n` (`XX` = a 2-hex-digit checksum), but the *interior* structure splits into two families:

| Family | Tags | Header style |
|---|---|---|
| **SOM tag frame** | `EFE4`, `SB49`/`SB41`, `ALTI`, `ISAP`, `ACTU`, `SEGM`, `SPEC`, `AVGS`, `RATE`, `APF0`/`APF1`/`APF2`, `ECOP` (fluorometer), `TTV1`/`TTV2`/`TTV3` | Fixed 5-field SOM header: sync, 4-char tag, hex timestamp, hex length, header checksum |
| **NMEA-style sentence** | `VNMAR`/`VNYPR` (vector nav / IMU), `GPGGA`/`INGGA` (GPS) | Borrows the `$...*XX\r\n` wrapper, but the timestamp is hex digits placed *before* the `$`, and the payload is comma-separated ASCII (standard NMEA field order for GPS) |

Two more blocks are metadata, read once per file (not repeating data records):

| Tag | What it is | Format |
|---|---|---|
| `SOM3` | Mission/hardware setup - mission & vehicle name, firmware rev, git id, serial numbers, per-sensor config sub-modules (`CALENDAR`, `EFE`, `SBE49`/`SBE41`, `SDIO`, `VOLT`, `ALTI`) | Fixed-layout binary struct |
| `DCAL` | SBE49 calibration coefficients, dumped straight from the CTD's own `.cal` file | Plain-text `name=value`, one per line |

---

## Family 1: the SOM tag frame

Example: `$EFE4 0000018f449d43f1 00001900 *3A <...tag-specific DATA...> *8F\r\n`

Every tag in this family (`EFE4`, `SB49`, `SEGM`, `RATE`, ...) uses this exact same wrapper - only the tag code and the `DATA` slice change from tag to tag. The wrapper fields:

| Field | Offset (chars after `$`) | Length (chars) | Contents |
|---|---|---|---|
| sync | 0 | 1 | literal `$` |
| tag | 1 | 4 | tag code, e.g. `EFE4`, `SB49`, `ALTI` |
| hex timestamp | 5 | 16 | hex milliseconds - since power-on for small values, since the 1970 epoch when the decoded value exceeds `1e9` |
| hex length | 21 | 8 | hex byte-count of DATA (exceptions: `ALTI`/`ISAP`, see below) |
| header checksum | 29 | 3 | `*` + 2 hex digits - checksum of the header fields only |
| DATA | 32 | per hex length | tag-specific payload, see table below |
| trailing checksum | end - 5 | 5 | `*` + 2 hex digits + `\r\n` - checksum of the whole block |

The `DATA` field is the only thing that changes from tag to tag - that's what each subsection under [Per-tag DATA payload](#per-tag-data-payload) below maps out, byte by byte, for that one tag.

This shared layout is built once into a `tag` struct in `mod_som_read_epsi_files_v4.m` (lines 104-139) and reused for every tag in this family - that's why one parsing helper covers all of them.

!!! tip "Why the tag codes are all 4 characters"
    `EFE` and `ALT` look like 3-letter tags in the regex patterns (`\$EFE`, `\$ALT`), but the byte offsets above only work if the tag field is exactly 4 characters. On disk they're actually padded: `EFE4` and `ALTI`. The regexes still match because they only require the first 3 letters - the 4th character just becomes part of what gets read into the tag field.

### Per-tag DATA payload

| Tag | Sensor / data | Sample rate | Records per block | DATA payload structure |
|---|---|---|---|---|
| `EFE4` | Shear probes, FP07 thermistors, accelerometers (raw ADC) | 320 Hz (7-ch epsi) or 160 Hz (3-ch FCTD) | 80 | Repeating elements: 8-byte little-endian timestamp + 3 bytes/channel x (7 or 3 channels), 24-bit big-endian ADC counts per channel |
| `SB49` | SBE49 CTD | 16 Hz | `Meta_Data.CTD.sample_per_record` | Repeating records: 16 hex-char timestamp + 24 ASCII-hex chars = `T_raw`(6) `C_raw`(6) `P_raw`(6) `PT_raw`(4), raw engineering counts (needs `$DCAL` or a `.cal` file to convert to T/C/P) |
| `SB41` | SBE41 CTD (e.g. APEX float) | 1 Hz | `Meta_Data.CTD.sample_per_record` | Repeating records: 16 hex-char timestamp + 28 ASCII chars = comma-separated `P,T,S` decimal text (already engineering units, no cal needed; `C` is not transmitted, comes back `NaN`) |
| `ALTI` | MOD altimeter board | on demand, 1 value/block | 1 | **Exception:** the "hex length" field isn't a length - it holds the raw distance reading as ASCII text (units of 10 µs of round-trip time), converted via `x * 1e-5 s * 1500 m/s` sound speed. DATA payload after the header is empty/unused. |
| `ISAP` | ISA500 altimeter board | on demand, 1 value/block | 1 | Similar exception to `ALTI` - distance comes back directly in meters as ASCII text, read from a slightly nonstandard offset past the normal header (treat it as "everything after the header, as text") |
| `ACTU` | Actuator | - | - | Tag is matched and counted, but `v4` does not currently decode a payload (`act` always returns `[]`) |
| `SEGM` | Onboard raw time-segment (firmware-computed) | 320 Hz, NFFT=2048 samples/segment | 1 segment/block | 8-byte timestamp + 3 channels (`t1_volt`, `s1_volt`, `a3_g`) x 2048 samples, each sample a 4-byte little-endian IEEE-754 float |
| `SPEC` | Onboard power spectrum (firmware-computed) | derived from 320 Hz, NFFT/2=1024 freq bins | 1 spectrum/block | 8-byte timestamp + 3 channels x 1024 bins, each a 4-byte float |
| `AVGS` | Onboard averaged spectrum | derived from 160 Hz, NFFT/2=1024 bins | 1 spectrum/block | Same layout as `SPEC`; channels labeled `t1_k`/`s1_k`/`a3_g` |
| `RATE` | Onboard dissipation-rate summary | 1 value/block | 1 | 8-byte timestamp + 10 channels x 4-byte float: `pressure, temperature, salinity, dpdt, chi, chi_fom, epsilon, epsi_fom, nu, kappa` |
| `APF0`/`APF1` | APEX float telemetry, profile summary | metadata-driven | `sample_cnt` (in metadata) | 38-byte packed metadata header, then `sample_cnt` variable-format sample records - see [APF0/APF1 maps](#apf0apf1-data-field-metadata-header-sample-records) below |
| `APF2` | APEX float telemetry, newer fixed format | 1 record/block | 1 | Fixed record: timestamp(8B) + 10 x 4-byte floats, then three `nfft/2`-length averaged spectra (shear, thermal gradient, accel), all 4-byte floats. No metadata header (hardcoded `nfft=2048`) - see [APF2 map](#apf2-data-field) below |
| `ECOP` | Tridente fluorometer / backscatter sensor | 16 Hz | 1 | 16 hex-char timestamp + 12 ASCII-hex chars = three 4-hex-char (16-bit) raw counts: `bb` (backscatter), `chla`, `fDOM`, each normalized `(raw/65535 - 0.5)/scale` |
| `TTV1`/`TTV2`/`TTV3` | Travel-time flow meter (up to 3 transducer pairs) | 16 Hz | 10 | Repeating records: 16 hex-char timestamp + binary payload - see [TTV map](#ttv1ttv2ttv3-data-field) below |

## Tag-specific DATA

Every map below shows **only the DATA slice** - the part that sits inside `<...tag-specific DATA...>` in the frame diagram above. The sync/tag/timestamp/length/checksum wrapper around it is identical for every tag and is not repeated here. Byte counts (not bit counts) throughout; multi-byte numeric fields are little-endian unless noted. Field order is transcribed directly from the read/write offsets in `mod_som_read_epsi_files_v4.m`, cross-checked line-by-line against the code (line numbers noted per section).

### `EFE4` DATA field

One record, x80 per block (`mod_som_read_epsi_files_v4.m:305-308,377-385`):

| Field | Size | Contents |
|---|---|---|
| timestamp | 8 B | little-endian |
| ch1 | 3 B | 24-bit big-endian ADC count |
| ch2 | 3 B | 24-bit big-endian ADC count |
| ch3 | 3 B | 24-bit big-endian ADC count |
| ... | 3 B | one per channel, up to `chN` |

`N` = 3 channels (FCTD) or 7 channels (epsi) - so each record is 11 bytes (3-ch) or 29 bytes (7-ch). 80 records per block; only the per-channel bytes are big-endian, the leading timestamp is little-endian.

### `SB49` DATA field (`sbe.data.format = 'eng'`)

One record, x `Meta_Data.CTD.sample_per_record` per block, all ASCII/hex text (`mod_som_read_epsi_files_v4.m:475-480,544,557,577-580`):

| Field | Size | Contents |
|---|---|---|
| hex timestamp | 16 chars | ASCII hex |
| `T_raw` | 6 chars | ASCII hex |
| `C_raw` | 6 chars | ASCII hex |
| `P_raw` | 6 chars | ASCII hex |
| `PT_raw` | 4 chars | ASCII hex |

40 ASCII characters per record. `T_raw`/`C_raw`/`P_raw`/`PT_raw` are raw engineering counts - converted to physical units via `$DCAL` coefficients (or the SN-matched `.cal` file when `use_file_headers` is off).

### `SB41` DATA field (`sbe.data.format = 'PTS'`)

One record, x `Meta_Data.CTD.sample_per_record` per block, all ASCII text (`mod_som_read_epsi_files_v4.m:481-484,544,557,565-571`):

| Field | Size | Contents |
|---|---|---|
| hex timestamp | 16 chars | ASCII hex |
| `P,T,S` | 28 chars | comma-separated ASCII decimal |

44 ASCII characters per record. Already in engineering units - no calibration lookup needed. Conductivity (`C`) is not transmitted by the SBE41 and comes back `NaN`.

### `ALTI` DATA field

The whole block *is* the reading - there's no separate DATA section (`mod_som_read_epsi_files_v4.m:709-711`):

| Wrapper field | Normal contents | `ALTI` contents |
|---|---|---|
| hex length (8 chars) | byte-count of `DATA` | repurposed: round-trip time in units of 10 µs, as ASCII text |
| `DATA` | tag-specific payload | empty/unused |

Example: `hex length = "00001900"` -> decimal `6400` -> `6400 x 1e-5 s x 1500 m/s = 96 m`.

### `ISAP` DATA field

Same repurposed-header trick as `ALTI`, but the reading is read from further into the block, past where a second `data_offset`-sized chunk would sit - an apparent off-by-one/copy-paste artifact in the parser, not a documented protocol feature (`mod_som_read_epsi_files_v4.m:798-805`):

| Wrapper field | Normal contents | `ISAP` contents |
|---|---|---|
| hex length (8 chars) | byte-count of `DATA` | unused |
| bytes 33-55 of block | `DATA` payload | unused (skipped over) |
| bytes 56 to `end-5` | (n/a) | distance in meters, ASCII text |

The start offset (56) is computed as `tag.data_offset + tag.hextimestamp.length + tag.header.offset + tag.header.length + 2` = `33 + 16 + 1 + 4 + 2` = byte 56 of the block - deliberately called out here because it doesn't match any of the other tags' offset math and isn't explained in the source.

### `ACTU` DATA field

No payload is decoded in `v4` - the tag is matched and counted (so it shows up in the "processed data types" log line) but `act` is always returned as `[]` (`mod_som_read_epsi_files_v4.m:846-868`).

### `SEGM` DATA field

One segment per block, channel-major (not interleaved) (`mod_som_read_epsi_files_v4.m:970-979,1012-1028`):

| Field | Size | Contents |
|---|---|---|
| timestamp | 8 B | little-endian |
| `t1_volt` | 8,192 B | 2048 samples, 4-byte float each |
| `s1_volt` | 8,192 B | 2048 samples, 4-byte float each |
| `a3_g` | 8,192 B | 2048 samples, 4-byte float each |

24,584 bytes total (8 + 3x2048x4). All 2048 `t1_volt` samples come first, then all 2048 `s1_volt`, then all 2048 `a3_g` - the reshape in the code is `[4 bytes, 2048*3]` read column-major, then sliced by channel in contiguous 2048-sample chunks.

### `SPEC` / `AVGS` DATA field

Same channel-major layout as `SEGM`, but 1024 bins/channel instead of 2048 samples (`mod_som_read_epsi_files_v4.m:1078-1086,1119-1134` for `SPEC`; `:1188-1196,1229-1244` for `AVGS`):

| Field | Size | Contents |
|---|---|---|
| timestamp | 8 B | little-endian |
| channel1 | 4,096 B | 1024 bins, 4-byte float each |
| channel2 | 4,096 B | 1024 bins, 4-byte float each |
| channel3 | 4,096 B | 1024 bins, 4-byte float each |

12,296 bytes total (8 + 3x1024x4).

| Tag | channel1 | channel2 | channel3 |
|---|---|---|---|
| `SPEC` | `t1_volt` | `s1_volt` | `a3_g` |
| `AVGS` | `t1_k` | `s1_k` | `a3_g` |

### `RATE` DATA field

One record per block, fixed field order (`mod_som_read_epsi_files_v4.m:1296-1303,1342-1349`):

| Field | Size |
|---|---|
| timestamp | 8 B, little-endian |
| pressure | 4 B float |
| temperature | 4 B float |
| salinity | 4 B float |
| dpdt | 4 B float |
| chi | 4 B float |
| chi_fom | 4 B float |
| epsilon | 4 B float |
| epsi_fom | 4 B float |
| nu | 4 B float |
| kappa | 4 B float |

48 bytes total (8 + 10x4).

### `APF0`/`APF1` DATA field: metadata header + sample records

Fixed 38-byte metadata header first, once per block (`mod_som_read_epsi_files_v4.m:1442-1456,1508-1526`):

| Field | Size | Contents |
|---|---|---|
| `daq_timestamp` | 4 B | uint32 |
| `profile_id` | 2 B | uint16 |
| `modsom_sn` | 2 B | uint16 |
| `efe_sn` | 2 B | uint16 |
| `firmware_rev` | 4 B | uint32 |
| `nfft` | 2 B | uint16 |
| `nfftdiag` | 2 B | uint16 |
| `probe1` | 5 B | `type`(1B) + `sn`(2B) + `cal`(2B) |
| `probe2` | 5 B | `type`(1B) + `sn`(2B) + `cal`(2B) |
| `comm_telemetry_packet_format` | 1 B | uint8, selects sample record layout below |
| `sd_format` | 1 B | uint8 |
| `sample_cnt` | 2 B | uint16, number of sample records that follow |
| `voltage` | 4 B | uint32 |
| `end_metadata` | 2 B | always `0xFFFF` |

38 bytes total, immediately followed by `sample_cnt` sample records.

`packet_format` (from the header above) selects the sample record layout (`mod_som_read_epsi_files_v4.m:1564-1631`):

**`packet_format` 1:**

| Field | Size | Contents |
|---|---|---|
| time | 2 B | uint16 |
| pressure | 4 B | float |
| dissrate (packed) | 3 B | `epsilon` + `chi`, 12 bits each |
| fom (packed) | 1 B | `epsi_fom` + `chi_fom`, 4 bits each |
| pad | 1 B | trailing pad byte, marked `TODO` in source (firmware writes one extra byte per sample) |

Bit packing: `epsilon` (12 bits) = `byte1<<4 | byte2>>4`; `chi` (12 bits) = `byte2>>8 | byte3`; `epsi_fom` (4 bits) = `fom_byte>>4`; `chi_fom` (4 bits) = `fom_byte | 0x0F` (as coded - see note below).

**`packet_format` 2:**

| Field | Size | Contents |
|---|---|---|
| time | 2 B | uint16 |
| pressure | 4 B | float |
| temperature | 4 B | float |
| salinity | 4 B | float |
| dpdt | 4 B | float |
| dissrate (packed) | 3 B | same packing as format 1 |
| kcutoff_shear* | 4 B | float - *see off-by-one note below |
| fcutoff_temp | 4 B | float |
| fom (packed) | 1 B | same packing as format 1 |
| `shear_k`/`tg_k`/`accel_k` | 2 B each, repeated `nfftdiag` times | "foco"-encoded uint16, interleaved shear/tg/accel per diagnostic bin |

\* `kcutoff_shear` is read starting 1 byte past where the running offset says it should be - an off-by-one in the parser (`apf_block_data(local_apf_block_counter(end)+(2:float_length+1))` instead of `1:float_length`).

!!! note "`chi_fom` bit math looks suspicious"
    The source computes `chi_fom` as `uint32(bitor(fom_byte, 15))`, i.e. OR-ing with `0b1111` rather than masking/shifting to extract the low nibble. That forces the low 4 bits to `1` regardless of their actual value, which looks like a bug rather than intentional packing - transcribed here as-coded, not verified against firmware intent.

### `APF2` DATA field

One fixed record per block, no metadata header - `nfft=2048` is hardcoded in the MATLAB parser rather than read from the stream (`mod_som_read_epsi_files_v4.m:1793,1822-1871`):

| Field | Size |
|---|---|
| timestamp | 8 B, little-endian |
| pressure | 4 B float |
| temperature | 4 B float |
| salinity | 4 B float |
| dpdt | 4 B float |
| epsilon | 4 B float |
| chi | 4 B float |
| kcutoff_shear | 4 B float |
| fcutoff_temp | 4 B float |
| epsi_fom | 4 B float |
| chi_fom | 4 B float |
| avg_shear_k | 1024 x 4 B float |
| avg_tg_k | 1024 x 4 B float |
| avg_accel_k | 1024 x 4 B float |

12,336 bytes total (8 + 10x4 + 3x1024x4). Unlike `APF0`/`APF1`, every field here is a plain unpacked 4-byte float - no bit-packing, no `foco` encoding.

### `ECOP` DATA field (fluorometer)

One record per block, all ASCII/hex text (`mod_som_read_epsi_files_v4.m:1924-1930,1989-2001`):

| Field | Size | Contents |
|---|---|---|
| hex timestamp | 16 chars | ASCII hex |
| `bb` | 4 chars | ASCII hex, uint16 |
| `chla` | 4 chars | ASCII hex, uint16 |
| `fDOM` | 4 chars | ASCII hex, uint16 |

28 ASCII characters per record. Normalization: `(raw_uint16 / 65535 - 0.5) / scale`, where `scale` is `0.05` for `bb`, `50` for `chla`, `1000` for `fDOM`.

### `TTV1`/`TTV2`/`TTV3` DATA field

!!! warning "Not directly verified against the live parser"
    As of this checkout, TTV blocks are parsed by a helper function `parse_ttv_block.m` (called at `mod_som_read_epsi_files_v4.m:2054,2185,2193`) that isn't present in the `MOD_fish_lib` working copy used to write this page - it may live in an untracked file, a different branch, or a submodule not checked out locally. The map below is transcribed from the **format 2** description left in a commented-out legacy code block in the same file (`mod_som_read_epsi_files_v4.m:2141-2159`), which appears to be the design the current helper implements (`ttv1.data.ttv_format = 2` was hardcoded before the code was extracted). Treat this as the best available documentation, not confirmed against the function that actually runs - re-derive from `parse_ttv_block.m` directly if you need certainty.

| Field | Size | Contents |
|---|---|---|
| hex timestamp | 16 chars | ASCII hex |
| `tof_up` | 4 B | float, upstream time-of-flight |
| `tof_down` | 4 B | float, downstream time-of-flight |
| `dtof` | 4 B | float, delta time-of-flight |
| error code | 1 B | uint8 |
| up ADC peak | 2 B | uint16 |
| dn ADC peak | 2 B | uint16 |

16 hex chars + 17 binary bytes per record, x10 records/block, 16 Hz.

!!! note "Legacy ASCII TTV format still referenced in code"
    An older, human-readable TTV format also appears in comments: `$TTV...*2C...00:28:07 447 ms-000000050 ps,+650 mV,+651 mV,078, 078*12`. The parsing code for that format ("format 1") is preserved commented-out in `mod_som_read_epsi_files_v4.m` in case older files need it, but is not active in the current parser.

---

## Family 2: NMEA-style sentences (VNAV, GPS)

Example: `0000018f449d43f1 $VNMAR ,0.12,0.03,-0.98,0.01,0.00,9.79,...*4C\r\n`

Unlike Family 1, the hex timestamp comes *before* the `$`, not after it - everything from the tag onward is comma-separated ASCII, ending in the usual `*XX\r\n` checksum.

| Tag | Sensor | Timestamp offset | Payload |
|---|---|---|---|
| `VNMAR` | VectorNav IMU, compass/accel/gyro packet | 16 hex chars immediately before `$` | 9 comma-separated ASCII floats: compass (x,y,z, gauss), acceleration (x,y,z, m/s²), gyro (x,y,z, rad/s) |
| `VNYPR` | VectorNav IMU, yaw/pitch/roll packet | 16 hex chars immediately before `$` | 3 comma-separated ASCII floats: yaw, pitch, roll (degrees) |
| `GPGGA`/`INGGA` | GPS | 10 hex chars immediately before `$` | Standard NMEA-0183 GGA sentence, comma-separated - field 3 = latitude (`ddmm.mmmm`), field 4 = `N`/`S`, field 5 = longitude (`dddmm.mmmm`), field 6 = `E`/`W` |

---

## The one-off metadata blocks

### `$SOM3` - mission/hardware setup

Not a repeating data record - read once per file (if present) to populate `Meta_Data` before any data tags are parsed. Fixed-layout binary struct, parsed by `mod_som_read_setup_from_raw.m`:

| Field | Length | Contents |
|---|---|---|
| `size` | 4 bytes | total struct size (also selects whether a `gitid` field is present: 24 bytes if `size` is 864 or 896) |
| `header` | 8 bytes | ASCII |
| `mission_name` | 24 bytes | ASCII |
| `vehicle_name` | 24 bytes | ASCII |
| `firmware` | 40 bytes | ASCII version string |
| `gitid` | 0 or 24 bytes | ASCII git commit id, only present for some firmware builds |
| `rev` | 8 bytes | ASCII |
| `sn` | 8 bytes | ASCII |
| `initialize_flag` | 4 bytes | uint32 |

Followed by named, self-length-prefixed sub-modules (`CALENDAR`, `EFE`, `SBE49`/`SBE41`, `SDIO`, `VOLT`, `ALTI`) with per-sensor configuration - each is located by string search rather than a fixed offset, since not every deployment has every module.

### `$DCAL` - SBE calibration coefficients

Not a repeating data record either - plain-text lines of `name=value`, one coefficient per line, parsed by `get_CalSBE_v2.m`. It's the CTD manufacturer's own calibration sheet (temperature: `ta0`-`ta3`, `toffset`; conductivity: `g`,`h`,`i`,`j`,`pcor`,`tcor`,`cslope`; pressure coefficients follow), copied verbatim into the file header at the start of a deployment so raw `SB49` engineering counts can be converted to physical units without a separate `.cal` file.

---

## Quick lookup

| Tag | Family | Sensor |
|---|---|---|
| `SOM3` | metadata | mission/hardware setup |
| `DCAL` | metadata | SBE calibration coefficients |
| `GPGGA`/`INGGA` | NMEA | GPS |
| `EFE4` | SOM frame | epsi shear/FP07/accel raw ADC |
| `SB49`/`SB41` | SOM frame | CTD |
| `ALTI` | SOM frame | MOD altimeter |
| `ISAP` | SOM frame | ISA500 altimeter |
| `ACTU` | SOM frame | actuator (tag only, no payload decode) |
| `VNMAR`/`VNYPR` | NMEA | VectorNav IMU |
| `SEGM` | SOM frame | onboard raw time-segment |
| `SPEC` | SOM frame | onboard power spectrum |
| `AVGS` | SOM frame | onboard averaged spectrum |
| `RATE` | SOM frame | onboard dissipation-rate summary |
| `APF0`/`APF1`/`APF2` | SOM frame | APEX float telemetry |
| `ECOP` | SOM frame | Tridente fluorometer/backscatter |
| `TTV1`/`TTV2`/`TTV3` | SOM frame | travel-time flow meter |

## History

Derived by reading `mod_som_read_epsi_files_v4.m` in `MOD_fish_lib` (the header-offset struct at lines 104-139, and each tag's per-block parsing loop) rather than from a firmware spec document - no such document was available. Byte offsets and field names are transcribed directly from the parsing code; a couple of details (the `ALTI`/`ISAP` "hex length field is actually the reading" quirk, and the exact `ISAP` data offset) are called out as quirks rather than presented as clean spec because the code itself treats them inconsistently with the rest of the frame family.
