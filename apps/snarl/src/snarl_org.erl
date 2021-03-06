-module(snarl_org).
-include_lib("riak_core/include/riak_core_vnode.hrl").

-export([
         sync_repair/3,
         list/0, list/1, list_/1, list/3,
         get/2, raw/2, lookup/2,
         add/2,
         delete/2,
         set_metadata/3,
         create/3,
         import/3,
         trigger/4,
         add_trigger/3, remove_trigger/3,
         remove_target/3,
         resource_action/6,
         reindex/2,
         wipe/2
        ]).

-ignore_xref([
              import/3,
              lookup/2,
              create/3,
              import/3,
              list_/1,
              raw/2,
              sync_repair/3,
              wipe/2,
              reindex/2
             ]).

-define(TIMEOUT, 5000).

-define(FM(Met, Mod, Fun, Args),
        folsom_metrics:histogram_timed_update(
          {snarl, org, Met},
          Mod, Fun, Args)).

-type template() :: [binary()|placeholder].
%% Public API


-define(NAME_2i, {?MODULE, name}).

reindex(Realm, UUID) ->
    case ?MODULE:get(Realm, UUID) of
        {ok, O} ->
            snarl_2i:add(Realm, ?NAME_2i, ft_org:name(O), UUID),
            ok;
        E ->
            E
    end.

wipe(Realm, UUID) ->
    ?FM(wipe, snarl_coverage, start,
        [snarl_org_vnode_master, snarl_org, {wipe, Realm, UUID}]).

sync_repair(Realm, UUID, Obj) ->
    do_write(Realm, UUID, sync_repair, Obj).

add_trigger(Realm, Org, Trigger) ->
    do_write(Realm, Org, add_trigger, {uuid:uuid4s(), Trigger}).

remove_target(Realm, Org, Target) ->
    do_write(Realm, Org, remove_target, Target).

remove_trigger(Realm, Org, Trigger) ->
    do_write(Realm, Org, remove_trigger, Trigger).

trigger(Realm, Org, Event, Payload) ->
    case ?MODULE:get(Realm, Org) of
        {ok, OrgObj} ->
            Triggers = [T || {_, T} <- ft_org:triggers(OrgObj)],
            Executed = do_events(Realm, Triggers, Event, Payload, 0),
            {ok, Executed};
        R  ->
            R
    end.

resource_action(Realm, Org, Resource, TimeStamp, Action, Opts) ->
    do_write(Realm, Org,  resource_action, {Resource, TimeStamp, Action, Opts}).

do_events(Realm, [{Event, Template}|Ts], Event, Payload, N) ->
    do_event(Realm, Template, Payload),
    do_events(Realm, Ts, Event, Payload, N+1);

do_events(Realm, [_|Ts], Event, Payload, N) ->
    do_events(Realm, Ts, Event, Payload, N);

do_events(_Realm, [], _Event, _Payload, N) ->
    N.

-spec do_event(Realm::binary(),
               Action::{grant, role, Role::fifo:role_id(), Template::template()} |
                       {grant, user, User::fifo:user_id(), Template::template()} |
                       {join, role, Role::fifo:role_id()} |
                       {join, org, Org::fifo:org_id()},
               Payload::template()) ->
                      ok.

do_event(Realm, {join, role, Role}, Payload) ->
    snarl_user:join(Realm, Payload, Role),
    ok;

do_event(Realm, {join, org, Org}, Payload) ->
    snarl_user:join_org(Realm, Payload, Org),
    snarl_user:select_org(Realm, Payload, Org),
    ok;

do_event(Realm, {grant, role, Role, Template}, Payload) ->
    snarl_role:grant(Realm, Role, build_template(Template, Payload)),
    ok;

do_event(Realm, {grant, user, Role, Template}, Payload) ->
    snarl_user:grant(Realm, Role, build_template(Template, Payload)),
    ok.

build_template(Template, Payload) ->
    lists:map(fun(placeholder) ->
                      Payload;
                 (E) ->
                      E
              end, Template).


import(Realm, Org, Data) ->
    do_write(Realm, Org, import, Data).

-spec lookup(Realm::binary(), OrgName::binary()) ->
                    not_found |
                    {error, timeout} |
                    {ok, Org::fifo:org()}.

lookup(Realm, OrgName) ->
    folsom_metrics:histogram_timed_update(
      {snarl, role, lookup},
      fun() ->
              case snarl_2i:get(Realm, ?NAME_2i, OrgName) of
                  {ok, UUID} ->
                      ?MODULE:get(Realm, UUID);
                  R ->
                      R
              end
      end).

-spec get(Realm::binary(), Org::fifo:org_id()) ->
                 not_found |
                 {error, timeout} |
                 {ok, Org::fifo:org()}.
get(Realm, Org) ->
    case ?FM(get, snarl_entity_read_fsm, start,
             [{snarl_org_vnode, snarl_org}, get, {Realm, Org}]) of
        {ok, not_found} ->
            not_found;
        R ->
            R
    end.

raw(Realm, Org) ->
    case ?FM(get, snarl_entity_read_fsm, start,
             [{snarl_org_vnode, snarl_org}, get,
              {Realm, Org}, undefined, true]) of
        {ok, not_found} ->
            not_found;
        R ->
            R
    end.

list_(Realm) ->
    {ok, Res} =
        ?FM(list, snarl_full_coverage, start,
            [snarl_org_vnode_master, snarl_org, {list, Realm, [], true, true}]),
    Res1 = [R || {_, R} <- Res],
    {ok,  Res1}.

-spec list(Realm::binary()) -> {ok, [fifo:org_id()]} |
                               not_found |
                               {error, timeout}.

list(Realm) ->
    ?FM(list, snarl_coverage, start,
        [snarl_org_vnode_master, snarl_org, {list, Realm}]).

list() ->
    ?FM(list_all, snarl_coverage, start,
        [snarl_org_vnode_master, snarl_org, list]).

-spec list(Realm::binary(), [fifo:matcher()], boolean()) ->
                  {error, timeout} | {ok, [fifo:uuid()]}.

list(Realm, Requirements, Full)
  when Full == true orelse Full == false ->
    {ok, Res} =
        ?FM(list, snarl_full_coverage, start,
            [snarl_org_vnode_master, snarl_org,
             {list, Realm, Requirements, Full}]),
    Res1 = rankmatcher:apply_scales(Res),
    {ok,  lists:sort(Res1)}.

-spec add(Realm::binary(), Org::binary()) ->
                 {ok, UUID::fifo:org_id()} |
                 douplicate |
                 {error, timeout}.

add(Realm, Org) ->
    UUID = uuid:uuid4s(),
    create(Realm, UUID, Org).

create(Realm, UUID, Org) ->
    case ?MODULE:lookup(Realm, Org) of
        not_found ->
            ok = do_write(Realm, UUID, add, Org),
            snarl_2i:add(Realm, ?NAME_2i, Org, UUID),
            {ok, UUID};
        {ok, _OrgObj} ->
            duplicate
    end.

-spec delete(Realm::binary(), Org::fifo:org_id()) ->
                    ok |
                    not_found|
                    {error, timeout}.

delete(Realm, Org) ->
    case ?MODULE:get(Realm, Org) of
        {ok, O} ->
            snarl_2i:delete(Realm, ?NAME_2i, ft_org:name(O)),
            ok;
        E ->
            E
    end,
    spawn(
      fun () ->
              Prefix = [<<"orgs">>, Org],
              {ok, Users} = snarl_user:list(Realm),
              [begin
                   snarl_user:leave_org(Realm, U, Org),
                   snarl_user:revoke_prefix(Realm, U, Prefix)
               end || U <- Users],
              {ok, Roles} = snarl_role:list(Realm),
              [snarl_role:revoke_prefix(Realm, R, Prefix) || R <- Roles],
              {ok, Orgs} = ?MODULE:list(Realm),
              [?MODULE:remove_target(Realm, O, Org) || O <- Orgs]
      end),
    do_write(Realm, Org, delete).



-spec set_metadata(Realm::binary(), Org::fifo:org_id(), Attirbutes::fifo:attr_list()) ->
                          not_found |
                          {error, timeout} |
                          ok.
set_metadata(Realm, Org, Attributes) ->
    do_write(Realm, Org, set_metadata, Attributes).


%%%===================================================================
%%% Internal Functions
%%%===================================================================

do_write(Realm, Org, Op) ->
    ?FM(Op, snarl_entity_write_fsm, write,
        [{snarl_org_vnode, snarl_org}, {Realm, Org}, Op]).

do_write(Realm, Org, Op, Val) ->
    ?FM(Op, snarl_entity_write_fsm, write,
        [{snarl_org_vnode, snarl_org}, {Realm, Org}, Op, Val]).
