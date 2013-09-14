%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pagodabox.com>
%%% @copyright 2013, Pagoda Box, Inc.
%%% @doc
%%%
%%% @end
%%% Created :  05 Sep 2013 by Andrew Bennett <andrew@pagodabox.com>
%%%-------------------------------------------------------------------
-module(redneck_sup).
-behaviour(supervisor).

-include("redneck.hrl").

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

init([]) ->
	redneck_names = ets:new(redneck_names, [ordered_set, public, named_table]),
	RedneckSpec = {redneck,
		{redneck, start_link, []},
		permanent, 5000, worker, [redneck]},
	{NbAcceptors, Transport, TransOpts, Handler, HandlerOpts} = server_config(),
	ServerSpec = ranch:child_spec(redneck_server, NbAcceptors, Transport,
		TransOpts, redneck_protocol, {Handler, HandlerOpts}),
	KernelSpec = {redneck_kernel,
		{redneck_kernel, start_link, []},
		permanent, 5000, worker, [redneck_kernel]},
	%% five restarts in 60 seconds, then shutdown
	Restart = {rest_for_one, 5, 60},
	{ok, {Restart, [RedneckSpec, ServerSpec, KernelSpec]}}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
server_config() ->
	Defaults = [
		{acceptors, 4},
		{transport, ranch_tcp},
		{transport_opts, [
			{port, 0}
		], merge},
		{handler, redneck_handler},
		{handler_opts, []}
	],
	Config = merge(Defaults, application:get_env(redneck, server, [])),
	{
		proplists:get_value(acceptors, Config),
		proplists:get_value(transport, Config),
		proplists:get_value(transport_opts, Config),
		proplists:get_value(handler, Config),
		proplists:get_value(handler_opts, Config)
	}.

%% @private
merge([], Config) ->
	Config;
merge([{Key, Val} | KeyVals], Config) ->
	case lists:keyfind(Key, 1, Config) of
		false ->
			merge(KeyVals, [{Key, Val} | Config]);
		_ ->
			merge(KeyVals, Config)
	end;
merge([{Key, Val, merge} | KeyVals], Config) ->
	case lists:keytake(Key, 1, Config) of
		{value, {Key, OldVal}, Config2} ->
			merge(KeyVals, [{Key, merge(Val, OldVal)} | Config2]);
		false ->
			merge(KeyVals, [{Key, Val} | Config])
	end.
