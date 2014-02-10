%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pagodabox.com>
%%% @copyright 2014, Pagoda Box, Inc.
%%% @doc
%%%
%%% @end
%%% Created :  08 Feb 2013 by Andrew Bennett <andrew@pagodabox.com>
%%%-------------------------------------------------------------------
-module(redneck_proxy).

-include("redneck.hrl").

%% API
-export([start_link/1]).
-export([init/1]).
-export([loop/4]).

%%%===================================================================
%%% API functions
%%%===================================================================

%% @private
start_link(Node=?REDNECK_NODE()) ->
	proc_lib:start_link(?MODULE, init, [Node]).

%% @private
init(Node=?REDNECK_NODE()) ->
	case redneck_internal:register_name({proxy, Node}, self()) of
		yes ->
			ok = proc_lib:init_ack({ok, self()}),
			case redneck_internal:whereis_name({client, Node}) of
				ProxyTo when is_pid(ProxyTo) ->
					Monitor = erlang:monitor(process, ProxyTo),
					Timeout = timer:minutes(5),
					loop(ProxyTo, Monitor, Node, Timeout);
				undefined ->
					ok = redneck_internal:unregister_name(Node),
					erlang:exit({error, no_client})
			end;
		no ->
			ok = redneck:unregister_name(Node),
			ok = proc_lib:init_ack({error, {already_started, redneck_internal:whereis_name({proxy, Node})}}),
			erlang:exit(normal)
	end.

%% @private
loop(ProxyTo, Monitor, Node, Timeout) ->
	receive
		{'DOWN', Monitor, process, ProxyTo, Reason} ->
			ok = redneck_internal:unregister_name({proxy, Node}),
			erlang:exit(Reason);
		Message=?REDNECK_MSG{} ->
			ProxyTo ! Message,
			loop(ProxyTo, Monitor, Node, Timeout);
		{{'$redneck_call', From=?REDNECK_NODE()}, Tag, Request} ->
			ProxyTo ! redneck_msg:new(Node, From, Tag, {'$redneck_call', Request}),
			loop(ProxyTo, Monitor, Node, Timeout);
		Message ->
			ProxyTo ! redneck_msg:new(Node, Message),
			loop(ProxyTo, Monitor, Node, Timeout)
	after
		Timeout ->
			erlang:hibernate(?MODULE, loop, [ProxyTo, Monitor, Node, Timeout])
	end.
