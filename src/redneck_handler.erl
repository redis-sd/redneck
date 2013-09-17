%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pagodabox.com>
%%% @copyright 2013, Pagoda Box, Inc.
%%% @doc
%%%
%%% @end
%%% Created :  14 Sep 2013 by Andrew Bennett <andrew@pagodabox.com>
%%%-------------------------------------------------------------------
-module(redneck_handler).

-callback init(Transport::atom(), Options::any())
	-> {ok, State::any()}
	| {ok, State::any(), hibernate}
	| {ok, State::any(), Timeout::timeout()}
	| {ok, State::any(), Timeout::timeout(), hibernate}
	| {stop, Reason::any()}.
-callback handle_call(Request::any(), From::{non_neg_integer(), {pid(), reference()}}, State::any())
	-> {reply, Reply::any(), State::any()}
	| {reply, Reply::any(), State::any(), hibernate}
	| {reply, Reply::any(), State::any(), Timeout::timeout()}
	| {reply, Reply::any(), State::any(), Timeout::timeout(), hibernate}
	| {noreply, State::any()}
	| {noreply, State::any(), hibernate}
	| {noreply, State::any(), Timeout::timeout()}
	| {noreply, State::any(), Timeout::timeout(), hibernate}
	| {stop, Reason::any(), State::any()}.
-callback handle_cast(Request::any(), State::any())
	-> {noreply, State::any()}
	| {noreply, State::any(), hibernate}
	| {noreply, State::any(), Timeout::timeout()}
	| {noreply, State::any(), Timeout::timeout(), hibernate}
	| {stop, Reason::any(), State::any()}.
-callback handle_message(Message::any(), State::any())
	-> {noreply, State::any()}
	| {noreply, State::any(), hibernate}
	| {noreply, State::any(), Timeout::timeout()}
	| {noreply, State::any(), Timeout::timeout(), hibernate}
	| {stop, Reason::any(), State::any()}.
-callback handle_info(Message::any(), State::any())
	-> {noreply, State::any()}
	| {noreply, State::any(), hibernate}
	| {noreply, State::any(), Timeout::timeout()}
	| {noreply, State::any(), Timeout::timeout(), hibernate}
	| {stop, Reason::any(), State::any()}.
-callback terminate(Reason::any(), State::any())
	-> term().

%% redneck_handler callbacks
-export([init/2, handle_call/3, handle_cast/2, handle_message/2,
	handle_info/2, terminate/2]).

%%%===================================================================
%%% redneck_handler callbacks
%%%===================================================================

%% @private
init(_Transport, _Options) ->
	{ok, stateless}.

%% @private
handle_call(_Request, _From, State) ->
	{reply, {error, undef}, State}.

%% @private
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_message(_Message, State) ->
	{noreply, State}.

%% @private
handle_info(_Info, State) ->
	{noreply, State}.

%% @private
terminate(_Reason, _State) ->
	ok.
