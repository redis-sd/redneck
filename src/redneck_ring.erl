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
-module(redneck_ring).

-include("redneck.hrl").

%% API
-export([soft_new/1, soft_delete/1, add_node/3, del_node/1, node_for/2]).

%%%===================================================================
%%% API functions
%%%===================================================================

soft_new(Ring) ->
	case ryng:is_ring(Ring) of
		true ->
			ok;
		false ->
			_ = ryng:new_ring([{id, Ring}]),
			redneck_ring_event:up(Ring),
			ok
	end.

soft_delete(Ring) ->
	case ryng:is_ring_empty(Ring) of
		true ->
			ryng:rm_ring(Ring),
			redneck_ring_event:down(Ring),
			ok;
		_ ->
			ok
	end.

add_node(Node=?REDNECK_NODE(Ring), Weight, Priority) ->
	ryng:set_node(Ring, Node, Weight, Priority),
	ryng:sync_ring(Ring),
	redneck_node_event:up(Node),
	ok.

del_node(Node=?REDNECK_NODE(Ring)) ->
	ryng:del_node(Ring, Node),
	ryng:sync_ring(Ring),
	redneck_node_event:down(Node),
	ok.

node_for(Ring, Term) ->
	ryng:node_for(Ring, Term).
