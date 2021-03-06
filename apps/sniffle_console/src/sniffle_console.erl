%% @doc Interface for sniffle-admin commands.
%% A lot of the code is taken from
%% https://github.com/basho/riak_kv/blob/develop/src/riak_kv_console.erl
-module(sniffle_console).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
         init_leo/1,
         db_keys/1,
         db_get/1,
         db_delete/1,
         get_ring/1,
         connections/1,
         db_update/1,
         update_snarl_meta/1
        ]).

-export([
         aae_status/1
        ]).

-export([
         config/1,
         ds/1,
         dtrace/1,
         hvs/1,
         ips/1,
         networks/1,
         pkgs/1,
         vms/1
        ]).

-export([
         pp_json/1
        ]).

-ignore_xref([
              init_leo/1,
              db_keys/1,
              db_get/1,
              db_delete/1,
              get_ring/1,
              connections/1,
              aae_status/1,
              config/1,
              ds/1,
              dtrace/1,
              hvs/1,
              ips/1,
              networks/1,
              pkgs/1,
              vms/1,
              db_update/1,
              update_snarl_meta/1
             ]).

update_snarl_meta([]) ->
    update_metadata("Organisation", ls_org, ft_org),
    update_metadata("User", ls_user, ft_user),
    update_metadata("Role", ls_role, ft_role).

update_metadata(Name, LS, FT) ->
    {ok, Es} = LS:list(),
    io:format("[~s] Updating ~p elements: ", [Name, length(Es)]),
    [update_meta_element(LS, FT, E) || E <- Es],
    io:format("done.~n").

update_meta_element(LS, FT, ID) ->
    {ok, E} = LS:get(ID),
    M = FT:metadata(E),
    MChanges = lists:foldl(fun({<<"public">>, _V}, Cs) ->
                                   Cs;
                              ({K, V}, Cs) ->
                                   [{K, delete}, {[<<"public">>, K], V} | Cs]
                           end, [], M),
    LS:set_metadata(ID, MChanges),
    io:format(".").

init_leo([Host]) ->
    init_leo([Host, Host]);

init_leo([Manager, Gateway]) ->
    P = 10020,
    User = "fifo",
    OK = {ok,[{<<"result">>,<<"OK">>}]},

    %% Create the user and store access and secret key
    {ok,[{<<"access_key_id">>,AKey}, {<<"secret_access_key">>, SKey}]} =
        libleofs:create_user(Manager, P, User),
    sniffle_opt:set(["storage", "s3", "access_key"], AKey),
    sniffle_opt:set(["storage", "s3", "secret_key"], SKey),
    io:format("Created user ~s:~n"
              "Access Key: ~s~n"
              "Secret Key: ~s~n",
              [User, AKey, SKey]),

    %% Create the general bucket
    GenBucket = "fifo",
    OK = libleofs:add_bucket(Manager, P, GenBucket, AKey),
    sniffle_opt:set(["storage", "s3", "general_bucket"], GenBucket),
    io:format("Created bucket general bucket: ~s~n", [GenBucket]),

    %% Create the image bucket
    ImgBucket = "fifo-images",
    OK = libleofs:add_bucket(Manager, P, ImgBucket, AKey),
    sniffle_opt:set(["storage", "s3", "image_bucket"], ImgBucket),
    io:format("Created bucket image bucket: ~s~n", [ImgBucket]),

    %% Create the backup bucket
    SnapBucket = "fifo-backups",
    OK = libleofs:add_bucket(Manager, P, SnapBucket, AKey),
    sniffle_opt:set(["storage", "s3", "snapshot_bucket"], SnapBucket),
    io:format("Created bucket snapshot bucket: ~s~n", [SnapBucket]),

    %% Add the enpoint
    OK = libleofs:add_endpoint(Manager, P, Gateway),
    sniffle_opt:set(["storage", "s3", "host"], Gateway),
    ok = sniffle_opt:set(["storage", "s3", "port"], 443),
    io:format("Configuring endpoint as: https://~s:~p~n", [Gateway, P]),
    io:format("Setting storage backend to s3, please reastart sniffle for this "
              "to take full effect!~n"),
    ok.


db_update([]) ->
    [db_update([E]) || E <- ["vms", "datasets", "dtraces", "hypervisors",
                             "ipranges", "networks", "packages"]],
    ok;

db_update(["datasets"]) ->
    io:format("Updating datasets...~n"),
    do_update(sniffle_dataset, ft_dataset);

db_update(["dtraces"]) ->
    io:format("Updating dtrace scripts...~n"),
    do_update(sniffle_dtrace, ft_dtrace);

db_update(["hypervisors"]) ->
    io:format("Updating hypervisors...~n"),
    do_update(sniffle_hypervisor, ft_hypervisor);

db_update(["ipranges"]) ->
    io:format("Updating ipranges...~n"),
    do_update(sniffle_iprange, ft_iprange);

db_update(["networks"]) ->
    io:format("Updating networks...~n"),
    do_update(sniffle_network, ft_network);

db_update(["packages"]) ->
    io:format("Updating packages...~n"),
    do_update(sniffle_package, ft_package);

db_update(["vms"]) ->
    io:format("Updating vms...~n"),
    do_update(sniffle_vm, ft_vm).

print_endpoints(Es) ->
    io:format("Hostname            "
              "                    "
              " Node               "
              " Errors    ~n"),
    io:format("--------------------"
              "--------------------"
              "----------"
              " ---------------~n", []),
    [print_endpoint(E) || E <- Es].

print_endpoint([{{Hostname, [{port,Port},{ip,IP}]}, _, Fails}]) ->
    HostPort = <<IP/binary, ":", Port/binary>>,
    io:format("~40s ~-19s ~9b~n", [Hostname, HostPort, Fails]).

connections(["snarl"]) ->
    io:format("Snarl endpoints.~n"),
    print_endpoints(libsnarl:servers());

connections(["howl"]) ->
    io:format("Howl endpoints.~n"),
    print_endpoints(libhowl:servers());

connections([]) ->
    connections(["snarl"]),
    connections(["howl"]).

get_ring([]) ->
    {ok, RingData} = riak_core_ring_manager:get_my_ring(),
    {_S, CHash} = riak_core_ring:chash(RingData),
    io:format("Hash                "
              "                    "
              "          "
              " Node~n"),
    io:format("--------------------"
              "--------------------"
              "----------"
              " ---------------~n", []),
    lists:map(fun({K, H}) ->
                      io:format("~50b ~-40s~n", [K, H])
              end, CHash),
    ok.

is_prefix(Prefix, K) ->
    binary:longest_common_prefix([Prefix, K]) =:= byte_size(Prefix).

db_delete([CHashS, CatS, KeyS]) ->
    Cat = list_to_binary(CatS),
    Key = list_to_binary(KeyS),
    CHash = list_to_integer(CHashS),
    {ok, RingData} = riak_core_ring_manager:get_my_ring(),
    {_S, CHashs} = riak_core_ring:chash(RingData),
    case lists:keyfind(CHash, 1, CHashs) of
        false ->
            io:format("C-Hash ~b does not exist.~n", [CHash]),
            error;
        _ ->
            CHashA = list_to_atom(CHashS),
            fifo_db:delete(CHashA, Cat, Key)
    end.
db_get([CHashS, CatS, KeyS]) ->
    Cat = list_to_binary(CatS),
    Key = list_to_binary(KeyS),
    CHash = list_to_integer(CHashS),
    {ok, RingData} = riak_core_ring_manager:get_my_ring(),
    {_S, CHashs} = riak_core_ring:chash(RingData),
    case lists:keyfind(CHash, 1, CHashs) of
        false ->
            io:format("C-Hash ~b does not exist.~n", [CHash]),
            error;
        _ ->
            CHashA = list_to_atom(CHashS),
            case fifo_db:get(CHashA, Cat, Key) of
                {ok, E} ->
                    io:format("~p~n", [E]);
                _ ->
                    io:format("Not found.~n", []),
                    error
            end
    end.

db_keys([]) ->
    db_keys(["-p", ""]);

db_keys(["-p", PrefixS]) ->
    Prefix = list_to_binary(PrefixS),
    {ok, RingData} = riak_core_ring_manager:get_my_ring(),
    {_S, CHashs} = riak_core_ring:chash(RingData),
    lists:map(fun({Hash, H}) ->
                      io:format("~n~50b ~-15s~n", [Hash, H]),
                      io:format("--------------------"
                                "--------------------"
                                "--------------------"
                                "------~n", []),
                      CHashA = list_to_atom(integer_to_list(Hash)),
                      Keys = fifo_db:list_keys(CHashA, <<>>),
                      [io:format("~s~n", [K])
                       || K <- Keys,
                          is_prefix(Prefix, K) =:= true]
              end, CHashs),
    ok;

db_keys([CHashS]) ->
    db_keys([CHashS, ""]);

db_keys([CHashS, PrefixS]) ->
    Prefix = list_to_binary(PrefixS),
    CHash = list_to_integer(CHashS),
    {ok, RingData} = riak_core_ring_manager:get_my_ring(),
    {_S, CHashs} = riak_core_ring:chash(RingData),
    case lists:keyfind(CHash, 1, CHashs) of
        false ->
            io:format("C-Hash ~b does not exist.", [CHash]),
            error;
        _ ->
            CHashA = list_to_atom(CHashS),
            Keys = fifo_db:list_keys(CHashA, Prefix),
            [io:format("~s~n", [K]) || K <- Keys],
            ok
    end.

aae_status([]) ->
    Services = [{sniffle_hypervisor, "Hypervisor"}, {sniffle_vm, "VM"},
                {sniffle_iprange, "IP Range"}, {sniffle_package, "Package"},
                {sniffle_dataset, "Dataset"}, {sniffle_network, "Network"},
                {sniffle_dtrace, "DTrace"}],
    [fifo_console:aae_status(E) || E <- Services].

%% aae_status([]) ->
%%     ExchangeInfo = riak_kv_entropy_info:compute_exchange_info(),
%%     aae_exchange_status(ExchangeInfo),
%%     io:format("~n"),
%%     TreeInfo = riak_kv_entropy_info:compute_tree_info(),
%%     aae_tree_status(TreeInfo),
%%     io:format("~n"),
%%     aae_repair_status(ExchangeInfo).



dtrace([C, "-j" | R]) ->
    sniffle_console_dtrace:command(json, [C | R]);

dtrace([]) ->
    sniffle_console_dtrace:help(),
    ok;

dtrace(R) ->
    sniffle_console_dtrace:command(text, R).

vms([C, "-j" | R]) ->
    sniffle_console_vms:command(json, [C | R]);

vms([]) ->
    sniffle_console_vms:help(),
    ok;

vms(R) ->
    sniffle_console_vms:command(text, R).

hvs([C, "-j" | R]) ->
    sniffle_console_hypervisors:command(json, [C | R]);

hvs([]) ->
    sniffle_console_hypervisors:help(),
    ok;

hvs(R) ->
    sniffle_console_hypervisors:command(text, R).

pkgs([C, "-j" | R]) ->
    sniffle_console_packages:command(json, [C | R]);

pkgs([]) ->
    sniffle_console_packages:help(),
    ok;

pkgs(R) ->
    sniffle_console_packages:command(text, R).

ds([C, "-j" | R]) ->
    sniffle_console_datasets:command(json, [C | R]);

ds([]) ->
    sniffle_console_datasets:help(),
    ok;

ds(R) ->
    sniffle_console_datasets:command(text, R).

ips([]) ->
    sniffle_console_ipranges:help(),
    ok;

ips([C, "-j" | R]) ->
    sniffle_console_ipranges:command(json, [C | R]);

ips(R) ->
    sniffle_console_ipranges:command(text, R).

networks([]) ->
    sniffle_console_networks:help(),
    ok;

networks([C, "-j" | R]) ->
    sniffle_console_networks:command(json, [C | R]);

networks(R) ->
    sniffle_console_networks:command(text, R).

config(["show"]) ->
    io:format("Storage~n  General Section~n"),
    fifo_console:print_config(<<"storage">>, <<"general">>),
    io:format("  S3 Section~n"),
    fifo_console:print_config(<<"storage">>, <<"s3">>),
    io:format("Network~n  HTTP~n"),
    fifo_console:print_config(<<"network">>, <<"http">>),
    ok;

config(["set", Ks, V]) ->
    Ks1 = [binary_to_list(K) || K <- re:split(Ks, "\\.")],
    config(["set" | Ks1] ++ [V]);

config(["set" | R]) ->
    [K1, K2, K3, V] = R,
    Ks = [K1, K2, K3],
    case sniffle_opt:set(Ks, V) of
        {invalid, key, K} ->
            io:format("Invalid key: ~p~n", [K]),
            error;
        {invalid, type, T} ->
            io:format("Invalid type: ~p~n", [T]),
            error;
        _ ->
            io:format("Setting changed~n", []),
            ok
    end;

config(["unset", Ks]) ->
    Ks1 = [binary_to_list(K) || K <- re:split(Ks, "\\.")],
    config(["unset" | Ks1]);

config(["unset" | Ks]) ->
    sniffle_opt:unset(Ks),
    io:format("Setting changed~n", []),
    ok.

%%%===================================================================
%%% Private
%%%===================================================================


pp_json(Obj) ->
    io:format("~s~n", [jsx:prettify(jsx:encode(Obj))]).


do_update(MainMod, StateMod) ->
    {ok, US} = MainMod:list_(),
    io:format("  Entries found: ~p~n", [length(US)]),

    io:format("  Grabbing UUIDs"),
    US1 = [begin
               io:format("."),
               {StateMod:uuid(ft_obj:val(U)), ft_obj:update(U)}
           end|| U <- US],
    io:format(" done.~n"),

    io:format("  Wipeing old entries"),
    [begin
         io:format("."),
         MainMod:wipe(UUID)
     end || {UUID, _} <- US1],
    io:format(" done.~n"),

    io:format("  Restoring entries"),
    [begin
         io:format("."),
         MainMod:sync_repair(UUID, O)
     end || {UUID, O} <- US1],
    io:format(" done.~n"),
    io:format("Update complete.~n"),
    ok.
