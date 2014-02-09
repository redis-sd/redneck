%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pagodabox.com>
%%% @copyright 2014, Pagoda Box, Inc.
%%% @doc
%%%
%%% @end
%%% Created :  05 Sep 2013 by Andrew Bennett <andrew@pagodabox.com>
%%%-------------------------------------------------------------------
-module(redneck).
-behaviour(gen_server).

-include("redneck.hrl").

-define(SERVER, ?MODULE).
-define(TAB, ?MODULE).

%% API
-export([manual_start/0, start_link/0]).
-export([connected_endpoint/4]).
-export([node/0, nodes/0, ring/0, rings/0]).

%% Browse API
-export([new_browse/1, rm_browse/1, delete_browse/1, list_browses/0]).

%% Service API
-export([new_service/1, rm_service/1, delete_service/1, list_services/0]).

%% Name Server API
-export([register_name/2, whereis_name/1, unregister_name/1, send/2]).
-export([send/3, send/4, call/2, call/3, cast/2, reply/2]).

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
	ok = redis_sd:require([
		crypto,
		ryng,
		ranch
	]),
	ok = redis_sd_client:manual_start(),
	ok = redis_sd_server:manual_start(),
	redis_sd:require([
		redneck,
		sasl
	]).

%% @private
start_link() ->
	gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

connected_endpoint(Endpoint={?REDNECK_NODE(), ?REDNECK_META{}}, Key, BrowseRef, Status) ->
	gen_server:cast(?SERVER, {connected_endpoint, Endpoint, Key, BrowseRef, Status}).

node() ->
	case redneck_internal:nodes() of
		[Node=?REDNECK_NODE() | _] ->
			Node;
		_ ->
			undefined
	end.

nodes() ->
	[{Node, Status} || [Node, Status] <- ets:match(?TAB, {{node, '$1'}, '_', '$2'})].

ring() ->
	case ?MODULE:node() of
		?REDNECK_NODE(Ring) ->
			Ring;
		Error ->
			Error
	end.

rings() ->
	lists:usort([Ring || {?REDNECK_NODE(Ring), _Status} <- ?MODULE:nodes()]).

%%%===================================================================
%%% Browse API functions
%%%===================================================================

new_browse(BrowseConfig) when is_list(BrowseConfig) ->
	new_browse(redneck_config:list_to_browse(BrowseConfig));
new_browse(Browse=?REDIS_SD_BROWSE{ref=Ref}) ->
	Reply = redis_sd_client:new_browse(Browse),
	Pid = case Reply of
		{ok, P} ->
			P;
		{error, {already_started, P}} ->
			P
	end,
	ok = gen_server:cast(?SERVER, {new_browse, Ref, Pid}),
	Reply.

rm_browse(BrowseName) ->
	redis_sd_client:rm_browse(BrowseName).

delete_browse(BrowseName) ->
	redis_sd_client:delete_browse(BrowseName).

list_browses() ->
	BrowseRefs = gb_sets:from_list([BrowseRef || [BrowseRef] <- ets:match(?TAB, {{pid, browse, '$1'}, '_'})]),
	[Browse || Browse={BrowseRef, _} <- redis_sd_client:list_browses(), gb_sets:is_element(BrowseRef, BrowseRefs)].

%%%===================================================================
%%% Service API functions
%%%===================================================================

new_service(ServiceConfig) when is_list(ServiceConfig) ->
	new_service(redneck_config:list_to_service(ServiceConfig));
new_service(Service=?REDIS_SD_SERVICE{name=Ref}) ->
	Reply = redis_sd_server:new_service(Service),
	Pid = case Reply of
		{ok, P} ->
			P;
		{error, {already_started, P}} ->
			P
	end,
	ok = gen_server:cast(?SERVER, {new_service, Ref, Pid}),
	Reply.

rm_service(ServiceName) ->
	redis_sd_server:rm_service(ServiceName).

delete_service(ServiceName) ->
	redis_sd_server:delete_service(ServiceName).

list_services() ->
	ServiceRefs = gb_sets:from_list([ServiceRef || [ServiceRef] <- ets:match(?TAB, {{pid, service, '$1'}, '_'})]),
	[Service || Service={ServiceRef, _} <- redis_sd_server:list_services(), gb_sets:is_element(ServiceRef, ServiceRefs)].

%%%===================================================================
%%% Name Server API functions
%%%===================================================================

-spec register_name(Name::term(), Pid::pid()) -> 'yes' | 'no'.
register_name(Name, Pid) when is_pid(Pid) ->
	gen_server:call(?SERVER, {register_name, Name, Pid}, infinity).

-spec whereis_name(Name::term()) -> pid() | 'undefined'.
whereis_name(Ring = << _:32/bits >>) ->
	case redneck_ring:node_for(Ring, os:timestamp()) of
		{ok, Node} ->
			whereis_name(Node);
		_ ->
			undefined
	end;
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

-spec send(To::redneck_node() | redneck_ring(), Msg::term())
	-> Pid::pid().
send(Ring = << _:32/bits >>, Msg) ->
	case redneck_ring:node_for(Ring, os:timestamp()) of
		{ok, Node} ->
			?MODULE:send(Node, Msg);
		_ ->
			erlang:error(badarg, [Ring, Msg])
	end;
send(To=?REDNECK_NODE(), Msg) ->
	case whereis_name(To) of
		Pid when is_pid(Pid) ->
			Pid ! redneck_msg:new(To, Msg),
			Pid;
		undefined ->
			erlang:error(badarg, [To, Msg])
	end.

-spec send(To::redneck_node() | redneck_ring(), From::redneck_node(), Msg::term())
	-> Pid::pid().
send(Ring = << _:32/bits >>, From=?REDNECK_NODE(), Msg) ->
	case redneck_ring:node_for(Ring, os:timestamp()) of
		{ok, Node} ->
			send(Node, From, Msg);
		_ ->
			erlang:error(badarg, [Ring, From, Msg])
	end;
send(To=?REDNECK_NODE(), From=?REDNECK_NODE(), Msg) ->
	case whereis_name(To) of
		Pid when is_pid(Pid) ->
			Pid ! redneck_msg:new(To, From, Msg),
			Pid;
		undefined ->
			erlang:error(badarg, [To, From, Msg])
	end.

-spec send(To::redneck_node() | redneck_ring(), From::redneck_node(), Tag::term(), Msg::term())
	-> Pid::pid().
send(Ring = << _:32/bits >>, From=?REDNECK_NODE(), Tag, Msg) ->
	case redneck_ring:node_for(Ring, os:timestamp()) of
		{ok, Node} ->
			send(Node, From, Tag, Msg);
		_ ->
			erlang:error(badarg, [Ring, From, Tag, Msg])
	end;
send(To=?REDNECK_NODE(), From=?REDNECK_NODE(), Tag, Msg) ->
	case whereis_name(To) of
		Pid when is_pid(Pid) ->
			Pid ! redneck_msg:new(To, From, Tag, Msg),
			Pid;
		undefined ->
			erlang:error(badarg, [To, From, Tag, Msg])
	end.

call({To, From=?REDNECK_NODE()}, Request) ->
	case catch gen:call({via, ?MODULE, To}, {'$redneck_call', From}, Request) of
		{ok, Reply} ->
			Reply;
		{'EXIT', Reason} ->
			exit({Reason, {?MODULE, call, [{To, From}, Request]}})
	end;
call(To, Request) ->
	case ?MODULE:node() of
		From=?REDNECK_NODE() ->
			?MODULE:call({To, From}, Request);
		undefined ->
			exit({{error, no_local_node}, {?MODULE, call, [To, Request]}})
	end.

call({To, From=?REDNECK_NODE()}, Request, Timeout) ->
	case catch gen:call({via, ?MODULE, To}, {'$redneck_call', From}, Request, Timeout) of
		{ok, Reply} ->
			Reply;
		{'EXIT', Reason} ->
			exit({Reason, {?MODULE, call, [{To, From}, Request, Timeout]}})
	end;
call(To, Request, Timeout) ->
	case ?MODULE:node() of
		From=?REDNECK_NODE() ->
			?MODULE:call({To, From}, Request);
		undefined ->
			exit({{error, no_local_node}, {?MODULE, call, [To, Request, Timeout]}})
	end.

cast(To, Message) ->
	catch ?MODULE:send(To, {'$redneck_cast', Message}),
	ok.

reply({Pid, {To, From, Tag}}, Reply) ->
	catch erlang:send(Pid, redneck_msg:new(To, From, Tag, Reply)),
	Reply.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init([]) ->
	Monitors = [{{erlang:monitor(process, Pid), Pid}, Ref} || [Ref, Pid] <- ets:match(?TAB, {{name, '$1'}, '$2'})],
	ok = redis_sd_client_event:add_handler(redis_sd_event_handler, self()),
	ok = redis_sd_server_event:add_handler(redis_sd_event_handler, self()),
	ok = redneck_node_event:add_handler(redneck_event_handler, self()),
	ok = redneck_ring_event:add_handler(redneck_event_handler, self()),
	{ok, #state{monitors=Monitors}}.

%% @private
handle_call({register_name, Name, Pid}, _From, State=#state{monitors=Monitors}) ->
	case ets:insert_new(?TAB, {{name, Name}, Pid}) of
		true ->
			MonitorRef = erlang:monitor(process, Pid),
			{reply, yes, State#state{monitors=[{{MonitorRef, Pid}, {name, Name}} | Monitors]}};
		false ->
			{reply, no, State}
	end;
handle_call(_Request, _From, State) ->
	{reply, ignore, State}.

%% @private
handle_cast({new_browse, Ref, Pid}, State=#state{monitors=Monitors}) ->
	State2 = case ets:insert_new(?TAB, {{pid, browse, Ref}, Pid}) of
		true ->
			MonitorRef = erlang:monitor(process, Pid),
			State#state{monitors=[{{MonitorRef, Pid}, {browse, Ref}} | Monitors]};
		false ->
			State
	end,
	{noreply, State2};
handle_cast({new_service, Ref, Pid}, State=#state{monitors=Monitors}) ->
	State2 = case ets:insert_new(?TAB, {{pid, service, Ref}, Pid}) of
		true ->
			MonitorRef = erlang:monitor(process, Pid),
			State#state{monitors=[{{MonitorRef, Pid}, {service, Ref}} | Monitors]};
		false ->
			State
	end,
	{noreply, State2};
handle_cast({connected_endpoint, {Node, Meta}, Key, BrowseRef, Status}, State) ->
	case ets:member(?TAB, {pid, browse, BrowseRef}) of
		false ->
			{noreply, State};
		true ->
			case ets:lookup(?TAB, {node, Node}) of
				[{{node, Node}, {BrowseRef, Key, Meta}, Status}] ->
					{noreply, State};
				_ ->
					true = ets:insert(?TAB, {{node, Node}, {BrowseRef, Key, Meta}, Status}),
					{noreply, State}
			end
	end;
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_info({'$redis_sd', {record, add, Key, Record, Browse}}, State) ->
	ok = maybe_connect(Key, Record, Browse),
	{noreply, State};
handle_info({'$redis_sd', {record, expire, Key, Record, Browse}}, State) ->
	ok = maybe_disconnect(Key, Record, Browse),
	{noreply, State};
handle_info({'$redis_sd', _Event}, State) ->
	{noreply, State};
handle_info({'$redneck', _Event}, State) ->
	{noreply, State};
handle_info({'DOWN', MonitorRef, process, Pid, _Reason}, State=#state{monitors=Monitors}) ->
	case lists:keytake({MonitorRef, Pid}, 1, Monitors) of
		{value, {{MonitorRef, Pid}, {browse, Ref}}, Monitors2} ->
			true = ets:delete(?TAB, {pid, browse, Ref}),
			true = ets:match_delete(?TAB, {{node, '_'}, {Ref, '_', '_'}, '_'}),
			{noreply, State#state{monitors=Monitors2}};
		{value, {{MonitorRef, Pid}, {service, Ref}}, Monitors2} ->
			true = ets:delete(?TAB, {pid, service, Ref}),
			{noreply, State#state{monitors=Monitors2}};
		{value, {{MonitorRef, Pid}, {name, Name}}, Monitors2} ->
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
is_valid_node(Record, ?REDIS_SD_BROWSE{ref=BrowseRef}) ->
	case ets:member(?TAB, {pid, browse, BrowseRef}) of
		false ->
			false;
		true ->
			redneck_dns:is_valid(Record)
	end.

%% @private
maybe_connect(Key, Record=?REDIS_SD_DNS{}, Browse=?REDIS_SD_BROWSE{ref=BrowseRef}) ->
	case is_valid_node(Record, Browse) of
		{true, Endpoint={Node=?REDNECK_NODE(), Meta=?REDNECK_META{}}} ->
			case ets:match(?TAB, {{node, Node}, {BrowseRef, Key, Meta}, '$1'}) of
				[[true]] ->
					ok;
				R ->
					case R of
						[] ->
							redneck_node_event:add(Node);
						_ ->
							ok
					end,
					_ = redneck_sup:start_worker(Endpoint, Key, Record, Browse, connect),
					ok
			end;
		false ->
			ok
	end.

%% @private
maybe_disconnect(Key, Record=?REDIS_SD_DNS{}, Browse=?REDIS_SD_BROWSE{}) ->
	case is_valid_node(Record, Browse) of
		{true, Endpoint={Node=?REDNECK_NODE(), ?REDNECK_META{}}} ->
			redneck_node_event:expire(Node),
			true = ets:delete(?TAB, {node, Node}),
			_ = redneck_sup:start_worker(Endpoint, Key, Record, Browse, disconnect),
			ok;
		false ->
			ok
	end.
