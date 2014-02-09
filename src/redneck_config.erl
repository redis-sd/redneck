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
-module(redneck_config).

-include("redneck.hrl").

%% API
-export([list_to_browse/1, list_to_browse/2, list_to_service/1, list_to_service/2]).

%% Service API
-export([service_instance/1, service_port/1, service_target/1, service_txtdata/2]).

%%%===================================================================
%%% API functions
%%%===================================================================

-spec list_to_browse([{atom(), term()}]) -> redis_sd_browse().
list_to_browse(BrowseConfig) ->
	list_to_browse([], BrowseConfig).

-spec list_to_browse([module()], [{atom(), term()}]) -> redis_sd_browse().
list_to_browse(Apps, BrowseConfig) when is_list(Apps) ->
	_Default = ?REDIS_SD_BROWSE{},
	Defaults = [
		{domain, "local", app},
		{type, "tcp", force},
		{service, "redneck", app}
	],
	B = redis_sd_config:merge(Apps ++ [redneck], Defaults, BrowseConfig),
	redis_sd_client_config:list_to_browse(Apps ++ [redneck], B).

-spec list_to_service([{atom(), term()}]) -> redis_sd_service().
list_to_service(ServiceConfig) ->
	list_to_service([], ServiceConfig).

-spec list_to_service([module()], [{atom(), term()}]) -> redis_sd_service().
list_to_service(Apps, ServiceConfig) when is_list(Apps) ->
	_Default = ?REDIS_SD_SERVICE{},
	Defaults = [
		{domain, "local", app},
		{type, "tcp", force},
		{service, "redneck", app},
		{instance, wrap_service_instance(ServiceConfig), app},
		{ttl, 120, app},
		{priority, 0, app},
		{weight, 0, app},
		{port, fun ?MODULE:service_port/1, app},
		{target, fun ?MODULE:service_target/1, app},
		fun config_service_txtdata/1
	],
	S = redis_sd_config:merge(Apps ++ [redneck], Defaults, ServiceConfig),
	redis_sd_server_config:list_to_service(Apps ++ [redneck], S).

%%%===================================================================
%%% Service API functions
%%%===================================================================

service_instance(_Record) ->
	atom_to_list(node()) ++ ":redneck".

service_port(_Record) ->
	try
		ranch:get_port(redneck_tcp_server)
	catch
		_:_ ->
			0
	end.

service_target(?REDIS_SD_DNS{domain=Domain}) ->
	{ok, Hostname} = inet:gethostname(),
	redis_sd_ns:join([Hostname, Domain]).

service_txtdata(Record, TXTData) ->
	[
		{"protocol", "redneck"},
		{"version", "1"}
		| redis_sd_server_dns:val(Record, TXTData)
	].

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
config_service_txtdata(S) ->
	case lists:keyfind(txtdata, 1, S) of
		false ->
			[{txtdata, {fun ?MODULE:service_txtdata/2, [[]]}} | S];
		{txtdata, TXTData} ->
			[{txtdata, {fun ?MODULE:service_txtdata/2, [TXTData]}} | S]
	end.

%% @private
wrap_service_instance(S) ->
	case lists:keyfind(name, 1, S) of
		false ->
			fun ?MODULE:service_instance/1;
		{name, Name} ->
			fun() ->
				atom_to_list(node()) ++ ":redneck:" ++ atom_to_list(Name)
			end
	end.
