function scan_length = mod_scan_length_from_segments(fft_length, fft_segments_per_scan)
% mod_scan_length_from_segments        Part of MOD_fish_processing
%
% scan_length = mod_scan_length_from_segments(fft_length, fft_segments_per_scan)
%
% DESCRIPTION
%   scan_length = fft_length*(fft_segments_per_scan+1)/2 - the total
%   number of samples needed for fft_segments_per_scan Welch segments of
%   length fft_length to exactly tile a scan at a hardcoded 50% overlap
%   (matching mod_scan_get_spectra.m's FFT_OVERLAP constant). Exact
%   integer whenever fft_length is even (true for any power of 2 - see
%   MODsetup_metadata_field_registry.m's fft_length entry).
%
%   Single place that turns fft_length/fft_segments_per_scan into a scan
%   sample count, so mod_L2_tile_scans.m and MODplot_scan_context.m can't
%   disagree on it - same "single source of truth" rationale as
%   toolbox/mod_scan_dof.m.
%
% INPUTS
%   fft_length             - FFT segment length [samples]
%                             (metadata.PROCESS.fft_length)
%   fft_segments_per_scan  - number of Welch segments per scan
%                             (metadata.PROCESS.fft_segments_per_scan)
%
% OUTPUTS
%   scan_length - total scan length [samples]
%
% CALLED BY
%   mod_L2_tile_scans.m, MODplot_scan_context.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

scan_length = fft_length * (fft_segments_per_scan + 1) / 2;

if mod(scan_length, 1) ~= 0
    error('mod_scan_length_from_segments:notInteger', ...
        ['fft_length=%d and fft_segments_per_scan=%d give a non-integer scan_length ' ...
         '(%.2f samples) at 50%% overlap - fft_length must be even.'], ...
        fft_length, fft_segments_per_scan, scan_length);
end

end %end function
