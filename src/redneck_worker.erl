%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pagodabox.com>
%%% @copyright 2014, Pagoda Box, Inc.
%%% @doc
%%%
%%% @end
%%% Created :  31 Jan 2014 by Andrew Bennett <andrew@pagodabox.com>
%%%-------------------------------------------------------------------
-module(redneck_worker).

-include("redneck.hrl").

%% API
-export([start_link/5]).

%% proc_lib callbacks
-export([init/5]).

%% Internal API
-export([connect/4, disconnect/4]).

%%%===================================================================
%%% API functions
%%%===================================================================

%% @private
start_link(Endpoint={?REDNECK_NODE(), ?REDNECK_META{}}, Key, Record=?REDIS_SD_DNS{}, Browse=?REDIS_SD_BROWSE{}, Command) ->
	proc_lib:start_link(?MODULE, init, [Endpoint, Key, Record, Browse, Command]).

%%%===================================================================
%%% proc_lib callbacks
%%%===================================================================

%% @private
init(Endpoint, Key, Record, Browse, Command) ->
	ok = proc_lib:init_ack({ok, self()}),
	?MODULE:Command(Endpoint, Key, Record, Browse).

%%%-------------------------------------------------------------------
%%% States
%%%-------------------------------------------------------------------

%% @private
connect(Endpoint, Key, Record, Browse=?REDIS_SD_BROWSE{ref=BrowseRef}) ->
	Status = redneck_kernel:connect_endpoint(Endpoint),
	ok = redneck:connected_endpoint(Endpoint, Key, BrowseRef, Status),
	terminate(normal, Endpoint, Key, Record, Browse).

%% @private
disconnect(Endpoint, Key, Record, Browse) ->
	true = redneck_kernel:disconnect_endpoint(Endpoint),
	terminate(normal, Endpoint, Key, Record, Browse).

%% @private
terminate(Reason, _Endpoint, _Key, _Record, _Browse) ->
	exit(Reason).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
