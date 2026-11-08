%% -*- mode: erlang -*-
-module(p72_match_server).
-behaviour(gen_statem).

-include("p72_torneo_de_esports.hrl").

-export([start_link/3, submit_result/3, start_match/2, pause_match/2, resume_match/2,
         cancel_match/2, get_state/2, get_data/2, disqualify_team/4,
         resolve_dispute/3, mark_disputed/3]).

-export([init/1, callback_mode/0,
         scheduled/3, in_play/3, finished/3, disputed/3, cancelled/3, walkover/3, disqualified/3,
         terminate/3, code_change/4]).

-define(STATES, [scheduled, in_play, finished, disputed, cancelled, walkover, disqualified]).

%% API
start_link(TournamentId, MatchId, MatchData) ->
    gen_statem:start_link(server_name(TournamentId, MatchId), ?MODULE,
                          [TournamentId, MatchId, MatchData], []).

submit_result(TournamentId, MatchId, Result) ->
    gen_statem:call(server_name(TournamentId, MatchId), {submit_result, Result}).

start_match(TournamentId, MatchId) ->
    gen_statem:call(server_name(TournamentId, MatchId), start_match).

pause_match(TournamentId, MatchId) ->
    gen_statem:call(server_name(TournamentId, MatchId), pause_match).

resume_match(TournamentId, MatchId) ->
    gen_statem:call(server_name(TournamentId, MatchId), resume_match).

cancel_match(TournamentId, MatchId) ->
    gen_statem:call(server_name(TournamentId, MatchId), cancel_match).

get_state(TournamentId, MatchId) ->
    gen_statem:call(server_name(TournamentId, MatchId), get_state).

get_data(TournamentId, MatchId) ->
    gen_statem:call(server_name(TournamentId, MatchId), get_data).

disqualify_team(TournamentId, MatchId, DisqualifiedTeamId, Reason) ->
    gen_statem:call(server_name(TournamentId, MatchId),
                    {disqualify, DisqualifiedTeamId, Reason}).

resolve_dispute(TournamentId, MatchId, Result) ->
    gen_statem:call(server_name(TournamentId, MatchId), {resolve_dispute, Result}).

mark_disputed(TournamentId, MatchId, Reason) ->
    gen_statem:call(server_name(TournamentId, MatchId), {mark_disputed, Reason}).

%% Match processes are scoped by tournament because match IDs are only unique
%% inside each tournament bracket.
server_name(TournamentId, MatchId) ->
    {global, {?MODULE, TournamentId, MatchId}}.

%% Callbacks
callback_mode() -> state_functions.

init([TournamentId, MatchId, MatchData]) ->
    logger:info("~s iniciado para torneo ~p, partida ~p",
                [?MODULE, TournamentId, MatchId]),
    Data = MatchData#match{tournament_id = TournamentId,
                           id = MatchId,
                           started_at = undefined,
                           finished_at = undefined},
    {ok, scheduled, Data}.

%% State functions

scheduled({call, From}, {submit_result, _Result}, Data) ->
    %% Can't submit result in scheduled state
    reply(From, {error, invalid_state}, scheduled, Data);

scheduled({call, From}, start_match, Data) ->
    reply(From, ok, in_play, Data#match{state = in_play, started_at = erlang:system_time(second)});

scheduled({call, From}, {mark_disputed, Reason}, Data) ->
    transition_to_disputed(From, Reason, Data, scheduled);

scheduled({call, From}, cancel_match, Data) ->
    reply(From, ok, cancelled, Data#match{state = cancelled, finished_at = erlang:system_time(second)});

scheduled({call, From}, {disqualify, DisqualifiedTeamId, Reason}, Data) ->
    %% Determine winner (the other team)
    WinnerId = case {Data#match.team1_id, Data#match.team2_id} of
        {DisqualifiedTeamId, T2} when T2 =/= undefined -> T2;
        {T1, DisqualifiedTeamId} when T1 =/= undefined -> T1;
        _ -> undefined  %% Should not happen
    end,
    case WinnerId of
        undefined ->
            reply(From, {error, no_opponent}, scheduled, Data);
        _ ->
            Result = #match_result{
                winner_team_id = WinnerId,
                loser_team_id = DisqualifiedTeamId,
                scores = [{WinnerId, 1}, {DisqualifiedTeamId, 0}],
                submitted_by = system,
                submitted_at = erlang:system_time(second),
                disputed = false,
                dispute_reason = Reason
            },
            NewData = Data#match{
                state = disqualified,
                result = Result,
                finished_at = erlang:system_time(second)
            },
            notify_result(Data#match.tournament_id, Data#match.id, Result),
            reply(From, {ok, Result}, disqualified, NewData)
    end;

scheduled({call, From}, get_state, Data) -> reply(From, scheduled, scheduled, Data);
scheduled({call, From}, get_data, Data) -> reply(From, Data, scheduled, Data);

scheduled(EventType, EventContent, Data) ->
    handle_common_events(EventType, EventContent, Data, scheduled).

in_play({call, From}, {submit_result, Result}, Data) ->
    %% Validate result
    case validate_result(Data, Result) of
        {ok, ValidatedResult} ->
            %% Check for duplicate/conflicting results
            case check_conflict(Data, ValidatedResult) of
                    {conflict, _ExistingResult} ->
                    %% Mark as disputed
                    DisputeResult = Result#match_result{
                        disputed = true,
                        dispute_reason = <<"Conflicting result submitted">>
                    },
                    NewData = Data#match{state = disputed},
                    register_conflicting_result(Data, DisputeResult),
                    reply(From, {disputed, DisputeResult}, disputed, NewData);
                no_conflict ->
                    NewData = Data#match{
                        state = finished,
                        result = ValidatedResult,
                        finished_at = erlang:system_time(second)
                    },
                    %% Notify bracket server and live score
                    notify_result(Data#match.tournament_id, Data#match.id, ValidatedResult),
                    reply(From, {ok, ValidatedResult}, finished, NewData)
            end;
        {error, Reason} ->
            reply(From, {error, Reason}, in_play, Data)
    end;

in_play({call, From}, pause_match, Data) ->
    reply(From, {error, unsupported}, in_play, Data);

in_play({call, From}, resume_match, Data) ->
    reply(From, {error, unsupported}, in_play, Data);

in_play({call, From}, start_match, Data) ->
    reply(From, ok, in_play, Data);

in_play({call, From}, {mark_disputed, Reason}, Data) ->
    transition_to_disputed(From, Reason, Data, in_play);

in_play({call, From}, cancel_match, Data) ->
    reply(From, ok, cancelled, Data#match{state = cancelled, finished_at = erlang:system_time(second)});

in_play({call, From}, {disqualify, DisqualifiedTeamId, Reason}, Data) ->
    %% Determine winner (the other team)
    WinnerId = case {Data#match.team1_id, Data#match.team2_id} of
        {DisqualifiedTeamId, T2} when T2 =/= undefined -> T2;
        {T1, DisqualifiedTeamId} when T1 =/= undefined -> T1;
        _ -> undefined
    end,
    case WinnerId of
        undefined ->
            reply(From, {error, no_opponent}, in_play, Data);
        _ ->
            Result = #match_result{
                winner_team_id = WinnerId,
                loser_team_id = DisqualifiedTeamId,
                scores = [{WinnerId, 1}, {DisqualifiedTeamId, 0}],
                submitted_by = system,
                submitted_at = erlang:system_time(second),
                disputed = false,
                dispute_reason = Reason
            },
            NewData = Data#match{
                state = disqualified,
                result = Result,
                finished_at = erlang:system_time(second)
            },
            notify_result(Data#match.tournament_id, Data#match.id, Result),
            reply(From, {ok, Result}, disqualified, NewData)
    end;

in_play({call, From}, get_state, Data) -> reply(From, in_play, in_play, Data);
in_play({call, From}, get_data, Data) -> reply(From, Data, in_play, Data);

in_play(EventType, EventContent, Data) ->
    handle_common_events(EventType, EventContent, Data, in_play).

finished({call, From}, {submit_result, Result}, Data) ->
    case validate_result(Data, Result) of
        {error, Reason} -> reply(From, {error, Reason}, finished, Data);
        {ok, ValidatedResult} ->
            case Data#match.result of
                undefined -> reply(From, {error, no_previous_result}, finished, Data);
                ExistingResult ->
                    if
                        ValidatedResult#match_result.winner_team_id =/=
                           ExistingResult#match_result.winner_team_id ->
                            DisputeResult = ValidatedResult#match_result{
                                disputed = true,
                                dispute_reason = <<"Conflicting result submitted">>
                            },
                            NewData = Data#match{state = disputed},
                            register_conflicting_result(Data, DisputeResult),
                            reply(From, {disputed, DisputeResult}, disputed, NewData);
                        true ->
                            UpdatedResult = ExistingResult#match_result{
                                scores = ValidatedResult#match_result.scores,
                                submitted_at = erlang:system_time(second)
                            },
                            NewData = Data#match{result = UpdatedResult},
                            notify_result(Data#match.tournament_id, Data#match.id, UpdatedResult),
                            reply(From, {ok, UpdatedResult}, finished, NewData)
                    end
            end
    end;

finished({call, From}, start_match, Data) ->
    reply(From, {error, already_finished}, finished, Data);

finished({call, From}, {mark_disputed, Reason}, Data) ->
    transition_to_disputed(From, Reason, Data, finished);

finished({call, From}, get_state, Data) -> reply(From, finished, finished, Data);
finished({call, From}, get_data, Data) -> reply(From, Data, finished, Data);

finished(EventType, EventContent, Data) ->
    handle_common_events(EventType, EventContent, Data, finished).

disputed({call, From}, {submit_result, Result}, Data) ->
    %% Additional result while disputed - add to evidence
    case validate_result(Data, Result) of
        {ok, _ValidatedResult} ->
            reply(From, {ok, evidence_added}, disputed, Data);
        {error, Reason} -> reply(From, {error, Reason}, disputed, Data)
    end;

disputed({call, From}, {mark_disputed, _Reason}, Data) ->
    reply(From, ok, disputed, Data);

disputed({call, From}, {resolve_dispute, Result}, Data) ->
    case validate_result(Data, Result) of
        {ok, ValidatedResult} ->
            NewData = Data#match{
                state = finished,
                result = ValidatedResult#match_result{disputed = false, dispute_reason = undefined},
                finished_at = erlang:system_time(second)
            },
            notify_result(Data#match.tournament_id, Data#match.id, NewData#match.result),
            reply(From, {ok, NewData#match.result}, finished, NewData);
        {error, Reason} ->
            reply(From, {error, Reason}, disputed, Data)
    end;

disputed({call, From}, start_match, Data) ->
    reply(From, {error, disputed}, disputed, Data);

disputed({call, From}, get_state, Data) -> reply(From, disputed, disputed, Data);
disputed({call, From}, get_data, Data) -> reply(From, Data, disputed, Data);

disputed(EventType, EventContent, Data) ->
    handle_common_events(EventType, EventContent, Data, disputed).

cancelled({call, From}, get_state, Data) -> reply(From, cancelled, cancelled, Data);
cancelled({call, From}, get_data, Data) -> reply(From, Data, cancelled, Data);

cancelled(_EventType, _EventContent, Data) ->
    {keep_state, Data}.

walkover({call, From}, get_state, Data) -> reply(From, walkover, walkover, Data);
walkover({call, From}, get_data, Data) -> reply(From, Data, walkover, Data);

walkover(_EventType, _EventContent, Data) ->
    {keep_state, Data}.

disqualified({call, From}, get_state, Data) -> reply(From, disqualified, disqualified, Data);
disqualified({call, From}, get_data, Data) -> reply(From, Data, disqualified, Data);

disqualified(_EventType, _EventContent, Data) ->
    {keep_state, Data}.

%% Common event handlers
handle_common_events({info, {assign_table, TableId}}, _Content, Data, StateName) ->
    {next_state, StateName, Data#match{table_id = TableId}};
handle_common_events({info, {assign_referee, RefereeId}}, _Content, Data, StateName) ->
    {next_state, StateName, Data#match{referee_id = RefereeId}};
handle_common_events({info, {schedule_at, Timestamp}}, _Content, Data, StateName) ->
    {next_state, StateName, Data#match{scheduled_at = Timestamp}};
handle_common_events({info, {disqualify, DisqualifiedTeamId, Reason}}, _Content, Data, StateName) when StateName =:= scheduled; StateName =:= in_play ->
    %% Handle DQ via cast (async)
    WinnerId = case {Data#match.team1_id, Data#match.team2_id} of
        {DisqualifiedTeamId, T2} when T2 =/= undefined -> T2;
        {T1, DisqualifiedTeamId} when T1 =/= undefined -> T1;
        _ -> undefined
    end,
    case WinnerId of
        undefined ->
            {keep_state, Data};
        _ ->
            Result = #match_result{
                winner_team_id = WinnerId,
                loser_team_id = DisqualifiedTeamId,
                scores = [{WinnerId, 1}, {DisqualifiedTeamId, 0}],
                submitted_by = system,
                submitted_at = erlang:system_time(second),
                disputed = false,
                dispute_reason = Reason
            },
            NewData = Data#match{
                state = disqualified,
                result = Result,
                finished_at = erlang:system_time(second)
            },
            notify_result(Data#match.tournament_id, Data#match.id, Result),
            {next_state, disqualified, NewData}
    end;
handle_common_events(_EventType, _EventContent, Data, _StateName) ->
    {keep_state, Data}.

%% Validation
validate_result(Data, Result) ->
    Winner = Result#match_result.winner_team_id,
    Loser = Result#match_result.loser_team_id,
    Team1 = Data#match.team1_id,
    Team2 = Data#match.team2_id,
    Scores = Result#match_result.scores,
    Format = Data#match.format,

    WinnerValid = Winner =:= Team1 orelse Winner =:= Team2,
    LoserValid = Loser =:= Team1 orelse Loser =:= Team2,
    Submitter = Result#match_result.submitted_by,
    SubmitterValid = Submitter =:= system orelse Submitter =:= Team1 orelse Submitter =:= Team2,
    MapsToWin = case Format of bo1 -> 1; bo3 -> 2; bo5 -> 3 end,
    ScoresValid = lists:all(fun({TeamId, Score}) ->
        (TeamId =:= Team1 orelse TeamId =:= Team2) andalso
        is_integer(Score) andalso Score >= 0;
       (_) -> false
    end, Scores),
    case {WinnerValid, LoserValid, Winner =:= Loser, SubmitterValid,
          ScoresValid, length(Scores) > 0} of
        {false, _, _, _, _, _} -> {error, invalid_winner};
        {_, false, _, _, _, _} -> {error, invalid_loser};
        {_, _, true, _, _, _} -> {error, same_winner_loser};
        {_, _, _, false, _, _} -> {error, invalid_reporter};
        {_, _, _, _, false, _} -> {error, invalid_scores};
        {_, _, _, _, _, false} -> {error, insufficient_scores};
        _ ->
            WinnerMapWins = length([ok || {T, _} <- Scores, T =:= Winner]),
            LoserMapWins = length([ok || {T, _} <- Scores, T =:= Loser]),
            case WinnerMapWins >= MapsToWin andalso LoserMapWins < MapsToWin andalso
                 WinnerMapWins > LoserMapWins of
                true -> {ok, Result};
                false -> {error, scores_inconsistent_with_winner}
            end
    end.

check_conflict(Data, NewResult) ->
    case Data#match.result of
        undefined -> no_conflict;
        ExistingResult ->
            NewWinner = NewResult#match_result.winner_team_id,
            case ExistingResult#match_result.winner_team_id of
                NewWinner ->
                    no_conflict;
                _ ->
                    {conflict, ExistingResult}
            end
    end.

%% Notifications
notify_result(TournamentId, MatchId, Result) ->
    %% Notify bracket server
    gen_server:cast({global, {p72_bracket_server, TournamentId}},
                    {match_finished, MatchId, Result}),
    %% Notify live score server
    gen_server:cast({global, {p72_live_score_server, TournamentId}},
                    {match_finished, MatchId, Result}).

register_conflicting_result(Data, DisputeResult) ->
    TournamentId = Data#match.tournament_id,
    MatchId = Data#match.id,
    gen_server:cast({global, {p72_bracket_server, TournamentId}},
                    {match_disputed, MatchId}),
    case global:whereis_name({p72_dispute_resolver, TournamentId}) of
        undefined -> ok;
        _Pid ->
            _ = p72_dispute_resolver:submit_dispute(TournamentId, MatchId, #{
                reported_by => DisputeResult#match_result.submitted_by,
                claimed_winner => DisputeResult#match_result.winner_team_id,
                claimed_scores => DisputeResult#match_result.scores,
                reason => DisputeResult#match_result.dispute_reason
            }),
            ok
    end,
    gen_server:cast({global, {p72_live_score_server, TournamentId}},
                    {match_disputed, MatchId, DisputeResult}).

terminate(_Reason, _StateName, Data) ->
    %% Release table/referee resources
    TournamentId = Data#match.tournament_id,
    Round = Data#match.round,
    TableId = Data#match.table_id,
    RefereeId = Data#match.referee_id,
    p72_match_sup:release_resources(TournamentId, Round, TableId, RefereeId),
    ok.

reply(From, ReplyValue, StateName, Data) ->
    {next_state, StateName, Data, [{reply, From, ReplyValue}]}.

transition_to_disputed(From, Reason, Data, _CurrentState) ->
    TournamentId = Data#match.tournament_id,
    MatchId = Data#match.id,
    gen_server:cast({global, {p72_bracket_server, TournamentId}}, {match_disputed, MatchId}),
    gen_server:cast({global, {p72_live_score_server, TournamentId}},
                    {match_status, MatchId, disputed, Reason}),
    reply(From, ok, disputed, Data#match{state = disputed}).

code_change(_OldVsn, StateName, Data, _Extra) ->
    {ok, StateName, Data}.
