%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pagodabox.com>
%%% @copyright 2013, Pagoda Box, Inc.
%%% @doc
%%%
%%% @end
%%% Created :  17 Sep 2013 by Andrew Bennett <andrew@pagodabox.com>
%%%-------------------------------------------------------------------
-module(redneck_event).

-include("redneck.hrl").

%% API
-export([manager/0, add_handler/2]).
-export([nodeup/3, nodedown/3, ringup/2, ringdown/2]).

%%%===================================================================
%%% API functions
%%%===================================================================

manager() ->
	redneck_event.

add_handler(Handler, Pid) ->
	gen_event:add_handler(manager(), Handler, Pid).

nodeup(Ring, Node, {Domain, Type, Service, Instance}) ->
	notify({nodeup, Ring, Node, {Domain, Type, Service, Instance}}).

nodedown(Ring, Node, {Domain, Type, Service, Instance}) ->
	notify({nodedown, Ring, Node, {Domain, Type, Service, Instance}}).

ringup(Ring, {Domain, Type, Service}) ->
	notify({ringup, Ring, {Domain, Type, Service}}).

ringdown(Ring, {Domain, Type, Service}) ->
	notify({ringdown, Ring, {Domain, Type, Service}}).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
notify(Message) ->
	gen_event:notify(manager(), Message).
