%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pagodabox.com>
%%% @copyright 2013, Pagoda Box, Inc.
%%% @doc
%%%
%%% @end
%%% Created :  10 Sep 2013 by Andrew Bennett <andrew@pagodabox.com>
%%%-------------------------------------------------------------------
-module(redneck_node).

-include("redneck.hrl").
-include("redneck_internal.hrl").

%% API
-export([start_link/1, call/2, call/3, cast/2, reply/2, connect/1, disconnect/1]).
-export([init/1]).
-export([loop/2]).

-record(state, {
	record = undefined :: undefined | #dns_sd{},
	ring   = undefined :: undefined | atom(),
	node   = undefined :: undefined | integer(),
	%% Connection
	addr    = undefined     :: undefnied | inet:ip_address(),
	addrs   = gb_sets:new() :: gb_set(),
	port    = undefined     :: undefined | inet:port_number(),
	backoff = undefined     :: undefined | backoff:backoff(),
	bref    = undefined     :: undefined | reference(),
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
%%% API functions
%%%===================================================================

%% @private
start_link(Record=#dns_sd{}) ->
	proc_lib:start_link(?MODULE, init, [Record]).

call(Node, Request) ->
	case catch gen:call({via, redneck, Node}, '$redneck_node_call', Request) of
		{ok, Result} ->
			Result;
		{'EXIT', Reason} ->
			erlang:exit({Reason, {?MODULE, call, [Node, Request]}})
	end.

call(Node, Request, Timeout) ->
	case catch gen:call({via, redneck, Node}, '$redneck_node_call', Request, Timeout) of
		{ok, Result} ->
			Result;
		{'EXIT', Reason} ->
			erlang:exit({Reason, {?MODULE, call, [Node, Request, Timeout]}})
	end.

cast(Node, Request) ->
	catch redneck:send(Node, {'$redneck_node_cast', Request}),
	ok.

reply(From, Reply) ->
	gen:reply(From, Reply).

connect(Record=#dns_sd{}) ->
	Node = redneck_kernel:node(Record),
	case redneck:whereis_name(Node) of
		undefined ->
			{ok, _} = start_link(Record),
			ok;
		_ ->
			redneck_node:cast(Node, {connect, Record})
	end.

disconnect(NodeOrRecord) ->
	redneck_node:cast(NodeOrRecord, disconnect).

%% @private
init(Record=#dns_sd{}) ->
	Node = redneck_kernel:node(Record),
	Ring = redneck_kernel:ring(Record),
	case redneck_proxy:start_link(self(), Record) of
		{ok, _ProxyPid} ->
			ok = proc_lib:init_ack({ok, self()}),
			Backoff = backoff:init(timer:seconds(1), timer:seconds(120), self(), connect),
			Transport = ranch_tcp,
			Messages = Transport:messages(),
			State = #state{record=Record, ring=Ring, node=Node,
				transport=Transport, messages=Messages, backoff=Backoff},
			connect_loop(State);
		ProxyError ->
			ok = proc_lib:init_ack(ProxyError),
			erlang:exit(normal)
	end.

%%%-------------------------------------------------------------------
%%% loop functions
%%%-------------------------------------------------------------------

%% @private
connect_loop(State=#state{port=undefined, record=#dns_sd{target=Target, port=Port}}) ->
	TargetString = redis_sd:any_to_string(Target),
	Addrs4 = case inet:getaddrs(TargetString, inet) of
		{ok, A4} ->
			A4;
		_ ->
			[]
	end,
	Addrs6 = case inet:getaddrs(TargetString, inet6) of
		{ok, A6} ->
			A6;
		_ ->
			[]
	end,
	Addrs = gb_sets:union(gb_sets:from_list(Addrs4), gb_sets:from_list(Addrs6)),
	State2 = State#state{addrs=Addrs, port=Port},
	connect_loop(State2);
connect_loop(State=#state{socket=undefined, transport=Transport, addrs=Addrs, port=Port, backoff=Backoff}) ->
	case gb_sets:is_empty(Addrs) of
		false ->
			{Addr, Addrs2} = gb_sets:take_smallest(Addrs),
			case Transport:connect(Addr, Port, [{reuseaddr, true}]) of
				{ok, Socket} ->
					ok = register_node(State),
					{_Start, Backoff2} = backoff:succeed(Backoff),
					State2 = State#state{backoff=Backoff2, addr=Addr, addrs=Addrs2, socket=Socket},
					before_loop(State2, <<>>);
				_ ->
					State2 = State#state{addrs=Addrs2},
					connect_loop(State2)
			end;
		true ->
			BRef = backoff:fire(Backoff),
			{_Delay, Backoff2} = backoff:fail(Backoff),
			State2 = State#state{bref=BRef, backoff=Backoff2, addr=undefined, port=undefined},
			loop(State2, <<>>)
	end.

%% @private
before_loop(State=#state{hibernate=true, transport=Transport, socket=Socket}, SoFar) ->
	Transport:setopts(Socket, [{active, once}]),
	erlang:hibernate(?MODULE, loop, [State#state{hibernate=false}, SoFar]);
before_loop(State=#state{transport=Transport, socket=Socket}, SoFar) ->
	Transport:setopts(Socket, [{active, once}]),
	loop(State, SoFar).

%% @private
loop(State=#state{socket=undefined, bref=BRef}, SoFar) ->
	receive
		{timeout, BRef, connect} ->
			State2 = State#state{bref=undefined},
			connect_loop(State2);
		{'$redneck_node_call', From, Request} ->
			handle_node_call(State, SoFar, Request, From, fun loop/2);
		{'$redneck_node_cast', Request} ->
			handle_node_cast(State, SoFar, Request, fun loop/2);
		{'$redneck_call', {Node, {From, Tag}}, _Request} ->
			catch From ! {nodedown, Tag, Node},
			loop(State, SoFar);
		{'$redneck_cast', _Request} ->
			loop(State, SoFar);
		{'$redneck_reply', _From, _Reply} ->
			loop(State, SoFar);
		{'$redneck', _Message} ->
			loop(State, SoFar);
		Info ->
			error_logger:warning_msg(
				"** ~p ~p unhandled info in ~p/~p~n"
				"** Info was ~p~n~n",
				[?MODULE, self(), loop, 2, Info]),
			loop(State, SoFar)
	end;
loop(State=#state{socket=Socket, messages={OK, Closed, Error}, timeout_ref=TRef}, SoFar) ->
	receive
		{OK, Socket, Data} ->
			State2 = loop_timeout(State),
			parse_data(State2, << SoFar/binary, Data/binary >>);
		{Closed, Socket} ->
			ok = unregister_node(State),
			connect_loop(State#state{socket=undefined});
		{Error, Socket, Reason} ->
			ok = unregister_node(State),
			error_logger:warning_msg(
				"** ~p ~p transport error in ~p/~p~n"
				"   for the reason ~p:~p~n** Socket was ~p~n~n",
				[?MODULE, self(), loop, 2, Error, Reason, Socket]),
			connect_loop(State#state{socket=undefined});
		{timeout, TRef, ?MODULE} ->
			terminate(timeout, State);
		{timeout, OlderTRef, ?MODULE} when is_reference(OlderTRef) ->
			loop(State, SoFar);
		{'$redneck_node_call', From, Request} ->
			handle_node_call(State, SoFar, Request, From, fun loop/2);
		{'$redneck_node_cast', Request} ->
			handle_node_cast(State, SoFar, Request, fun loop/2);
		{'$redneck_call', From, Request} ->
			Message = {?REDNECK_REQUEST, From, Request},
			send(State, SoFar, Message, fun before_loop/2);
		{'$redneck_cast', Request} ->
			Message = {?REDNECK_NOTIFY, Request},
			send(State, SoFar, Message, fun before_loop/2);
		{'$redneck_reply', From, Reply} ->
			Message = {?REDNECK_RESPONSE, From, Reply},
			send(State, SoFar, Message, fun before_loop/2);
		{'$redneck', Message} ->
			send(State, SoFar, Message, fun before_loop/2);
		Info ->
			error_logger:warning_msg(
				"** ~p ~p unhandled info in ~p/~p~n"
				"** Info was ~p~n~n",
				[?MODULE, self(), loop, 2, Info]),
			loop(State, SoFar)
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
parse_data(State, << Len:4/big-unsigned-integer-unit:8, Data/binary >>) when byte_size(Data) >= Len ->
	Binary = binary_part(Data, 0, Len),
	Rest = binary_part(Data, Len, byte_size(Data) - Len),
	try erlang:binary_to_term(Binary) of
		Term ->
			error_logger:warning_msg(
				"** ~p ~p unhandled term in ~p/~p~n"
				"** Term was ~p~n~n",
				[?MODULE, self(), parse_data, 2, Term]),
			parse_data(State, Rest)
	catch
		Class:Reason ->
			error_logger:error_msg(
				"** ~p ~p terminating in ~p/~p~n"
				"   for the reason ~p:~p~n** Data was ~p~n"
				"** Stacktrace: ~p~n~n",
				[?MODULE, self(), parse_data, 3, Class, Reason, Data, erlang:get_stacktrace()]),
			terminate({Class, Reason}, State)
	end;
parse_data(State, Data) ->
	%% need more data
	before_loop(State, Data).

%% @private
handle_node_call(State=#state{socket=Socket, node=Node, ring=Ring, record=Record}, SoFar, info, From, NextState) ->
	Connected = case Socket of
		undefined ->
			down;
		_ ->
			up
	end,
	_ = reply(From, {Node, Ring, Connected, Record}),
	NextState(State, SoFar);
handle_node_call(State=#state{ring=Ring}, SoFar, ring, From, NextState) ->
	_ = reply(From, Ring),
	NextState(State, SoFar);
handle_node_call(State=#state{ring=Ring, record=#dns_sd{domain=Domain, type=Type, service=Service}}, SoFar, ring_info, From, NextState) ->
	{ok, RingObj} = ryng:get_ring(Ring),
	_ = reply(From, {Ring, {Domain, Type, Service}, RingObj}),
	NextState(State, SoFar);
handle_node_call(State, SoFar, _Request, From, NextState) ->
	_ = reply(From, {error, undef}),
	NextState(State, SoFar).

%% @private
handle_node_cast(State=#state{record=Record}, SoFar, {connect, Record}, NextState) ->
	NextState(State, SoFar);
handle_node_cast(State, SoFar, {connect, Record}, NextState) ->
	State2 = State#state{record=Record},
	NextState(State2, SoFar);
handle_node_cast(State, _SoFar, disconnect, _NextState) ->
	terminate(normal, State);
handle_node_cast(State, SoFar, _Request, NextState) ->
	NextState(State, SoFar).

%% @private
send(State=#state{transport=Transport, socket=Socket}, SoFar, Message, NextState) ->
	try erlang:term_to_binary(Message) of
		Data ->
			Packet = << (byte_size(Data)):4/big-unsigned-integer-unit:8, Data/binary >>,
			case Transport:send(Socket, Packet) of
				ok ->
					State2 = loop_timeout(State),
					NextState(State2, SoFar);
				{error, SocketReason} ->
					terminate(SocketReason, State)
			end
	catch
		Class:Reason ->
			error_logger:error_msg(
				"** ~p ~p terminating in ~p/~p~n"
				"   for the reason ~p:~p~n** Stacktrace: ~p~n~n",
				[?MODULE, self(), send, 4, Class, Reason, erlang:get_stacktrace()]),
			terminate({Class, Reason}, State)
	end.

%% @private
terminate(Reason, State=#state{node=Node, transport=Transport, socket=Socket}) ->
	catch unregister_node(State),
	catch redneck:unregister_name(Node),
	catch Transport:close(Socket),
	erlang:exit(Reason).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
register_node(#state{ring=Ring, node=Node, record=#dns_sd{weight=Weight, priority=Priority, domain=Domain, type=Type, service=Service, instance=Instance}}) ->
	ryng:set_node(Ring, Node, Weight, Priority),
	redneck_event:nodeup(Ring, Node, {Domain, Type, Service, Instance}),
	ok.

%% @private
unregister_node(#state{ring=Ring, node=Node, record=#dns_sd{domain=Domain, type=Type, service=Service, instance=Instance}}) ->
	ryng:del_node(Ring, Node),
	redneck_event:nodedown(Ring, Node, {Domain, Type, Service, Instance}),
	ok.
