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
-module(redneck_kernel).
-behaviour(gen_server).

-include("redneck.hrl").

-define(SERVER, ?MODULE).
-define(TAB, ?MODULE).
-define(BROWSE, redneck_kernel_browse).
-define(SERVICE, redneck_kernel_service).

%% API
-export([start_link/0]).
-export([watch/1, watch/2, unwatch/1, browse_name/1]).
-export([connect_node/1, disconnect_node/1, node/0, node/1, ring/0, ring/1]).
-export([get_port/0, get_port/1, get_record/0, get_target/0, get_target/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	terminate/2, code_change/3]).

-type monitors() :: [{{reference(), pid()}, any()}].
-record(state, {
	browse   = undefined :: undefined | {pid(), reference()},
	bref     = undefined :: undefiend | reference(),
	service  = undefined :: undefined | {pid(), reference()},
	sref     = undefined :: undefined | reference(),
	monitors = []        :: monitors()
}).

%%%===================================================================
%%% API functions
%%%===================================================================

%% @private
start_link() ->
	gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

watch([]) ->
	ok;
watch([{Service, BrowseConfig} | Watches]) ->
	watch(Service, BrowseConfig),
	watch(Watches);
watch([Service | Watches]) when is_list(Service) ->
	watch(iolist_to_binary(Service)),
	watch(Watches);
watch(Service) when is_list(Service) ->
	watch(iolist_to_binary(Service));
watch(Service) when is_binary(Service) ->
	watch(Service, []).

watch(Service, BrowseConfig0) ->
	BrowseConfig = merge_config([
		{service, Service, force}
	], BrowseConfig0),
	gen_server:call(?SERVER, {watch, browse_name(Service), BrowseConfig}).

unwatch(Service) ->
	gen_server:call(?SERVER, {unwatch, browse_name(Service)}).

connect_node(Record=#dns_sd{}) ->
	gen_server:call(?SERVER, {connect, Record}).

disconnect_node(Record=#dns_sd{}) ->
	gen_server:call(?SERVER, {disconnect, Record}).

node() ->
	?MODULE:node(get_record()).

node(Record=#dns_sd{}) ->
	?MODULE:node(redis_sd:obj_key(Record));
node({Domain, Type, Service, Instance}) ->
	erlang:phash2({Domain, Type, Service, Instance}).

ring() ->
	?MODULE:ring(get_record()).

ring(#dns_sd{domain=Domain, type=Type, service=Service}) ->
	ring({Domain, Type, Service});
ring({Domain, Type, Service}) ->
	list_to_atom(integer_to_list(erlang:phash2({Domain, Type, Service})));
ring(ServiceRef) when is_atom(ServiceRef) ->
	case redis_sd_client:list(ServiceRef) of
		[{{{browse, ServiceRef}, {Domain, Type, Service, _Instance}}, _} | _] ->
			ring({Domain, Type, Service});
		_ ->
			{error, ring_not_found}
	end;
ring(ServiceName) ->
	ServiceRef = browse_name(ServiceName),
	ring(ServiceRef).

get_port() ->
	try
		ranch:get_port(redneck_server)
	catch
		_:_ ->
			0
	end.

get_port(#dns_sd{port=Port}) ->
	Port.

get_record() ->
	{ok, Record} = redis_sd_server:get_record(?SERVICE),
	Record.

get_target() ->
	get_target(get_record()).

get_target(#dns_sd{domain=Domain, target=undefined}) ->
	{ok, Hostname} = inet:gethostname(),
	redis_sd_ns:join([Hostname, Domain]);
get_target(#dns_sd{target=Target}) ->
	Target.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init([]) ->
	case maybe_start_service() of
		{ok, ServicePid} when is_pid(ServicePid) ->
			case maybe_start_browse() of
				{ok, BrowsePid} ->
					?TAB = ryng_ets:soft_new(?TAB, [
						named_table,
						protected,
						ordered_set
					]),
					Monitors = [{{erlang:monitor(process, Pid), Pid}, Ref} || [Ref, Pid] <- ets:match(?TAB, {{name, '$1'}, '$2'})],
					Browse = {BrowsePid, erlang:monitor(process, BrowsePid)},
					Service = {ServicePid, erlang:monitor(process, ServicePid)},
					State = #state{browse=Browse, service=Service, monitors=Monitors},
					_ = erlang:spawn(?MODULE, watch, [application:get_env(redneck, watch, [])]),
					{ok, State};
				BrowseError ->
					ok = redis_sd_server:rm_service(?SERVICE),
					{stop, BrowseError}
			end;
		ServiceError ->
			{stop, ServiceError}
	end.

%% @private
handle_call({watch, BrowseName, BrowseConfig}, _From, State=#state{monitors=Monitors}) ->
	Result = case whereis(BrowseName) of
		undefined ->
			case start_browse(BrowseName, BrowseConfig) of
				{ok, BrowsePid} ->
					{ok, BrowsePid, BrowseName};
				StartError ->
					StartError
			end;
		ExistingPid when is_pid(ExistingPid) ->
			{ok, ExistingPid}
	end,
	case Result of
		{ok, Pid} ->
			case ets:insert_new(?TAB, {{name, BrowseName}, Pid}) of
				false ->
					{reply, {ok, Pid}, State};
				true ->
					true = ets:insert(?TAB, {{config, BrowseName}, BrowseConfig}),
					Monitors2 = [{{erlang:monitor(process, Pid), Pid}, BrowseName} | Monitors],
					{reply, {ok, Pid}, State#state{monitors=Monitors2}}
			end;
		Error ->
			{reply, Error, State}
	end;
handle_call({unwatch, BrowseName}, _From, State=#state{monitors=Monitors}) ->
	case lists:keytake(BrowseName, 2, Monitors) of
		{value, {{MonitorRef, _Pid}, BrowseName}, Monitors2} ->
			true = ets:delete(?TAB, {name, BrowseName}),
			true = ets:delete(?TAB, {config, BrowseName}),
			true = erlang:demonitor(MonitorRef),
			catch redis_sd_client:rm_browse(BrowseName),
			{reply, ok, State#state{monitors=Monitors2}};
		false ->
			{reply, ok, State}
	end;
handle_call({connect, Record=#dns_sd{}}, _From, State) ->
	Ring = redneck_kernel:ring(Record),
	case ryng:is_ring(Ring) of
		true ->
			ok;
		false ->
			_ = ryng:new_ring([{name, Ring}]),
			redneck_event:ringup(Ring, {Record#dns_sd.domain, Record#dns_sd.type, Record#dns_sd.service}),
			ok
	end,
	ok = redneck_node:connect(Record),
	{reply, ok, State};
handle_call({disconnect, Record=#dns_sd{}}, _From, State) ->
	ok = redneck_node:disconnect(Record),
	Ring = redneck_kernel:ring(Record),
	case ryng:is_ring_empty(Ring) of
		true ->
			ryng:rm_ring(Ring),
			redneck_event:ringdown(Ring, {Record#dns_sd.domain, Record#dns_sd.type, Record#dns_sd.service});
		_ ->
			ok
	end,
	{reply, ok, State};
handle_call(_Request, _From, State) ->
	{reply, ignore, State}.

%% @private
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_info({timeout, BRef, browse}, State=#state{bref=BRef}) ->
	case maybe_start_browse() of
		{ok, BrowsePid} ->
			Browse = {BrowsePid, erlang:monitor(process, BrowsePid)},
			State2 = State#state{browse=Browse, bref=undefined},
			{noreply, State2};
		BrowseError ->
			{stop, BrowseError, State}
	end;
handle_info({timeout, SRef, service}, State=#state{sref=SRef}) ->
	case maybe_start_service() of
		{ok, ServicePid} ->
			Service = {ServicePid, erlang:monitor(process, ServicePid)},
			State2 = State#state{service=Service, sref=undefined},
			{noreply, State2};
		ServiceError ->
			{stop, ServiceError, State}
	end;
handle_info({'DOWN', Ref, process, Pid, _Reason}, State=#state{browse={Pid, Ref}}) ->
	BRef = erlang:start_timer(100, self(), browse),
	{noreply, State#state{browse=undefined, bref=BRef}};
handle_info({'DOWN', Ref, process, Pid, _Reason}, State=#state{service={Pid, Ref}}) ->
	SRef = erlang:start_timer(100, self(), service),
	{noreply, State#state{service=undefined, sref=SRef}};
handle_info({'DOWN', MonitorRef, process, Pid, _Reason}, State=#state{monitors=Monitors}) ->
	case lists:keytake({MonitorRef, Pid}, 1, Monitors) of
		{value, {{MonitorRef, Pid}, Ref}, Monitors2} ->
			true = ets:delete(?TAB, {name, Ref}),
			try ets:lookup_element(?TAB, {config, Ref}, 2) of
				BrowseConfig ->
					erlang:spawn(fun() ->
						timer:sleep(100),
						gen_server:call(?SERVER, {watch, Ref, BrowseConfig})
					end),
					{noreply, State#state{monitors=Monitors2}}
			catch
				_:_ ->
					{noreply, State#state{monitors=Monitors2}}
			end;
		false ->
			{noreply, State}
	end;
handle_info({'ETS-TRANSFER', ?MODULE, _Pid, _Data}, State) ->
	{noreply, State};
handle_info(Info, State) ->
	error_logger:error_msg(
		"** ~p ~p unhandled info in ~p/~p~n"
		"   Info was: ~p~n",
		[?MODULE, self(), handle_info, 2, Info]),
	{noreply, State}.

%% @private
terminate(normal, _State) ->
	catch redis_sd_client:rm_browse(?BROWSE),
	catch redis_sd_server:rm_service(?SERVICE),
	ok;
terminate(_Reason, _State) ->
	ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
browse_name(Service) ->
	binary_to_atom(iolist_to_binary(io_lib:format("redneck_kernel_browse_~s", [Service])), unicode).

%% @private
config_browser(B) ->
	{BrowserOpts, B2} = case lists:keytake(browser_opts, 1, B) of
		false ->
			{[], B};
		{value, {browser_opts, BOpts}, BWithoutOpts} ->
			{BOpts, BWithoutOpts}
	end,
	case lists:keytake(browser, 1, B2) of
		false ->
			[{browser, redneck_browser}, {browser_opts, []} | B2];
		{value, {browser, SubBrowser}, B3} ->
			[{browser, redneck_browser}, {browser_opts, [{browser, SubBrowser}, {opts, BrowserOpts}]} | B3]
	end.

%% @private
config_txtdata(S) ->
	case lists:keyfind(txtdata, 1, S) of
		false ->
			[{txtdata, {fun merge_txtdata/2, [[]]}} | S];
		{txtdata, TXTData} ->
			[{txtdata, {fun merge_txtdata/2, [TXTData]}} | S]
	end.

%% @private
make_instance() ->
	erlang:phash2(erlang:node()).

%% @private
merge_config([], Config) ->
	Config;
merge_config([F | Defaults], Config) when is_function(F, 1) ->
	merge_config(Defaults, F(Config));
merge_config([{Key, Val} | Defaults], Config) ->
	Config2 = case lists:keyfind(Key, 1, Config) of
		false ->
			[{Key, Val} | Config];
		_ ->
			Config
	end,
	merge_config(Defaults, Config2);
merge_config([{Key, Val, force} | Defaults], Config) ->
	merge_config(Defaults, lists:keystore(Key, 1, Config, {Key, Val})).

%% @private
merge_txtdata(DNSSD, TXTData) ->
	[
		{"protocol", "redneck"},
		{"version", "0"}
		| redis_sd_server_dns:val(DNSSD, TXTData)
	].

%% @private
maybe_start_browse() ->
	case whereis(?BROWSE) of
		undefined ->
			start_browse();
		Pid when is_pid(Pid) ->
			{ok, Pid}
	end.

%% @private
start_browse() ->
	start_browse(?BROWSE, []).

%% @private
start_browse(BrowseName, BrowseConfig0) ->
	Defaults = [
		{name, BrowseName, force},
		{domain, "local"},
		{type, "tcp"},
		{service, "redneck"},
		fun config_browser/1
	],
	BrowseConfig = merge_config(merge_config(Defaults, application:get_env(redneck, browse, [])), BrowseConfig0),
	Result = case redis_sd_client:new_browse(BrowseConfig) of
		{ok, _} ->
			ok;
		{error, {already_started, _}} ->
			ok;
		BrowseError ->
			BrowseError
	end,
	case Result of
		ok ->
			case whereis(BrowseName) of
				undefined ->
					{error, {not_found, BrowseName}};
				Pid when is_pid(Pid) ->
					{ok, Pid}
			end;
		_ ->
			Result
	end.

%% @private
maybe_start_service() ->
	case whereis(?SERVICE) of
		undefined ->
			Res = start_service(),
			Res;
		Pid when is_pid(Pid) ->
			{ok, Pid}
	end.

%% @private
start_service() ->
	Defaults = [
		{name, ?SERVICE, force},
		{domain, "local"},
		{type, "tcp"},
		{service, "redneck"},
		{instance, fun make_instance/0},
		{ttl, 120},
		{priority, 0},
		{weight, 0},
		{port, fun redneck_kernel:get_port/0},
		{target, fun redneck_kernel:get_target/1},
		fun config_txtdata/1
	],
	ServiceConfig = merge_config(Defaults, application:get_env(redneck, service, [])),
	Result = case redis_sd_server:new_service(ServiceConfig) of
		{ok, _} ->
			ok;
		{error, {already_started, _}} ->
			ok;
		ServiceError ->
			ServiceError
	end,
	case Result of
		ok ->
			case whereis(?SERVICE) of
				undefined ->
					{error, {not_found, ?SERVICE}};
				Pid when is_pid(Pid) ->
					{ok, Pid}
			end;
		_ ->
			Result
	end.
