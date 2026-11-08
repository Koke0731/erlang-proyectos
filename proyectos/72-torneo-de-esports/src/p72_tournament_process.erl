%% -*- mode: erlang -*-
-module(p72_tournament_process).
-behaviour(gen_statem).

-include("p72_torneo_de_esports.hrl").

-export([start_link/1, start_tournament/1, finish_tournament/1, cancel_tournament/1,
         register_team/2, get_teams/1, get_state/1]).

-export([init/1, callback_mode/0,
         registration_open/3, in_progress/3, completed/3, cancelled/3,
         terminate/3, code_change/4]).

%% API
start_link(TournamentId) ->
    gen_statem:start_link({global, {?MODULE, TournamentId}}, ?MODULE, TournamentId, []).

start_tournament(TournamentId) ->
    gen_statem:call({global, {?MODULE, TournamentId}}, start_tournament).

finish_tournament(TournamentId) ->
    gen_statem:call({global, {?MODULE, TournamentId}}, finish_tournament).

cancel_tournament(TournamentId) ->
    gen_statem:call({global, {?MODULE, TournamentId}}, cancel_tournament).

register_team(TournamentId, TeamData) ->
    gen_statem:call({global, {?MODULE, TournamentId}}, {register_team, TeamData}).

get_teams(TournamentId) ->
    gen_statem:call({global, {?MODULE, TournamentId}}, get_teams).

get_state(TournamentId) ->
    gen_statem:call({global, {?MODULE, TournamentId}}, get_state).

%% Callbacks
callback_mode() -> state_functions.

init(TournamentId) ->
    logger:info("~s iniciado para torneo ~p", [?MODULE, TournamentId]),
    {ok, registration_open, #{
        tournament_id => TournamentId,
        teams => #{},
        next_team_id => 1
    }}.

%% State functions

registration_open({call, From}, start_tournament, Data) ->
    TournamentId = maps:get(tournament_id, Data),
    TeamCount = map_size(maps:get(teams, Data)),
    {ok, Tournament} = p72_tournament_registry:get_tournament(TournamentId),
    MinTeams = 2,
    MaxTeams = Tournament#tournament.max_teams,

    if
        TeamCount < MinTeams ->
            reply(From, {error, not_enough_teams}, registration_open, Data);
        TeamCount > MaxTeams ->
            reply(From, {error, too_many_teams}, registration_open, Data);
        true ->
            %% Generate brackets
            Teams = maps:values(maps:get(teams, Data)),
            {ok, Brackets} = p72_bracket_server:generate_bracket(TournamentId, Teams),
            %% Start matches for round 1
            start_round_matches(TournamentId, Brackets, 1),
            NewData = Data#{
                state => in_progress,
                brackets => Brackets
            },
            reply(From, ok, in_progress, NewData)
    end;

registration_open({call, From}, {register_team, TeamData}, Data) ->
    {ok, Tournament} = p72_tournament_registry:get_tournament(maps:get(tournament_id, Data)),
    TeamCount = map_size(maps:get(teams, Data)),
    MaxTeams = Tournament#tournament.max_teams,

    if
        TeamCount >= MaxTeams ->
            reply(From, {error, tournament_full}, registration_open, Data);
        true ->
            TeamId = maps:get(next_team_id, Data),
            Team = #team{
                id = TeamId,
                name = maps:get(name, TeamData),
                players = maps:get(players, TeamData, []),
                seed = maps:get(seed, TeamData, 0),
                metadata = maps:get(metadata, TeamData, #{})
            },
            NewTeams = maps:put(TeamId, Team, maps:get(teams, Data)),
            NewData = Data#{teams => NewTeams, next_team_id => TeamId + 1},
            reply(From, {ok, Team}, registration_open, NewData)
    end;

registration_open({call, From}, get_state, Data) ->
    reply(From, registration_open, registration_open, Data);

registration_open({call, From}, get_teams, Data) ->
    reply(From, maps:values(maps:get(teams, Data)), registration_open, Data);

registration_open(_EventType, _EventContent, Data) ->
    {keep_state, Data}.

in_progress({call, From}, finish_tournament, Data) ->
    reply(From, ok, completed, Data);

in_progress({call, From}, start_tournament, Data) ->
    %% Starting an already-running tournament is safe and idempotent.
    reply(From, ok, in_progress, Data);

in_progress({call, From}, cancel_tournament, Data) ->
    reply(From, ok, cancelled, Data);

in_progress({call, From}, get_state, Data) ->
    reply(From, in_progress, in_progress, Data);

in_progress({call, From}, get_teams, Data) ->
    reply(From, maps:values(maps:get(teams, Data)), in_progress, Data);

in_progress(_EventType, _EventContent, Data) ->
    {keep_state, Data}.

completed({call, From}, get_state, Data) -> reply(From, completed, completed, Data);
completed({call, From}, get_teams, Data) -> reply(From, maps:values(maps:get(teams, Data)), completed, Data);
completed(_EventType, _EventContent, Data) -> {keep_state, Data}.

cancelled({call, From}, get_state, Data) -> reply(From, cancelled, cancelled, Data);
cancelled({call, From}, get_teams, Data) -> reply(From, maps:values(maps:get(teams, Data)), cancelled, Data);
cancelled(_EventType, _EventContent, Data) -> {keep_state, Data}.

%% Internal
start_round_matches(TournamentId, Brackets, Round) ->
    lists:foreach(
        fun(Bracket) ->
            Matches = maps:values(Bracket#bracket.matches),
            RoundMatches = lists:filter(fun(M) -> M#match.round =:= Round end, Matches),
            lists:foreach(
                fun(Match) ->
                    case Match#match.state of
                        scheduled ->
                            p72_match_sup:start_match(TournamentId, Match#match.id, Match);
                        walkover ->
                            %% Auto-resolve walkover
                            handle_walkover(TournamentId, Match);
                        _ -> ok
                    end
                end,
                RoundMatches
            )
        end,
        Brackets
    ).

handle_walkover(TournamentId, Match) ->
    WinnerId = case {Match#match.team1_id, Match#match.team2_id} of
        {undefined, T2} -> T2;
        {T1, undefined} -> T1;
        _ -> Match#match.team1_id
    end,
    Result = #match_result{
        winner_team_id = WinnerId,
        loser_team_id = case WinnerId =:= Match#match.team1_id of
            true -> Match#match.team2_id;
            false -> Match#match.team1_id
        end,
        scores = [{WinnerId, 1}, {case WinnerId =:= Match#match.team1_id of true -> Match#match.team2_id; false -> Match#match.team1_id end, 0}],
        submitted_by = system,
        submitted_at = erlang:system_time(second),
        disputed = false,
        dispute_reason = undefined
    },
    p72_bracket_server:update_match_result(TournamentId, Match#match.id, Result).

reply(From, ReplyValue, StateName, Data) ->
    {next_state, StateName, Data, [{reply, From, ReplyValue}]}.

terminate(_Reason, _StateName, _Data) -> ok.
code_change(_OldVsn, StateName, Data, _Extra) -> {ok, StateName, Data}.
