%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pagodabox.com>
%%% @copyright 2013, Pagoda Box, Inc.
%%% @doc
%%%
%%% @end
%%% Created :  10 Sep 2013 by Andrew Bennett <andrew@pagodabox.com>
%%%-------------------------------------------------------------------
-module(redneck_browser).
-behaviour(redis_sd_browser).

-include_lib("redis_sd_client/include/redis_sd_client.hrl").
-include("redneck.hrl").

%% redis_sd_browser callbacks
-export([browser_init/2, browser_service_add/2, browser_service_remove/2,
	browser_call/3, browser_info/2, browser_terminate/2]).

-record(state, {
	browser = undefined     :: undefined | module(),
	bstate  = undefined     :: undefined | any(),
	name    = undefined     :: undefined | any()
}).

%%%===================================================================
%%% API functions
%%%===================================================================

%%%===================================================================
%%% redis_sd_browser callbacks
%%%===================================================================

%% @private
browser_init(Browse=#browse{name=Name}, Opts) ->
	Browser = get_value(browser, Opts),
	BrowserOpts = get_value(opts, Opts),
	State = #state{browser=Browser, bstate=BrowserOpts, name=Name},
	sub_browser_init(Browse, State).

%% @private
browser_service_add(Record=#dns_sd{txtdata=TXTData}, State) ->
	case is_redneck(TXTData) of
		false ->
			{ok, State};
		true ->
			_ = erlang:spawn(redneck_kernel, connect_node, [Record]),
			sub_browser_service_add(Record, State)
	end.

%% @private
browser_service_remove(Record=#dns_sd{txtdata=TXTData}, State) ->
	case is_redneck(TXTData) of
		false ->
			{ok, State};
		true ->
			_ = erlang:spawn(redneck_kernel, disconnect_node, [Record]),
			sub_browser_service_remove(Record, State)
	end.

%% @private
browser_call(Request, From, State) ->
	sub_browser_call(Request, From, State).

%% @private
browser_info(Info, State) ->
	sub_browser_info(Info, State).

%% @private
browser_terminate(Reason, State) ->
	sub_browser_terminate(Reason, State).

%%%-------------------------------------------------------------------
%%% Sub Browser functions
%%%-------------------------------------------------------------------

%% @private
sub_browser_init(_Browse, State=#state{browser=undefined}) ->
	{ok, State};
sub_browser_init(Browse, State=#state{browser=Browser, bstate=BOpts}) ->
	case Browser:browser_init(Browse, BOpts) of
		{ok, BState} ->
			{ok, State#state{bstate=BState}}
	end.

%% @private
sub_browser_service_add(_Record, State=#state{browser=undefined}) ->
	{ok, State};
sub_browser_service_add(Record, State=#state{browser=Browser, bstate=BState}) ->
	case Browser:browser_service_add(Record, BState) of
		{ok, BState2} ->
			{ok, State#state{bstate=BState2}}
	end.

%% @private
sub_browser_service_remove(_Record, State=#state{browser=undefined}) ->
	{ok, State};
sub_browser_service_remove(Record, State=#state{browser=Browser, bstate=BState}) ->
	case Browser:browser_service_remove(Record, BState) of
		{ok, BState2} ->
			{ok, State#state{bstate=BState2}}
	end.

%% @private
sub_browser_call(_Request, From, State=#state{browser=undefined}) ->
	_ = redis_sd_browser:reply(From, {error, no_browser_defined}),
	{ok, State};
sub_browser_call(Request, From, State=#state{browser=Browser, bstate=BState}) ->
	case Browser:browser_call(Request, From, BState) of
		{noreply, BState2} ->
			{noreply, State#state{bstate=BState2}};
		{reply, Reply, BState2} ->
			{reply, Reply, State#state{bstate=BState2}}
	end.

%% @private
sub_browser_info(Info, State=#state{browser=undefined}) ->
	error_logger:error_msg(
		"** ~p ~p unhandled info in ~p/~p~n"
		"   Info was: ~p~n",
		[?MODULE, self(), sub_browser_info, 2, Info]),
	{ok, State};
sub_browser_info(Info, State=#state{browser=Browser, bstate=BState}) ->
	case Browser:browser_info(Info, BState) of
		{ok, BState2} ->
			{ok, State#state{bstate=BState2}}
	end.

%% @private
sub_browser_terminate(_Reason, #state{browser=undefined}) ->
	ok;
sub_browser_terminate(Reason, #state{browser=Browser, bstate=BState}) ->
	_ = Browser:browser_terminate(Reason, BState),
	ok.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
is_redneck(TXTData) ->
	case get_values([<<"protocol">>, <<"version">>], TXTData) of
		[<<"redneck">>, <<"0">>] ->
			true;
		_ ->
			false
	end.

%% @private
get_values(Keys, Opts) ->
	gv(Keys, Opts, []).

%% @private
gv([], _Opts, Acc) ->
	lists:reverse(Acc);
gv([Key | Keys], Opts, Acc) ->
	case get_value(Key, Opts) of
		undefined ->
			undefined;
		Val ->
			gv(Keys, Opts, [Val | Acc])
	end.

%% @private
get_value(Key, Opts) ->
	get_value(Key, Opts, undefined).

%% @doc Faster alternative to proplists:get_value/3.
%% @private
get_value(Key, Opts, Default) ->
	case lists:keyfind(Key, 1, Opts) of
		{_, Value} -> Value;
		_ -> Default
	end.
