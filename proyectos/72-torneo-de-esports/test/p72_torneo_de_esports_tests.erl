%% -*- mode: erlang -*-
-module(p72_torneo_de_esports_tests).
-behaviour(supervisor).

-include_lib("eunit/include/eunit.hrl").
-include("p72_torneo_de_esports.hrl").

-export([init/1]).

%% Each test gets a fresh OTP tree so registered processes and in-memory state
%% cannot leak between cases.
torneo_test_() ->
    {foreach,
     fun start_system/0,
     fun stop_system/1,
     [fun supervision_tree/1,
      fun single_elimination_bracket/1,
      fun single_elimination_completion_and_appeal/1,
      fun propagated_result_correction/1,
      fun single_elimination_byes/1,
      fun match_state_machine/1,
      fun multiple_tournaments_same_match_id/1,
      fun conflicting_reports_and_adjudication/1,
      fun disqualification_advances_opponent/1,
      fun double_elimination_reset/1,
      fun sixty_four_team_double_elimination/1,
      fun shared_resource_reservations/1,
      fun match_process_restarts/1,
      fun three_hundred_live_viewers/1,
      fun dispute_lifecycle/1,
      fun live_score_broadcast/1,
      fun metrics_collection/1]}.

start_system() ->
    %% The HTTP listener needs socket permissions that are unavailable in the
    %% test sandbox. Start the same OTP services without that external listener.
    {ok, Pid} = supervisor:start_link(?MODULE, test),
    unlink(Pid),
    Pid.

stop_system(Pid) ->
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    after 5000 ->
        erlang:demonitor(Ref, [flush]),
        ?assert(false)
    end.

supervision_tree(SupPid) ->
    ?_test(supervision_tree_case(SupPid)).

supervision_tree_case(SupPid) ->
    {ok, {{one_for_one, _Intensity, _Period}, RootChildren}} =
        p72_torneo_de_esports_sup:init([]),
    ?assert(lists:any(fun(Child) -> maps:get(id, Child) =:= http_server end,
                      RootChildren)),
    ?assert(is_process_alive(SupPid)),
    ?assert(is_pid(whereis(p72_tournament_registry))),
    ?assert(is_pid(whereis(p72_tournament_sup))),
    ?assert(is_pid(whereis(p72_metrics_collector))).

single_elimination_bracket(_SupPid) ->
    ?_test(single_elimination_bracket_case()).

single_elimination_bracket_case() ->
    Tournament = create_tournament(<<"Bracket test">>, single_elim, 4),
    TournamentId = Tournament#tournament.id,
    lists:foreach(
      fun({Name, Seed}) ->
          {ok, _Team} = p72_tournament_process:register_team(TournamentId, #{
              name => Name,
              players => [],
              seed => Seed
          })
      end,
      [{<<"Alpha">>, 1}, {<<"Bravo">>, 2}, {<<"Charlie">>, 3}, {<<"Delta">>, 4}]),

    ?assertEqual(ok, p72_tournament_process:start_tournament(TournamentId)),
    {ok, [Bracket]} = p72_bracket_server:get_bracket(TournamentId),
    ?assertEqual(single_elim, Bracket#bracket.format),
    ?assertEqual(2, Bracket#bracket.total_rounds),
    ?assertEqual(3, map_size(Bracket#bracket.matches)),

    [FirstMatch | _] = [M || M <- maps:values(Bracket#bracket.matches), M#match.round =:= 1],
    WinnerId = FirstMatch#match.team1_id,
    LoserId = FirstMatch#match.team2_id,
    Result = #match_result{
        winner_team_id = WinnerId,
        loser_team_id = LoserId,
        scores = [{WinnerId, 2}, {WinnerId, 2}, {LoserId, 1}],
        submitted_by = WinnerId,
        submitted_at = erlang:system_time(second),
        disputed = false,
        dispute_reason = undefined
    },
    {ok, _UpdatedBracket} = p72_bracket_server:update_match_result(
                              TournamentId, FirstMatch#match.id, Result),
    ?assertEqual(in_progress, p72_tournament_process:get_state(TournamentId)),
    {ok, [AdvancedBracket]} = p72_bracket_server:get_bracket(TournamentId),
    NextRound = [M || M <- maps:values(AdvancedBracket#bracket.matches), M#match.round =:= 2],
    ?assert(lists:any(fun(M) ->
        M#match.team1_id =:= WinnerId orelse M#match.team2_id =:= WinnerId
    end, NextRound)).

single_elimination_completion_and_appeal(_SupPid) ->
    ?_test(single_elimination_completion_and_appeal_case()).

single_elimination_completion_and_appeal_case() ->
    {TournamentId, MatchId, Team1, Team2} =
        start_two_team_tournament(<<"Completion and appeal test">>),
    ?assertEqual(in_progress, p72_tournament_process:get_state(TournamentId)),
    ok = p72_match_server:start_match(TournamentId, MatchId),
    FirstResult = match_result(Team1, Team2, Team1),
    {ok, _} = p72_match_server:submit_result(TournamentId, MatchId, FirstResult),

    %% The final result closes the tournament automatically.
    wait_until(fun() ->
        case p72_tournament_registry:get_tournament(TournamentId) of
            {ok, #tournament{state = completed}} -> true;
            _ -> false
        end
    end, 100),
    ?assertEqual(completed, p72_tournament_process:get_state(TournamentId)),
    {ok, FinalMatch} = p72_bracket_server:get_match(TournamentId, MatchId),
    ?assertMatch(#match{state = finished,
                        result = #match_result{winner_team_id = Team1}},
                 FinalMatch),

    %% A conflicting report on the final is the appeal path.  It must reopen
    %% the tournament while the dispute remains unresolved.
    Conflicting = match_result(Team2, Team1, Team2),
    ?assertMatch({disputed, _},
                 p72_match_server:submit_result(TournamentId, MatchId, Conflicting)),
    ?assertEqual(disputed, p72_match_server:get_state(TournamentId, MatchId)),
    wait_until(fun() ->
        case p72_tournament_registry:get_tournament(TournamentId) of
            {ok, #tournament{state = in_progress}} -> true;
            _ -> false
        end
    end, 100),
    ?assertEqual(in_progress, p72_tournament_process:get_state(TournamentId)),
    {ok, DisputedFinal} = p72_bracket_server:get_match(TournamentId, MatchId),
    ?assertEqual(scheduled, DisputedFinal#match.state),
    {ok, [Dispute]} = p72_dispute_resolver:get_open_disputes(TournamentId),

    %% Resolving the appeal with the official result closes it again.
    OfficialResult = match_result(Team1, Team2, system),
    {ok, _Resolved, recalculated} = p72_dispute_resolver:resolve_and_recalculate(
        TournamentId, Dispute#dispute.id, <<"Appeal reviewed">>, OfficialResult),
    wait_until(fun() ->
        case p72_tournament_registry:get_tournament(TournamentId) of
            {ok, #tournament{state = completed}} -> true;
            _ -> false
        end
    end, 100),
    ?assertEqual(completed, p72_tournament_process:get_state(TournamentId)),
    {ok, ResolvedFinal} = p72_bracket_server:get_match(TournamentId, MatchId),
    ?assertMatch(#match{state = finished,
                        result = #match_result{winner_team_id = Team1}},
                 ResolvedFinal),
    ?assertEqual(finished, p72_match_server:get_state(TournamentId, MatchId)),
    {ok, []} = p72_dispute_resolver:get_open_disputes(TournamentId).

match_state_machine(_SupPid) ->
    ?_test(match_state_machine_case()).

match_state_machine_case() ->
    Tournament = create_tournament(<<"Match test">>, single_elim, 2),
    TournamentId = Tournament#tournament.id,
    MatchId = 9001,
    Match = #match{
        id = MatchId,
        tournament_id = TournamentId,
        bracket_id = 1,
        round = 1,
        position = 1,
        format = bo3,
        team1_id = 11,
        team2_id = 22,
        state = scheduled,
        result = undefined,
        scheduled_at = undefined,
        started_at = undefined,
        finished_at = undefined,
        table_id = undefined,
        referee_id = undefined,
        metadata = #{}
    },
    {ok, _ViewerId} = p72_live_score_server:subscribe(TournamentId, self()),
    receive {tournament_state, _} -> ok after 1000 -> ?assert(false) end,
    {ok, _Pid} = p72_match_sup:start_match(TournamentId, MatchId, Match),
    ?assertEqual(scheduled, p72_match_server:get_state(TournamentId, MatchId)),
    ?assertEqual(ok, p72_match_server:start_match(TournamentId, MatchId)),
    ?assertEqual(in_play, p72_match_server:get_state(TournamentId, MatchId)),
    Result = #match_result{
        winner_team_id = 11,
        loser_team_id = 22,
        scores = [{11, 2}, {22, 0}, {11, 2}],
        submitted_by = 11,
        submitted_at = erlang:system_time(second),
        disputed = false,
        dispute_reason = undefined
    },
    ?assertMatch({ok, _}, p72_match_server:submit_result(TournamentId, MatchId, Result)),
    ?assertEqual(finished, p72_match_server:get_state(TournamentId, MatchId)),
    receive
        {match_finished, MatchId, Result} -> ok
    after 1000 -> ?assert(false)
    end,
    ?assert(is_pid(global:whereis_name({p72_live_score_server, TournamentId}))).

multiple_tournaments_same_match_id(_SupPid) ->
    ?_test(multiple_tournaments_same_match_id_case()).

multiple_tournaments_same_match_id_case() ->
    {Tournament1, Match1, Team1A, Team1B} =
        start_two_team_tournament(<<"Same match id A">>),
    {Tournament2, Match2, Team2A, Team2B} =
        start_two_team_tournament(<<"Same match id B">>),
    ?assertEqual(1, Match1),
    ?assertEqual(1, Match2),
    ?assertNotEqual(Tournament1, Tournament2),
    {ok, Pid1} = p72_match_sup:get_match_pid(Tournament1, Match1),
    {ok, Pid2} = p72_match_sup:get_match_pid(Tournament2, Match2),
    ?assertNotEqual(Pid1, Pid2),
    Data1 = p72_match_server:get_data(Tournament1, Match1),
    Data2 = p72_match_server:get_data(Tournament2, Match2),
    ?assertEqual(Tournament1, Data1#match.tournament_id),
    ?assertEqual(Tournament2, Data2#match.tournament_id),
    ?assertEqual(Match1, Data1#match.id),
    ?assertEqual(Match2, Data2#match.id),
    ok = p72_match_server:start_match(Tournament1, Match1),
    ok = p72_match_server:start_match(Tournament2, Match2),
    {ok, _} = p72_match_server:submit_result(
        Tournament1, Match1, match_result(Team1A, Team1B, Team1A)),
    ?assertEqual(finished, p72_match_server:get_state(Tournament1, Match1)),
    ?assertEqual(in_play, p72_match_server:get_state(Tournament2, Match2)),
    {ok, _} = p72_match_server:submit_result(
        Tournament2, Match2, match_result(Team2A, Team2B, Team2A)),
    ?assertEqual(finished, p72_match_server:get_state(Tournament2, Match2)).

single_elimination_byes(_SupPid) ->
    ?_test(single_elimination_byes_case()).

single_elimination_byes_case() ->
    Tournament = create_tournament(<<"Bye test">>, single_elim, 5),
    TournamentId = Tournament#tournament.id,
    register_teams(TournamentId, 5),
    ?assertEqual(ok, p72_tournament_process:start_tournament(TournamentId)),
    {ok, [Bracket]} = p72_bracket_server:get_bracket(TournamentId),
    ?assertEqual(3, Bracket#bracket.total_rounds),
    ?assertEqual(7, map_size(Bracket#bracket.matches)),
    RoundOne = [M || M <- maps:values(Bracket#bracket.matches), M#match.round =:= 1],
    ?assertEqual(3, length([M || M <- RoundOne, M#match.state =:= finished])),
    ?assertEqual(1, length([M || M <- RoundOne, M#match.state =:= scheduled])).

propagated_result_correction(_SupPid) ->
    ?_test(propagated_result_correction_case()).

propagated_result_correction_case() ->
    Tournament = create_tournament(<<"Correction test">>, single_elim, 4),
    TournamentId = Tournament#tournament.id,
    register_teams(TournamentId, 4),
    ok = p72_tournament_process:start_tournament(TournamentId),
    {ok, [Bracket0]} = p72_bracket_server:get_bracket(TournamentId),
    Semifinals = lists:sort(fun(A, B) -> A#match.position < B#match.position end,
        [M || M <- maps:values(Bracket0#bracket.matches), M#match.round =:= 1]),
    [Semi1, Semi2] = Semifinals,
    OldWinner = Semi1#match.team1_id,
    OtherWinner = Semi2#match.team1_id,
    {ok, _} = p72_bracket_server:update_match_result(TournamentId, Semi1#match.id,
        match_result(OldWinner, Semi1#match.team2_id, OldWinner)),
    {ok, _} = p72_bracket_server:update_match_result(TournamentId, Semi2#match.id,
        match_result(OtherWinner, Semi2#match.team2_id, OtherWinner)),
    {ok, [Bracket1]} = p72_bracket_server:get_bracket(TournamentId),
    [Final0] = [M || M <- maps:values(Bracket1#bracket.matches), M#match.round =:= 2],
    FinalWinner = Final0#match.team1_id,
    {ok, _} = p72_bracket_server:update_match_result(TournamentId, Final0#match.id,
        match_result(FinalWinner, Final0#match.team2_id, FinalWinner)),
    NewWinner = Semi1#match.team2_id,
    {ok, _} = p72_bracket_server:update_match_result(TournamentId, Semi1#match.id,
        match_result(NewWinner, OldWinner, NewWinner)),
    {ok, _} = p72_bracket_server:recalculate_bracket(TournamentId),
    {ok, [Bracket2]} = p72_bracket_server:get_bracket(TournamentId),
    [Final1] = [M || M <- maps:values(Bracket2#bracket.matches), M#match.round =:= 2],
    ?assert(Final1#match.team1_id =:= NewWinner orelse Final1#match.team2_id =:= NewWinner),
    ?assertNotEqual(finished, Final1#match.state).

conflicting_reports_and_adjudication(_SupPid) ->
    ?_test(conflicting_reports_and_adjudication_case()).

conflicting_reports_and_adjudication_case() ->
    {TournamentId, MatchId, Team1, Team2} = start_two_team_tournament(<<"Conflict test">>),
    ok = p72_match_server:start_match(TournamentId, MatchId),
    FirstResult = match_result(Team1, Team2, Team1),
    ?assertMatch({ok, _}, p72_match_server:submit_result(TournamentId, MatchId, FirstResult)),
    Conflicting = match_result(Team2, Team1, Team2),
    ?assertMatch({disputed, _}, p72_match_server:submit_result(TournamentId, MatchId, Conflicting)),
    ?assertEqual(disputed, p72_match_server:get_state(TournamentId, MatchId)),
    {ok, [Dispute]} = p72_dispute_resolver:get_open_disputes(TournamentId),
    ?assertEqual(Team2, Dispute#dispute.claimed_winner),
    OfficialResult = match_result(Team2, Team1, system),
    {ok, _Resolved, recalculated} = p72_dispute_resolver:resolve_and_recalculate(
        TournamentId, Dispute#dispute.id, <<"Evidence reviewed">>, OfficialResult),
    ?assertEqual(finished, p72_match_server:get_state(TournamentId, MatchId)),
    wait_until(fun() ->
        case p72_bracket_server:get_match(TournamentId, MatchId) of
            {ok, #match{state = finished, result = #match_result{winner_team_id = Team2}}} -> true;
            _ -> false
        end
    end, 50).

disqualification_advances_opponent(_SupPid) ->
    ?_test(disqualification_advances_opponent_case()).

disqualification_advances_opponent_case() ->
    Tournament = create_tournament(<<"DQ test">>, single_elim, 4),
    TournamentId = Tournament#tournament.id,
    register_teams(TournamentId, 4),
    ok = p72_tournament_process:start_tournament(TournamentId),
    {ok, [Bracket]} = p72_bracket_server:get_bracket(TournamentId),
    [Match | _] = [M || M <- maps:values(Bracket#bracket.matches), M#match.round =:= 1],
    DQTeam = Match#match.team1_id,
    AdvancingTeam = Match#match.team2_id,
    {ok, _Result} = p72_match_server:disqualify_team(TournamentId, Match#match.id, DQTeam, <<"No-show">>),
    wait_until(fun() ->
        {ok, [B]} = p72_bracket_server:get_bracket(TournamentId),
        lists:any(fun(Next) ->
            Next#match.round =:= 2 andalso
            (Next#match.team1_id =:= AdvancingTeam orelse Next#match.team2_id =:= AdvancingTeam)
        end, maps:values(B#bracket.matches))
    end, 50).

double_elimination_reset(_SupPid) ->
    ?_test(double_elimination_reset_case()).

double_elimination_reset_case() ->
    Tournament = create_tournament(<<"Double elimination test">>, double_elim, 4),
    TournamentId = Tournament#tournament.id,
    register_teams(TournamentId, 4),
    ok = p72_tournament_process:start_tournament(TournamentId),
    simulate_double_elimination(TournamentId, 20),
    {ok, Brackets} = p72_bracket_server:get_bracket(TournamentId),
    Finals = [M || B <- Brackets, M <- maps:values(B#bracket.matches),
        maps:get(match_stage, M#match.metadata, undefined) =:= grand_final orelse
        maps:get(match_stage, M#match.metadata, undefined) =:= grand_final_reset],
    ?assertEqual(2, length(Finals)),
    ?assert(lists:all(fun(M) -> M#match.state =:= finished end, Finals)),
    ?assertEqual(completed, p72_tournament_process:get_state(TournamentId)).

sixty_four_team_double_elimination(_SupPid) ->
    ?_test(sixty_four_team_double_elimination_case()).

sixty_four_team_double_elimination_case() ->
    Tournament = create_tournament(<<"64 team scenario">>, double_elim, 64),
    TournamentId = Tournament#tournament.id,
    register_teams(TournamentId, 64),
    ok = p72_tournament_process:start_tournament(TournamentId),
    simulate_double_elimination(TournamentId, 20),
    {ok, Brackets} = p72_bracket_server:get_bracket(TournamentId),
    Matches = lists:flatmap(fun(B) -> maps:values(B#bracket.matches) end, Brackets),
    Finals = [M || M <- Matches,
        maps:get(match_stage, M#match.metadata, undefined) =:= grand_final orelse
        maps:get(match_stage, M#match.metadata, undefined) =:= grand_final_reset],
    ?assertEqual(2, length(Finals)),
    ?assert(lists:all(fun(M) -> M#match.state =:= finished end, Finals)),
    ?assertEqual(127, length(Matches)),
    ?assertEqual(completed, p72_tournament_process:get_state(TournamentId)).

shared_resource_reservations(_SupPid) ->
    ?_test(shared_resource_reservations_case()).

shared_resource_reservations_case() ->
    Tournament = create_tournament(<<"Resource test">>, single_elim, 2),
    TournamentId = Tournament#tournament.id,
    Parent = self(),
    _Pid1 = spawn(fun() -> Parent ! {resource_result,
        p72_match_sup:assign_table(TournamentId, 1, 3, 1)} end),
    _Pid2 = spawn(fun() -> Parent ! {resource_result,
        p72_match_sup:assign_table(TournamentId, 1, 3, 2)} end),
    Results = [receive {resource_result, R1} -> R1 after 1000 -> timeout end,
               receive {resource_result, R2} -> R2 after 1000 -> timeout end],
    ?assertEqual(1, length([ok || ok <- Results])),
    ?assertEqual(1, length([{error, table_in_use} || {error, table_in_use} <- Results])),
    ?assertEqual(ok, p72_match_sup:assign_referee(TournamentId, 1, 8, 1)),
    ?assertEqual({error, referee_in_use}, p72_match_sup:assign_referee(TournamentId, 1, 8, 2)).

match_process_restarts(_SupPid) ->
    ?_test(match_process_restarts_case()).

match_process_restarts_case() ->
    {TournamentId, MatchId, _Team1, _Team2} = start_two_team_tournament(<<"Restart test">>),
    {ok, OldPid} = p72_match_sup:get_match_pid(TournamentId, MatchId),
    exit(OldPid, kill),
    wait_until(fun() ->
        case p72_match_sup:get_match_pid(TournamentId, MatchId) of
            {ok, NewPid} -> NewPid =/= OldPid;
            _ -> false
        end
    end, 50),
    ?assert(is_pid(global:whereis_name({p72_live_score_server, TournamentId}))).

three_hundred_live_viewers(_SupPid) ->
    ?_test(three_hundred_live_viewers_case()).

three_hundred_live_viewers_case() ->
    Tournament = create_tournament(<<"300 viewers">>, single_elim, 2),
    TournamentId = Tournament#tournament.id,
    Parent = self(),
    Viewers = [spawn(fun() -> viewer_loop(Parent) end) || _ <- lists:seq(1, 300)],
    lists:foreach(fun(Pid) ->
        {ok, _} = p72_live_score_server:subscribe(TournamentId, Pid)
    end, Viewers),
    Score = #score_update{
        match_id = 33,
        tournament_id = TournamentId,
        team_scores = #{1 => 1, 2 => 0},
        current_map = 1,
        maps_won = #{1 => 1, 2 => 0},
        timestamp = erlang:system_time(second)
    },
    Started = erlang:monotonic_time(millisecond),
    p72_live_score_server:update_score(TournamentId, 33, Score),
    wait_for_viewers(300, Started + 2000),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    lists:foreach(fun(Pid) ->
        ok = p72_live_score_server:unsubscribe(TournamentId, Pid),
        Pid ! stop
    end, Viewers),
    ?assert(Elapsed < 2000).

viewer_loop(Parent) ->
    receive
        {tournament_state, _Summary} -> viewer_loop(Parent);
        {score_update, _Score} -> Parent ! {viewer_received, self()}, viewer_loop(Parent);
        stop -> ok
    end.

wait_for_viewers(0, _Deadline) -> ok;
wait_for_viewers(Remaining, Deadline) ->
    Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {viewer_received, _Pid} -> wait_for_viewers(Remaining - 1, Deadline)
    after Timeout ->
        ?assert(false)
    end.

dispute_lifecycle(_SupPid) ->
    ?_test(dispute_lifecycle_case()).

dispute_lifecycle_case() ->
    Tournament = create_tournament(<<"Dispute test">>, single_elim, 2),
    TournamentId = Tournament#tournament.id,
    {ok, Dispute} = p72_dispute_resolver:submit_dispute(TournamentId, 1, #{
        reported_by => 1,
        claimed_winner => 1,
        claimed_scores => [{1, 2}, {2, 1}],
        reason => <<"Resultado reportado incorrectamente">>
    }),
    ?assertEqual(open, Dispute#dispute.status),
    {ok, OpenDisputes} = p72_dispute_resolver:get_open_disputes(TournamentId),
    ?assertEqual(1, length(OpenDisputes)),
    {ok, Resolved} = p72_dispute_resolver:resolve_dispute(
                       TournamentId, Dispute#dispute.id, <<"Resultado confirmado">>),
    ?assertEqual(resolved, Resolved#dispute.status),
    {ok, []} = p72_dispute_resolver:get_open_disputes(TournamentId).

start_two_team_tournament(Name) ->
    Tournament = create_tournament(Name, single_elim, 2),
    TournamentId = Tournament#tournament.id,
    {ok, Team1} = p72_tournament_process:register_team(TournamentId, #{
        name => <<"Alpha">>, players => [], seed => 1}),
    {ok, Team2} = p72_tournament_process:register_team(TournamentId, #{
        name => <<"Bravo">>, players => [], seed => 2}),
    ok = p72_tournament_process:start_tournament(TournamentId),
    {ok, [Bracket]} = p72_bracket_server:get_bracket(TournamentId),
    [Match] = maps:values(Bracket#bracket.matches),
    {TournamentId, Match#match.id, Team1#team.id, Team2#team.id}.

register_teams(TournamentId, Count) ->
    lists:foreach(fun(Seed) ->
        {ok, _} = p72_tournament_process:register_team(TournamentId, #{
            name => <<"Team ", (integer_to_binary(Seed))/binary>>,
            players => [], seed => Seed})
    end, lists:seq(1, Count)).

match_result(WinnerId, LoserId, SubmittedBy) ->
    #match_result{
        winner_team_id = WinnerId,
        loser_team_id = LoserId,
        scores = [{WinnerId, 2}, {WinnerId, 2}, {LoserId, 1}],
        submitted_by = SubmittedBy,
        submitted_at = erlang:system_time(second),
        disputed = false,
        dispute_reason = undefined
    }.

simulate_double_elimination(_TournamentId, 0) ->
    ?assert(false);
simulate_double_elimination(TournamentId, RoundsLeft) ->
    {ok, Matches} = p72_bracket_server:get_upcoming_matches(TournamentId),
    case Matches of
        [] -> ok;
        _ ->
            lists:foreach(fun(Match) ->
                Stage = maps:get(match_stage, Match#match.metadata, undefined),
                WinnerId = case Stage of
                    grand_final -> Match#match.team2_id;
                    _ -> Match#match.team1_id
                end,
                LoserId = case WinnerId =:= Match#match.team1_id of
                    true -> Match#match.team2_id;
                    false -> Match#match.team1_id
                end,
                Result = match_result(WinnerId, LoserId, WinnerId),
                {ok, _} = p72_bracket_server:update_match_result(
                    TournamentId, Match#match.id, Result)
            end, Matches),
            simulate_double_elimination(TournamentId, RoundsLeft - 1)
    end.

wait_until(_Predicate, 0) -> ?assert(false);
wait_until(Predicate, Attempts) ->
    case Predicate() of
        true -> ok;
        false -> timer:sleep(10), wait_until(Predicate, Attempts - 1)
    end.

live_score_broadcast(_SupPid) ->
    ?_test(live_score_broadcast_case()).

live_score_broadcast_case() ->
    Tournament = create_tournament(<<"Live score test">>, single_elim, 2),
    TournamentId = Tournament#tournament.id,
    {ok, _ViewerId} = p72_live_score_server:subscribe(TournamentId, self()),
    receive
        {tournament_state, _InitialState} -> ok
    after 1000 ->
        ?assert(false)
    end,
    Score = #score_update{
        match_id = 77,
        tournament_id = TournamentId,
        team_scores = #{1 => 2, 2 => 1},
        current_map = 2,
        maps_won = #{1 => 1, 2 => 0},
        timestamp = erlang:system_time(second)
    },
    p72_live_score_server:update_score(TournamentId, 77, Score),
    receive
        {score_update, Score} -> ok
    after 1000 ->
        ?assert(false)
    end,
    ?assertEqual({ok, Score}, p72_live_score_server:get_match_score(TournamentId, 77)),
    ?assertEqual(ok, p72_live_score_server:unsubscribe(TournamentId, self())).

metrics_collection(_SupPid) ->
    ?_test(metrics_collection_case()).

metrics_collection_case() ->
    p72_metrics_collector:record_match_start(501),
    Metrics1 = p72_metrics_collector:get_metrics(),
    ?assertEqual(1, Metrics1#metrics.matches_total),
    ?assertEqual(1, Metrics1#metrics.matches_in_progress),
    p72_metrics_collector:record_match_finish(501),
    Metrics2 = p72_metrics_collector:get_metrics(),
    ?assertEqual(0, Metrics2#metrics.matches_in_progress),
    ?assertEqual(1, Metrics2#metrics.matches_finished).

create_tournament(Name, Format, MaxTeams) ->
    {ok, Tournament} = p72_tournament_registry:create_tournament(#{
        name => Name,
        format => Format,
        series_format => bo3,
        max_teams => MaxTeams,
        config => #{
            tables_count => 4,
            match_duration_estimate => 30,
            allow_disputes => true,
            dispute_timeout => 300
        }
    }),
    Tournament.

init(test) ->
    Children = [
        #{id => tournament_registry,
          start => {p72_tournament_registry, start_link, []},
          restart => permanent, shutdown => 5000, type => worker,
          modules => [p72_tournament_registry]},
        #{id => tournament_sup_manager,
          start => {p72_tournament_sup, start_link, []},
          restart => permanent, shutdown => 5000, type => supervisor,
          modules => [p72_tournament_sup]},
        #{id => metrics_collector,
          start => {p72_metrics_collector, start_link, []},
          restart => permanent, shutdown => 5000, type => worker,
          modules => [p72_metrics_collector]}
    ],
    {ok, {{one_for_one, 10, 60}, Children}}.
