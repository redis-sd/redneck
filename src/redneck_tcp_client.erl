%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pagodabox.com>
%%% @copyright 2014, Pagoda Box, Inc.
%%% @doc
%%%
%%% @end
%%% Created :  01 Feb 2014 by Andrew Bennett <andrew@pagodabox.com>
%%%-------------------------------------------------------------------
-module(redneck_tcp_client).
-behaviour(gen_server).

-include("redneck.hrl").

%% API
-export([start_link/1]).
-export([connect_endpoint/1, disconnect_endpoint/1, disconnect/1, is_connected/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	terminate/2, code_change/3]).

-record(state, {
	so_far = <<>>      :: binary(),
	node   = undefined :: undefined | redneck_node(),
	meta   = undefined :: undefined | redneck_meta(),
	%% Connection
	backoff = undefined :: undefined | backoff:backoff(),
	bref    = undefined :: undefined | reference(),
	%% Transport & Socket
	socket    = undefined :: undefined | inet:socket(),
	transport = undefined :: undefined | module(),
	messages  = undefined :: undefined | {atom(), atom(), atom()}
}).

%%%===================================================================
%%% API functions
%%%===================================================================

%% @private
start_link(Node=?REDNECK_NODE()) ->
	gen_server:start_link({via, redneck_internal, {tcp_client, Node}}, ?MODULE, Node, []).

connect_endpoint({Node=?REDNECK_NODE(), Meta=?REDNECK_META{}}) ->
	gen_server:call({via, redneck_internal, {tcp_client, Node}}, {connect_endpoint, Meta}).

disconnect_endpoint({Node=?REDNECK_NODE(), Meta=?REDNECK_META{}}) ->
	gen_server:cast({via, redneck_internal, {tcp_client, Node}}, {disconnect_endpoint, Meta}).

disconnect(Node) ->
	gen_server:call({via, redneck_internal, {tcp_client, Node}}, disconnect).

is_connected(Node) ->
	gen_server:call({via, redneck_internal, {tcp_client, Node}}, is_connected).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init(Node=?REDNECK_NODE()) ->
	Backoff = backoff:init(timer:seconds(1), timer:seconds(120), self(), connect),
	Transport = ranch_tcp,
	Messages = Transport:messages(),
	State = #state{node=Node, transport=Transport, messages=Messages,
		backoff=Backoff},
	{ok, State}.

%% @private
handle_call({connect_endpoint, Meta}, _From, State=#state{meta=Meta}) ->
	{reply, ok, State};
handle_call({connect_endpoint, Meta}, From, State=#state{transport=Transport, socket=Socket, backoff=Backoff, bref=BRef}) ->
	catch erlang:cancel_timer(BRef),
	catch Transport:close(Socket),
	{_Start, Backoff2} = backoff:succeed(Backoff),
	gen_server:reply(From, ok),
	State2 = State#state{backoff=Backoff2, meta=Meta, socket=undefined, bref=undefined},
	connect(State2);
handle_call(disconnect, _From, State) ->
	{stop, normal, true, State};
handle_call(is_connected, _From, State=#state{socket=undefined}) ->
	{reply, false, State};
handle_call(is_connected, _From, State) ->
	{reply, true, State};
handle_call(_Request, _From, State) ->
	{reply, ignore, State}.

%% @private
handle_cast({disconnect_endpoint, _Meta}, State=#state{transport=Transport, socket=Socket, backoff=Backoff, bref=BRef}) ->
	catch unregister_node(State),
	catch erlang:cancel_timer(BRef),
	catch Transport:close(Socket),
	{_Start, Backoff2} = backoff:succeed(Backoff),
	State2 = State#state{backoff=Backoff2, socket=undefined, bref=undefined},
	{noreply, State2};
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_info({timeout, BRef, connect}, State=#state{bref=BRef, socket=undefined}) ->
	State2 = State#state{bref=undefined},
	connect(State2);
handle_info({OK, Socket, Data}, State=#state{socket=Socket, messages={OK, _Closed, _Error}, so_far=SoFar}) ->
	parse_data(State, << SoFar/binary, Data/binary >>);
handle_info({Closed, Socket}, State=#state{socket=Socket, messages={_OK, Closed, _Error}, transport=Transport}) ->
	catch unregister_node(State),
	catch Transport:close(Socket),
	connect(State#state{socket=undefined});
handle_info({Error, Socket, Reason}, State=#state{socket=Socket, messages={_OK, _Closed, Error}, transport=Transport}) ->
	catch unregister_node(State),
	catch Transport:close(Socket),
	error_logger:warning_msg(
		"** ~p ~p transport error in ~p/~p~n"
		"   for the reason ~p:~p~n** Socket was ~p~n~n",
		[?MODULE, self(), handle_info, 2, Error, Reason, Socket]),
	connect(State#state{socket=undefined});
handle_info(?REDNECK_MSG{}, State=#state{socket=undefined}) ->
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
terminate(_Reason, State=#state{transport=Transport, socket=Socket}) ->
	catch unregister_node(State),
	catch Transport:close(Socket),
	ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%-------------------------------------------------------------------
%%% loop functions
%%%-------------------------------------------------------------------

%% @private
connect(State=#state{meta=?REDNECK_META{port=0}}) ->
	{noreply, State};
connect(State=#state{meta=?REDNECK_META{target=Host}}) ->
	Target = redis_sd:any_to_string(Host),
	Addrs = getaddrs([inet, inet6], Target, []),
	SoFar = <<>>,
	State2 = State#state{socket=undefined, so_far=SoFar},
	connect_addrs(Addrs, State2).

%% @private
connect_addrs([], State=#state{backoff=Backoff}) ->
	BRef = backoff:fire(Backoff),
	{_Delay, Backoff2} = backoff:fail(Backoff),
	State2 = State#state{backoff=Backoff2, bref=BRef},
	{noreply, State2};
connect_addrs([Addr | Addrs], State=#state{backoff=Backoff, meta=?REDNECK_META{port=Port}, transport=Transport}) ->
	case Transport:connect(Addr, Port, [{reuseaddr, true}]) of
		{ok, Socket} ->
			{_Start, Backoff2} = backoff:succeed(Backoff),
			SoFar = <<>>,
			State2 = State#state{backoff=Backoff2, socket=Socket, so_far=SoFar},
			ok = register_node(State2),
			before_loop(State2);
		_ ->
			connect_addrs(Addrs, State)
	end.

%% @private
before_loop(State=#state{transport=Transport, socket=Socket}) ->
	Transport:setopts(Socket, [{active, once}]),
	{noreply, State}.

%% @private
parse_data(State=#state{node=Node}, Data) ->
	try redneck_msg:from_binary_stream(Data) of
		{?REDNECK_MSG{to=Node, tag=Tag, message=Message}, SoFar} ->
			case Tag of
				{via, Mod, Ref} ->
					catch Mod:send(Ref, Message);
				{Pid, Ref} when is_pid(Pid) ->
					catch Pid ! {Ref, Message};
				_ ->
					catch Tag ! Message
			end,
			parse_data(State, SoFar);
		{?REDNECK_MSG{}, SoFar} ->
			%% not for this node
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
					catch unregister_node(State),
					catch Transport:close(Socket),
					error_logger:warning_msg(
						"** ~p ~p transport error in ~p/~p~n"
						"   for the reason ~p:~p~n** Socket was ~p~n~n",
						[?MODULE, self(), handle_info, 2, error, SocketReason, Socket]),
					connect(State#state{socket=undefined})
			end
	catch
		Class:Reason ->
			error_logger:error_msg(
				"** ~p ~p terminating in ~p/~p~n"
				"   for the reason ~p:~p~n** Stacktrace: ~p~n~n",
				[?MODULE, self(), send, 4, Class, Reason, erlang:get_stacktrace()]),
			{stop, {Class, Reason}, State}
	end.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
getaddrs([], _Target, Addrs) ->
	Addrs;
getaddrs([Type | Types], Target, Addrs) ->
	case inet:getaddrs(Target, Type) of
		{ok, A} ->
			getaddrs(Types, Target, Addrs ++ A);
		_ ->
			getaddrs(Types, Target, Addrs)
	end.

%% @private
register_node(#state{node=Node, meta=?REDNECK_META{priority=Priority, weight=Weight}}) ->
	redneck_ring:add_node(Node, Weight, Priority).

%% @private
unregister_node(#state{node=Node}) ->
	redneck_ring:del_node(Node).
