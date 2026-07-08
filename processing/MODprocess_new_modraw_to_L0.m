function [obj] = MODprocess_new_modraw_to_L0(obj_or_modraw_path)
% [obj_or_data] = MODprocess_new_modraw_to_L0(obj_or_modraw_path)
%
% This function processes all .modraw files in the specified data path to L0
% format using MODprocess_single_modraw_to_L0. It skips the files that have
% already been processed.
%
% Based on epsiProcess_convert_new_raw_to_mat.m from epsilib.
%
% INPUTS
%    mod_class object, obj, with Meta_Data.paths.data.raw pointing to a folder of .modraw files
%   OR
%    modraw_path - string with full path to folder of .modraw files
%
% OUTPUTS
%    mod_class object, obj, with L0 data files created in Meta_Data.paths.data.L0
%

if exist("obj_or_modraw_path","class") && strcmp(class(obj_or_modraw_path),"mod_class")
    obj = obj_or_modraw_path;
    modraw_path = obj.Meta_Data.paths.data.raw;
    version = obj.Meta_Data.PROCESS.raw_files.version; % Get processing version from Meta_Data (default is version 5)
    raw_file_suffix = obj.Meta_Data.PROCESS.raw_file_suffix;
    disp('--- MODprocess_new_modraw_to_L0 ---')
elseif ischar(obj_or_modraw_path) || isstring(obj_or_modraw_path)
    modraw_path = char(obj_or_modraw_path);
    version = 5; % Default processing version
    raw_file_suffix = '.modraw'; % Default raw file suffix
    % Create paths inside obj so that L0 data can be saved
    obj.Meta_Data.paths.data.raw = modraw_path;
    data_root = fileparts(modraw_path); % Assume ../data_root/raw/modraw_file
    obj.Meta_Data.paths.data.L0 = fullfile(data_root,'L0');
    if ~exist(obj.Meta_Data.paths.data.L0,'dir')
        mkdir(obj.Meta_Data.paths.data.L0);
    end
end

% Pull out data directories
dirs = obj.Meta_Data.paths.data;

% Get list of raw files in the data path
list_rawfile = dir(fullfile(modraw_path,['*',raw_file_suffix]));
nfiles = length(list_rawfile);
% Stop if no raw files are found
if nfiles == 0
    disp(['MODprocess_new_modraw_to_L0: No ' raw_file_suffix ' files found in ' modraw_path])
    return
end

% NC - Make matData for output even if there is no new data
% NC - I'm not sure if this is necessary so I'm commenting it out for now (but it might be something I need for real-time processing)
%matData.epsi  = [];
%matData.ctd   = [];
%matData.alt   = [];
%matData.isap  = [];
%matData.act   = [];
%matData.vnav  = [];
%matData.gps   = [];
%matData.seg   = [];
%matData.spec  = [];
%matData.micro = [];
%matData.ttv   = [];
%matData.fluor = [];


% Loop through files and convert to L0 .mat files
for i=1:nfiles

    filename = list_rawfile(i).name;

    if strcmp(filename(1),'.')
        % Sometimes you end up with hidden files that begin with '.'
        % Don't include those in list_rawfile
        % DO NOTHING
    else

        % Get the base name of the file (without suffix)
        indSuffix = strfind(filename,raw_file_suffix);
        base = filename(1:indSuffix-1);

        % Define the L0 file with the same base name
        myL0file = dir(fullfile(dirs.L0, [base '.mat']));

        % If the mat file exists, load it to get the file size of the raw file
        % that created it.
        if ~isempty(myL0file)
            load(fullfile(myL0file.folder,myL0file.name),'raw_file_info')
        end

        % Convert new data to .mat if:
        %   (1) there is no .mat file to match the current raw file, or
        %   (2) the current raw file size is larger than what is saved in mat data 'raw_file_size'
        if ~isempty(myL0file) && list_rawfile(i).bytes<=raw_file_info.bytes && i~=length(list_rawfile)
            % If the L0 file exists and its matching modraw file is equal in size to the ascii file, skip recoverting. All
            % of the raw data has already been converted:
            % DO NOTHING. Load the Meta_Data, because I think you need this in real-time processing, but nothing else.
            % (We always convert the last file, in case it's still being written to)

            old_Meta_Data = load(fullfile(myL0file.folder,myL0file.name),'Meta_Data');
            matData.Meta_Data = old_Meta_Data.Meta_Data;

        elseif (~isempty(myL0file) && list_rawfile(i).bytes>raw_file_info.bytes) || isempty(myL0file)
            % If the L0 file exists already but is older than the raw data
            % file, it will be reconverted. OR, if the L0 file does not exist
            % yet, it will be converted.

            fprintf(1,'%s | raw/%s%s --> L0/%s.mat | ',datestr(now,'YYYY.mm.dd HH:MM:SS'),base,raw_file_suffix,base')

            switch version
                case 5
                    matData = MODprocess_single_modraw_to_L0(fullfile(dirs.raw,filename));
                case 4
                    matData = mod_som_read_epsi_files_v4(fullfile(dirs.raw,filename),obj.Meta_Data);
                case 3
                    [epsi,ctd,alt,act,vnav,gps] = mod_som_read_epsi_files_v3(fullfile(dirs.raw,filename),Meta_Data);
                    make matData epsi ctd alt act vnav gps
                otherwise
                    error('Unsupported raw file version specified. Try using epsiProcess_convert_new_raw_to_mat.m or looking directly at the older scripts it calls for earlier data version.')
            end

            % Add Meta_Data to matData
            matData.Meta_Data = obj.Meta_Data;

            % Add raw_file_info to matData - NC added 8 Aug. 2022
            matData.raw_file_info.bytes = list_rawfile(i).bytes;
            matData.raw_file_info.filename = base;

            % Save data in .mat file
            save(fullfile(dirs.L0,base),'-struct','matData')

            % Clear matData so stale fields from this file can't leak into
            % the next loop iteration (e.g. if the next file hits the
            % "already converted, skip" branch above).
            clear matData

            % NC 1/7/26 - Commenting this out for now since I'm not sure if we need it. MODprocess_update_TimeIndex is in _MAYBE. 
            % if ~isempty(epsi) && isfield(epsi,'time_s')
            %     MODprocess_update_TimeIndex(dirs.L0,base,epsi);
            % elseif isempty(epsi) &&  ~isempty(ctd) && isfield(ctd,'time_s') %For the case where the is no epsi data, but there is ctd data
            %     MODprocess_update_TimeIndex(dirs.L0,base,ctd);
            % end


        end %end if the data should be converted
    end %end if name of file does not begin with '.'
end %end loop through files

end %end function
