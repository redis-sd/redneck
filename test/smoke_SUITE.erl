%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet

-module(smoke_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("../include/redneck.hrl").

-define(REDIS_NS, "smoke_SUITE:").

%% ct.
-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).

%% Tests.
-export([
	smoke/1
]).

all() ->
	[
		{group, tcp_simple},
		{group, unix_simple}
	].

groups() ->
	Tests = [
		smoke
	],
	[
		{tcp_simple, [parallel], Tests},
		{unix_simple, [parallel], Tests}
	].

init_per_suite(Config) ->
	ok = application:start(redis_test_server),
	ok = application:start(crypto),
	ok = application:start(ryng),
	ok = application:start(ranch),
	ok = application:start(hierdis),
	ok = application:start(backoff),
	ok = application:start(redis_sd_spec),
	ok = application:start(redis_sd_client),
	ok = application:start(redis_sd_server),
	ok = application:start(redneck),
	Config.

end_per_suite(_Config) ->
	application:stop(redneck),
	application:stop(redis_sd_server),
	application:stop(redis_sd_client),
	application:stop(redis_sd_spec),
	application:stop(backoff),
	application:stop(hierdis),
	application:stop(ranch),
	application:stop(ryng),
	application:stop(crypto),
	application:stop(redis_test_server),
	ok.

init_per_group(Name, Config) ->
	ct:log("starting ~s server...", [Name]),
	Options = redis_options_for_group(Name),
	{ok, _Pid} = redis_test_server:start_listener(Name, Options),
	ct:log("started"),
	[{redis_ref, Name} | Config].

end_per_group(Name, _Config) ->
	ct:log("stopping ~s server...", [Name]),
	redis_test_server:stop_listener(Name),
	ct:log("stopped"),
	ok.

%%====================================================================
%% Tests
%%====================================================================

smoke(Config) ->
	Name = ?config(redis_ref, Config),
	ok = redneck_node_event:add_handler(redneck_event_handler, self()),
	{_Browse, BrowseConfig} = browse_for_group(Name),
	?REDIS_SD_BROWSE{ref=BrowseRef} = redneck_config:list_to_browse(BrowseConfig),
	{Service, ServiceConfig} = service_for_group(Name),
	[] = redneck:nodes(),
	{ok, _} = redneck:new_browse(BrowseConfig),
	ok = ensure_whereis(fun redis_sd_client:whereis_name/1, {pid, BrowseRef}, 100, 10),
	ignore = gen_server:call(redneck, ignore),
	[{BrowseRef, _}] = redneck:list_browses(),
	{ok, _} = test_node:start_link(ServiceConfig),
	ignore = gen_server:call(redneck, ignore),
	ok = ensure_whereis(fun erlang:whereis/1, test_node, 100, 10),
	[{Service, _}] = redneck:list_services(),
	Node = redneck:node(),
	ok = receive
		{'$redneck', {node, add, Node}} ->
			wait_for_message({'$redneck', {node, up, Node}}, 5000),
			ignore = gen_server:call(redneck, ignore),
			case redneck:nodes() of
				[{Node, true}] ->
					ok;
				Nodes0 ->
					ct:fail(
						"Expected ~p to be found in nodes list.~n"
						"Actual: ~p",
						[Node, Nodes0])
			end,

			Pid = redneck:whereis_name(Node),

			%% Call
			CallRef = erlang:make_ref(),
			{echo_call, CallRef} = redneck:call(Node, CallRef),

			%% Cast
			CastRef = erlang:make_ref(),
			ok = redneck:cast(Node, {self(), CastRef}),
			ok = wait_for_message({echo_cast, CastRef}, 5000),

			%% Notify
			NotifyRef = erlang:make_ref(),
			Pid = redneck:send(Node, {self(), NotifyRef}),
			ok = wait_for_message({echo_notify, NotifyRef}, 5000),

			%% Request
			RequestRef = erlang:make_ref(),
			Pid = redneck:send(Node, Node, RequestRef),
			ok = wait_for_message({echo_request, RequestRef}, 5000),
			Pid = redneck:send(Node, Node, self(), RequestRef),
			ok = wait_for_message({echo_request, RequestRef}, 5000),

			ok = redneck_sup:stop_node(Service),
			ok = wait_for_message({'$redneck', {node, expire, Node}}, 5000),
			case redneck:nodes() of
				[] ->
					ok;
				Nodes1 ->
					ct:fail(
						"Expected ~p to be found in nodes list.~n"
						"Actual: ~p",
						[Node, Nodes1])
			end,
			ok = redneck:rm_browse(BrowseRef)
	after
		5000 ->
			message_timeout({'$redneck', {node, add, Node}}, 5000)
	end,
	ok.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

%% @private
browse_for_group(tcp_simple) ->
	{tcp_simple_browse, [
		{service, "tcp-simple"},
		{type, "tcp"},
		{domain, "local"},
		{redis_ns, ?REDIS_NS},
		{redis_opts, {tcp, ["127.0.0.1", redis_test_server:get_port(tcp_simple)]}}
	]};
browse_for_group(unix_simple) ->
	{unix_simple_browse, [
		{service, "unix-simple"},
		{type, "tcp"},
		{domain, "local"},
		{redis_ns, ?REDIS_NS},
		{redis_opts, {unix, [redis_test_server:get_path(unix_simple)]}}
	]}.

%% @private
service_for_group(tcp_simple) ->
	{tcp_simple_service, [
		{name, tcp_simple_service},
		{service, "tcp-simple"},
		{type, "tcp"},
		{domain, "local"},
		{redis_ns, ?REDIS_NS},
		{redis_opts, {tcp, ["127.0.0.1", redis_test_server:get_port(tcp_simple)]}}
	]};
service_for_group(unix_simple) ->
	{unix_simple_service, [
		{name, unix_simple_service},
		{service, "unix-simple"},
		{type, "tcp"},
		{domain, "local"},
		{redis_ns, ?REDIS_NS},
		{redis_opts, {unix, [redis_test_server:get_path(unix_simple)]}}
	]}.

%% @private
redis_options_for_group(tcp_simple) ->
	[{tcp, true}];
redis_options_for_group(unix_simple) ->
	[{unix, true}].

%% @private
ensure_whereis(Fun, Ref, Wait, {Retried, Retried}) ->
	case Fun(Ref) of
		Pid when is_pid(Pid) ->
			ok;
		Other ->
			ct:fail(
				"erlang:whereis/1 failed for ~p after waiting ~pms~n"
				"Returned: ~p",
				[Ref, Wait * Retried, Other])
	end;
ensure_whereis(Fun, Ref, Wait, {Retries, Retried}) ->
	case Fun(Ref) of
		Pid when is_pid(Pid) ->
			ok;
		_ ->
			timer:sleep(Wait),
			ensure_whereis(Fun, Ref, Wait, {Retries, Retried + 1})
	end;
ensure_whereis(Fun, Ref, Wait, Retries) ->
	ensure_whereis(Fun, Ref, Wait, {Retries, 0}).

%% @private
wait_for_message(Message, Timeout) ->
	receive
		Message ->
			ok
	after
		Timeout ->
			message_timeout(Message, Timeout)
	end.

%% @private
message_timeout(Message, Timeout) ->
	receive
		Received ->
			ct:fail(
				"Waited ~pms for message.~n"
				"Expected: ~p~n"
				"Received: ~p",
				[Timeout, Message, Received])
	after
		0 ->
			ct:fail(
				"Waited ~pms for message, but received nothing.~n"
				"Expected: ~p",
				[Timeout, Message])
	end.
