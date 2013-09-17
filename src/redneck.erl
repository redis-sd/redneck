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
-module(redneck).
-behaviour(gen_server).

-include("redneck.hrl").

-define(SERVER, redneck_name_server).
-define(TAB, redneck_names).

%% API
-export([manual_start/0, start_link/0]).
-export([node/0, node_names/0, nodes/0, ring/0, ring_names/0, rings/0]).

%% Browse API
-export([new_browse/1, rm_browse/1, delete_browse/1]).

%% Name Server API
-export([register_name/2, whereis_name/1, unregister_name/1, send/2, call/2, call/3, cast/2, reply/2]).

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

%% @doc Manually start redneck and all dependencies.
-spec manual_start() -> ok.
manual_start() ->
	redis_sd:require([
		crypto,
		ryng,
		ranch,
		hierdis,
		redis_sd_client,
		redis_sd_server,
		redneck
		,sasl
	]).

%% @private
start_link() ->
	gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

node() ->
	redneck_kernel:node().

node_names() ->
	lists:flatten(ets:match(?TAB, {{name, '$1'}, '_'})).

nodes() ->
	[begin
		redneck_node:call(Node, info)
	end || Node <- node_names()].

ring() ->
	redneck_kernel:ring().

ring_names() ->
	gb_sets:to_list(gb_sets:from_list([begin
		redneck_node:call(Node, ring)
	end || Node <- node_names()])).

rings() ->
	gb_sets:to_list(gb_sets:from_list([begin
		redneck_node:call(Node, ring_info)
	end || Node <- node_names()])).

%%%===================================================================
%%% Browse API functions
%%%===================================================================

new_browse(BrowseConfig) ->
	redis_sd_client:new_browse(redneck_browse_config:wrap(BrowseConfig)).

rm_browse(BrowseName) ->
	redis_sd_client:rm_browse(BrowseName).

delete_browse(BrowseName) ->
	redis_sd_client:delete_browse(BrowseName).

%%%===================================================================
%%% Name Server API functions
%%%===================================================================

-spec register_name(Name::term(), Pid::pid()) -> 'yes' | 'no'.
register_name(Name, Pid) when is_pid(Pid) ->
	gen_server:call(?SERVER, {register_name, Name, Pid}, infinity).

-spec whereis_name(Name::term()) -> pid() | 'undefined'.
whereis_name({Domain, Type, Service})
		when is_binary(Domain)
		andalso is_binary(Type)
		andalso is_binary(Service) ->
	whereis_name(redneck_kernel:ring({Domain, Type, Service}));
whereis_name(Ring) when is_atom(Ring) ->
	case ryng:node_for(Ring, erlang:now()) of
		{ok, Node} ->
			whereis_name(Node);
		_ ->
			undefined
	end;
whereis_name({Domain, Type, Service, Instance})
		when is_binary(Domain)
		andalso is_binary(Type)
		andalso is_binary(Service)
		andalso is_binary(Instance) ->
	Node = redneck_kernel:node({Domain, Type, Service, Instance}),
	whereis_name(Node);
whereis_name(Record=#dns_sd{}) ->
	Node = redneck_kernel:node(Record),
	whereis_name(Node);
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

call(Name, Request) ->
	case catch do_call(Name, '$redneck_call', Request, 5000) of
		{ok, Reply} ->
			Reply;
		{'EXIT', Reason} ->
			exit({Reason, {?MODULE, call, [Name, Request]}})
	end.

call(Name, Request, Timeout) ->
	case catch do_call(Name, '$redneck_call', Request, Timeout) of
		{ok, Reply} ->
			Reply;
		{'EXIT', Reason} ->
			exit({Reason, {?MODULE, call, [Name, Request, Timeout]}})
	end.

cast(Name, Message) ->
	catch send(Name, {'$redneck_cast', Message}),
	ok.

reply({Node, From}, Reply) ->
	catch redneck:send(Node, {'$redneck_reply', From, Reply}),
	Reply.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init([]) ->
	Monitors = [{{erlang:monitor(process, Pid), Pid}, Ref} || [Ref, Pid] <- ets:match(?TAB, {{name, '$1'}, '$2'})],
	{ok, #state{monitors=Monitors}}.

%% @private
handle_call({register_name, Name, Pid}, _From, State=#state{monitors=Monitors}) ->
	case ets:insert_new(?TAB, {{name, Name}, Pid}) of
		true ->
			MonitorRef = erlang:monitor(process, Pid),
			{reply, yes, State#state{monitors=[{{MonitorRef, Pid}, Name} | Monitors]}};
		false ->
			{reply, no, State}
	end;
handle_call(_Request, _From, State) ->
	{reply, ignore, State}.

%% @private
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_info({'DOWN', MonitorRef, process, Pid, _},
		State=#state{monitors=Monitors}) ->
	{_, Ref} = lists:keyfind({MonitorRef, Pid}, 1, Monitors),
	true = ets:delete(?TAB, {name, Ref}),
	Monitors2 = lists:keydelete({MonitorRef, Pid}, 1, Monitors),
	{noreply, State#state{monitors=Monitors2}};
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
do_call(Name, Label, Request, Timeout) ->
	case whereis_name(Name) of
		undefined ->
			exit(noproc);
		Process when is_pid(Process) ->
			try erlang:monitor(process, Process) of
				MRef ->
					catch erlang:send(Process, {Label, {self(), MRef}, Request}, [noconnect]),
					receive
						{MRef, Reply} ->
							erlang:demonitor(MRef, [flush]),
							{ok, Reply};
						{nodedown, MRef, Node} ->
							exit({nodedown, Node});
						{'DOWN', MRef, _, _, noconnection} ->
							Node = get_node(Process),
							exit({nodedown, Node});
						{'DOWN', MRef, _, _, Reason} ->
							exit(Reason)
					after
						Timeout ->
							erlang:demonitor(MRef, [flush]),
							exit(timeout)
					end
			catch
				error:_ ->
					Node = get_node(Process),
					erlang:monitor_node(Node, true),
					receive
						{nodedown, Node} ->
							erlang:monitor_node(Node, false),
							exit({nodedown, Node})
					after
						0 ->
							Tag = erlang:make_ref(),
							Process ! {Label, {self(), Tag}, Request},
							receive
								{Tag, Reply} ->
									erlang:monitor_node(Node, false),
									{ok, Reply};
								{nodedown, Node} ->
									erlang:monitor_node(Node, false),
									exit({nodedown, Node})
							after
								Timeout ->
									erlang:monitor_node(Node, false),
									exit(timeout)
							end
					end
			end
	end.

%% @private
get_node(Process) ->
	case Process of
		{_S, N} when is_atom(N) ->
			N;
		_ when is_pid(Process) ->
			erlang:node(Process)
	end.
