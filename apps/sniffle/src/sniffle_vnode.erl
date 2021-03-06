-module(sniffle_vnode).

-include("sniffle.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").

-export([init/5,
         is_empty/1,
         delete/1,
         put/3,
         handle_command/3,
         handle_coverage/4,
         handle_info/2,
         hash_object/2,
         mkid/0,
         repair/2,
         mk_reqid/0]).

-define(FM(Mod, Fun, Args),
        folsom_metrics:histogram_timed_update(
          {Mod, Fun},
          Mod, Fun, Args)).


hash_object(Key, Obj) ->
    term_to_binary(erlang:phash2({Key, Obj})).

mkid() ->
    mkid(node()).

mkid(Actor) ->
    {mk_reqid(), Actor}.

mk_reqid() ->
    erlang:system_time(nano_seconds).

init(Partition, Bucket, Service, VNode, StateMod) ->
    DB = list_to_atom(integer_to_list(Partition)),
    fifo_db:start(DB),
    HT = riak_core_aae_vnode:maybe_create_hashtrees(Service, Partition, VNode,
                                                    undefined),
    WorkerPoolSize = application:get_env(sniffle, async_workers, 5),
    FoldWorkerPool = {pool, sniffle_worker, WorkerPoolSize, []},
    {ok,
     #vstate{db=DB, hashtrees=HT, partition=Partition, node=node(),
             service_bin=list_to_binary(atom_to_list(Service)),
             service=Service, bucket=Bucket, state=StateMod, vnode=VNode},
     [FoldWorkerPool]}.

list(Getter, Requirements, Sender, State=#vstate{state=StateMod}) ->
    ID = mkid(),
    FoldFn = fun (Key, E, C) ->
                     E1 = load_obj(ID, StateMod, E),
                     case rankmatcher:match(E1, Getter, Requirements) of
                         false ->
                             C;
                         Pts ->
                             [{Pts, {Key, E1}} | C]
                     end
             end,
    fold(FoldFn, [], Sender, State).

list_keys(Sender, State=#vstate{db=DB, bucket=Bucket}) ->
    FoldFn = fun (K, L) ->
                     [K|L]
             end,
    AsyncWork = fun() ->
                        ?FM(fifo_db, fold_keys, [DB, Bucket, FoldFn, []])
                end,
    FinishFun = fun(Data) ->
                        reply(Data, Sender, State)
                end,
    {async, {fold, AsyncWork, FinishFun}, Sender, State}.

list_keys(Getter, Requirements, Sender, State=#vstate{state=StateMod}) ->
    ID = mkid(),
    FoldFn = fun (Key, E, C) ->
                     E1 = load_obj(ID, StateMod, E),
                     case rankmatcher:match(E1, Getter, Requirements) of
                         false ->
                             C;
                         Pts ->
                             [{Pts, Key} | C]
                     end
             end,
    fold(FoldFn, [], Sender, State).

fold_with_bucket(Fun, Acc0, Sender, State=#vstate{state=StateMod}) ->
    ID = mkid(),
    FoldFn = fun(K, E, O) ->
                     E1 = load_obj(ID, StateMod, E),
                     Fun({State#vstate.bucket, K}, E1, O)
             end,
    fold(FoldFn, Acc0, Sender, State).

fold(Fun, Acc0, Sender, State=#vstate{db=DB, bucket=Bucket}) ->
    AsyncWork = fun() ->
                        ?FM(fifo_db, fold, [DB, Bucket, Fun, Acc0])
                end,
    FinishFun = fun(Data) ->
                        reply(Data, Sender, State)
                end,
    {async, {fold, AsyncWork, FinishFun}, Sender, State}.

put(Key, Obj, State) ->
    ?FM(fifo_db, put, [State#vstate.db, State#vstate.bucket, Key, Obj]),
    riak_core_aae_vnode:update_hashtree(
      State#vstate.service_bin, Key, vc_bin(ft_obj:vclock(Obj)), State#vstate.hashtrees).

change(UUID, Action, Vals, {ReqID, Coordinator} = ID,
       State=#vstate{state=Mod}) ->
    case get(UUID, State) of
        {ok, O} ->
            O1 = load_obj(ID, Mod, O),
            H1 = ft_obj:val(O1),
            H2 = case Vals of
                     [Val] ->
                         Mod:Action(ID, Val, H1);
                     [Val1, Val2] ->
                         Mod:Action(ID, Val1, Val2, H1)
                 end,
            Obj = ft_obj:update(H2, Coordinator, O1),
            sniffle_vnode:put(UUID, Obj, State),
            {reply, {ok, ReqID}, State};
        R ->
            lager:warning("[~s] tried to write to a non existing element: ~p",
                          [State#vstate.bucket, R]),
            {reply, {ok, ReqID, not_found}, State}
    end.


%%%===================================================================
%%% Callbacks
%%%===================================================================

is_empty(State=#vstate{db=DB, bucket=Bucket}) ->
    FoldFn = fun (_, _) -> {false, State} end,
    ?FM(fifo_db, fold_keys, [DB, Bucket, FoldFn, {true, State}]).

delete(State=#vstate{db=DB, bucket=Bucket}) ->
    FoldFn = fun (K, A) -> [{delete, <<Bucket/binary, K/binary>>} | A] end,
    Trans = ?FM(fifo_db, fold_keys, [DB, Bucket, FoldFn, []]),
    ?FM(fifo_db, transact, [State#vstate.db, Trans]),
    {ok, State}.

handle_coverage({wipe, UUID}, _KeySpaces, {_, ReqID, _}, State) ->
    ?FM(fifo_db, delete, [State#vstate.db, State#vstate.bucket, UUID]),
    {reply, {ok, ReqID}, State};

handle_coverage({lookup, Name}, _KeySpaces, Sender, State=#vstate{state=Mod}) ->
    ID = mkid(),
    FoldFn = fun (U, O, [not_found]) ->
                     O1 = load_obj(ID, Mod, O),
                     V = ft_obj:val(O1),
                     case Mod:name(V) of
                         AName when AName =:= Name ->
                             [U];
                         _ ->
                             [not_found]
                     end;
                 (_, O, Res) ->
                     lager:info("Oops: ~p", [O]),
                     Res
             end,
    fold(FoldFn, [not_found], Sender, State);

handle_coverage(list, _KeySpaces, Sender, State) ->
    list_keys(Sender, State);

handle_coverage({list, Requirements}, _KeySpaces, Sender, State) ->
    handle_coverage({list, Requirements, false}, _KeySpaces, Sender, State);

handle_coverage({list, Requirements, Full}, _KeySpaces, Sender,
                State = #vstate{state=Mod}) ->
    case Full of
        true ->
            list(fun Mod:getter/2, Requirements, Sender, State);
        false ->
            list_keys(fun Mod:getter/2, Requirements, Sender, State)
    end;

handle_coverage(Req, _KeySpaces, _Sender, State) ->
    lager:warning("Unknown coverage request: ~p", [Req]),
    {stop, not_implemented, State}.


handle_command(ping, _Sender, State) ->
    {reply, {pong, State#vstate.partition}, State};

handle_command({repair, UUID, _VClock, Obj}, _Sender,
               State=#vstate{state=Mod}) ->
    ID = mkid(),
    Obj1 = load_obj(ID, Mod, Obj),
    case get(UUID, State) of
        {ok, Old} ->
            Old1 = load_obj(ID, Mod, Old),
            Merged = ft_obj:merge(sniffle_entity_read_fsm, [Old1, Obj1]),
            sniffle_vnode:put(UUID, Merged, State);
        not_found ->
            sniffle_vnode:put(UUID, Obj1, State);
        _ ->
            lager:error("[~s] Read repair failed, data was updated too recent.",
                        [State#vstate.bucket])
    end,
    {noreply, State};

handle_command({sync_repair, {ReqID, _}, UUID, Obj}, _Sender,
               State=#vstate{state=Mod}) ->
    case get(UUID, State) of
        {ok, Old} ->
            ID = sniffle_vnode:mkid(),
            Old1 = load_obj(ID, Mod, Old),
            lager:info("[sync-repair:~s] Merging with old object", [UUID]),
            Merged = ft_obj:merge(sniffle_entity_read_fsm, [Old1, Obj]),
            sniffle_vnode:put(UUID, Merged, State);
        not_found ->
            lager:info("[sync-repair:~s] Writing new object", [UUID]),
            sniffle_vnode:put(UUID, Obj, State);
        _ ->
            lager:error("[~s] Read repair failed, data was updated too recent.",
                        [State#vstate.bucket])
    end,
    {reply, {ok, ReqID}, State};

handle_command({get, ReqID, UUID}, _Sender, State) ->
    Res = case get(UUID, State) of
              {ok, R} ->
                  ID = {ReqID, load},
                  %% We want to write a loaded object back to storage
                  %% if a change happend.
                  case  load_obj(ID, State#vstate.state, R) of
                      R1 when R =/= R1 ->
                          sniffle_vnode:put(UUID, R1, State),
                          R1;
                      R1 ->
                          R1
                  end;
              not_found ->
                  not_found
          end,
    NodeIdx = {State#vstate.partition, State#vstate.node},
    {reply, {ok, ReqID, NodeIdx, Res}, State};

handle_command({delete, {ReqID, _Coordinator}, UUID}, _Sender, State) ->
    ?FM(fifo_db, delete, [State#vstate.db, State#vstate.bucket, UUID]),
    riak_core_index_hashtree:delete(
      {State#vstate.service_bin, UUID}, State#vstate.hashtrees),
    {reply, {ok, ReqID}, State};


handle_command({set,
                {ReqID, Coordinator} = ID, UUID,
                Resources}, _Sender,
               State = #vstate{state=Mod, bucket=Bucket}) ->
    case get(UUID, State) of
        {ok, O} ->
            O1 = load_obj(ID, Mod, O),
            H1 = ft_obj:val(O1),
            H2 = lists:foldr(
                   fun ({Resource, Value}, H) ->
                           Mod:set(ID, Resource, Value, H)
                   end, H1, Resources),
            Obj = ft_obj:update(H2, Coordinator, O),
            sniffle_vnode:put(UUID, Obj, State),
            {reply, {ok, ReqID}, State};
        R ->
            lager:error("[~s/~p] tried to write to non existing element: ~s -> ~p",
                        [Bucket, State#vstate.partition, UUID, R]),
            {reply, {ok, ReqID, not_found}, State}
    end;

%%%===================================================================
%%% AAE
%%%===================================================================

handle_command({hashtree_pid, Node}, _, State) ->
    %% Handle riak_core request forwarding during ownership handoff.
    %% Following is necessary in cases where anti-entropy was enabled
    %% after the vnode was already running
    case {node(), State#vstate.hashtrees} of
        {Node, undefined} ->
            HT1 =  riak_core_aae_vnode:maybe_create_hashtrees(
                     State#vstate.service,
                     State#vstate.partition,
                     State#vstate.vnode,
                     undefined),
            {reply, {ok, HT1}, State#vstate{hashtrees = HT1}};
        {Node, HT} ->
            {reply, {ok, HT}, State};
        _ ->
            {reply, {error, wrong_node}, State}
    end;

handle_command({rehash, {_, UUID}}, _,
               State=#vstate{service_bin=ServiceBin, hashtrees=HT}) ->
    case get(UUID, State) of
        {ok, Obj} ->
            riak_core_aae_vnode:update_hashtree(
              ServiceBin, UUID, vc_bin(ft_obj:vclock(Obj)), HT);
        _ ->
            %% Make sure hashtree isn't tracking deleted data
            riak_core_index_hashtree:delete({ServiceBin, UUID}, HT)
    end,
    {noreply, State};

handle_command(?FOLD_REQ{foldfun=Fun, acc0=Acc0}, Sender, State) ->
    fold_with_bucket(Fun, Acc0, Sender, State);

handle_command({Action, ID, UUID, Param1, Param2}, _Sender, State) ->
    change(UUID, Action, [Param1, Param2], ID, State);

handle_command({Action, ID, UUID, Param}, _Sender, State) ->
    change(UUID, Action, [Param], ID, State);

handle_command(Message, _Sender, State) ->
    lager:error("[~s] Unknown command: ~p", [State#vstate.bucket, Message]),
    {noreply, State}.

reply(Reply, {_, ReqID, _} = Sender, #vstate{node=N, partition=P}) ->
    riak_core_vnode:reply(Sender, {ok, ReqID, {P, N}, Reply}).

get(UUID, State) ->
    try
        ?FM(fifo_db, get, [State#vstate.db, State#vstate.bucket, UUID])
    catch
        E1:E2 ->
            lager:error("[fifo_db] Failed to get object ~s/~s ~p:~p ~w",
                        [State#vstate.bucket, UUID, E1, E2,
                         erlang:get_stacktrace()]),
            not_found
    end.

handle_info(retry_create_hashtree,
            State=#vstate{service=Srv, hashtrees=undefined, partition=Idx,
                          vnode=VNode}) ->
    lager:debug("~p/~p retrying to create a hash tree.", [Srv, Idx]),
    HT = riak_core_aae_vnode:maybe_create_hashtrees(Srv, Idx, VNode, undefined),
    {ok, State#vstate{hashtrees = HT}};
handle_info(retry_create_hashtree, State) ->
    {ok, State};
handle_info({'DOWN', _, _, Pid, _},
            State=#vstate{service=Service, hashtrees=Pid, partition=Idx}) ->
    lager:debug("~p/~p hashtree ~p went down.", [Service, Idx, Pid]),
    erlang:send_after(1000, self(), retry_create_hashtree),
    {ok, State#vstate{hashtrees = undefined}};
handle_info({'DOWN', _, _, _, _}, State) ->
    {ok, State};
handle_info(_, State) ->
    {ok, State}.

%% We decrement the Time by 1 to make sure that the following actions
%% are ensured to overwrite load changes.
load_obj({T, ID}, Mod, Obj) ->
    V = ft_obj:val(Obj),
    case Mod:load({T-1, ID}, V) of
        V1 when V1 /= V ->
            ft_obj:update(V1, ID, Obj);
        _ ->
            ft_obj:update(Obj)
    end.

vc_bin(VClock) ->
    term_to_binary(lists:sort(VClock)).

repair(Data, State) ->
    {UUID, Obj} = binary_to_term(Data),
    {noreply, State1} = handle_command({repair, UUID, undefined, Obj},
                                       undefined, State),
    {reply, ok, State1}.
