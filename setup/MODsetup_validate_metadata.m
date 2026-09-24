function metadata = MODsetup_validate_metadata(metadata, yaml_file, list_of_variables)
% MODsetup_validate_metadata        Part of MOD_fish_processing
%
% metadata = MODsetup_validate_metadata(metadata, yaml_file, list_of_variables)
%
% DESCRIPTION
%   Called as the first thing a processing function does, with the exact
%   list of metadata values that function (and anything it calls in turn)
%   is about to need - already documented in that function's own header.
%   Checks each one against MODsetup_metadata_field_registry.m's lookup
%   table; if everything requested is already present in metadata, this
%   is a cheap no-op and metadata comes back unchanged.
%
%   metadata.PROCESS.CHI.* (and friends) are never silently defaulted
%   anywhere in this repo - MODsetup_read_yaml.m only sets a field when
%   setup.yml actually declares it, since not every deployment needs
%   every value (a FastCTD deployment needs zero chi variables). This
%   function is what fills the gap when a value genuinely is needed and
%   isn't there: it prompts the operator (MODsetup_prompt_value.m -
%   interactive dialog, text fallback, or a hard error under -batch -
%   never fabricates a value on its own).
%
%   What happens after prompting depends on whether the operator saved
%   the answer to setup.yml:
%     - Saved: MODsetup_write_yaml_value.m writes it in, and this function
%       throws 'MODsetup_validate_metadata:yamlUpdated' rather than
%       returning a patched metadata struct. setup.yml is now the single
%       source of truth and every other scan/channel/file this session
%       processes must see the same value metadata currently lacks - so
%       the caller's enclosing loop must catch this identifier, reload
%       metadata fresh via MODsetup_read_yaml.m(metadata.paths.setup_yml),
%       and retry the whole operation from the start, not resume it
%       mid-way with two different metadata structs in play. See
%       processing/MODprocess_all_L1_to_L2.m for the reference retry
%       wrapper.
%     - Declined, or yaml_file is '' (no setup.yml at all - the
%       standalone/hand-built metadata case the (scan, metadata, ...)
%       convention is meant to support): the value is filled directly
%       onto the returned metadata and this function returns normally.
%       Nothing was persisted, so there's nothing for any other call site
%       to get out of sync with - no retry needed, the current call just
%       proceeds with the answer it got.
%
% INPUTS
%   metadata          - metadata struct to check (and possibly patch)
%   yaml_file         - full path to the deployment's setup.yml, or ''
%                        when there is none (standalone usage). Callers
%                        typically pass metadata.paths.setup_yml (empty
%                        string if that field doesn't exist):
%                          yaml_file = '';
%                          if isfield(metadata,'paths') && isfield(metadata.paths,'setup_yml')
%                              yaml_file = metadata.paths.setup_yml;
%                          end
%   list_of_variables - cellstr of short names from
%                        MODsetup_metadata_field_registry.m, e.g.
%                        {'kmin_obs','time_constant_s'}. An unrecognized
%                        name errors immediately (a typo should fail
%                        loud, not silently skip validation).
%
% OUTPUTS
%   metadata - unchanged if everything requested was already present, or
%              patched in-memory with newly-prompted (not saved-to-yaml)
%              values. Never returned after a yaml save - see DESCRIPTION.
%
% CALLED BY
%   mod_scan_get_spectra.m, mod_scan_fpo7_cutoff.m,
%   mod_scan_fpo7_volts_to_Tg_spectrum.m, mod_scan_calc_chi_obs.m,
%   mod_scan_calc_chi_mle.m, mod_scan_calc_epsilon.m,
%   mod_scan_calc_epsilon_obs.m, mod_scan_calc_epsilon_mle.m,
%   mod_scan_shear_accel_coherence.m, mod_scan_shear_volts_to_shear_spectrum.m,
%   mod_L1_detect_profiling_direction.m, modProcess_detect_profiles.m,
%   modProcess_extract_profile.m, MODprocess_single_L1_to_L2.m,
%   mod_L2_tile_scans.m, MODsetup_define_filters.m
%
% CALLS
%   MODsetup_metadata_field_registry.m, MODsetup_prompt_value.m,
%   MODsetup_write_yaml_value.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

registry = MODsetup_metadata_field_registry();
registry_names = {registry.name};

missing_specs = {};
for iV = 1:numel(list_of_variables)
    name = list_of_variables{iV};
    idx = find(strcmp(registry_names, name), 1);
    if isempty(idx)
        error('MODsetup_validate_metadata:unknownField', ...
            '"%s" is not in MODsetup_metadata_field_registry.m - add it there first.', name);
    end
    spec = registry(idx);
    if ~has_nested_field(metadata, spec.metadata_path)
        missing_specs{end+1} = spec; %#ok<AGROW>
    end
end

if isempty(missing_specs)
    return
end

any_saved = false;
resolved_names = cell(1, numel(missing_specs));
for iM = 1:numel(missing_specs)
    spec = missing_specs{iM};
    [value, saved] = MODsetup_prompt_value(spec, yaml_file);
    if saved
        MODsetup_write_yaml_value(yaml_file, spec.yaml_section, spec.yaml_key, value);
        any_saved = true;
    else
        metadata = set_nested_field(metadata, spec.metadata_path, value);
    end
    resolved_names{iM} = spec.name;
end

if any_saved
    error('MODsetup_validate_metadata:yamlUpdated', ...
        ['%s was updated with new value(s) for: %s. metadata must be reloaded ' ...
         '(MODsetup_read_yaml.m) - retry the operation that needed it.'], ...
        MODutil_short_path(yaml_file), strjoin(resolved_names, ', '));
end

end %end function

%% True if every element of a nested field-name path exists in s
function tf = has_nested_field(s, path)
tf = true;
for i = 1:numel(path)
    if ~isstruct(s) || ~isfield(s, path{i})
        tf = false;
        return
    end
    s = s.(path{i});
end
end

%% Sets a possibly-nested field, creating intermediate structs as needed
function s = set_nested_field(s, path, value)
if isscalar(path)
    s.(path{1}) = value;
    return
end
if ~isfield(s, path{1}) || ~isstruct(s.(path{1}))
    s.(path{1}) = struct();
end
s.(path{1}) = set_nested_field(s.(path{1}), path(2:end), value);
end
