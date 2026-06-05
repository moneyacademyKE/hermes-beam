-module(hermes_agent_ffi).
-export([write_file/2, read_file/1]).

%% Write content (binary) to a file path.
write_file(PathBin, ContentBin) ->
    Path = unicode:characters_to_list(PathBin),
    Content = unicode:characters_to_list(ContentBin),
    case file:write_file(Path, list_to_binary(Content)) of
        ok ->
            {ok, nil};
        {error, Reason} ->
            {error, list_to_binary(atom_to_list(Reason))}
    end.

%% Read a file's content and return it as a binary string.
read_file(PathBin) ->
    Path = unicode:characters_to_list(PathBin),
    case file:read_file(Path) of
        {ok, Data} ->
            {ok, Data};
        {error, Reason} ->
            {error, list_to_binary(atom_to_list(Reason))}
    end.
