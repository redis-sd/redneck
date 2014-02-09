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
-module(redneck_node_event).

-include("redneck.hrl").

-define(MANAGER, redneck_node_manager).

%% API
-export([manager/0, add_handler/2]).
-export([add/1, expire/1, up/1, down/1]).

%%%===================================================================
%%% API functions
%%%===================================================================

manager() ->
	?MANAGER.

add_handler(Handler, Pid) ->
	gen_event:add_handler(manager(), Handler, Pid).

add(Node) ->
	notify({node, add, Node}).

expire(Node) ->
	notify({node, expire, Node}).

up(Node) ->
	notify({node, up, Node}).

down(Node) ->
	notify({node, down, Node}).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
notify(Message) ->
	gen_event:notify(manager(), Message).
