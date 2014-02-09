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
-module(redneck_client).

-include("redneck.hrl").

%% API
-export([start_link/1]).
-export([connect_endpoint/1, connect/1, disconnect_endpoint/1, disconnect/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	terminate/2, code_change/3]).

-record(state, {
	node = undefined :: undefined | redneck_node(),
	meta = undefined :: undefined | redneck_meta()
}).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link(Node=?REDNECK_NODE()) ->
	gen_server:start_link({via, redneck_internal, {client, Node}}, ?MODULE, Node, []).

connect_endpoint({Node=?REDNECK_NODE(), Meta=?REDNECK_META{}}) ->
	case start_client(Node) of
		ok ->
			gen_server:call({via, redneck_internal, {client, Node}}, {connect_endpoint, Meta});
		StartClientError ->
			StartClientError
	end.

connect(Node=?REDNECK_NODE()) ->
	case start_client(Node) of
		ok ->
			gen_server:call({via, redneck_internal, {client, Node}}, is_connected);
		StartClientError ->
			StartClientError
	end.

disconnect_endpoint({Node=?REDNECK_NODE(), Meta=?REDNECK_META{}}) ->
	gen_server:cast({via, redneck_internal, {client, Node}}, {disconnect_endpoint, Meta}).

disconnect(Node=?REDNECK_NODE()) ->
	case redneck_internal:whereis_name({client, Node}) of
		Pid when is_pid(Pid) ->
			gen_server:call(Pid, disconnect);
		undefined ->
			true
	end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init(Node=?REDNECK_NODE()) ->
	State = #state{node=Node},
	{ok, State}.

%% @private
handle_call({connect_endpoint, Meta}, _From, State=#state{meta=Meta}) ->
	{reply, ok, State};
handle_call({connect_endpoint, Meta}, _From, State=#state{node=Node}) ->
	Reply = redneck_tcp_client:connect_endpoint({Node, Meta}),
	{reply, Reply, State};
handle_call(disconnect, _From, State=#state{node=Node}) ->
	Reply = redneck_tcp_client:disconnect(Node),
	{stop, normal, Reply, State};
handle_call(is_connected, _From, State=#state{node=Node}) ->
	Reply = redneck_tcp_client:is_connected(Node),
	{reply, Reply, State};
handle_call(_Request, _From, Node) ->
	{reply, ignore, Node}.

%% @private
handle_cast({disconnect_endpoint, Meta}, State=#state{node=Node}) ->
	ok = redneck_tcp_client:disconnect_endpoint({Node, Meta}),
	State2 = State#state{meta=undefined},
	{noreply, State2};
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_info(Msg=?REDNECK_MSG{to=Node}, State=#state{node=Node}) ->
	catch redneck_internal:send({tcp_client, Node}, Msg),
	{noreply, State};
handle_info(Info, State) ->
	error_logger:error_msg(
		"** ~p ~p unhandled info in ~p/~p~n"
		"   Info was: ~p~n",
		[?MODULE, self(), handle_info, 2, Info]),
	{noreply, State}.

%% @private
terminate(_Reason, _State) ->
	ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
start_client(Node=?REDNECK_NODE()) ->
	case redneck_sup:start_client(Node) of
		{ok, _} ->
			ok;
		{error, {already_started, _}} ->
			ok;
		StartClientError ->
			StartClientError
	end.
