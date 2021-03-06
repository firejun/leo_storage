%%======================================================================
%%
%% Leo Storage
%%
%% Copyright (c) 2012-2014 Rakuten, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%======================================================================
-module(leo_sync_local_cluster).
-author('Yosuke Hara').

-behaviour(leo_ordning_reda_behaviour).

-include("leo_storage.hrl").
-include_lib("leo_logger/include/leo_logger.hrl").
-include_lib("leo_object_storage/include/leo_object_storage.hrl").
-include_lib("leo_ordning_reda/include/leo_ordning_reda.hrl").
-include_lib("leo_redundant_manager/include/leo_redundant_manager.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([start_link/3, stop/1, stack/5,  store/1]).
-export([handle_send/3,
         handle_fail/2]).


%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
%% @doc Add a container into the supervisor
%%
-spec(start_link(Node, BufSize, Timeout) ->
             ok | {error, any()} when Node::atom(),
                                      BufSize::integer(),
                                      Timeout::integer()).
start_link(Node, BufSize, Timeout) ->
    leo_ordning_reda_api:add_container(Node, [{module,      ?MODULE},
                                              {buffer_size, BufSize},
                                              {timeout,     Timeout}]).

%% @doc Remove a container from the supervisor
%%
-spec(stop(Node) ->
             ok | {error, any()} when Node::atom()).
stop(Node) ->
    leo_ordning_reda_api:remove_container(Node).


%% @doc Stack a object into the ordning&reda
%%
-spec(stack(DestNodes, AddrId, Key, Metadata, Object) ->
             ok |
             {error, any()} when DestNodes::[atom()],
                                 AddrId::integer(),
                                 Key::binary(),
                                 Metadata::#metadata{},
                                 Object::#?OBJECT{}).
stack(DestNodes, AddrId, Key, Metadata, Object) ->
    stack_fun(DestNodes, AddrId, Key, Metadata, Object, []).


%% Store stacked objects
%%
-spec(store(CompressedObjs) ->
             ok | {error, any()} when CompressedObjs::binary()).
store(CompressedObjs) ->
    case catch lz4:unpack(CompressedObjs) of
        {ok, OriginalObjects} ->
            case slice_and_replicate(OriginalObjects) of
                ok ->
                    ok;
                {error, _Cause} ->
                    {error, fail_storing_files}
            end;
        {_, Cause} ->
            {error, Cause}
    end.


%%--------------------------------------------------------------------
%% Callback
%%--------------------------------------------------------------------
%% @doc Handle send object to a remote-node.
%%
handle_send(Node,_StackedInfo, CompressedObjs) ->
    RPCKey = rpc:async_call(Node, ?MODULE, store, [CompressedObjs]),
    case rpc:nb_yield(RPCKey, ?DEF_REQ_TIMEOUT) of
        {value, ok} ->
            ok;
        {value, {error, Cause}} ->
            {error, Cause};
        {value, {badrpc, Cause}} ->
            {error, Cause};
        timeout = Cause ->
            {error, Cause}
    end.


%% @doc Handle a fail process
%%
-spec(handle_fail(atom(), list({integer(), string()})) ->
             ok | {error, any()}).
handle_fail(_, []) ->
    ok;
handle_fail(Node, [{AddrId, Key}|Rest]) ->
    ?warn("handle_fail/2","node:~w, addr-id:~w, key:~s", [Node, AddrId, Key]),
    QId = ?QUEUE_TYPE_PER_OBJECT,
    case leo_storage_mq:publish(QId, AddrId, Key, ?ERR_TYPE_REPLICATE_DATA) of
        ok ->
            void;
        {error, Cause} ->
            ?warn("handle_fail/2",
                  "qid:~p, addr-id:~p, key:~p, cause:~p", [QId, AddrId, Key, Cause])
    end,
    handle_fail(Node, Rest).


%%--------------------------------------------------------------------
%% INNER FUNCTION
%%--------------------------------------------------------------------
%% @doc
%%
-spec(stack_fun(list(atom()), integer(), string(), tuple(), binary(), list()) ->
             ok | {error, any()}).
stack_fun([],_AddrId,_Key,_Metadata,_Object, []) ->
    ok;
stack_fun([],_AddrId,_Key,_Metadata,_Object, E) ->
    {error, lists:reverse(E)};
stack_fun([Node|Rest] = NodeList, AddrId, Key, Metadata, Object, E) ->
    case node_state(Node) of
        ok ->
            MetaBin  = term_to_binary(Metadata),
            MetaSize = byte_size(MetaBin),
            ObjSize  = byte_size(Object),
            Data = << MetaSize:?DEF_BIN_META_SIZE, MetaBin/binary,
                      ObjSize:?DEF_BIN_OBJ_SIZE, Object/binary,
                      ?DEF_BIN_PADDING/binary >>,

            case leo_ordning_reda_api:stack(Node, {AddrId, Key}, Data) of
                ok ->
                    stack_fun(Rest, AddrId, Key, Metadata, Object, E);
                {error, undefined} ->
                    ok = start_link(Node, ?env_size_of_stacked_objs(), ?env_stacking_timeout()),
                    stack_fun(NodeList, AddrId, Key, Metadata, Object, E);
                {error, Cause} ->
                    stack_fun(Rest, AddrId, Key, Metadata, Object, [{Node, Cause}|E])
            end;
        {error, Cause} ->
            stack_fun(Rest, AddrId, Key, Metadata, Object, [{Node, Cause}|E])
    end.


%% @doc Retrieve the node state from redundant-manager and ordning-reda
%%
-spec(node_state(Node) ->
             ok | {error, inactive} when Node::atom()).
node_state(Node) ->
    case leo_redundant_manager_api:get_member_by_node(Node) of
        {ok, #member{state = ?STATE_RUNNING}} ->
            ok;
        _ ->
            {error, inactive}
    end.


%% @doc Slicing objects and Store objects
%%
-spec(slice_and_replicate(Objects) ->
             ok | {error, any()} when Objects::binary()).
slice_and_replicate(Objects) ->
    slice_and_replicate(Objects, []).

-spec(slice_and_replicate(binary(), list()) ->
             ok | {error, any()}).
slice_and_replicate(<<>>, []) ->
    ok;
slice_and_replicate(<<>>, Errors) ->
    {error, Errors};
slice_and_replicate(Objects, Errors) ->
    %% Retrieve metadata, object and pending objects
    {ok, Metadata, Object, Rest_5} = slice(Objects),

    %% store an object to object-storage
    case leo_storage_handler_object:head(Metadata#?METADATA.addr_id,
                                         Metadata#?METADATA.key, false) of
        {ok, #?METADATA{clock = Clock}} when Clock >= Metadata#?METADATA.clock ->
            slice_and_replicate(Rest_5, Errors);
        _ ->
            case leo_misc:get_env(leo_redundant_manager, ?PROP_RING_HASH) of
                {ok, RingHashCur} ->
                    case leo_object_storage_api:store(Metadata#?METADATA{ring_hash = RingHashCur},
                                                      Object) of
                        ok ->
                            slice_and_replicate(Rest_5, Errors);
                        {error, Cause} ->
                            ?warn("slice_and_replicate/2","key:~s, cause:~p",
                                  [binary_to_list(Metadata#?METADATA.key), Cause]),
                            slice_and_replicate(Rest_5, [Metadata|Errors])
                    end;
                _ ->
                    ?warn("slice_and_replicate/2","key:~s, cause:~p",
                          [binary_to_list(Metadata#?METADATA.key),
                           "Current ring-hash is not found"]),
                    slice_and_replicate(Rest_5, [Metadata|Errors])
            end
    end.

%% @private
slice(Objects) ->
    try
        %% Retrieve metadata
        <<MetaSize:?DEF_BIN_META_SIZE, Rest_1/binary>> = Objects,
        MetaBin  = binary:part(Rest_1, {0, MetaSize}),
        Rest_2   = binary:part(Rest_1, {MetaSize, byte_size(Rest_1) - MetaSize}),
        Metadata = binary_to_term(MetaBin),

        %% Retrieve object
        <<ObjSize:?DEF_BIN_OBJ_SIZE, Rest_3/binary>> = Rest_2,
        Object = binary:part(Rest_3, {0, ObjSize}),
        Rest_4  = binary:part(Rest_3, {ObjSize, byte_size(Rest_3) - ObjSize}),

        %% Retrieve footer
        <<_Fotter:64, Rest_5/binary>> = Rest_4,
        {ok, Metadata, Object, Rest_5}
    catch
        _:Cause ->
            ?error("slice/1","cause:~p",[Cause]),
            {error, invalid_format}
    end.
