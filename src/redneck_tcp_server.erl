%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pagodabox.com>
%%% @copyright 2014, Pagoda Box, Inc.
%%% @doc
%%%
%%% @end
%%% Created :  05 Feb 2014 by Andrew Bennett <andrew@pagodabox.com>
%%%-------------------------------------------------------------------
-module(redneck_tcp_server).
-behaviour(ranch_protocol).
-behaviour(gen_server).

-include("redneck.hrl").

%% ranch_protocol callbacks
-export([start_link/4]).

%% API

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	terminate/2, code_change/3]).

-record(state, {
	so_far = <<>> :: binary(),
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
-spec start_link(ranch:ref(), inet:socket(), module(), any())
	-> {ok, pid()}.
start_link(Ref, Socket, Transport, ProtocolOptions) ->
	proc_lib:start_link(?MODULE, init, [{Ref, Socket, Transport, ProtocolOptions}]).

%%%===================================================================
%%% API functions
%%%===================================================================

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init({Ref, Socket, Transport, _ProtocolOptions}) ->
	ok = proc_lib:init_ack({ok, self()}),
	ok = ranch:accept_ack(Ref),
	State = #state{socket=Socket, transport=Transport, messages=Transport:messages()},
	case before_loop(State) of
		{noreply, State2} ->
			gen_server:enter_loop(?MODULE, [], State2);
		{noreply, State2, Timeout} ->
			gen_server:enter_loop(?MODULE, [], State2, self(), Timeout)
	end.

%% @private
handle_call(_Request, _From, State) ->
	{reply, ignore, State}.

%% @private
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_info({OK, Socket, Data}, State=#state{socket=Socket, messages={OK, _Closed, _Error}, so_far=SoFar}) ->
	State2 = loop_timeout(State),
	parse_data(State2, << SoFar/binary, Data/binary >>);
handle_info({Closed, Socket}, State=#state{socket=Socket, messages={_OK, Closed, _Error}}) ->
	{stop, normal, State};
handle_info({Error, Socket, Reason}, State=#state{socket=Socket, messages={_OK, _Closed, Error}}) ->
	{stop, {error, Reason}, State};
handle_info({timeout, TRef, ?MODULE}, State=#state{timeout_ref=TRef}) ->
	{stop, normal, State};
handle_info({timeout, OlderTRef, ?MODULE}, State) when is_reference(OlderTRef) ->
	{noreply, State};
handle_info(Msg=?REDNECK_MSG{}, State) ->
	send(State, Msg);
handle_info(Info, State) ->
	error_logger:error_msg(
		"** ~p ~p unhandled info in ~p/~p~n"
		"   Info was: ~p~n",
		[?MODULE, self(), handle_info, 2, Info]),
	{noreply, State}.

%% @private
terminate(_Reason, #state{transport=Transport, socket=Socket}) ->
	catch Transport:close(Socket),
	ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%-------------------------------------------------------------------
%%% loop functions
%%%-------------------------------------------------------------------

%% @private
before_loop(State=#state{hibernate=true, transport=Transport, socket=Socket}) ->
	Transport:setopts(Socket, [{active, once}]),
	{noreply, State#state{hibernate=false}, hibernate};
before_loop(State=#state{transport=Transport, socket=Socket}) ->
	Transport:setopts(Socket, [{active, once}]),
	{noreply, State}.

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
parse_data(State, Data) ->
	try redneck_msg:from_binary_stream(Data) of
		{?REDNECK_MSG{to=To, from=undefined, message=Message}, SoFar} ->
			catch redneck_internal:send({node_server, To}, {'$redneck_node', {msg, To, Message}}),
			parse_data(State, SoFar);
		{?REDNECK_MSG{to=To, from=From, tag=Tag, message=Message}, SoFar} ->
			catch redneck_internal:send({node_server, To}, {'$redneck_node', {msg, To, {self(), {To, From, Tag}}, Message}}),
			parse_data(State, SoFar);
		{incomplete, SoFar} ->
			%% need more data
			before_loop(State#state{so_far=SoFar})
	catch
		Class:Reason ->
			error_logger:error_msg(
				"** ~p ~p terminating in ~p/~p~n"
				"   for the reason ~p:~p~n** Data was ~p~n"
				"** Stacktrace: ~p~n~n",
				[?MODULE, self(), parse_data, 2, Class, Reason, Data, erlang:get_stacktrace()]),
			{stop, Reason, State}
	end.

%% @private
send(State=#state{transport=Transport, socket=Socket}, Msg) ->
	try redneck_msg:to_binary(Msg) of
		Packet ->
			case Transport:send(Socket, Packet) of
				ok ->
					{noreply, State};
				{error, SocketReason} ->
					{stop, SocketReason, State}
			end
	catch
		Class:Reason ->
			error_logger:error_msg(
				"** ~p ~p terminating in ~p/~p~n"
				"   for the reason ~p:~p~n** Stacktrace: ~p~n~n",
				[?MODULE, self(), send, 4, Class, Reason, erlang:get_stacktrace()]),
			{stop, {Class, Reason}, State}
	end.
