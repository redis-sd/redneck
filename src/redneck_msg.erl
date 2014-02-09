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
-module(redneck_msg).

-include("redneck.hrl").

%% API
-export([new/2, new/3, new/4]).
-export([to_binary/1, to_binary_stream/2, from_binary/1, from_binary_stream/1]).

%%%===================================================================
%%% API functions
%%%===================================================================

new(To = << _:64/bits >>, Message) ->
	new(To, undefined, Message).

new(To = << _:64/bits >>, undefined, Message) ->
	new(To, undefined, undefined, Message);
new(To = << _:64/bits >>, From = << _:64/bits >>, Message) ->
	new(To, From, self(), Message).

new(To = << _:64/bits >>, undefined, _, Message) ->
	?REDNECK_MSG{to=To, message=Message};
new(To = << _:64/bits >>, From = << _:64/bits >>, Tag, Message) ->
	?REDNECK_MSG{to=To, from=From, tag=Tag, message=Message}.

to_binary(?REDNECK_MSG{to=To, from=From, tag=Tag, message=Message}) when From =/= undefined ->
	TagBinary = erlang:term_to_binary(Tag),
	TagLength = byte_size(TagBinary),
	TagLengthFieldLength = bit_size(binary:encode_unsigned(TagLength)),
	MessageBinary = erlang:term_to_binary(Message),
	MessageLength = byte_size(MessageBinary),
	MessageLengthFieldLength = bit_size(binary:encode_unsigned(MessageLength)),
	<<?REDNECK_TAG:8/integer, ?REDNECK_V1_VERS:8/integer,
		1:8/integer,
		To:64/bits,
		From:64/bits,
		TagLengthFieldLength:8/integer,
		TagLength:TagLengthFieldLength/big-unsigned-integer,
		TagBinary:TagLength/binary,
		MessageLengthFieldLength:8/integer,
		MessageLength:MessageLengthFieldLength/big-unsigned-integer,
		MessageBinary:MessageLength/binary
	>>;
to_binary(?REDNECK_MSG{to=To, from=undefined, message=Message}) ->
	MessageBinary = erlang:term_to_binary(Message),
	MessageLength = byte_size(MessageBinary),
	MessageLengthFieldLength = bit_size(binary:encode_unsigned(MessageLength)),
	<<?REDNECK_TAG:8/integer, ?REDNECK_V1_VERS:8/integer,
		0:8/integer,
		To:64/bits,
		MessageLengthFieldLength:8/integer,
		MessageLength:MessageLengthFieldLength/big-unsigned-integer,
		MessageBinary:MessageLength/binary
	>>.

to_binary_stream(Msg=?REDNECK_MSG{}, Stream) when is_binary(Stream) ->
	<< Stream/binary, (to_binary(Msg))/binary >>.

from_binary(Binary) when is_binary(Binary) ->
	{Msg, _Stream} = from_binary_stream(Binary),
	Msg.

from_binary_stream(<<?REDNECK_TAG:8/integer, ?REDNECK_V1_VERS:8/integer,
		1:8/integer,
		To:64/bits,
		From:64/bits,
		TagLengthFieldLength:8/integer,
		TagLength:TagLengthFieldLength/big-unsigned-integer,
		TagBinary:TagLength/binary,
		MessageLengthFieldLength:8/integer,
		MessageLength:MessageLengthFieldLength/big-unsigned-integer,
		MessageBinary:MessageLength/binary,
		Stream/binary
		>>) ->
	Tag = erlang:binary_to_term(TagBinary),
	Message = erlang:binary_to_term(MessageBinary),
	Msg = ?REDNECK_MSG{to=To, from=From, tag=Tag, message=Message},
	{Msg, Stream};
from_binary_stream(<<?REDNECK_TAG:8/integer, ?REDNECK_V1_VERS:8/integer,
		0:8/integer,
		To:64/bits,
		MessageLengthFieldLength:8/integer,
		MessageLength:MessageLengthFieldLength/big-unsigned-integer,
		MessageBinary:MessageLength/binary,
		Stream/binary
		>>) ->
	Message = erlang:binary_to_term(MessageBinary),
	Msg = ?REDNECK_MSG{to=To, message=Message},
	{Msg, Stream};
from_binary_stream(Stream = <<>>) ->
	{incomplete, Stream};
from_binary_stream(Stream = <<?REDNECK_TAG:8/integer>>) ->
	{incomplete, Stream};
from_binary_stream(Stream = <<?REDNECK_TAG:8/integer, ?REDNECK_V1_VERS:8/integer, _/binary>>) ->
	{incomplete, Stream}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
