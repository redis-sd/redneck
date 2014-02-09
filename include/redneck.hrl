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

-ifndef(REDNECK_HRL).

-include_lib("redis_sd_client/include/redis_sd_client.hrl").
-include_lib("redis_sd_server/include/redis_sd_server.hrl").

-define(REDNECK_REQUEST, 0).
-define(REDNECK_RESPONSE, 1).
-define(REDNECK_NOTIFY, 2).

-define(REDNECK_TAG, 114).
-define(REDNECK_V1_VERS, 1).

-record(redneck_meta_v1, {
	priority = undefined :: undefined | non_neg_integer(),
	weight   = undefined :: undefined | non_neg_integer(),
	port     = undefined :: undefined | non_neg_integer(),
	target   = undefined :: undefined | binary()
}).

-type redneck_meta() :: #redneck_meta_v1{}.

-type redneck_ring() :: <<_:32>>.
-type redneck_node() :: <<_:64>>.

-record(redneck_msg_v1, {
	to      = undefined :: undefined | redneck_node(),
	from    = undefined :: undefined | redneck_node(),
	tag     = undefined :: undefined | term(),
	message = undefined :: undefined | term()
}).

-type redneck_msg() :: #redneck_msg_v1{}.

-define(REDNECK_NODE(Ring, Node), <<
	Ring:32/bits,
	Node:32/bits
>>).
-define(REDNECK_NODE(Ring), ?REDNECK_NODE(Ring, _)).
-define(REDNECK_NODE(), ?REDNECK_NODE(_, _)).

-define(REDNECK_META, #redneck_meta_v1).
-define(REDNECK_MSG, #redneck_msg_v1).

-define(REDNECK_HRL, 1).

-endif.
