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
% -behaviour(redneck_node).
-behaviour(gen_server).

-include("redneck.hrl").

-callback init(Node::redneck_node(), Meta::redneck_meta(), Options::any()) ->
	{ok, State :: term()} |
	{ok, State :: term(), timeout() | hibernate} |
	{stop, Reason :: term()} |
	ignore.
-callback handle_redneck_call(Request :: term(), From :: {pid(), {ToNode :: redneck_node(), FromNode :: redneck_node(), Tag :: term()}}, State :: term()) ->
	{reply, Reply :: term(), NewState :: term()} |
	{reply, Reply :: term(), NewState :: term(), timeout() | hibernate} |
	{noreply, NewState :: term()} |
	{noreply, NewState :: term(), timeout() | hibernate} |
	{stop, Reason :: term(), Reply :: term(), NewState :: term()} |
	{stop, Reason :: term(), NewState :: term()}.
-callback handle_redneck_cast(Request :: term(), State :: term()) ->
	{noreply, NewState :: term()} |
	{noreply, NewState :: term(), timeout() | hibernate} |
	{stop, Reason :: term(), NewState :: term()}.
-callback handle_redneck({notify, Message :: term()} |
		{request, From :: term(), Message :: term()} |
		{syn, Node :: redneck_node(), Meta :: redneck_meta()} |
		{close, Node :: redneck_node()} |
		{error, Node :: redneck_node(), Reason :: any()}, State :: term()) ->
	{noreply, NewState :: term()} |
	{noreply, NewState :: term(), timeout() | hibernate} |
	{stop, Reason :: term(), NewState :: term()}.
-callback handle_call(Request :: term(), From :: {pid(), Tag :: term()}, State :: term()) ->
	{reply, Reply :: term(), NewState :: term()} |
	{reply, Reply :: term(), NewState :: term(), timeout() | hibernate} |
	{noreply, NewState :: term()} |
	{noreply, NewState :: term(), timeout() | hibernate} |
	{stop, Reason :: term(), Reply :: term(), NewState :: term()} |
	{stop, Reason :: term(), NewState :: term()}.
-callback handle_cast(Request :: term(), State :: term()) ->
	{noreply, NewState :: term()} |
	{noreply, NewState :: term(), timeout() | hibernate} |
	{stop, Reason :: term(), NewState :: term()}.
-callback handle_info(Info :: timeout | term(), State :: term()) ->
	{noreply, NewState :: term()} |
	{noreply, NewState :: term(), timeout() | hibernate} |
	{stop, Reason :: term(), NewState :: term()}.
-callback terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()), State :: term()) ->
	term().
-callback code_change(OldVsn :: (term() | {down, term()}), State :: term(), Extra :: term()) ->
	{ok, NewState :: term()} |
	{error, Reason :: term()}.

%% API
-export([start_link/4, start_link/5]).

%% redneck_node callbacks
-export([start_link/2]).

%% gen callbacks
-export([init_it/6]).

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

start_link(Node=?REDNECK_NODE(), Mod, Args, Options) ->
	gen:start(?MODULE, link, Mod, {Node, Args}, Options).

start_link(Name, Node=?REDNECK_NODE(), Mod, Args, Options) ->
	gen:start(?MODULE, link, Name, Mod, {Node, Args}, Options).

%%%===================================================================
%%% redneck_node callbacks
%%%===================================================================

start_link(Node=?REDNECK_NODE(), Options) ->
	case lists:keyfind(mod, 1, Options) of
		{mod, Mod} ->
			case lists:keyfind(name, 1, Options) of
				{name, Name} ->
					?MODULE:start_link(Name, Node, Mod, Options, []);
				false ->
					?MODULE:start_link(Node, Mod, Options, [])
			end;
		false ->
			erlang:error({missing_required_config, mod, Options})
	end.

%%%===================================================================
%%% gen callbacks
%%%===================================================================

%% @private
init_it(Starter, _Parent, Name, Mod, {Node=?REDNECK_NODE(), Args}, Options) ->
	ok = proc_lib:init_ack(Starter, {ok, self()}),
	Meta = redneck_node:ack(Node),
	Server = #server{node=Node, meta=Meta, mod=Mod},
	case catch Mod:init(Node, Meta, Args) of
		{ok, State} ->
			Server2 = Server#server{state=State},
			gen_server:enter_loop(?MODULE, Options, Server2, Name, infinity);
		{ok, State, Timeout} ->
			Server2 = Server#server{state=State},
			gen_server:enter_loop(?MODULE, Options, Server2, Name, Timeout);
		{stop, Reason} ->
			%% For consistency, we must make sure that the
			%% registered name (if any) is unregistered before
			%% the parent process is notified about the failure.
			%% (Otherwise, the parent process could get
			%% an 'already_started' error if it immediately
			%% tried starting the process again.)
			unregister_name(Name),
			exit(Reason);
		ignore ->
			unregister_name(Name),
			exit(normal);
		{'EXIT', Reason} ->
			unregister_name(Name),
			exit(Reason);
		Else ->
			Error = {bad_return_value, Else},
			exit(Error)
	end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% Unused
init(_) ->
	{ok, undefined}.

%% @private
handle_call(Request, From, Server=#server{mod=Mod, state=State}) ->
	case catch Mod:handle_call(Request, From, State) of
		{reply, Reply, State2} ->
			{reply, Reply, Server#server{state=State2}};
		{reply, Reply, State2, Timeout} ->
			{reply, Reply, Server#server{state=State2}, Timeout};
		{noreply, State2} ->
			{noreply, Server#server{state=State2}};
		{noreply, State2, Timeout} ->
			{noreply, Server#server{state=State2}, Timeout};
		{stop, Reason, Reply, State2} ->
			{stop, Reason, Reply, Server#server{state=State2}};
		{stop, Reason, State2} ->
			{stop, Reason, Server#server{state=State2}};
		Other ->
			Other
	end.

%% @private
handle_cast(Request, Server=#server{mod=Mod, state=State}) ->
	case catch Mod:handle_cast(Request, State) of
		{noreply, State2} ->
			{noreply, Server#server{state=State2}};
		{noreply, State2, Timeout} ->
			{noreply, Server#server{state=State2}, Timeout};
		{stop, Reason, State2} ->
			{stop, Reason, Server#server{state=State2}};
		Other ->
			Other
	end.

%% @private
handle_info({'$redneck_node', Message}, Server) ->
	handle_redneck_message(Message, Server);
handle_info(Info, Server=#server{mod=Mod, state=State}) ->
	case catch Mod:handle_info(Info, State) of
		Reply ->
			handle_common_reply(Reply, Server)
	end.

%% @private
terminate(Reason, #server{mod=Mod, state=State}) ->
	Mod:terminate(Reason, State).

%% @private
code_change(OldVsn, Server=#server{mod=Mod, state=State}, Extra) ->
	case catch Mod:code_change(OldVsn, State, Extra) of
		{ok, State2} ->
			{ok, Server#server{state=State2}};
		Else ->
			Else
	end.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
handle_common_reply({noreply, State}, Server) ->
	{noreply, Server#server{state=State}};
handle_common_reply({noreply, State, Timeout}, Server) ->
	{noreply, Server#server{state=State}, Timeout};
handle_common_reply({stop, Reason, State}, Server) ->
	{stop, Reason, Server#server{state=State}};
handle_common_reply(Other, _Server) ->
	Other.

%% @private
handle_redneck_message({syn, From, Node, Meta}, Server=#server{mod=Mod, state=State}) ->
	Meta = redneck_node:ack(From, Node, Meta),
	Server2 = Server#server{node=Node, meta=Meta},
	case catch Mod:handle_redneck({syn, Node, Meta}, State) of
		Reply ->
			handle_common_reply(Reply, Server2)
	end;
handle_redneck_message({msg, To, {'$redneck_cast', Message}}, Server=#server{node=To, mod=Mod, state=State}) ->
	case catch Mod:handle_redneck_cast(Message, State) of
		Reply ->
			handle_common_reply(Reply, Server)
	end;
handle_redneck_message({msg, To, Message}, Server=#server{node=To, mod=Mod, state=State}) ->
	case catch Mod:handle_redneck({notify, Message}, State) of
		Reply ->
			handle_common_reply(Reply, Server)
	end;
handle_redneck_message({msg, To, From, {'$redneck_call', Message}}, Server=#server{node=To, mod=Mod, state=State}) ->
	case catch Mod:handle_redneck_call(Message, From, State) of
		{reply, Reply, State2} ->
			redneck:reply(From, Reply),
			{noreply, Server#server{state=State2}};
		{reply, Reply, State2, Timeout} ->
			redneck:reply(From, Reply),
			{noreply, Server#server{state=State2}, Timeout};
		{stop, Reason, Reply, State2} ->
			redneck:reply(From, Reply),
			{stop, Reason, Server#server{state=State2}};
		Reply ->
			handle_common_reply(Reply, Server)
	end;
handle_redneck_message({msg, To, From, Message}, Server=#server{node=To, mod=Mod, state=State}) ->
	case catch Mod:handle_redneck({request, From, Message}, State) of
		{reply, Reply, State2} ->
			redneck:reply(From, Reply),
			{noreply, Server#server{state=State2}};
		{reply, Reply, State2, Timeout} ->
			redneck:reply(From, Reply),
			{noreply, Server#server{state=State2}, Timeout};
		{stop, Reason, Reply, State2} ->
			redneck:reply(From, Reply),
			{stop, Reason, Server#server{state=State2}};
		Reply ->
			handle_common_reply(Reply, Server)
	end;
handle_redneck_message({close, Node}, Server=#server{node=Node, mod=Mod, state=State}) ->
	case catch Mod:handle_redneck({close, Node}, State) of
		Reply ->
			handle_common_reply(Reply, Server)
	end;
handle_redneck_message({error, Node, Reason}, Server=#server{node=Node, mod=Mod, state=State}) ->
	case catch Mod:handle_redneck_error({error, Node, Reason}, State) of
		Reply ->
			handle_common_reply(Reply, Server)
	end;
handle_redneck_message(Message, Server) ->
	error_logger:error_msg(
		"** ~p ~p unhandled redneck message in ~p/~p~n"
		"   Message was: ~p~n",
		[?MODULE, self(), handle_redneck_message, 2, Message]),
	{noreply, Server}.

%% @private
unregister_name({local, Name}) ->
	_ = (catch unregister(Name));
unregister_name({global, Name}) ->
	_ = global:unregister_name(Name);
unregister_name({via, Mod, Name}) ->
	_ = Mod:unregister_name(Name);
unregister_name(Pid) when is_pid(Pid) ->
	Pid.
