%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pagodabox.com>
%%% @copyright 2014, Pagoda Box, Inc.
%%% @doc
%%%
%%% @end
%%% Created :  07 Feb 2014 by Andrew Bennett <andrew@pagodabox.com>
%%%-------------------------------------------------------------------
-module(redneck_client_sup).
-behaviour(supervisor).

-include("redneck.hrl").

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link(Node=?REDNECK_NODE()) ->
	supervisor:start_link({via, redneck_internal, {client_sup, Node}}, ?MODULE, Node).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

init(Node=?REDNECK_NODE()) ->
	TCPClientSpec = {redneck_tcp_client,
		{redneck_tcp_client, start_link, [Node]},
		transient, 2000, worker, [redneck_tcp_client]},
	ClientSpec = {redneck_client,
		{redneck_client, start_link, [Node]},
		transient, 2000, worker, [redneck_client]},
	ProxySpec = {redneck_proxy,
		{redneck_proxy, start_link, [Node]},
		transient, 2000, worker, [redneck_proxy]},
	%% five restarts in 60 seconds, then shutdown
	Restart = {rest_for_one, 5, 60},
	{ok, {Restart, [TCPClientSpec, ClientSpec, ProxySpec]}}.
