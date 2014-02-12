%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pagodabox.com>
%%% @copyright 2014, Pagoda Box, Inc.
%%% @doc
%%%
%%% @end
%%% Created :  05 Sep 2013 by Andrew Bennett <andrew@pagodabox.com>
%%%-------------------------------------------------------------------
-module(redneck_sup).
-behaviour(supervisor).

-include("redneck.hrl").

-define(SERVER, ?MODULE).

%% API
-export([start_link/0]).
-export([node_spec/3, start_node/3, start_client/1, start_worker/5, stop_node/1, stop_client/1]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link() ->
	supervisor:start_link({local, ?SERVER}, ?MODULE, []).

node_spec(Mod, Args, ServiceConfig) ->
	Service = case ServiceConfig of
		?REDIS_SD_SERVICE{} ->
			ServiceConfig;
		_ ->
			redneck_config:list_to_service(ServiceConfig)
	end,
	Name = Service?REDIS_SD_SERVICE.name,
	{{redneck_node, Name},
		{redneck_node, start_link, [Mod, Args, Service]},
		transient, 3000, worker, [redneck_node]}.

start_node(Mod, Args, ServiceConfig) ->
	NodeSpec = node_spec(Mod, Args, ServiceConfig),
	supervisor:start_child(?SERVER, NodeSpec).

start_client(Node=?REDNECK_NODE()) ->
	ClientSupSpec = {{redneck_client_sup, Node},
		{redneck_client_sup, start_link, [Node]},
		transient, 3000, supervisor, [redneck_client_sup]},
	supervisor:start_child(?SERVER, ClientSupSpec).

start_worker(Endpoint={?REDNECK_NODE(), ?REDNECK_META{}}, Key, Record=?REDIS_SD_DNS{}, Browse=?REDIS_SD_BROWSE{}, Command) ->
	WorkerSpec = worker_spec(Endpoint, Key, Record, Browse, Command),
	supervisor:start_child(?SERVER, WorkerSpec).

stop_node(ServiceName) ->
	catch redneck_node:stop(ServiceName),
	SupName = {redneck_node, ServiceName},
	case supervisor:terminate_child(?SERVER, SupName) of
		{error, not_found} ->
			ok;
		ok ->
			supervisor:delete_child(?SERVER, SupName);
		Error ->
			Error
	end.

stop_client(Node=?REDNECK_NODE()) ->
	SupName = {redneck_client_sup, Node},
	case supervisor:terminate_child(?SERVER, SupName) of
		{error, not_found} ->
			ok;
		ok ->
			supervisor:delete_child(?SERVER, SupName);
		Error ->
			Error
	end.

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

init([]) ->
	redneck = ets:new(redneck, [ordered_set, public, named_table]),
	redneck_internal = ets:new(redneck_internal, [ordered_set, public, named_table]),
	ManagerSpec = {redneck_event:manager(),
		{gen_event, start_link, [{local, redneck_event:manager()}]},
		permanent, 5000, worker, [gen_event]},
	RingManagerSpec = {redneck_ring_event:manager(),
		{gen_event, start_link, [{local, redneck_ring_event:manager()}]},
		permanent, 5000, worker, [gen_event]},
	NodeManagerSpec = {redneck_node_event:manager(),
		{gen_event, start_link, [{local, redneck_node_event:manager()}]},
		permanent, 5000, worker, [gen_event]},
	RedneckInternalSpec = {redneck_internal,
		{redneck_internal, start_link, []},
		permanent, 5000, worker, [redneck_internal]},
	RedneckSpec = {redneck,
		{redneck, start_link, []},
		permanent, 5000, worker, [redneck]},
	{NbAcceptors, Transport, TransOpts, Handler, HandlerOpts} = server_config(),
	ServerSpec = ranch:child_spec(redneck_tcp_server, NbAcceptors, Transport,
		TransOpts, redneck_tcp_server, {Handler, HandlerOpts}),
	KernelSpec = {redneck_kernel,
		{redneck_kernel, start_link, []},
		permanent, 5000, worker, [redneck_kernel]},
	%% five restarts in 60 seconds, then shutdown
	Restart = {rest_for_one, 5, 60},
	{ok, {Restart, [
		ManagerSpec,
		RingManagerSpec,
		NodeManagerSpec,
		RedneckInternalSpec,
		RedneckSpec,
		ServerSpec,
		KernelSpec
	]}}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
worker_spec(Endpoint, Key, Record=?REDIS_SD_DNS{}, Browse=?REDIS_SD_BROWSE{ref=Ref}, Command) ->
	{{redneck_worker, Ref, Key, Endpoint, Command},
		{redneck_worker, start_link, [Endpoint, Key, Record, Browse, Command]},
		temporary, brutal_kill, worker, [redneck_worker]}.

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
