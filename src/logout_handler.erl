%%
%% Logs user out.
%%
-module(logout_handler).
-behavior(cowboy_handler).

-export([init/2]).

-include("general.hrl").
-include("riak.hrl").

%%
%% Deletes auth token from DB
%%
-spec revoke_token(binary()) -> ok.

revoke_token(UUID4) when erlang:is_list(UUID4) ->
    PrefixedToken = utils:prefixed_object_key(?TOKEN_PREFIX, UUID4),
    riak_api:delete_object(?SECURITY_BUCKET_NAME, PrefixedToken).


init(Req0, _Opts) ->
    Settings = #general_settings{},
    SessionCookieName = Settings#general_settings.session_cookie_name,
    #{SessionCookieName := SessionID0} = cowboy_req:match_cookies([{SessionCookieName, [], undefined}], Req0),
    case SessionID0 of
	undefined ->
	    %% Try to revoke the bearer token, as this is request to REST API
	    case utils:get_token(Req0) of
		undefined -> ok;
		Token ->
		    case login_handler:check_token(Token) of
			not_found -> ok;
			expired -> revoke_token(Token);
			_User -> revoke_token(Token)
		    end
	    end,
	    Req1 = cowboy_req:reply(200, #{
		<<"content-type">> => <<"application/json">>
	    }, <<"{\"status\": \"ok\"}">>, Req0),
	    {ok, Req1, []};
	_ ->
	    %% Revoke session id, as this is request from browser
	    case login_handler:check_session_id(SessionID0) of
		false -> js_handler:redirect_to_login(Req0);
		{error, Code} -> js_handler:incorrect_configuration(Req0, Code);
		_User ->
		    %% Revoke session and CSRF cookie
		    Req1 = cowboy_req:set_resp_cookie(utils:to_binary(SessionCookieName),
			<<"deleted">>, Req0, #{max_age => 0}),
		    revoke_token(erlang:binary_to_list(SessionID0)),
		    js_handler:redirect_to_login(Req1)
	    end
    end.