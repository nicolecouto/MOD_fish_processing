function som3 = MODutil_read_som3(modraw_file, varargin)
% MODutil_read_som3        Part of MOD_fish_processing
%
% MODutil_read_som3(modraw_file)                 - print what's in the $SOM3 block
% som3 = MODutil_read_som3(modraw_file)          - return it as a struct
% MODutil_read_som3(modraw_file, 'hex', true)    - also print each module's bytes
%
% DESCRIPTION
%   Reads the $SOM3 block of a .modraw file: the SOM's own settings, which
%   the SOM firmware writes once near the start of each file (separate
%   from the fctd_epsi Setup text that's copied into the file header).
%
%   Layout, checked against raw files from blt2021_0715, canyonhead
%   (MAKO1), fctd_w_ucond (FCTDA), DeepSolo and Minnow:
%     "$SOM3" + 16 hex timestamp + 8 hex length + "*XX" header checksum,
%     then the payload, then "*XX\r\n". Payload (little-endian):
%       uint32 size, char[8] 'SOM3', char[24] mission name,
%       char[24] vehicle name, char[40] firmware,
%       then more text (git id, rev, SN - varies by firmware version),
%       then a chain of modules, each uint32 size followed by its tag
%       (CAL, EFE4, SB49, SDIO, VOLT, ACTU or $ACT, ALTI, VNAV).
%   Decoded per module:
%     EFE4 - rev, SN, nb_channel, sample_per_record, nb_record_per_buffer,
%            spi_baudrate, and per channel (60 bytes each) the name, probe
%            SN and the float32 calibration value stored with it
%     SB49 - SN, data_format, sample_data_per_record
%     SDIO - file_duration, file prefix
%   Every module also gets its size and the readable text in it; 'hex'
%   prints the raw bytes so anything not decoded can still be looked at.
%   Fields not listed above aren't decoded (the old reader's offsets for
%   them don't hold across firmware versions).
%
%   Not every raw file has a $SOM3 block (e.g. the 2025 FCTD fluorometer
%   files don't) - then som3 is [] and a message says so. If a file has
%   more than one, the first is read.
%
% INPUTS
%   modraw_file - full path to a .modraw (or older .raw) file
%   'hex'       - (optional, name-value) true to print each module's bytes
%
% OUTPUTS
%   som3 - struct (or [] if there's no $SOM3 block):
%            .file, .size, .header, .mission_name, .vehicle_name, .firmware
%            .other_text - cellstr of the other text between the firmware
%                          field and the first module (git id, rev, SN, ...)
%            .modules    - struct array: .tag, .offset (bytes into the
%                          payload), .size, .text (cellstr), .bytes (uint8),
%                          .decoded (struct, for EFE4/SB49/SDIO; [] otherwise)
%   With no output argument, prints a summary instead.
%
% CALLED BY
%   (by hand, to see what's in a raw file's $SOM3 block)
%
% CALLS
%   (none)
%
% PROVENANCE
%   Based on MOD_fish_lib EPSILOMETER/epsilib/mod_som_read_setup_from_raw.m
%   (the EFE/SB49/SDIO field layouts). Rewritten to find modules by their
%   size+tag instead of fixed offsets, since the block size differs by
%   firmware (872, 896, 920 bytes seen). MODprocess_single_modraw_to_L0.m
%   (line ~92) also locates $SOM3 blocks, with the same regex, but only to
%   skip them.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

p = inputParser;
addParameter(p, 'hex', false);
parse(p, varargin{:});

fid = fopen(modraw_file, 'r');
if fid < 0
    error('MODutil_read_som3:cantOpen', 'Cannot open %s', modraw_file);
end
% $SOM3 is written near the start of a file - look in the first 1 MB, then the rest
som3_pattern = '\$SOM3([\S\s]+?)\*([0-9A-Fa-f][0-9A-Fa-f])\r\n';
bytes = fread(fid, 2^20, '*uint8')';
[i0, i1] = regexp(char(bytes), som3_pattern, 'start', 'end', 'once');
if isempty(i0) && ~feof(fid)
    bytes = [bytes, fread(fid, Inf, '*uint8')'];
    [i0, i1] = regexp(char(bytes), som3_pattern, 'start', 'end', 'once');
end
fclose(fid);

som3 = [];
if isempty(i0)
    fprintf('%s: no $SOM3 block.\n', modraw_file);
    return
end
% "$SOM3"(5) + timestamp(16) + length(8) + "*XX"(3) = 32 bytes before the payload;
% the trailing "*XX\r\n" is 5 bytes
payload = bytes(i0 + 32 : i1 - 5);

som3.file = modraw_file;
som3.size = u32(payload, 1);
som3.header = text_at(payload, 5, 8);
som3.mission_name = text_at(payload, 13, 24);
som3.vehicle_name = text_at(payload, 37, 24);
som3.firmware = text_at(payload, 61, 40);

% Modules: uint32 size immediately before a known tag, chained to the end
tags = {'CAL', 'EFE4', 'SB49', 'SB41', 'SDIO', 'VOLT', 'ACTU', '$ACT', 'ALTI', 'VNAV'};
modules = struct('tag', {}, 'offset', {}, 'size', {}, 'text', {}, 'bytes', {}, 'decoded', {});
pstr = char(payload);
for iT = 1:numel(tags)
    for k = strfind(pstr, tags{iT})
        if k < 5
            continue
        end
        sz = u32(payload, k - 4);
        start = k - 4;
        if sz < 8 || start + sz - 1 > numel(payload)
            continue % not a real module header
        end
        mb = payload(start : start + sz - 1);
        modules(end+1) = struct('tag', tags{iT}, 'offset', start - 1, 'size', sz, ...
            'text', {readable_text(mb(9:end))}, 'bytes', mb, ...
            'decoded', decode_module(tags{iT}, mb)); %#ok<AGROW>
    end
end
if ~isempty(modules)
    [~, order] = sort([modules.offset]);
    modules = modules(order);
    % Modules sit end to end; drop any "tag" found inside an earlier module
    keep = true(size(modules));
    module_end = -1;
    for iM = 1:numel(modules)
        if modules(iM).offset < module_end
            keep(iM) = false;
        else
            module_end = modules(iM).offset + modules(iM).size;
        end
    end
    modules = modules(keep);
    first_module = modules(1).offset + 1;
else
    first_module = numel(payload) + 1;
end
som3.other_text = readable_text(payload(101 : first_module - 1));
som3.modules = modules;

if nargout == 0
    print_som3(som3, p.Results.hex);
    clear som3
end
end %end function

%% Module-specific fields (EFE4, SB49/SB41, SDIO); [] for the rest
function d = decode_module(tag, mb)
d = [];
switch tag
    case 'EFE4'
        % size4, tag8, rev8, sn8, nb_channel4, sample_per_record4,
        % nb_record_per_buffer4, spi_baudrate4, then 60 bytes per channel
        d.rev = text_at(mb, 13, 8);
        d.sn = text_at(mb, 21, 8);
        d.nb_channel = u32(mb, 29);
        d.sample_per_record = u32(mb, 33);
        d.nb_record_per_buffer = u32(mb, 37);
        d.spi_baudrate = u32(mb, 41);
        d.channels = struct('name', {}, 'sn', {}, 'cal', {});
        for iC = 1:min(d.nb_channel, 16)
            c0 = 45 + (iC - 1) * 60;
            if c0 + 11 > numel(mb)
                break
            end
            d.channels(end+1) = struct('name', text_at(mb, c0, 4), ...
                'sn', text_at(mb, c0 + 4, 4), ...
                'cal', double(typecast(mb(c0 + 8 : c0 + 11), 'single')));
        end
    case {'SB49', 'SB41'}
        d.sn = text_at(mb, 13, 8);
        d.data_format = u32(mb, 21);
        d.sample_data_per_record = u32(mb, 25);
    case 'SDIO'
        d.file_duration = u32(mb, 13);
        d.prefix_file = text_at(mb, 17, 40);
end
end

function print_som3(s, show_hex)
fprintf('$SOM3 in %s\n', s.file);
fprintf('  size          %d bytes\n', s.size);
fprintf('  mission name  %s\n', s.mission_name);
fprintf('  vehicle name  %s\n', s.vehicle_name);
fprintf('  firmware      %s\n', s.firmware);
if ~isempty(s.other_text)
    fprintf('  other text    %s\n', strjoin(s.other_text, ' | '));
end
for m = s.modules
    fprintf('  module %-5s %4d bytes at offset %d', m.tag, m.size, m.offset);
    if ~isempty(m.text)
        fprintf('   text: %s', strjoin(m.text, ' | '));
    end
    fprintf('\n');
    d = m.decoded;
    switch m.tag
        case 'EFE4'
            fprintf(['      rev %s, SN %s, %d channels, %d samples/record, %d records/buffer, ' ...
                'SPI %d baud\n'], d.rev, d.sn, d.nb_channel, d.sample_per_record, ...
                d.nb_record_per_buffer, d.spi_baudrate);
            for c = d.channels
                fprintf('      %-4s probe SN %-5s cal %g\n', c.name, c.sn, c.cal);
            end
        case {'SB49', 'SB41'}
            fprintf('      SN %s, data_format %d, %d samples/record\n', d.sn, d.data_format, d.sample_data_per_record);
        case 'SDIO'
            fprintf('      file duration %d, prefix %s\n', d.file_duration, d.prefix_file);
    end
    if show_hex
        hex_dump(m.bytes);
    end
end
end

function hex_dump(b)
for r = 1:16:numel(b)
    row = b(r : min(r + 15, numel(b)));
    asc = char(row);
    asc(row < 32 | row > 126) = '.';
    fprintf('        %04x  %-48s %s\n', r - 1, sprintf('%02x ', row), asc);
end
end

%% Little-endian uint32 at 1-based byte position i
function v = u32(b, i)
v = double(typecast(uint8(b(i : i + 3)), 'uint32'));
end

%% NUL-terminated text in a fixed-width field
function t = text_at(b, i, n)
field = b(i : min(i + n - 1, numel(b)));
nul = find(field == 0, 1);
if ~isempty(nul)
    field = field(1 : nul - 1);
end
t = char(field);
end

%% Runs of 2+ printable characters
function t = readable_text(b)
t = regexp(char(b), '[ -~]{2,}', 'match');
end
