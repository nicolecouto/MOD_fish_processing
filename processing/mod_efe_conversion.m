function conversion = mod_efe_conversion(n_slots, metadata)
% mod_efe_conversion        Part of MOD_fish_processing
%
% conversion = mod_efe_conversion(n_slots, metadata)
%
% DESCRIPTION
%   Builds the per-channel counts <-> volts/g conversion record for an EFE
%   with n_slots ADC slots: which name each slot gets, its electrical
%   config, and the exact linear map
%       value = counts * scale + offset      (value in V, or g for acc)
%       counts = (value - offset) / scale
%   plus plain-text instructions for recovering counts. This record is
%   stored with the data (L0_data.epsi_conversion, carried on to L1), and
%   is the only place mod_efe_counts_to_volts_g.m and
%   mod_efe_volts_g_to_counts.m get their numbers from, so the written
%   formula and the code can't drift apart.
%
%   Each slot starts from the standard EFE board (MODsetup_default_efe.m)
%   and is overridden by whatever metadata supplies:
%     name        - metadata.PROCESS.channels{slot}
%     type        - metadata.AFE.(name).type
%     full_range  - metadata.AFE.(name).full_range
%     ADCconf     - metadata.AFE.(name).ADCconf
%   A value metadata doesn't supply falls back to the default for that
%   SLOT (not that name), so e.g. a microconductivity probe named c1 in
%   slot 4 keeps slot 4's bipolar 2.5 V config unless setup.yml says
%   otherwise. Each channel records where its name and config came from.
%
% INPUTS
%   n_slots  - number of EFE ADC slots in the data (7 for a standard EFE)
%   metadata - (optional) metadata struct from MODsetup_read_yaml.m, or
%              [] / omitted to use the standard EFE defaults for everything.
%              Uses: PROCESS.channels, PROCESS.Fs_epsi,
%              AFE.(name).type/.full_range/.ADCconf, paths.setup_yml
%              (for the source label only)
%
% OUTPUTS
%   conversion - struct with:
%     README             - char, how to read this record and recover counts
%     source             - char, 'default EFE (MODsetup_default_efe.m)',
%                          the setup.yml path, or that path + ' (partial,
%                          remaining fields from default EFE)'
%     Fs_epsi            - [Hz] nominal sample rate, and Fs_epsi_source
%     bit_counts, gain, acc_offset_V, acc_factor_V_per_g - board constants
%     channels           - cellstr of names in slot order
%     channel.(name)     - struct per channel:
%        slot, field (e.g. 't1_volt', 'a1_g'), unit ('V' or 'g'), type,
%        full_range [V], ADCconf, name_source, config_source,
%        scale [unit/count], offset [unit], how_to_recover_counts (char)
%
% CALLED BY
%   mod_efe_counts_to_volts_g.m, MODvis_spectra_L0.m, MODvis_spectra.m
%
% CALLS
%   MODsetup_default_efe.m
%
% NOTES
%   scale is also one ADC LSB in the channel's own units, which is what
%   the viewers' bit-noise lines use: an N-bit ADC's quantization floor is
%   (scale * 2^(bit_counts - N))^2 / 12 / (Fs/2) in unit^2/Hz.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 2
    metadata = [];
end

def = MODsetup_default_efe();
default_label = 'default EFE (MODsetup_default_efe.m)';
yml_label = 'setup.yml';
if isstruct(metadata) && isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yml_label = metadata.paths.setup_yml;
end

meta_channels = {};
if isstruct(metadata) && isfield(metadata, 'PROCESS') && isfield(metadata.PROCESS, 'channels')
    meta_channels = metadata.PROCESS.channels;
end

conversion = struct();
conversion.README = '';   % filled in below, once the numbers are known
conversion.source = '';
conversion.Fs_epsi = def.PROCESS.Fs_epsi;
conversion.Fs_epsi_source = default_label;
if isstruct(metadata) && isfield(metadata, 'PROCESS') && isfield(metadata.PROCESS, 'Fs_epsi') ...
        && ~isempty(metadata.PROCESS.Fs_epsi)
    conversion.Fs_epsi = metadata.PROCESS.Fs_epsi;
    conversion.Fs_epsi_source = yml_label;
end
conversion.bit_counts = def.EFE.bit_counts;
conversion.gain = def.EFE.gain;
conversion.acc_offset_V = def.EFE.acc_offset_V;
conversion.acc_factor_V_per_g = def.EFE.acc_factor_V_per_g;
conversion.channels = cell(1, n_slots);
conversion.channel = struct();

used_default = false;
used_yml = false;
for slot = 1:n_slots
    if slot > numel(def.PROCESS.channels)
        error('mod_efe_conversion:tooManySlots', ...
            'Data has %d EFE slots but the standard EFE (MODsetup_default_efe.m) only defines %d.', ...
            n_slots, numel(def.PROCESS.channels));
    end
    default_name = def.PROCESS.channels{slot};
    slot_default = def.AFE.(default_name);

    name = default_name;
    name_source = default_label;
    if slot <= numel(meta_channels) && ~isempty(meta_channels{slot})
        name = meta_channels{slot};
        name_source = yml_label;
    end

    meta_afe = struct();
    if isstruct(metadata) && isfield(metadata, 'AFE') && isfield(metadata.AFE, name)
        meta_afe = metadata.AFE.(name);
    end
    ch = slot_default;
    from_yml = {};
    for key = {'type', 'full_range', 'ADCconf'}
        if isfield(meta_afe, key{1}) && ~isempty(meta_afe.(key{1}))
            ch.(key{1}) = meta_afe.(key{1});
            from_yml{end+1} = key{1}; %#ok<AGROW>
        end
    end
    if numel(from_yml) == 3
        config_source = yml_label;
    elseif isempty(from_yml)
        config_source = default_label;
    else
        config_source = sprintf('%s (%s); rest from %s', yml_label, strjoin(from_yml, ', '), default_label);
    end
    used_default = used_default || ~strcmp(name_source, yml_label) || ~strcmp(config_source, yml_label);
    used_yml = used_yml || strcmp(name_source, yml_label) || ~isempty(from_yml);

    conversion.channels{slot} = name;
    conversion.channel.(name) = build_channel(conversion, slot, name, ch, name_source, config_source);
end

if used_yml && used_default
    conversion.source = [yml_label ' (partial, remaining fields from ' default_label ')'];
elseif used_yml
    conversion.source = yml_label;
else
    conversion.source = default_label;
end

conversion.README = build_readme(conversion);

end %end function

%% One channel's entry: config, exact linear map, and recovery text
function c = build_channel(conversion, slot, name, ch, name_source, config_source)
bits = conversion.bit_counts;
FR = ch.full_range / conversion.gain;   % effective full range at the ADC [V]
is_acc = strcmpi(ch.type, 'acc');

switch lower(ch.ADCconf)
    case 'unipolar'
        % V = FR * counts / 2^bits
        scale_V = FR / 2^bits;
        offset_V = 0;
        volt_formula = sprintf('volts = counts * %g/2^%d', FR, bits);
    case 'bipolar'
        % V = FR * (counts / 2^(bits-1) - 1)
        scale_V = FR / 2^(bits-1);
        offset_V = -FR;
        volt_formula = sprintf('volts = counts * %g/2^%d - %g', FR, bits-1, FR);
    otherwise
        error('mod_efe_conversion:unknownADCconf', ...
            'Channel %s (slot %d) has unrecognized ADCconf "%s" - expected Unipolar or Bipolar.', ...
            name, slot, ch.ADCconf);
end

c.slot = slot;
c.type = ch.type;
c.full_range = ch.full_range;
c.ADCconf = ch.ADCconf;
c.name_source = name_source;
c.config_source = config_source;

if is_acc
    % g = (V - acc_offset_V) / acc_factor_V_per_g
    a0 = conversion.acc_offset_V;
    a1 = conversion.acc_factor_V_per_g;
    c.field = [name '_g'];
    c.unit = 'g';
    c.scale = scale_V / a1;
    c.offset = (offset_V - a0) / a1;
    c.how_to_recover_counts = sprintf([ ...
        '%s (slot %d, %s, full_range %g V, accelerometer %g V at 0 g, %g V/g): ' ...
        'volts = %s*%g + %g; counts = %s. ' ...
        'Equivalently counts = round((%s - offset)/scale) with the scale/offset stored here. ' ...
        'Forward: %s; %s = (volts - %g)/%g.'], ...
        name, slot, ch.ADCconf, ch.full_range, a0, a1, ...
        c.field, a1, a0, invert_text(ch.ADCconf, 'volts', FR, bits), ...
        c.field, volt_formula, c.field, a0, a1);
else
    c.field = [name '_volt'];
    c.unit = 'V';
    c.scale = scale_V;
    c.offset = offset_V;
    c.how_to_recover_counts = sprintf([ ...
        '%s (slot %d, %s, full_range %g V): counts = %s. ' ...
        'Equivalently counts = round((%s - offset)/scale) with the scale/offset stored here. ' ...
        'Forward: %s.'], ...
        name, slot, ch.ADCconf, ch.full_range, invert_text(ch.ADCconf, c.field, FR, bits), ...
        c.field, strrep(volt_formula, 'volts', c.field));
end
end

%% "counts = ..." text for one ADC config, in terms of variable v
function s = invert_text(ADCconf, v, FR, bits)
if strcmpi(ADCconf, 'bipolar')
    s = sprintf('(%s + %g) * 2^%d/%g', v, FR, bits-1, FR);
else
    s = sprintf('%s * 2^%d/%g', v, bits, FR);
end
end

%% Plain-text README stored in the record itself
function txt = build_readme(conversion)
lines = {
    'EFE counts -> volts/g conversion used for this data (mod_efe_conversion.m).'
    'Each EFE channel was stored in physical units, not raw ADC counts:'
    '  <name>_volt [V] for every non-accelerometer channel, <name>_g [g] for accelerometers.'
    'The conversion is exactly linear per channel:'
    '  value = counts * scale + offset,   so   counts = round((value - offset) / scale)'
    'with scale [unit/count] and offset [unit] stored in channel.(name).scale/.offset.'
    'scale is also one ADC LSB in that channel''s units.'
    sprintf('ADC: %d bits, gain %g. Unipolar: volts = counts*FR/2^%d. Bipolar: volts = counts*FR/2^%d - FR.', ...
        conversion.bit_counts, conversion.gain, conversion.bit_counts, conversion.bit_counts-1)
    sprintf('Accelerometers: g = (volts - %g) / %g  (%g V at 0 g, %g V/g sensitivity).', ...
        conversion.acc_offset_V, conversion.acc_factor_V_per_g, conversion.acc_offset_V, conversion.acc_factor_V_per_g)
    'Per channel, with the numbers filled in:'
    };
for i = 1:numel(conversion.channels)
    lines{end+1, 1} = ['  ' conversion.channel.(conversion.channels{i}).how_to_recover_counts]; %#ok<AGROW>
end
lines{end+1, 1} = ['Source of names/config: ' conversion.source];
lines{end+1, 1} = 'In code: mod_efe_volts_g_to_counts(epsi, conversion) recovers the counts exactly.';
txt = strjoin(lines, newline);
end
