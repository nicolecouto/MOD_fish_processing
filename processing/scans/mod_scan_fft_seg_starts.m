function fft_seg_starts = mod_scan_fft_seg_starts(fft_length, fft_segments_per_scan)
% mod_scan_fft_seg_starts        Part of MOD_fish_processing
%
% fft_seg_starts = mod_scan_fft_seg_starts(fft_length, fft_segments_per_scan)
%
% DESCRIPTION
%   Within-scan Welch segment start offsets (1-based, relative to a scan's
%   own first sample) for fft_segments_per_scan segments of fft_length
%   samples at the hardcoded 50% intra-scan overlap (see docs/concepts/
%   spectral_windowing.md - the 1.9 Nuttall dof factor, mod_scan_dof.m, is
%   only valid at exactly 50% overlap, which is why this isn't a tunable
%   fraction). A scan built to mod_scan_length_from_segments.m's
%   scan_length always tiles exactly fft_segments_per_scan segments with
%   no leftover samples, so this needs no data, just the two parameters
%   that determine it - the same offsets apply to every scan.
%
% INPUTS
%   fft_length             - Welch segment length [samples]
%   fft_segments_per_scan  - number of segments per scan
%
% OUTPUTS
%   fft_seg_starts - 1 x fft_segments_per_scan, 1-based sample offset of
%                    each segment's first sample, relative to a scan's own
%                    first sample. A scan's absolute per-segment start
%                    indices are scan_idx0 + fft_seg_starts - 1.
%
% CALLED BY
%   mod_L2_tile_scans.m, mod_scan_get_spectra.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

noverlap = round(0.5 * fft_length);
step = fft_length - noverlap;
fft_seg_starts = (0:(fft_segments_per_scan - 1)) * step + 1;

end %end function
