%% -*- mode: erlang -*-
-module(p72_match_sup).
-behaviour(supervisor).

-include("p72_torneo_de_esports.hrl").

-export([start_link/1, start_match/3, stop_match/1, get_match_pid/1,
         assign_table/4, assign_referee/4, release_table/3, release_referee/3,
         is_table_free/3, is_referee_free/3, release_resources/4]).

-export([init/1]).

start_link(TournamentId) ->
    supervisor:start_link({global, {?MODULE, TournamentId}}, ?MODULE, TournamentId).

%% Start a match process under this supervisor
start_match(TournamentId, MatchId, MatchData) ->
    SupId = {global, {?MODULE, TournamentId}},
    %% Validate table_id and referee_id if assigned
    TableId = MatchData#match.table_id,
    RefereeId = MatchData#match.referee_id,
    Round = MatchData#match.round,
    Validation = case {TableId, RefereeId} of
        {undefined, undefined} ->
            ok;  %% No resources to validate
        {TId, undefined} when is_integer(TId) ->
            case is_table_free(TournamentId, Round, TId) of
                true -> ok;
                false -> {error, {table_in_use, TId}}
            end;
        {undefined, RId} when is_integer(RId) ->
            case is_referee_free(TournamentId, Round, RId) of
                true -> ok;
                false -> {error, {referee_in_use, RId}}
            end;
        {TId, RId} when is_integer(TId), is_integer(RId) ->
            case {is_table_free(TournamentId, Round, TId), is_referee_free(TournamentId, Round, RId)} of
                {true, true} -> ok;
                {false, _} -> {error, {table_in_use, TId}};
                {_, false} -> {error, {referee_in_use, RId}}
            end
    end,
    case Validation of
        {error, _} = Error -> Error;
        ok -> start_match_with_resources(TournamentId, MatchId, MatchData, SupId, Round, TableId, RefereeId)
    end.

start_match_with_resources(TournamentId, MatchId, MatchData, SupId, Round, TableId, RefereeId) ->
    case reserve_resources(TournamentId, Round, MatchId, TableId, RefereeId) of
        ok ->
            ChildSpec = #{id => MatchId,
                          start => {p72_match_server, start_link, [MatchId, MatchData]},
                          restart => transient,
                          shutdown => 5000,
                          type => worker,
                          modules => [p72_match_server]},
            case supervisor:start_child(SupId, ChildSpec) of
                {ok, Pid} ->
                    {ok, Pid};
                {ok, Pid, _Info} ->
                    {ok, Pid};
                Error ->
                    release_resources(TournamentId, Round, TableId, RefereeId),
                    Error
            end;
        {error, _} = Error -> Error
    end.

reserve_resources(TournamentId, Round, MatchId, TableId, RefereeId) ->
    case TableId of
        undefined -> reserve_referee(TournamentId, Round, MatchId, RefereeId);
        _ ->
            case assign_table(TournamentId, Round, TableId, MatchId) of
                ok ->
                    case reserve_referee(TournamentId, Round, MatchId, RefereeId) of
                        ok -> ok;
                        Error ->
                            release_table(TournamentId, Round, TableId),
                            Error
                    end;
                Error -> Error
            end
    end.

reserve_referee(_TournamentId, _Round, _MatchId, undefined) -> ok;
reserve_referee(TournamentId, Round, MatchId, RefereeId) ->
    assign_referee(TournamentId, Round, RefereeId, MatchId).

stop_match(MatchId) ->
    %% Find which tournament supervisor owns this match
    %% For simplicity, we iterate - in production use a registry
    {ok, Pid} = get_match_pid(MatchId),
    exit(Pid, shutdown).

get_match_pid(MatchId) ->
    %% This is a simplified lookup - in production use gproc or pg
    case global:whereis_name({p72_match_server, MatchId}) of
        undefined -> {error, not_found};
        Pid -> {ok, Pid}
    end.

init(TournamentId) ->
    logger:info("~s iniciado para torneo ~p", [?MODULE, TournamentId]),
    %% Initialize ETS tables for resource tracking
    case ets:whereis(match_resources) of
        undefined -> _ = ets:new(match_resources, [named_table, set, public]);
        _Table -> ok
    end,
    {ok, {{one_for_one, 10, 60}, []}}.

%%% Resource Management API

%% Assign a table to a match
assign_table(TournamentId, Round, TableId, MatchId) ->
    Key = {TournamentId, Round, TableId},
    case ets:insert_new(match_resources, {Key, MatchId}) of
        true -> ok;
        false -> {error, table_in_use}
    end.

%% Assign a referee to a match
assign_referee(TournamentId, Round, RefereeId, MatchId) ->
    Key = {TournamentId, Round, referee, RefereeId},
    case ets:insert_new(match_resources, {Key, MatchId}) of
        true -> ok;
        false -> {error, referee_in_use}
    end.

%% Release table assignment
release_table(TournamentId, Round, TableId) ->
    Key = {TournamentId, Round, TableId},
    ets:delete(match_resources, Key),
    ok.

%% Release referee assignment
release_referee(TournamentId, Round, RefereeId) ->
    Key = {TournamentId, Round, referee, RefereeId},
    ets:delete(match_resources, Key),
    ok.

%% Check if table is free for a tournament round
is_table_free(TournamentId, Round, TableId) ->
    Key = {TournamentId, Round, TableId},
    case ets:lookup(match_resources, Key) of
        [] -> true;
        [_] -> false
    end.

%% Check if referee is free for a tournament round
is_referee_free(TournamentId, Round, RefereeId) ->
    Key = {TournamentId, Round, referee, RefereeId},
    case ets:lookup(match_resources, Key) of
        [] -> true;
        [_] -> false
    end.

%% Release resources when match finishes
release_resources(TournamentId, Round, TableId, RefereeId) ->
    case TableId of
        undefined -> ok;
        TId -> release_table(TournamentId, Round, TId)
    end,
    case RefereeId of
        undefined -> ok;
        RId -> release_referee(TournamentId, Round, RId)
    end,
    ok.
