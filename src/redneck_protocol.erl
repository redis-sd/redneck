%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pagodabox.com>
%%% @copyright 2013, Pagoda Box, Inc.
%%% @doc
%%%
%%% @end
%%% Created :  05 Sep 2013 by Andrew Bennett <andrew@pagodabox.com>
%%%-------------------------------------------------------------------
-module(redneck_protocol).
-behaviour(ranch_protocol).

-include("redneck.hrl").
-include("redneck_internal.hrl").

%% ranch_protocol callbacks
-export([start_link/4]).

%% API
-export([init/1]).
-export([loop/3]).

-record(state, {
	%% Transport & Socket
	socket    = undefined :: undefined | inet:socket(),
	transport = undefined :: undefined | module(),
	messages  = undefined :: undefined | {atom(), atom(), atom()},
	%% Options
	hibernate   = false     :: boolean(),
	timeout     = infinity  :: infinity | timeout(),
	timeout_ref = undefined :: unefined | reference()
}).

%%%===================================================================
%%% ranch_protocol callbacks
%%%===================================================================

%% @doc Start an redneck_protocol process.
-spec start_link(ranch:ref(), inet:socket(), module(), {module(), any()})
	-> {ok, pid()}.
start_link(Ref, Socket, Transport, {Handler, HandlerOpts}) ->
	proc_lib:start_link(?MODULE, init, [{Ref, Socket, Transport, Handler, HandlerOpts}]).

%%%===================================================================
%%% API functions
%%%===================================================================

%% @private
init({Ref, Socket, Transport, Handler, HandlerOpts}) ->
	ok = proc_lib:init_ack({ok, self()}),
	ok = ranch:accept_ack(Ref),
	State = #state{socket=Socket, transport=Transport, messages=Transport:messages()},
	handler_init(State, Handler, HandlerOpts).

%%%-------------------------------------------------------------------
%%% Handler functions
%%%-------------------------------------------------------------------

%% @private
handler_init(State=#state{transport=Transport}, Handler, HandlerOpts) ->
	try Handler:init(Transport:name(), HandlerOpts) of
		{ok, HandlerState} ->
			before_loop(State, {Handler, HandlerState}, <<>>);
		{ok, HandlerState, hibernate} ->
			before_loop(State#state{hibernate=true}, {Handler, HandlerState}, <<>>);
		{ok, HandlerState, Timeout} ->
			before_loop(State#state{timeout=Timeout}, {Handler, HandlerState}, <<>>);
		{ok, HandlerState, Timeout, hibernate} ->
			before_loop(State#state{timeout=Timeout, hibernate=true}, {Handler, HandlerState}, <<>>);
		{stop, Reason} ->
			terminate(Reason, State)
	catch
		Class:Reason ->
			error_logger:error_msg(
				"** ~p ~p terminating in ~p/~p~n"
				"   for the reason ~p:~p~n** Handler was ~p~n"
				"** Handler options were ~p~n** Stacktrace: ~p~n~n",
				[?MODULE, self(), handler_init, 3, Class, Reason, Handler, HandlerOpts, erlang:get_stacktrace()]),
			terminate(Reason, State)
	end.

%% @private
handler_call(State, {Handler, HandlerState}, Data, Callback, From, Request, NextState) ->
	try Handler:Callback(Request, From, HandlerState) of
		{reply, Reply, HandlerState2} ->
			_ = redneck:reply(From, Reply),
			State2 = loop_timeout(State),
			NextState(State2, {Handler, HandlerState2}, Data);
		{reply, Reply, HandlerState2, hibernate} ->
			_ = redneck:reply(From, Reply),
			State2 = loop_timeout(State#state{hibernate=true}),
			NextState(State2, {Handler, HandlerState2}, Data);
		{reply, Reply, HandlerState2, Timeout} ->
			_ = redneck:reply(From, Reply),
			State2 = loop_timeout(State#state{timeout=Timeout}),
			NextState(State2, {Handler, HandlerState2}, Data);
		{reply, Reply, HandlerState2, Timeout, hibernate} ->
			_ = redneck:reply(From, Reply),
			State2 = loop_timeout(State#state{timeout=Timeout, hibernate=true}),
			NextState(State2, {Handler, HandlerState2}, Data);
		{noreply, HandlerState2} ->
			State2 = loop_timeout(State),
			NextState(State2, {Handler, HandlerState2}, Data);
		{noreply, HandlerState2, hibernate} ->
			State2 = loop_timeout(State#state{hibernate=true}),
			NextState(State2, {Handler, HandlerState2}, Data);
		{noreply, HandlerState2, Timeout} ->
			State2 = loop_timeout(State#state{timeout=Timeout}),
			NextState(State2, {Handler, HandlerState2}, Data);
		{noreply, HandlerState2, Timeout, hibernate} ->
			State2 = loop_timeout(State#state{timeout=Timeout, hibernate=true}),
			NextState(State2, {Handler, HandlerState2}, Data);
		{stop, Reason, HandlerState2} ->
			handler_terminate(State, {Handler, HandlerState2}, Reason)
	catch
		Class:Reason ->
			error_logger:error_msg(
				"** ~p ~p terminating in ~p/~p~n"
				"   for the reason ~p:~p~n** Callback was ~p~n"
				"** From was ~p~n** Request was ~p~n** Handler was ~p~n"
				"** Handler state was ~p~n** Stacktrace: ~p~n~n",
				[?MODULE, self(), handler_call, 7, Class, Reason, Callback, From, Request, Handler, HandlerState, erlang:get_stacktrace()]),
			handler_terminate(State, {Handler, HandlerState}, Reason)
	end.

%% @private
handler_message(State, {Handler, HandlerState}, Data, Callback, Message, NextState) ->
	try Handler:Callback(Message, HandlerState) of
		{noreply, HandlerState2} ->
			State2 = loop_timeout(State),
			NextState(State2, {Handler, HandlerState2}, Data);
		{noreply, HandlerState2, hibernate} ->
			State2 = loop_timeout(State#state{hibernate=true}),
			NextState(State2, {Handler, HandlerState2}, Data);
		{noreply, HandlerState2, Timeout} ->
			State2 = loop_timeout(State#state{timeout=Timeout}),
			NextState(State2, {Handler, HandlerState2}, Data);
		{noreply, HandlerState2, Timeout, hibernate} ->
			State2 = loop_timeout(State#state{timeout=Timeout, hibernate=true}),
			NextState(State2, {Handler, HandlerState2}, Data);
		{stop, Reason, HandlerState2} ->
			handler_terminate(State, {Handler, HandlerState2}, Reason)
	catch
		Class:Reason ->
			error_logger:error_msg(
				"** ~p ~p terminating in ~p/~p~n"
				"   for the reason ~p:~p~n** Callback was ~p~n"
				"** Message was ~p~n** Handler was ~p~n"
				"** Handler state was ~p~n** Stacktrace: ~p~n~n",
				[?MODULE, self(), handler_message, 6, Class, Reason, Callback, Message, Handler, HandlerState, erlang:get_stacktrace()]),
			handler_terminate(State, {Handler, HandlerState}, Reason)
	end.

%% @private
handler_terminate(State, {Handler, HandlerState}, TerminateReason) ->
	try
		Handler:terminate(TerminateReason, HandlerState)
	catch
		Class:Reason ->
			error_logger:error_msg(
				"** ~p ~p terminating in ~p/~p~n"
				"   for the reason ~p:~p~n** Handler was ~p~n"
				"** Handler state was ~p~n** Stacktrace: ~p~n~n",
				[?MODULE, self(), handler_terminate, 3, Class, Reason, Handler, HandlerState, erlang:get_stacktrace()]),
			terminate(Reason, State)
	end.

%%%-------------------------------------------------------------------
%%% loop functions
%%%-------------------------------------------------------------------

%% @private
before_loop(State=#state{hibernate=true, transport=Transport, socket=Socket}, HandlerState, SoFar) ->
	Transport:setopts(Socket, [{active, once}]),
	erlang:hibernate(?MODULE, loop, [State#state{hibernate=false}, HandlerState, SoFar]);
before_loop(State=#state{transport=Transport, socket=Socket}, HandlerState, SoFar) ->
	Transport:setopts(Socket, [{active, once}]),
	loop(State, HandlerState, SoFar).

%% @private
loop(State=#state{socket=Socket, messages={OK, Closed, Error}, timeout_ref=TRef}, HandlerState, SoFar) ->
	receive
		{OK, Socket, Data} ->
			State2 = loop_timeout(State),
			parse_data(State2, HandlerState, << SoFar/binary, Data/binary >>);
		{Closed, Socket} ->
			handler_terminate(State, HandlerState, {error, closed});
		{Error, Socket, Reason} ->
			handler_terminate(State, HandlerState, {error, Reason});
		{timeout, TRef, ?MODULE} ->
			handler_terminate(State, HandlerState, {normal, timeout});
		{timeout, OlderTRef, ?MODULE} when is_reference(OlderTRef) ->
			loop(State, HandlerState, SoFar);
		Info ->
			handler_message(State, HandlerState, SoFar, handle_info, Info, fun loop/3)
	end.

%% @private
loop_timeout(State=#state{timeout=infinity}) ->
	State#state{timeout_ref=undefined};
loop_timeout(State=#state{timeout=Timeout, timeout_ref=PrevRef}) ->
	_ = case PrevRef of
		undefined -> ignore;
		PrevRef -> erlang:cancel_timer(PrevRef)
	end,
	TRef = erlang:start_timer(Timeout, self(), ?MODULE),
	State#state{timeout_ref=TRef}.

%% @private
parse_data(State, HandlerState, << Len:4/big-unsigned-integer-unit:8, Data/binary >>) when byte_size(Data) >= Len ->
	Binary = binary_part(Data, 0, Len),
	Rest = binary_part(Data, Len, byte_size(Data) - Len),
	try erlang:binary_to_term(Binary) of
		{?REDNECK_REQUEST, From, Request} ->
			handler_call(State, HandlerState, Rest, handle_call, From, Request, fun parse_data/3);
		{?REDNECK_RESPONSE, {To, Tag}, Reply} ->
			catch To ! {Tag, Reply},
			parse_data(State, HandlerState, Rest);
		{?REDNECK_NOTIFY, Message} ->
			handler_message(State, HandlerState, Rest, handle_cast, Message, fun parse_data/3);
		Message ->
			handler_message(State, HandlerState, Rest, handle_message, Message, fun parse_data/3)
	catch
		Class:Reason ->
			error_logger:error_msg(
				"** ~p ~p terminating in ~p/~p~n"
				"   for the reason ~p:~p~n** Data was ~p~n"
				"** Stacktrace: ~p~n~n",
				[?MODULE, self(), parse_data, 3, Class, Reason, Data, erlang:get_stacktrace()]),
			handler_terminate(State, HandlerState, Reason)
	end;
parse_data(State, HandlerState, Data) ->
	%% need more data
	before_loop(State, HandlerState, Data).

% %% @private
% send(State=#state{transport=Transport, socket=Socket}, HandlerState, Data, Message, NextState) ->
% 	try erlang:term_to_binary(Message) of
% 		Packet ->
% 			case Transport:send(Socket, Packet) of
% 				ok ->
% 					State2 = loop_timeout(State),
% 					NextState(State2, HandlerState, Data);
% 				{error, SocketReason} ->
% 					handler_terminate(State, HandlerState, {error, SocketReason})
% 			end
% 	catch
% 		Class:Reason ->
% 			error_logger:error_msg(
% 				"** ~p ~p terminating in ~p/~p~n"
% 				"   for the reason ~p:~p~n** Stacktrace: ~p~n~n",
% 				[?MODULE, self(), send, 5, Class, Reason, erlang:get_stacktrace()]),
% 			handler_terminate(State, HandlerState, {error, Reason})
% 	end.

terminate(_TerminateReason, _State=#state{transport=Transport, socket=Socket}) ->
	catch Transport:close(Socket),
	ok.
