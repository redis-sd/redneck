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
-module(test_node).
-behaviour(redneck_node_server).

%% API
-export([start_link/1]).

%% redneck_node_server callbacks
-export([init/3, handle_redneck_call/3, handle_redneck_cast/2,
	handle_redneck/2, handle_call/3, handle_cast/2, handle_info/2,
	terminate/2, code_change/3]).

-record(state, {
	node,
	meta
}).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link(ServiceOptions) when is_list(ServiceOptions) ->
	redneck_sup:start_node(redneck_node_server,
		[{mod, ?MODULE}, {name, {local, ?MODULE}}],
		ServiceOptions).

%%%===================================================================
%%% redneck_node_server callbacks
%%%===================================================================

init(Node, Meta, _Options) ->
	State = #state{node=Node, meta=Meta},
	{ok, State}.

handle_redneck_call(Request, _From, State) ->
	Reply = {echo_call, Request},
	{reply, Reply, State}.

handle_redneck_cast({Pid, Request}, State) when is_pid(Pid) ->
	catch Pid ! {echo_cast, Request},
	{noreply, State};
handle_redneck_cast(_Request, State) ->
	{noreply, State}.

handle_redneck({notify, {Pid, Message}}, State) when is_pid(Pid) ->
	catch Pid ! {echo_notify, Message},
	{noreply, State};
handle_redneck({notify, _Message}, State) ->
	{noreply, State};
handle_redneck({request, From, Message}, State) ->
	redneck:reply(From, {echo_request, Message}),
	{noreply, State};
handle_redneck({syn, Node, Meta}, State) ->
	{noreply, State#state{node=Node, meta=Meta}};
handle_redneck({close, _Node}, State) ->
	{stop, normal, State};
handle_redneck({error, _Node, Reason}, State) ->
	{stop, Reason, State}.

handle_call(_Request, _From, State) ->
	{reply, ignore, State}.

handle_cast(_Request, State) ->
	{noreply, State}.

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
