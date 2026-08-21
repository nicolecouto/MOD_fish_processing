function [value, saved] = MODsetup_prompt_value(spec, yaml_file)
% MODsetup_prompt_value        Part of MOD_fish_processing
%
% [value, saved] = MODsetup_prompt_value(spec, yaml_file)
%
% DESCRIPTION
%   Reusable single-value popup: asks the operator what one missing
%   metadata value should be, and (when there's a setup.yml to write it
%   to) whether to save it there for every future run of this deployment.
%   Never fabricates a value on its own - if there is no way to ask (no
%   display and no console to type into, i.e. MATLAB running -batch), it
%   errors clearly rather than silently guessing spec.suggested_default.
%
%   Three tiers, same interactive-vs-batch fallback as
%   MODsetup_pad_raw_filenames.m:
%     1. Interactive (a display is available): a small modal uifigure -
%        "Required variable missing from <setup.yml filename>: <name>"
%        (bold), the description, an edit field pre-filled with
%        spec.suggested_default, a "save to setup.yml" checkbox (checked
%        by default, only shown when yaml_file is non-empty) with the
%        full setup.yml path wrapped underneath it, OK/Cancel.
%     2. No display, but a console to type into: text input() prompt for
%        the value (spec.suggested_default shown as the bracketed
%        default), then a y/n prompt to save (only asked when yaml_file
%        is non-empty).
%     3. MATLAB running -batch (batchStartupOptionUsed): neither prompt
%        is possible - errors immediately naming the missing field.
%   Cancelling the dialog, or entering nothing at the text prompt with no
%   default to fall back on, also errors - "never silently default" means
%   declining to answer cannot silently produce a value either.
%
% INPUTS
%   spec      - one entry from MODsetup_metadata_field_registry.m (needs
%               .name, .description, .yaml_section, .yaml_key,
%               .suggested_default)
%   yaml_file - full path to the deployment's setup.yml, or '' if there
%               is none to write to (e.g. a hand-built metadata struct
%               with no metadata.paths.setup_yml - the standalone-usage
%               case). When '', the "save" question is never asked and
%               saved is always false.
%
% OUTPUTS
%   value - the value the operator provided, same class as
%           spec.suggested_default
%   saved - true if the operator chose to save it to yaml_file (always
%           false when yaml_file is '')
%
% CALLED BY
%   MODsetup_validate_metadata.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

can_offer_save = ~isempty(yaml_file);
interactive = ~batchStartupOptionUsed && feature('ShowFigureWindows');

if interactive
    [value, saved] = prompt_dialog(spec, yaml_file, can_offer_save);
elseif ~batchStartupOptionUsed
    [value, saved] = prompt_text(spec, yaml_file, can_offer_save);
else
    error('MODsetup_prompt_value:batchNoValue', ...
        ['metadata.%s is not set and MATLAB is running non-interactively (-batch), ' ...
         'so there is no way to ask for it. Add "%s: <value>" under "%s:" in %s and ' ...
         'rerun, or call MODsetup_prompt_value interactively once to fill it in.'], ...
        strjoin(spec.metadata_path, '.'), spec.yaml_key, spec.yaml_section, MODutil_short_path(yaml_file));
end

end %end function

%% Modal uifigure prompt - styled on MODsetup_pad_raw_filenames.m's dialog
function [value, saved] = prompt_dialog(spec, yaml_file, can_offer_save)
dlg_w = 480;
dlg_h = 400;
root_units = get(groot, 'Units');
cleanup_units = onCleanup(@() set(groot, 'Units', root_units));
set(groot, 'Units', 'pixels');
scr = get(groot, 'ScreenSize');
dlg_pos = [scr(1) + (scr(3) - dlg_w)/2, scr(2) + (scr(4) - dlg_h)/2, dlg_w, dlg_h];

fig = uifigure('Visible', 'on', 'Position', dlg_pos, 'Name', 'MODsetup_prompt_value');
fig.UserData = struct('ok', false);

if can_offer_save
    [~, yaml_name, yaml_ext] = fileparts(yaml_file);
    header_text = sprintf('Required variable missing from %s:', [yaml_name yaml_ext]);
else
    header_text = 'Required variable missing (no setup.yml file for this call):';
end
uilabel(fig, 'Position', [20, 345, dlg_w - 40, 34], 'Text', header_text, ...
    'WordWrap', 'on', 'VerticalAlignment', 'top');

uilabel(fig, 'Position', [20, 315, dlg_w - 40, 24], 'Text', spec.name, ...
    'FontWeight', 'bold', 'FontSize', 13);

uilabel(fig, 'Position', [20, 255, dlg_w - 40, 50], 'Text', spec.description, ...
    'WordWrap', 'on', 'VerticalAlignment', 'top');

if isnumeric(spec.suggested_default)
    default_str = sprintf('%.10g', spec.suggested_default);
else
    default_str = char(spec.suggested_default);
end
uilabel(fig, 'Position', [20, 230, dlg_w - 40, 20], ...
    'Text', sprintf('Commonly used value: %s', default_str), 'FontColor', [0.4 0.4 0.4]);

uilabel(fig, 'Position', [20, 195, 60, 22], 'Text', 'Value:');
is_numeric = isnumeric(spec.suggested_default);
if is_numeric
    value_field = uieditfield(fig, 'numeric', 'Position', [85, 193, 200, 26], ...
        'Value', spec.suggested_default, 'Limits', [-Inf, Inf]);
else
    value_field = uieditfield(fig, 'text', 'Position', [85, 193, 200, 26], ...
        'Value', char(spec.suggested_default));
end

if can_offer_save
    uilabel(fig, 'Position', [20, 163, dlg_w - 40, 20], ...
        'Text', sprintf('Will be saved to setup file as "%s: %s" if checked below.', ...
            spec.yaml_section, spec.yaml_key), ...
        'FontColor', [0.4 0.4 0.4]);

    save_box = uicheckbox(fig, 'Position', [20, 125, dlg_w - 40, 22], ...
        'Text', 'Save to setup file:', 'Value', true);

    uilabel(fig, 'Position', [40, 88, dlg_w - 60, 32], 'Text', yaml_file, ...
        'WordWrap', 'on', 'VerticalAlignment', 'top', 'FontColor', [0.4 0.4 0.4]);
else
    save_box = [];
end

uibutton(fig, 'Position', [dlg_w - 190, 15, 80, 30], 'Text', 'OK', ...
    'ButtonPushedFcn', @(~, ~) prompt_dialog_button(fig, true));
uibutton(fig, 'Position', [dlg_w - 100, 15, 80, 30], 'Text', 'Cancel', ...
    'ButtonPushedFcn', @(~, ~) prompt_dialog_button(fig, false));

uiwait(fig);
result = fig.UserData;
ok = result.ok;
if ok
    value = value_field.Value;
    if is_numeric && isnan(value)
        ok = false; % numeric edit field left blank/invalid
    end
    if can_offer_save
        saved = save_box.Value;
    else
        saved = false;
    end
end
if isvalid(fig)
    delete(fig);
end

if ~ok
    error('MODsetup_prompt_value:cancelled', ...
        'No value provided for metadata.%s - cannot continue.', strjoin(spec.metadata_path, '.'));
end
end

function prompt_dialog_button(fig, ok)
fig.UserData.ok = ok;
uiresume(fig);
end

%% Text-console fallback (no display, e.g. MATLAB through a plain terminal)
function [value, saved] = prompt_text(spec, yaml_file, can_offer_save)
fprintf('\nmetadata.%s is not set.\n  %s\n', strjoin(spec.metadata_path, '.'), spec.description);
if is_numeric_default(spec)
    default_str = sprintf('%.10g', spec.suggested_default);
else
    default_str = char(spec.suggested_default);
end
resp = strtrim(input(sprintf('Value [%s]: ', default_str), 's'));
if isempty(resp)
    value = spec.suggested_default;
else
    if is_numeric_default(spec)
        value = str2double(resp);
        if isnan(value)
            error('MODsetup_prompt_value:invalidNumber', ...
                '"%s" is not a valid number for metadata.%s.', resp, strjoin(spec.metadata_path, '.'));
        end
    else
        value = resp;
    end
end

saved = false;
if can_offer_save
    resp = input(sprintf('Save to %s? y/n: ', MODutil_short_path(yaml_file)), 's');
    saved = strcmpi(strtrim(resp), 'y');
end
end

function tf = is_numeric_default(spec)
tf = isnumeric(spec.suggested_default);
end
