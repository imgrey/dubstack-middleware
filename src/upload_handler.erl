%%
%% Allows to upload objects to Riak CS.
%%
-module(upload_handler).
-behavior(cowboy_handler).

-export([init/2, resource_exists/2, content_types_accepted/2, handle_post/2,
	 allowed_methods/2, previously_existed/2, allow_missing_post/2,
	 content_types_provided/2, is_authorized/2, forbidden/2, to_json/2, extract_rfc2231_filename/1]).

-include("riak.hrl").
-include("user.hrl").
-include("action_log.hrl").
-include("log.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%%
%% Returns callback 'handle_post()'
%% ( called after 'resource_exists()' )
%%
content_types_accepted(Req, State) ->
    {[{{<<"multipart">>, <<"form-data">>, '*'}, handle_post}], Req, State}.

%%
%% Returns callback 'to_json()'
%% ( called after 'forbidden()' )
%%
content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"json">>, []}, to_json}
    ], Req, State}.

%%
%% Serializes response to json
%%
to_json(Req0, State) ->
    {jsx:encode(State), Req0, State}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"POST">>], Req, State}.

%%
%% Checks if content-range header matches size of uploaded data
%%
validate_data_size(DataSize, StartByte, EndByte) ->
    case EndByte of
	undefined -> ok;  % content-range header is not required for small files
	_ ->
	    case (EndByte - StartByte + 1 =/= DataSize) of
		true -> {error, 1};
		false -> true
	    end
    end.

%%
%% Checks if modification time is a valid positive integer timestamp
%%
%% modified_utc is required
validate_modified_time(undefined) ->  {error, 22};
validate_modified_time(ModifiedTime0) ->
    try
	ModifiedTime1 = utils:to_integer(ModifiedTime0),
	ModifiedTime2 = calendar:gregorian_seconds_to_datetime(ModifiedTime1),
	{{Year, Month, Day}, {Hour, Minute, Second}} = ModifiedTime2,
	calendar:datetime_to_gregorian_seconds({{Year, Month, Day}, {Hour, Minute, Second}})
    catch error:badarg -> 
        {error, 22}
    end.

%%
%% Checks timestamp and GUID, if provided.
%%
validate_modified_time(BucketId, GUID, ModifiedTime0)
	when erlang:is_list(GUID) orelse GUID =:= undefined ->
    case validate_modified_time(ModifiedTime0) of
	{error, Number} -> {error, Number};
	ModifiedTime1 ->
	    case GUID of
		undefined -> ModifiedTime1;
		_ ->
		    RealPrefix = utils:prefixed_object_key(?RIAK_REAL_OBJECT_PREFIX, GUID),
		    RiakResponse = riak_api:list_objects(BucketId, [{prefix, RealPrefix}, {marker, undefined}]),
		    case RiakResponse of
			not_found -> {error, 42};
			_ -> ModifiedTime1
		    end
	    end
    end.

add_action_log_record(State) ->
    User = proplists:get_value(user, State),
    BucketId = proplists:get_value(bucket_id, State),
    Prefix = proplists:get_value(prefix, State),
    OrigName = proplists:get_value(orig_name, State),  %% generated name
    TotalBytes = proplists:get_value(total_bytes, State),
    UploadTime = proplists:get_value(upload_time, State),
    ActionLogRecord0 = #riak_action_log_record{
	action="upload",
	user_name=User#user.name,
	tenant_name=User#user.tenant_name,
	timestamp=UploadTime
    },
    UnicodeObjectKey = unicode:characters_to_list(OrigName),
    Summary = lists:flatten([["Uploaded \""], [UnicodeObjectKey],
	[io_lib:format("\" ( ~p B )", [TotalBytes])]]),
    ActionLogRecord1 = ActionLogRecord0#riak_action_log_record{details=Summary},
    action_log:add_record(BucketId, Prefix, ActionLogRecord1).

%%
%% .Net sends UTF-8 filename in "filename*" field, when "filename" contains garbage.
%%
%% Params:
%%
%% [{<<"name">>,<<"files[]">>},
%% {<<"filename">>,
%%  <<"Something.random">>},
%% {<<"filename*">>,
%%  <<"utf-8''Something.random">>}]
%%
extract_rfc2231_filename(FormDataParams) ->
    case proplists:get_value(<<"filename*">>, FormDataParams) of
	undefined -> proplists:get_value(<<"filename">>, FormDataParams);  %% TODO: remove that
	FileName2 ->
	    FileNameByteSize = byte_size(FileName2),
	    if FileNameByteSize < 8 -> undefined;
		true ->
		    case binary:part(FileName2, {0, 7}) of
			<<"utf-8''">> ->
			    FileName4 = binary:part(FileName2, {7, FileNameByteSize-7}),
			    unicode:characters_to_list(cow_qs:urldecode(FileName4));
			_ -> undefined
		    end
	    end
    end.

%%
%% Parse POST fields.
%%
%% modified_utc -- timestamp (UTC)
%% etags[] -- list of MD5
%% prefix -- hex-encoded directory name
%% files[] --
%% force_overwrite -- make server to overwrite file
%% guid -- the key in object storage. It also used to track history of file
%%
acc_multipart(Req0, Acc) ->
    case cowboy_req:read_part(Req0) of
	{ok, Headers0, Req1} ->
    {ok, Body, Req2} = stream_body(Req1, <<>>),
	    Headers1 = maps:to_list(Headers0),
	    {_, DispositionBin} = lists:keyfind(<<"content-disposition">>, 1, Headers1),
	    {<<"form-data">>, Params} = cow_multipart:parse_content_disposition(DispositionBin),
	    {_, FieldName0} = lists:keyfind(<<"name">>, 1, Params),
	    FieldName1 =
		case FieldName0 of
		    <<"modified_utc">> -> last_modified_utc;
		    <<"etags[]">> -> etags;
		    <<"prefix">> -> prefix;
		    <<"files[]">> -> blob;
		    <<"force_overwrite">> -> force_overwrite;
		    <<"guid">> -> guid;
		    _ -> undefined
		end,
	    case FieldName1 of
		blob ->
		    Filename = extract_rfc2231_filename(Params),
		    acc_multipart(Req2, [{blob, Body}, {filename, Filename}|Acc]);
		undefined -> acc_multipart(Req2, Acc);
		_ -> acc_multipart(Req2, [{FieldName1, Body}|Acc])
	    end;
        {done, Req} -> {lists:reverse(Acc), Req}
    end.

%%
%% Reads HTTP request body.
%%
stream_body(Req0, Acc) ->
    case cowboy_req:read_part_body(Req0, #{length => ?FILE_UPLOAD_CHUNK_SIZE + 5000}) of
        {more, Data, Req} -> stream_body(Req, << Acc/binary, Data/binary >>);
        {ok, Data, Req} -> {ok, << Acc/binary, Data/binary >>, Req}
    end.

%%
%% Validates provided content range values and calls 'upload_to_riak()'
%%
handle_post(Req0, State) ->
    case cowboy_req:method(Req0) of
	<<"POST">> ->
	    {FieldValues, Req1} = acc_multipart(Req0, []),
	    FileName0 = proplists:get_value(filename, FieldValues),
	    Etags = proplists:get_value(etags, FieldValues),
	    BucketId = proplists:get_value(bucket_id, State),
	    Prefix0 = list_handler:validate_prefix(BucketId, proplists:get_value(prefix, FieldValues)),
	    %% Current server UTC time
	    %% It is used by desktop client. TODO: use DVV instead
	    GUID0 =
		case proplists:get_value(guid, FieldValues) of
		    undefined -> undefined;
		    <<>> -> undefined;
		    G -> unicode:characters_to_list(G)
		end,
	    ModifiedTime = validate_modified_time(BucketId, GUID0,
						  proplists:get_value(last_modified_utc, FieldValues)),
	    Blob = proplists:get_value(blob, FieldValues),
	    StartByte = proplists:get_value(start_byte, State),
	    EndByte = proplists:get_value(end_byte, State),
	    DataSizeOK =
		case Blob of
		    undefined -> true;
		    _ -> validate_data_size(size(Blob), StartByte, EndByte)
		end,
	    ForceOverwrite =
		case proplists:get_value(force_overwrite, FieldValues) of
		    <<"1">> -> true;
		    _ -> false
		end,
	    case lists:keyfind(error, 1, [Prefix0, ModifiedTime, DataSizeOK]) of
		{error, Number} -> js_handler:bad_request(Req1, Number);
		false ->
		    FileName1 = unicode:characters_to_binary(FileName0),
		    GUID1 =
			case GUID0 of
			    undefined -> utils:to_list(riak_crypto:uuid4());
			    _ -> GUID0
			end,
		    NewState = [
			{etags, Etags},
			{prefix, Prefix0},
			{file_name, FileName1},
			{last_modified_utc, ModifiedTime},
			{force_overwrite, ForceOverwrite},
			{guid, GUID1}
		    ] ++ State,
		    upload_to_riak(Req1, NewState, Blob)
	    end;
	_ -> js_handler:bad_request(Req0, 2)
    end.

%%
%% Compares binary's Md5 and Etag.
%%
%% Returns false in case Etag:
%% - Not valid
%% - Not specified
%% - Not equal to Md5(BinaryData)
%%
%%
validate_md5(undefined, BinaryData) when erlang:is_binary(BinaryData) -> false;
validate_md5(Etag0, BinaryData) when erlang:is_binary(BinaryData) ->
    try utils:unhex(Etag0) of
	Etag1 ->
	    Md5 = riak_crypto:md5(BinaryData),
	    Etag1 =:= Md5
    catch
	error:_ -> false
    end.

%%
%% Creates link to actual object, updates index.
%%
update_index(Req0, State0) ->
    User = proplists:get_value(user, State0),
    UserId = User#user.id,
    Tel =
	case User#user.tel of
	    "" -> undefined;
	    undefined -> undefined;
	    V -> utils:to_list(utils:unhex(utils:to_binary(V)))
	end,
    BucketId = proplists:get_value(bucket_id, State0),
    Prefix = proplists:get_value(prefix, State0),
    ObjectKey = proplists:get_value(object_key, State0),
    OrigName = proplists:get_value(orig_name, State0),
    ModifiedTime = proplists:get_value(last_modified_utc, State0),
    UploadTime = proplists:get_value(upload_time, State0),
    TotalBytes = proplists:get_value(total_bytes, State0),
    GUID = proplists:get_value(guid, State0),
    IsLocked = proplists:get_value(is_locked, State0, false),

    %% Put link to the real object at the specified prefix
    Options = [{acl, public_read}, {meta, [{"orig-filename", OrigName},
					   {"modified-utc", utils:to_list(ModifiedTime)},
					   {"upload-time", UploadTime},
					   {"bytes", utils:to_list(TotalBytes)},
					   {"guid", GUID},
					   {"author-id", UserId},
					   {"author-name", User#user.name},
					   {"author-tel", Tel},
					   {"lock-user-id", UserId},
					   {"is-locked", utils:to_list(IsLocked)},
					   {"lock-modified-utc", UploadTime},
					   {"is-deleted", "false"}]}],
    Response = riak_api:put_object(BucketId, Prefix, ObjectKey, <<>>, Options),
    case Response of
	ok ->
	    %% Update pseudo-directory index for faster listing.
	    case indexing:update(BucketId, Prefix, [{modified_keys, [ObjectKey]},
						    {undelete, [erlang:list_to_binary(ObjectKey)]}]) of
		lock -> js_handler:too_many(Req0);
		_ ->
		    %% Update Solr index if file type is supported
		    %% TODO: uncomment the following
		    %%gen_server:abcast(solr_api, [{bucket_id, BucketId},
		    %% {prefix, Prefix},
		    %% {total_bytes, TotalBytes}]),
		    State1 = [
			{bucket_id, BucketId},
			{prefix, Prefix},
			{upload_time, UploadTime},
			{orig_name, OrigName},
			{total_bytes, proplists:get_value(total_bytes, State0)},
			{user, proplists:get_value(user, State0)}
		    ],
		    add_action_log_record(State1),
		    {true, Req0, []}
	    end;
	{error, Reason} ->
	    ?WARN("[upload_handler] Error: ~p~n", [Reason]),
	    js_handler:incorrect_configuration(Req0, 5)
    end.

%%
%% Picks object name and uploads file to Riak CS
%%
upload_to_riak(Req0, State0, BinaryData) ->
    BucketId = proplists:get_value(bucket_id, State0),
    Prefix = proplists:get_value(prefix, State0),
    PartNumber = proplists:get_value(part_number, State0),
    IsBig = proplists:get_value(is_big, State0),
    FileName = proplists:get_value(file_name, State0),
    ModifiedTime0 = proplists:get_value(last_modified_utc, State0),
    ForceOverwrite = proplists:get_value(force_overwrite, State0),
    Etags = proplists:get_value(etags, State0),
    GUID = proplists:get_value(guid, State0),
    %% Create a bucket if it do not exist
    case riak_api:head_bucket(BucketId) of
	not_found -> riak_api:create_bucket(BucketId);
	_ -> ok
    end,
    IndexContent = indexing:get_index(BucketId, Prefix),
    {ObjectKey, OrigName, IsNewVersion0} = riak_api:pick_object_key(BucketId, Prefix, FileName,
								    ModifiedTime0, IndexContent),
    %% Check the modified time to determine newest object
    UploadTime = io_lib:format("~p", [utils:timestamp()/1000]),

    %% In case client explicitly requests to replace newer file with older file,
    %% it must be overwritten.
    IsNewVersion1 =
	case ForceOverwrite of
	    true -> true;
	    false -> IsNewVersion0
	end,
    case IsNewVersion1 of
	false ->
	    Req1 = cowboy_req:reply(304, #{
		<<"content-type">> => <<"application/json">>
	    }, <<>>, Req0),
	    {true, Req1, []};
	true ->
	    RealPrefix = utils:prefixed_object_key(?RIAK_REAL_OBJECT_PREFIX, GUID),
	    RealKey = utils:format_timestamp(ModifiedTime0),
	    State1 = [{orig_name, OrigName}, {guid, GUID}, {upload_time, UploadTime}],
	    case IsBig of
		true ->
		    case (PartNumber > 1) of
			true ->
			    State2 = [{real_prefix, RealPrefix}, {real_key, RealKey}],
			    check_part(Req0, State0 ++ State1 ++ State2, BinaryData);
			false -> start_upload(Req0, State0 ++ State1, BinaryData)
		    end;
		false ->
		    case validate_md5(Etags, BinaryData) of
			false -> js_handler:bad_request(Req0, 40);
			true ->
			    User = proplists:get_value(user, State0),
			    UserId = User#user.id,
			    Tel =
				case User#user.tel of
				    "" -> undefined;
				    undefined -> undefined;
				    V -> utils:to_list(utils:unhex(utils:to_binary(V)))
				end,
			    %% Put object under service prefix
			    Options = [{acl, public_read}, {meta, [{"orig-filename", OrigName},
								   {"modified-utc", utils:to_list(ModifiedTime0)},
								   {"upload-time", UploadTime},
								   {"guid", GUID},
								   {"author-id", UserId},
								   {"author-name", User#user.name},
								   {"author-tel", Tel},
								   {"lock-user-id", UserId},
								   {"is-locked", "false"},
								   {"lock-modified-utc", UploadTime},
								   {"is-deleted", "false"}]}],
			    riak_api:put_object(BucketId, RealPrefix, RealKey, BinaryData, Options),

			    Req1 = cowboy_req:set_resp_body(jsx:encode([
				{guid, unicode:characters_to_binary(GUID)},
				{orig_name, OrigName},
				{last_modified_utc, ModifiedTime0},
				{object_key, erlang:list_to_binary(ObjectKey)}
			    ]), Req0),
			    State2 = [{orig_name, OrigName}, {object_key, ObjectKey}, {is_locked, false}],
			    update_index(Req1, State0 ++ State1 ++ State2)
		    end
	    end
    end.

%%
%% Checks if upload with provided ID exists and uploads `BinaryData` to Riak CS
%%
check_part(Req0, State, BinaryData) ->
    BucketId = proplists:get_value(bucket_id, State),
    UploadId = proplists:get_value(upload_id, State),
    RealPrefix = proplists:get_value(real_prefix, State),
    RealKey = proplists:get_value(real_key, State),
    RealPath = utils:prefixed_object_key(RealPrefix, RealKey),
    case riak_api:validate_upload_id(BucketId, RealPath, UploadId) of
	not_found -> js_handler:bad_request(Req0, 4);
	{error, _Reason} -> js_handler:bad_request(Req0, 5);
	_ -> upload_part(Req0, State, BinaryData)
    end.

%% @todo: get rid of utils:to_list() by using proper xml binary serialization
parse_etags([K,V | T]) -> [{
	utils:to_integer(K),
	utils:to_list(<<  <<$">>/binary, V/binary, <<$">>/binary >>)
    } | parse_etags(T)];
parse_etags([]) -> [].

upload_part(Req0, State0, BinaryData) ->
    UploadId = proplists:get_value(upload_id, State0),
    BucketId = proplists:get_value(bucket_id, State0),
    Prefix = proplists:get_value(prefix, State0),
    PartNumber = proplists:get_value(part_number, State0),
    Etags0 = proplists:get_value(etags, State0),
    EndByte = proplists:get_value(end_byte, State0),
    TotalBytes = proplists:get_value(total_bytes, State0),
    GUID = proplists:get_value(guid, State0),
    ModifiedTime0 = proplists:get_value(last_modified_utc, State0),

    RealPrefix = utils:prefixed_object_key(?RIAK_REAL_OBJECT_PREFIX, GUID),
    RealPath = utils:prefixed_object_key(RealPrefix, utils:format_timestamp(ModifiedTime0)),
    case riak_api:upload_part(BucketId, RealPath, UploadId, PartNumber, BinaryData) of
	{ok, [{_, NewEtag0}]} ->
	    case (EndByte+1 =:= TotalBytes) of
		true ->
		    case Etags0 =:= undefined of
			true -> js_handler:bad_request(Req0, 5);
			false ->
			    %% parse etags from request to complete upload
			    Etags1 = parse_etags(binary:split(Etags0, <<$,>>, [global])),
			    riak_api:complete_multipart(BucketId, RealPath, UploadId, Etags1),

			    %% Pick object key, as it could have been taken by now
			    MetaData = riak_api:head_object(BucketId, RealPath),
			    FinalEtag = proplists:get_value(etag, MetaData),
			    OrigName0 = proplists:get_value("x-amz-meta-orig-filename", MetaData),
			    OrigName1 = erlang:list_to_binary(OrigName0),
			    UploadTime = io_lib:format("~p", [utils:timestamp()/1000]),
			    IsLocked = proplists:get_value("x-amz-meta-is-locked", MetaData, "false"),

			    %% Update indices
			    IndexContent = indexing:get_index(BucketId, Prefix),
			    {ObjectKey, OrigName2, _IsNewVersion} = riak_api:pick_object_key(
				BucketId, Prefix, OrigName1, ModifiedTime0, IndexContent),

			    %% Create object key in destination prefix and update index
			    State1 = [{user, proplists:get_value(user, State0)}, {bucket_id, BucketId},
				      {prefix, Prefix}, {object_key, ObjectKey}, {orig_name, OrigName2},
				      {last_modified_utc, ModifiedTime0}, {is_locked, IsLocked},
				      {upload_time, UploadTime}, {guid, GUID}, {total_bytes, TotalBytes}],
			    Response = [
				{upload_id, unicode:characters_to_binary(UploadId)},
				{orig_name, OrigName2},
				{end_byte, EndByte},
				{md5, unicode:characters_to_binary(string:strip(FinalEtag, both, $"))},
				{last_modified_utc, ModifiedTime0},
				{guid, unicode:characters_to_binary(GUID)},
				{object_key, erlang:list_to_binary(ObjectKey)}
			    ],
			    Req1 = cowboy_req:set_resp_body(jsx:encode(Response), Req0),
			    update_index(Req1, State1)
		    end;
		false ->
		    <<_:1/binary, NewEtag1:32/binary, _:1/binary>> = unicode:characters_to_binary(NewEtag0),
		    Response = [
			{upload_id, unicode:characters_to_binary(UploadId)},
			{end_byte, EndByte},
			{md5, NewEtag1},
			{guid, unicode:characters_to_binary(GUID)}],
		    Req1 = cowboy_req:set_resp_body(jsx:encode(Response), Req0),
		    {true, Req1, []}
	    end;
	{error, _} -> js_handler:bad_request(Req0, 6)
    end.

%%
%% Creates identifier and uploads first part of data
%%
start_upload(Req0, State, BinaryData) ->
    User = proplists:get_value(user, State),
    UserId = User#user.id,
    Tel =
	case User#user.tel of
	    "" -> undefined;
	    undefined -> undefined;
	    V -> utils:unhex(V)
	end,
    BucketId = proplists:get_value(bucket_id, State),
    EndByte = proplists:get_value(end_byte, State),
    %% The filename is used to pick object name when upload finishes
    FileName = proplists:get_value(file_name, State),
    ModifiedTime = proplists:get_value(last_modified_utc, State),
    UploadTime = proplists:get_value(upload_time, State),
    GUID = proplists:get_value(guid, State),
    TotalBytes = proplists:get_value(total_bytes, State),

    RealPrefix = utils:prefixed_object_key(?RIAK_REAL_OBJECT_PREFIX, GUID),
    RealPath = utils:prefixed_object_key(RealPrefix, utils:format_timestamp(ModifiedTime)),
    Options = [{acl, public_read}, {meta, [{"orig-filename", FileName},
					   {"modified-utc", utils:to_list(ModifiedTime)},
					   {"upload-time", UploadTime},
					   {"bytes", utils:to_list(TotalBytes)},
					   {"guid", GUID},
					   {"author-id", UserId},
					   {"author-name", User#user.name},
					   {"author-tel", Tel},
					   {"lock-user-id", UserId},
					   {"is-locked", "false"},
					   {"lock-modified-utc", UploadTime},
					   {"is-deleted", "false"}
					  ]}],
    MimeType = utils:mime_type(unicode:characters_to_list(FileName)),
    Headers = [{"content-type", MimeType}],

    {ok, [{_, UploadId}]} = riak_api:start_multipart(BucketId, RealPath, Options, Headers),
    {ok, [{_, Etag0}]} = riak_api:upload_part(BucketId, RealPath, UploadId, 1, BinaryData),

    %% Remove quotes from md5
    <<_:1/binary, Etag1:32/binary, _:1/binary>> = unicode:characters_to_binary(Etag0),
    Response = [
	{upload_id, unicode:characters_to_binary(UploadId)},
	{last_modified_utc, ModifiedTime},
	{end_byte, EndByte},
	{md5, Etag1},
	{guid, unicode:characters_to_binary(GUID)}],
    Req1 = cowboy_req:set_resp_body(jsx:encode(Response), Req0),
    {true, Req1, []}.

%%
%% Checks if provided token is correct.
%% ( called after 'allowed_methods()' )
%%
is_authorized(Req0, _State) ->
    utils:is_authorized(Req0).

validate_content_range(Req) ->
    PartNumber =
	try utils:to_integer(cowboy_req:binding(part_num, Req)) of
	    N -> N
	catch error:_ -> 1
	end,
    UploadId0 =
	case cowboy_req:binding(upload_id, Req) of
	    undefined -> undefined;
	    UploadId1 -> erlang:binary_to_list(UploadId1)
	end,
    {StartByte0, EndByte0, TotalBytes0} =
	case cowboy_req:header(<<"content-range">>, Req) of
	    undefined -> {undefined, undefined, undefined};
	    Value ->
		{bytes, Start, End, Total} = cow_http_hd:parse_content_range(Value),
		{Start, End, Total}
	end,
    case TotalBytes0 of
	undefined ->
	    [{part_number, PartNumber},
	     {upload_id, UploadId0},
	     {start_byte, undefined},
	     {end_byte, undefined},
	     {total_bytes, undefined}];
	TotalBytes1 ->
	    case TotalBytes1 > ?FILE_MAXIMUM_SIZE of
		true -> {error, 24};
		false ->
		    case PartNumber > 1 andalso UploadId0 =:= undefined of
			true -> {error, 25};
			false -> [{part_number, PartNumber}, {upload_id, UploadId0},
				  {start_byte, StartByte0}, {end_byte, EndByte0},
				  {total_bytes, TotalBytes0}]
		    end
	    end
    end.

%%
%% Checks the following.
%% - User has access
%% - Bucket ID is correct
%% - Prefix is correct
%% - Part number is correct
%% - content-range request header is specified
%% - file size do not exceed the limit
%%
%% ( called after 'allowed_methods()' )
%%
forbidden(Req0, State0) ->
    BucketId =
	case cowboy_req:binding(bucket_id, Req0) of
	    undefined -> undefined;
	    BV -> erlang:binary_to_list(BV)
	end,
    case utils:is_valid_bucket_id(BucketId, State0#user.tenant_id) of
	true ->
	    UserBelongsToGroup = lists:any(fun(Group) ->
		utils:is_bucket_belongs_to_group(BucketId, State0#user.tenant_id, Group#group.id) end,
		State0#user.groups),
	    case UserBelongsToGroup of
		false -> js_handler:forbidden(Req0, 37);
		true ->
		    case validate_content_range(Req0) of
			{error, Reason} -> js_handler:forbidden(Req0, Reason);
			State1 -> {false, Req0, State1++[{user, State0}, {bucket_id, BucketId}]}
		    end
	    end;
	false -> js_handler:forbidden(Req0, 7)
    end.

%%
%% Check if file size do not exceed the limit
%% ( called after 'content_types_provided()' )
%%
resource_exists(Req0, State) ->
    PartNumber = proplists:get_value(part_number, State),
    TotalBytes = proplists:get_value(total_bytes, State),
    IsBig =
	case TotalBytes =:= undefined of
	    true -> false;
	    false -> (TotalBytes > ?FILE_UPLOAD_CHUNK_SIZE)
	end,
    MaximumPartNumber = (?FILE_MAXIMUM_SIZE div ?FILE_UPLOAD_CHUNK_SIZE),
    case PartNumber < MaximumPartNumber andalso PartNumber >= 1 of
	false -> {false, Req0, []};
	true -> {true, Req0, State ++ [{is_big, IsBig}]}
    end.

previously_existed(Req0, State) ->
    {false, Req0, State}.

allow_missing_post(Req0, State) ->
    {false, Req0, State}.
