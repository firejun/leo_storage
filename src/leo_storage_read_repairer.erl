%%======================================================================
%%
%% LeoFS Storage
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
%%
%% ---------------------------------------------------------------------
%% LeoFS Storage - Read Repair Server.
%% @doc
%% @end
%%======================================================================
-module(leo_storage_read_repairer).

-author('Yosuke Hara').

-include("leo_storage.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("leo_logger/include/leo_logger.hrl").
-include_lib("leo_object_storage/include/leo_object_storage.hrl").
-include_lib("leo_redundant_manager/include/leo_redundant_manager.hrl").

%% API
-export([repair/4]).

-record(state, {addr_id = 0       :: non_neg_integer(),
                key               :: string(),
                read_quorum = 0   :: integer(),
                redundancies = [] :: list(),
                metadata          :: #?METADATA{},
                rpc_key           :: rpc:key(),
                req_id = 0        :: integer()
               }).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
%% @doc Repair an object.
%% @end
-spec(repair(ReadParms, Redundancies, Metadata, Callback) ->
             any() when ReadParms::#read_parameter{},
                        Redundancies::[#redundant_node{}],
                        Metadata::#?METADATA{},
                        Callback::function()).
repair(#read_parameter{quorum = ReadQuorum,
                       req_id = ReqId}, Redundancies, Metadata, Callback) ->
    Ref    = make_ref(),
    From   = self(),
    AddrId = Metadata#?METADATA.addr_id,
    Key    = Metadata#?METADATA.key,
    Params = #state{read_quorum  = ReadQuorum,
                    redundancies = Redundancies,
                    metadata     = Metadata,
                    req_id       = ReqId},
    NumOfNodes = erlang:length(
                   [N || #redundant_node{node = N,
                                         can_read_repair = true}
                             <- Redundancies]),
    lists:foreach(
      fun(#redundant_node{node = Node,
                          available = true,
                          can_read_repair = true}) ->
              spawn(fun() ->
                            RPCKey = rpc:async_call(
                                       Node, leo_storage_handler_object,
                                       head, [AddrId, Key]),
                            compare(Ref, From, RPCKey, Node, Params)
                    end);
         (#redundant_node{}) ->
              void
      end, Redundancies),
    loop(ReadQuorum, Ref, From, NumOfNodes, {ReqId, Key, []}, Callback).


%% @doc Waiting for messages (compare a metadata)
%%
-spec(loop(R, Ref, From, NumOfNodes, Errors, Callback) ->
             {ok, reference()} |
             {error, reference(), any()} when R::non_neg_integer(),
                                              Ref::reference(),
                                              From::pid(),
                                              NumOfNodes::non_neg_integer(),
                                              Errors::{integer(), binary(), [any()]},
                                              Callback::function()).
loop(0,_Ref,_From,_NumOfNodes, {_,_,_E}, Callback) ->
    Callback(ok);
loop(R,_Ref,_From, NumOfNodes, {_,_, E}, Callback) when (NumOfNodes - R) < length(E) ->
    Callback({error, E});
loop(R, Ref, From, NumOfNodes, {ReqId, Key, E} = Args, Callback) ->
    receive
        {Ref, ok} ->
            loop(R-1, Ref, From, NumOfNodes, Args, Callback);
        {Ref, {error, {Node, Cause}}} ->
            loop(R,   Ref, From, NumOfNodes, {ReqId, Key, [{Node, Cause}|E]}, Callback)
    after
        ?DEF_REQ_TIMEOUT ->
            case (R > 0) of
                true ->
                    Cause = timeout,
                    ?warn("loop/6", "key:~p, cause:~p",
                          [Key, Cause]),
                    Callback({error, [Cause]});
                false ->
                    void
            end
    end.


%%--------------------------------------------------------------------
%% INTERNAL FUNCTIONS
%%--------------------------------------------------------------------
%% @doc Compare local-metadata with remote-metadata
%% @private
-spec(compare(Ref, Pid, RPCKey, Node, State) ->
             ok when Ref::reference(),
                     Pid::pid(),
                     RPCKey::rpc:key(),
                     Node::atom(),
                     State::#state{}).
compare(Ref, Pid, RPCKey, Node, #state{metadata = #?METADATA{addr_id = AddrId,
                                                             key     = Key,
                                                             clock   = Clock}}) ->
    Ret = case rpc:nb_yield(RPCKey, ?DEF_REQ_TIMEOUT) of
              {value, {ok, #?METADATA{clock = RemoteClock}}} when Clock == RemoteClock ->
                  ok;
              {value, {ok, #?METADATA{clock = RemoteClock}}} when Clock  > RemoteClock ->
                  {error, {Node, secondary_inconsistency}};
              {value, {ok, #?METADATA{clock = RemoteClock}}} when Clock  < RemoteClock ->
                  {error, {Node, primary_inconsistency}};
              {value, {error, Cause}} ->
                  {error, {Node, Cause}};
              {value, {badrpc, Cause}} ->
                  {error, {Node, Cause}};
              timeout = Cause ->
                  {error, {Node, Cause}}
          end,

    case Ret of
        ok ->
            ok;
        {error, {Node, Reason}} ->
            ?warn("compare/4", "node:~w, vnode-id:~w, key:~s, clock:~w, cause:~p",
                  [Node, AddrId, Key, Clock, Reason]),
            enqueue(AddrId, Key)
    end,
    erlang:send(Pid, {Ref, Ret}).


%% @doc Insert a message into the queue
%% @private
-spec(enqueue(AddrId, Key) ->
             ok | {error, any()} when AddrId::non_neg_integer(),
                                      Key::binary()).
enqueue(AddrId, Key) ->
    QId = ?QUEUE_TYPE_PER_OBJECT,
    case leo_storage_mq:publish(QId, AddrId, Key, ?ERR_TYPE_RECOVER_DATA) of
        ok ->
            void;
        {error, Cause} ->
            ?warn("enqueue/1", "qid:~p, addr-id:~p, key:~p, cause:~p",
                  [QId, AddrId, Key, Cause])
    end.
