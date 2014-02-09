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
-module(redneck_kernel).
-behaviour(gen_server).

-include("redneck.hrl").

-define(SERVER, ?MODULE).
-define(TAB, ?MODULE).

%% API
-export([start_link/0]).
-export([connect_endpoint/1, disconnect_endpoint/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	terminate/2, code_change/3]).

-type monitors() :: [{{reference(), pid()}, any()}].
-record(state, {
	browse   = undefined :: undefined | {pid(), reference()},
	bref     = undefined :: undefiend | reference(),
	service  = undefined :: undefined | {pid(), reference()},
	sref     = undefined :: undefined | reference(),
	monitors = []        :: monitors()
}).

%%%===================================================================
%%% API functions
%%%===================================================================

%% @private
start_link() ->
	gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

connect_endpoint(Endpoint={?REDNECK_NODE(), ?REDNECK_META{}}) ->
	gen_server:call(?SERVER, {connect_endpoint, Endpoint}).

disconnect_endpoint(Endpoint={?REDNECK_NODE(), ?REDNECK_META{}}) ->
	gen_server:call(?SERVER, {disconnect_endpoint, Endpoint}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init([]) ->
	{ok, #state{}}.

%% @private
handle_call({connect_endpoint, Endpoint={Node=?REDNECK_NODE(Ring), ?REDNECK_META{}}}, _From, State) ->
	ok = redneck_ring:soft_new(Ring),
	ok = redneck_client:connect_endpoint(Endpoint),
	Reply = redneck_client:connect(Node),
	{reply, Reply, State};
handle_call({disconnect_endpoint, Endpoint={Node=?REDNECK_NODE(Ring), ?REDNECK_META{}}}, _From, State) ->
	ok = redneck_client:disconnect_endpoint(Endpoint),
	Reply = redneck_client:disconnect(Node),
	ok = redneck_ring:soft_delete(Ring),
	{reply, Reply, State};
handle_call(_Request, _From, State) ->
	{reply, ignore, State}.

%% @private
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_info(Info, State) ->
	error_logger:error_msg(
		"** ~p ~p unhandled info in ~p/~p~n"
		"   Info was: ~p~n",
		[?MODULE, self(), handle_info, 2, Info]),
	{noreply, State}.

%% @private
terminate(normal, _State) ->
	ok;
terminate(_Reason, _State) ->
	ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
