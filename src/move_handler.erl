%%
%% Allows to move objects and pseudo-directories.
%%
-module(move_handler).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2, content_types_accepted/2,
	 to_json/2, allowed_methods/2, is_authorized/2, forbidden/2,
	 handle_post/2]).

-include("riak.hrl").
-include("user.hrl").
-include("action_log.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%%
%% Returns callback 'handle_post()'
%% ( called after 'resource_exists()' )
%%
content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, handle_post}], Req, State}.

%%
%% Returns callback 'to_json()'
%% ( called after 'forbidden()' )
%%
content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"json">>, []}, to_json}
    ], Req, State}.

%%
%% Validates POST request and sends request to Riak CS to copy objects and delete them
%%
handle_post(Req0, State0) ->
    case cowboy_req:method(Req0) of
	<<"POST">> ->
	    SrcBucketId = proplists:get_value(src_bucket_id, State0),
	    DstBucketId = proplists:get_value(dst_bucket_id, State0),
	    SrcPrefix0 = proplists:get_value(src_prefix, State0),
	    DstPrefix0 = proplists:get_value(dst_prefix, State0),
	    SrcObjectNames0 = proplists:get_value(src_object_names, State0),
	    User = proplists:get_value(user, State0),
	    case copy_handler:validate_post(SrcPrefix0, DstPrefix0, SrcObjectNames0) of
		{error, Number} -> js_handler:bad_request(Req0, Number);
		State1 ->
		    State2 = State1 ++ [
			{src_bucket_id, SrcBucketId},
			{dst_bucket_id, DstBucketId},
			{user, User}
		    ],
		    move(Req0, State2)
	    end;
	_ -> js_handler:bad_request(Req0, 16)
    end.

move(Req0, State) ->
    SrcBucketId = proplists:get_value(src_bucket_id, State),
    SrcPrefix0 = proplists:get_value(src_prefix, State),
    SrcObjectNames = proplists:get_value(src_object_names, State),
    DstBucketId = proplists:get_value(dst_bucket_id, State),
    DstPrefix0 = proplists:get_value(dst_prefix, State),
    ObjectNamesToMove0 = lists:map(
       fun(N) ->
	    case utils:ends_with(N, <<"/">>) of
		true ->
		    ON = string:to_lower(erlang:binary_to_list(N)),  %% lowercase hex prefix
		    riak_api:recursively_list_pseudo_dir(SrcBucketId, utils:prefixed_object_name(SrcPrefix0, ON));
		false -> [utils:prefixed_object_name(SrcPrefix0, erlang:binary_to_list(N))]
	    end
       end, SrcObjectNames),
    ObjectKeysToMove1 = lists:foldl(fun(X, Acc) -> X ++ Acc end, [], ObjectNamesToMove0),

    SrcIndexPath = utils:prefixed_object_name(SrcPrefix0, ?RIAK_INDEX_FILENAME),
    SrcIndexPaths = [IndexPath || IndexPath <- ObjectKeysToMove1, lists:suffix(?RIAK_INDEX_FILENAME, IndexPath)
			] ++ [SrcIndexPath],
    CopiedObjects0 = [copy_handler:copy_objects(SrcBucketId, DstBucketId, SrcPrefix0, DstPrefix0, ObjectKeysToMove1, I)
		     || I <- SrcIndexPaths],
    CopiedObjects1 = lists:foldl(fun(X, Acc) -> X ++ Acc end, [], CopiedObjects0),
    %% Delete objects in previous place
    lists:map(
	fun(I) ->
	    SrcPrefix = proplists:get_value(src_prefix, I),
	    OldKey = proplists:get_value(old_key, I),
	    PrefixedObjectKey = utils:prefixed_object_name(SrcPrefix, OldKey),
	    riak_api:delete_object(SrcBucketId, PrefixedObjectKey)
	end, CopiedObjects1),
    %% Delete pseudo-directories
    lists:map(
	fun(I) ->
	    ActionLogPath = utils:prefixed_object_name(filename:dirname(I), ?RIAK_ACTION_LOG_FILENAME),
	    riak_api:delete_object(SrcBucketId, ActionLogPath),
	    riak_api:delete_object(SrcBucketId, I)
	end, lists:droplast(SrcIndexPaths)),
    riak_index:update(SrcBucketId, SrcPrefix0),
    %%
    %% Add action log record
    %%
    MovedDirectories =
	case length(SrcIndexPaths) > 1 of
	    true ->
		    lists:map(
			fun(I) ->
			    D = utils:unhex(erlang:list_to_binary(filename:basename(filename:dirname(I)))),
			    [[" \""], unicode:characters_to_list(D), ["/\""]]
			end, lists:droplast(SrcIndexPaths));
	    false -> [" "]
	end,
    MovedObjects2 = lists:map(
	fun(I) ->
	    case proplists:get_value(src_orig_name, I) =:= proplists:get_value(dst_orig_name, I) of
		true -> [[" \""], unicode:characters_to_list(proplists:get_value(dst_orig_name, I)), "\""];
		false -> [[" \""], unicode:characters_to_list(proplists:get_value(src_orig_name, I)), ["\""],
			  [" as \""], unicode:characters_to_list(proplists:get_value(dst_orig_name, I)), ["\""]]
	    end
	end, [J || J <- CopiedObjects1, proplists:get_value(src_prefix, J) =:= filename:dirname(SrcIndexPath)]),
    User = proplists:get_value(user, State),
    ActionLogRecord0 = #riak_action_log_record{
	action="copy",
	user_name=User#user.name,
	tenant_name=User#user.tenant_name,
	timestamp=io_lib:format("~p", [utils:timestamp()])
    },
    SrcPrefix1 =
	case SrcPrefix0 of
	    undefined -> "/";
	    _ -> unicode:characters_to_list(utils:unhex_path(SrcPrefix0)) ++ ["/"]
	end,
    Summary0 = lists:flatten([["Moved"], MovedDirectories ++ MovedObjects2,
			     ["\" from \"", SrcPrefix1, "\"."]]),
    ActionLogRecord1 = ActionLogRecord0#riak_action_log_record{details=Summary0},
    action_log:add_record(DstBucketId, DstPrefix0, ActionLogRecord1),
    DstPrefix1 =
	case DstPrefix0 of
	    undefined -> "/";
	    _ -> unicode:characters_to_list(utils:unhex_path(DstPrefix0))++["/"]
	end,
    Summary1 = lists:flatten([["Moved"], MovedDirectories ++ MovedObjects2,
			     [" to \""], [DstPrefix1, "\"."]]),
    ActionLogRecord2 = ActionLogRecord0#riak_action_log_record{details=Summary1},
    action_log:add_record(SrcBucketId, SrcPrefix0, ActionLogRecord2),
    {true, Req0, []}.

%%
%% Serializes response to json
%%
to_json(Req0, State) ->
    {"{\"status\": \"ok\"}", Req0, State}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"POST">>], Req, State}.

%%
%% Checks if provided token is correct.
%% ( called after 'allowed_methods()' )
%%
is_authorized(Req0, _State) ->
    case utils:check_token(Req0) of
	undefined -> {{false, <<"Token">>}, Req0, []};
	not_found -> {{false, <<"Token">>}, Req0, []};
	expired -> {{false, <<"Token">>}, Req0, []};
	User -> {true, Req0, [{user, User}]}
    end.

%%
%% Checks if user has access
%% - To source bucket
%% - To destination bucket
%%
%% ( called after 'is_authorized()' )
%%
forbidden(Req0, State) ->
    copy_handler:copy_forbidden(Req0, State).
