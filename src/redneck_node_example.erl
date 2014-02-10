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
-module(redneck_node_example).
-behaviour(redneck_node_server).

-export([start_link/0]).

%% redneck_node_server callbacks
-export([init/3, handle_redneck_call/3, handle_redneck_cast/2,
	handle_redneck/2, handle_call/3, handle_cast/2, handle_info/2,
	terminate/2, code_change/3]).

-record(state, {
	node,
	meta
}).

start_link() ->
	redneck_sup:start_node(redneck_node_server, [{mod, ?MODULE}, {name, {local, ?MODULE}}], [{name, redneck_node_server}]).

init(Node, Meta, _Options) ->
	State = #state{node=Node, meta=Meta},
	{ok, State}.

handle_redneck_call(Request, _From, State) ->
	{reply, {echo, os:timestamp(), Request}, State}.

handle_redneck_cast(Request, State) ->
	io:format("CAST: ~p~n", [Request]),
	{noreply, State}.

handle_redneck({notify, Message}, State) ->
	io:format("NOTIFY: ~p~n", [Message]),
	{noreply, State};
handle_redneck({request, From, Message}, State) ->
	io:format("REQUEST: ~p ~p~n", [From, Message]),
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

handle_info(Info, State) ->
	io:format("INFO: ~p~n", [Info]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
