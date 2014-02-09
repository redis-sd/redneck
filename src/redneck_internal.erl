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
-module(redneck_internal).
-behaviour(gen_server).

-include("redneck.hrl").

-define(SERVER, ?MODULE).
-define(TAB, ?MODULE).

%% API
-export([start_link/0]).
-export([nodes/0, rings/0]).

%% Name Server API
-export([register_name/2, whereis_name/1, unregister_name/1, send/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	terminate/2, code_change/3]).

-type monitors() :: [{{reference(), pid()}, any()}].
-record(state, {
	monitors = [] :: monitors()
}).

%%%===================================================================
%%% API functions
%%%===================================================================

%% @private
start_link() ->
	gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

nodes() ->
	[Node || [Node] <- ets:match(?TAB, {{name, {node_server, '$1'}}, '_'})].

rings() ->
	lists:usort([Ring || ?REDNECK_NODE(Ring) <- ?MODULE:nodes()]).

%%%===================================================================
%%% Name Server API functions
%%%===================================================================

-spec register_name(Name::term(), Pid::pid()) -> 'yes' | 'no'.
register_name(Name, Pid) when is_pid(Pid) ->
	gen_server:call(?SERVER, {register_name, Name, Pid}, infinity).

-spec whereis_name(Name::term()) -> pid() | 'undefined'.
whereis_name(Name) ->
	case ets:lookup(?TAB, {name, Name}) of
		[{{name, Name}, Pid}] ->
			case erlang:is_process_alive(Pid) of
				true ->
					Pid;
				false ->
					undefined
			end;
		[] ->
			undefined
	end.

-spec unregister_name(Name::term()) -> term().
unregister_name(Name={proxy, Node}) ->
	ok = redneck:unregister_name(Node),
	case whereis_name(Name) of
		undefined ->
			ok;
		_ ->
			_ = ets:delete(?TAB, {name, Name}),
			ok
	end;
unregister_name(Name) ->
	case whereis_name(Name) of
		undefined ->
			ok;
		_ ->
			_ = ets:delete(?TAB, {name, Name}),
			ok
	end.

-spec send(Name::term(), Msg::term()) -> Pid::pid().
send(Name, Msg) ->
	case whereis_name(Name) of
		Pid when is_pid(Pid) ->
			Pid ! Msg,
			Pid;
		undefined ->
			erlang:error(badarg, [Name, Msg])
	end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init([]) ->
	Monitors = [{{erlang:monitor(process, Pid), Pid}, Ref} || [Ref, Pid] <- ets:match(?TAB, {{name, '$1'}, '$2'})],
	State = #state{monitors=Monitors},
	{ok, State}.

%% @private
handle_call({register_name, Name={proxy, Node}, Pid}, _From, State=#state{monitors=Monitors}) ->
	case redneck:register_name(Node, Pid) of
		yes ->
			{Reply, Monitors2} = ets_register_name(Name, Pid, Monitors),
			{reply, Reply, State#state{monitors=Monitors2}};
		no ->
			{reply, no, State}
	end;
handle_call({register_name, Name, Pid}, _From, State=#state{monitors=Monitors}) ->
	{Reply, Monitors2} = ets_register_name(Name, Pid, Monitors),
	{reply, Reply, State#state{monitors=Monitors2}};
handle_call(_Request, _From, State) ->
	{reply, ignore, State}.

%% @private
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_info({'DOWN', MonitorRef, process, Pid, Reason}, State=#state{monitors=Monitors}) ->
	case lists:keytake({MonitorRef, Pid}, 1, Monitors) of
		{value, {{MonitorRef, Pid}, {name, Name}}, Monitors2} ->
			case {Name, Reason} of
				{{tcp_client, Node}, normal} ->
					ok = redneck_sup:stop_client(Node);
				{{proxy, Node}, _} ->
					ok = redneck:unregister_name(Node);
				_ ->
					ok
			end,
			true = ets:delete(?TAB, {name, Name}),
			{noreply, State#state{monitors=Monitors2}};
		false ->
			{noreply, State}
	end;
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
ets_register_name(Name, Pid, Monitors) ->
	case ets:insert_new(?TAB, {{name, Name}, Pid}) of
		true ->
			MonitorRef = erlang:monitor(process, Pid),
			{yes, [{{MonitorRef, Pid}, {name, Name}} | Monitors]};
		false ->
			{no, Monitors}
	end.
