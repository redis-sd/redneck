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
-module(redneck_proxy).

-include("redneck.hrl").

%% API
-export([start_link/2]).
-export([init/2]).
-export([loop/4]).

%%%===================================================================
%%% API functions
%%%===================================================================

%% @private
start_link(ProxyTo, Record=#dns_sd{}) when is_pid(ProxyTo) ->
	proc_lib:start_link(?MODULE, init, [ProxyTo, Record]).

%% @private
init(ProxyTo, Record=#dns_sd{}) ->
	Node = redneck_kernel:node(Record),
	case redneck:register_name(Node, self()) of
		yes ->
			ok = proc_lib:init_ack({ok, self()}),
			Monitor = erlang:monitor(process, ProxyTo),
			Timeout = timer:minutes(5),
			loop(ProxyTo, Monitor, Node, Timeout);
		no ->
			ok = redneck:unregister_name(Node),
			ok = proc_lib:init_ack({error, {already_started, redneck:whereis_name(Node)}}),
			erlang:exit(normal)
	end.

%% @private
loop(ProxyTo, Monitor, Node, Timeout) ->
	receive
		{'DOWN', Monitor, process, ProxyTo, Reason} ->
			ok = redneck:unregister_name(Node),
			erlang:exit(Reason);
		Message = '$redneck_disconnect' ->
			ok = redneck:unregister_name(Node),
			ProxyTo ! Message,
			erlang:exit(normal);
		Message = {'$redneck_call', {Pid, Tag}, _Request} when is_pid(Pid) andalso is_reference(Tag) ->
			ProxyTo ! Message,
			loop(ProxyTo, Monitor, Node, Timeout);
		Message = {'$redneck_cast', _Request} ->
			ProxyTo ! Message,
			loop(ProxyTo, Monitor, Node, Timeout);
		Message ->
			ProxyTo ! {'$redneck', Message},
			loop(ProxyTo, Monitor, Node, Timeout)
	after
		Timeout ->
			erlang:hibernate(?MODULE, loop, [ProxyTo, Monitor, Node, Timeout])
	end.
