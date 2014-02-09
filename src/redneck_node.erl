%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pagodabox.com>
%%% @copyright 2014, Pagoda Box, Inc.
%%% @doc
%%%
%%% @end
%%% Created :  31 Jan 2014 by Andrew Bennett <andrew@pagodabox.com>
%%%-------------------------------------------------------------------
-module(redneck_node).

-include("redneck.hrl").

%% API
-export([start_link/3]).
-export([ack/1, ack/3, stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	terminate/2, code_change/3]).

-record(state, {
	service = undefined :: undefined | redis_sd_service(),
	record  = undefined :: undefined | redis_sd_dns(),
	node    = undefined :: undefined | redneck_node(),
	meta    = undefined :: undefined | redneck_meta(),
	child   = undefined :: undefined | pid(),
	monitor = undefined :: undefined | reference()
}).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link(Mod, Args, Service=?REDIS_SD_SERVICE{name=ServiceName}) ->
	gen_server:start_link({via, redneck_internal, {node, ServiceName}}, ?MODULE, {Mod, Args, Service?REDIS_SD_SERVICE{enabled=false}}, []).

ack(Node) ->
	receive
		{'$redneck_node', {syn, From={_, _}, Node, Meta}} ->
			ack(From, Node, Meta)
	end.

ack({To, Tag}, Node, Meta) ->
	To ! {'$redneck_node', {ack, Tag, Node, Meta}},
	Meta.

stop(ServiceName) ->
	gen_server:call({via, redneck_internal, {node, ServiceName}}, stop).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%% @private
init({Mod, Args, Service=?REDIS_SD_SERVICE{name=ServiceName}}) ->
	ok = redis_sd_server_service:disable(ServiceName),
	ok = redis_sd_server_event:add_handler(redis_sd_event_handler, self()),
	_Pid = case redneck:new_service(Service) of
		{ok, P} ->
			P;
		{error, {already_started, P}} ->
			P
	end,
	{ok, Record=?REDIS_SD_DNS{}} = redis_sd_server:get_record(ServiceName),
	{Node, Meta} = redneck_dns:to_endpoint(Record),
	Child = case Mod:start_link(Node, Args) of
		{ok, C} ->
			C;
		{error, {already_started, C}} ->
			C
	end,
	Monitor = erlang:monitor(process, Child),
	State = #state{service=Service, record=Record, node=Node,
		meta=Meta, child=Child, monitor=Monitor},
	Tag = erlang:make_ref(),
	Child ! {'$redneck_node', {syn, {self(), Tag}, Node, Meta}},
	ok = redneck_internal:unregister_name({node_server, Node}),
	yes = redneck_internal:register_name({node_server, Node}, Child),
	receive
		{'$redneck_node', {ack, Tag, Node, Meta}} ->
			ok = redis_sd_server_service:enable(ServiceName),
			{ok, State}
	after
		5000 ->
			{stop, {error, timeout}}
	end.

%% @private
handle_call(stop, _From, State) ->
	{stop, normal, ok, State};
handle_call(_Request, _From, State) ->
	{reply, ignore, State}.

%% @private
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_info({'$redis_sd', {service, announce, _Data, ?REDIS_SD_SERVICE{name=Name, rec=Record}}}, State=#state{node=OldNode, meta=OldMeta, service=?REDIS_SD_SERVICE{name=Name}}) ->
	case redneck_dns:to_endpoint(Record) of
		{OldNode, OldMeta} ->
			{noreply, State};
		{Node, Meta} ->
			Tag = erlang:make_ref(),
			State#state.child ! {'$redneck_node', {syn, {self(), Tag}, Node, Meta}},
			case Node of
				OldNode ->
					ok;
				_ ->
					ok = redneck_internal:unregister_name({node_server, OldNode}),
					yes = redneck_internal:register_name({node_server, Node}, State#state.child)
			end,
			State2 = State#state{node=Node, meta=Meta, record=Record},
			receive
				{'$redneck_node', {ack, Tag, Node, Meta}} ->
					{noreply, State2}
			after
				5000 ->
					{stop, {error, timeout}, State2}
			end
	end;
handle_info({'$redis_sd', {service, terminate, Reason, ?REDIS_SD_SERVICE{name=Name}}}, State=#state{service=?REDIS_SD_SERVICE{name=Name}}) ->
	{stop, {error, {service_terminated, Reason}}, State};
handle_info({'$redis_sd', _Event}, State) ->
	{noreply, State};
handle_info(Info, State) ->
	error_logger:error_msg(
		"** ~p ~p unhandled info in ~p/~p~n"
		"   Info was: ~p~n",
		[?MODULE, self(), handle_info, 2, Info]),
	{noreply, State}.

%% @private
terminate(normal, #state{child=Child, node=Node}) ->
	catch Child ! {'$redneck_node', {close, Node}},
	ok;
terminate(Reason, #state{child=Child, node=Node}) ->
	catch Child ! {'$redneck_node', {error, Node, Reason}},
	ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
