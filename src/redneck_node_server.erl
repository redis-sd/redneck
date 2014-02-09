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
-module(redneck_node_server).

-include("redneck.hrl").

%% API
-export([start_link/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	terminate/2, code_change/3]).

-record(server, {
	node  = undefined :: undefined | redneck_node(),
	meta  = undefined :: undefined | redneck_meta(),
	mod   = undefined :: undefined | module(),
	state = undefined :: undefined | any()
}).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link(Node, []) ->
	proc_lib:start_link(?MODULE, init, [Node]).
	% gen_server:start_link(?MODULE, [], {Node, Record}).
	% case redis_sd_server_dns:resolve(Service?REDIS_SD_SERVICE{rec=undefined}) of
	% 	{ok, ?REDIS_SD_SERVICE{rec=Record=?REDIS_SD_DNS{}}} ->
	% 		Node = from_redis_sd_dns(Record),

	% gen_server:start_link(?MODULE, )

% enter_loop(Mod, Node=?REDNECK_NODE(), State) ->
% 	Meta = redneck_node:ack(Node),
% 	Server = #server{node=Node, meta=Meta, mod=Mod, state=State},
% 	gen_server:enter_loop(?MODULE, [], Server).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init(Node) ->
	ok = proc_lib:init_ack({ok, self()}),
	Meta = redneck_node:ack(Node),
	Server = #server{node=Node, meta=Meta},
	gen_server:enter_loop(?MODULE, [], Server).

%% @private
handle_call(_Request, _From, Server) ->
	{reply, {os:timestamp(), ignore}, Server}.

%% @private
handle_cast(_Request, Server) ->
	{noreply, Server}.

%% @private
handle_info({'$redneck_node', Message}, Server) ->
	handle_redneck_message(Message, Server);
handle_info(Info, State) ->
	error_logger:error_msg(
		"** ~p ~p unhandled info in ~p/~p~n"
		"   Info was: ~p~n",
		[?MODULE, self(), handle_info, 2, Info]),
	{noreply, State}.

%% @private
handle_redneck_message({syn, From, Node, Meta}, Server) ->
	Meta = redneck_node:ack(From, Node, Meta),
	Server2 = Server#server{node=Node, meta=Meta},
	{noreply, Server2};
handle_redneck_message({msg, To, Message}, Server=#server{node=To}) ->
	io:format("NOTIFY: ~p ~p~n", [To, Message]),
	{noreply, Server};
handle_redneck_message({msg, To, From, Message}, Server=#server{node=To}) ->
	io:format("REQUEST: ~p ~p ~p~n", [To, From, Message]),
	redneck:reply(From, {os:timestamp(), Message}),
	{noreply, Server};
handle_redneck_message({close, Node}, Server=#server{node=Node}) ->
	{stop, normal, Server};
handle_redneck_message({error, Node, Reason}, Server=#server{node=Node}) ->
	{stop, Reason, Server};
handle_redneck_message(Info, Server) ->
	error_logger:error_msg(
		"** ~p ~p unhandled info in ~p/~p~n"
		"   Info was: ~p~n",
		[?MODULE, self(), handle_redneck_message, 2, Info]),
	{noreply, Server}.

%% @private
terminate(_Reason, _State) ->
	ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

% start_link(Node=?REDNECK_NODE(), Mod, Args, Options) ->
% 	gen:start(?MODULE, link, {via, redneck, Node}, Mod, Args, Options).

%%%===================================================================
%%% gen callbacks
%%%===================================================================

% init_it(Starter, Parent, Name, Mod, Args, Options) ->
% 	Mod:init({Starter, Parent, Name, Args, Options}).

% -define(TAG, $n).
% -define(V1_VERS, 1).

% to_binary(?REDNECK_NODE{ring=RingBinary, node=NodeBinary,
% 		host=HostBinary, port=Port}) ->
% 	HostLength = byte_size(HostBinary),
% 	HostLengthFieldLength = bit_size(binary:encode_unsigned(HostLength)),
% 	<<?TAG:8/integer, ?V1_VERS:8/integer,
% 		RingBinary:32/bits,
% 		NodeBinary:32/bits,
% 		Port:16/big-unsigned-integer,
% 		HostLengthFieldLength:8/integer,
% 		HostLength:HostLengthFieldLength/big-unsigned-integer,
% 		HostBinary:HostLength/binary
% 	>>.

% to_binary_stream(Node=?REDNECK_NODE{}, Stream) when is_binary(Stream) ->
% 	<< Stream/binary, (to_binary(Node))/binary >>.

% from_binary(Binary) when is_binary(Binary) ->
% 	{Node, _Stream} = from_binary_stream(Binary),
% 	Node.

% from_binary_stream(<<?TAG:8/integer, ?V1_VERS:8/integer,
% 		RingBinary:32/bits,
% 		NodeBinary:32/bits,
% 		Port:16/big-unsigned-integer,
% 		HostLengthFieldLength:8/integer,
% 		HostLength:HostLengthFieldLength/big-unsigned-integer,
% 		HostBinary:HostLength/binary, Stream/binary>>) ->
% 	Node = ?REDNECK_NODE{ring=RingBinary, node=NodeBinary, host=HostBinary, port=Port},
% 	{Node, Stream}.
