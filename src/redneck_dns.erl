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
-module(redneck_dns).

-include("redneck.hrl").

%% API
-export([is_valid/1, to_endpoint/1]).

%%%===================================================================
%%% API functions
%%%===================================================================

is_valid(Record=?REDIS_SD_DNS{txtdata=TXTData}) ->
	case get_values([<<"protocol">>, <<"version">>], TXTData) of
		[<<"redneck">>, <<"1">>] ->
			{true, to_endpoint(Record)};
		_ ->
			false
	end.

to_endpoint(?REDIS_SD_DNS{domain=Domain, type=Type, service=Service,
		instance=Instance, target=Target, port=Port,
		priority=Priority, weight=Weight}) ->
	RingTerm = {Domain, Type, Service},
	NodeTerm = {Domain, Type, Service, Instance},
	Ring = ryng:int_to_bin(erlang:phash2(RingTerm), 32),
	Node = ryng:int_to_bin(erlang:phash2(NodeTerm), 32),
	Meta = ?REDNECK_META{priority=Priority, weight=Weight, port=Port,
		target=Target},
	{?REDNECK_NODE(Ring, Node), Meta}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
get_values(Keys, Opts) ->
	gv(Keys, Opts, []).

%% @private
gv([], _Opts, Acc) ->
	lists:reverse(Acc);
gv([Key | Keys], Opts, Acc) ->
	case get_value(Key, Opts) of
		undefined ->
			undefined;
		Val ->
			gv(Keys, Opts, [Val | Acc])
	end.

%% @private
get_value(Key, Opts) ->
	get_value(Key, Opts, undefined).

%% @doc Faster alternative to proplists:get_value/3.
%% @private
get_value(Key, Opts, Default) ->
	case lists:keyfind(Key, 1, Opts) of
		{_, Value} -> Value;
		_ -> Default
	end.
