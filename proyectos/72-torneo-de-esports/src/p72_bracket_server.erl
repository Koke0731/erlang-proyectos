%% -*- mode: erlang -*-
-module(p72_bracket_server).
-behaviour(gen_server).

-include("p72_torneo_de_esports.hrl").

-export([start_link/1, generate_bracket/2, get_bracket/1, get_match/2,
         update_match_result/3, get_upcoming_matches/1, get_bracket_progress/1,
         recalculate_bracket/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% API
start_link(TournamentId) ->
    gen_server:start_link({global, {?MODULE, TournamentId}}, ?MODULE, TournamentId, []).

generate_bracket(TournamentId, Teams) ->
    gen_server:call({global, {?MODULE, TournamentId}}, {generate_bracket, Teams}).

get_bracket(TournamentId) ->
    gen_server:call({global, {?MODULE, TournamentId}}, get_bracket).

get_match(TournamentId, MatchId) ->
    gen_server:call({global, {?MODULE, TournamentId}}, {get_match, MatchId}).

update_match_result(TournamentId, MatchId, Result) ->
    gen_server:call({global, {?MODULE, TournamentId}}, {update_match_result, MatchId, Result}).

get_upcoming_matches(TournamentId) ->
    gen_server:call({global, {?MODULE, TournamentId}}, get_upcoming_matches).

get_bracket_progress(TournamentId) ->
    gen_server:call({global, {?MODULE, TournamentId}}, get_bracket_progress).

recalculate_bracket(TournamentId) ->
    gen_server:call({global, {?MODULE, TournamentId}}, recalculate_bracket).

%% Callbacks
init(TournamentId) ->
    logger:info("~s iniciado para torneo ~p", [?MODULE, TournamentId]),
    {ok, #{
        tournament_id => TournamentId,
        brackets => #{},           %% bracket_id => #bracket{}
        next_bracket_id => 1,
        next_match_id => 1,
        match_to_bracket => #{}    %% match_id => bracket_id
    }}.

handle_call({generate_bracket, Teams}, _From, State) ->
    TournamentId = maps:get(tournament_id, State),
    %% Get tournament info from registry
    {ok, Tournament} = p72_tournament_registry:get_tournament(TournamentId),
    Format = Tournament#tournament.format,
    SeriesFormat = Tournament#tournament.series_format,

    %% Generate brackets based on format
    BracketResult = case Format of
        single_elim ->
            {ok, Bracket} = generate_single_elim_bracket(Teams, SeriesFormat, State),
            {ok, [Bracket]};
        double_elim ->
            generate_double_elim_bracket(Teams, SeriesFormat, State);
        swiss ->
            {ok, Bracket} = generate_swiss_bracket(Teams, SeriesFormat, State),
            {ok, [Bracket]};
        groups ->
            {ok, Brackets} = generate_groups_bracket(Teams, SeriesFormat, State),
            {ok, Brackets}
    end,

    %% Process each bracket (double elim returns 2, others return 1 or more)
    {NewState, CreatedBrackets} = process_generated_brackets(State, TournamentId, BracketResult, #{}),

    {reply, {ok, CreatedBrackets}, NewState};

handle_call(get_bracket, _From, State) ->
    Brackets = maps:values(maps:get(brackets, State)),
    {reply, {ok, Brackets}, State};

handle_call({get_match, MatchId}, _From, State) ->
    case maps:find(MatchId, maps:get(match_to_bracket, State)) of
        {ok, BracketId} ->
            case maps:find(BracketId, maps:get(brackets, State)) of
                {ok, Bracket} ->
                    case maps:find(MatchId, Bracket#bracket.matches) of
                        {ok, Match} -> {reply, {ok, Match}, State};
                        error -> {reply, {error, not_found}, State}
                    end;
                error -> {reply, {error, not_found}, State}
            end;
        error -> {reply, {error, not_found}, State}
    end;

handle_call({update_match_result, MatchId, Result}, _From, State) ->
    case maps:find(MatchId, maps:get(match_to_bracket, State)) of
        {ok, BracketId} ->
            case maps:find(BracketId, maps:get(brackets, State)) of
                {ok, Bracket} ->
                    case maps:find(MatchId, Bracket#bracket.matches) of
                        {ok, Match} ->
                            %% Update match with result
                            UpdatedMatch = Match#match{
                                state = finished,
                                result = Result,
                                finished_at = erlang:system_time(second)
                            },
                            UpdatedBracket = Bracket#bracket{
                                matches = maps:put(MatchId, UpdatedMatch, Bracket#bracket.matches)
                            },
                            NewBrackets1 = maps:put(BracketId, UpdatedBracket, maps:get(brackets, State)),
                            case maps:get(match_stage, Match#match.metadata, undefined) of
                                grand_final ->
                                    NewState0 = State#{brackets => NewBrackets1},
                                    NewState = maybe_create_grand_final_reset(
                                        NewState0, UpdatedMatch, Result),
                                    {reply, {ok, maps:get(brackets, NewState)}, NewState};
                                grand_final_reset ->
                                    NewState = complete_tournament(
                                        Match#match.tournament_id,
                                        State#{brackets => NewBrackets1}),
                                    {reply, {ok, NewBrackets1}, NewState};
                                _ ->
                                    case Bracket#bracket.format of
                                        double_elim ->
                                            NewBrackets2 = recalculate_double_elim_full(NewBrackets1),
                                            State0 = State#{brackets => NewBrackets2},
                                            NewState = maybe_create_grand_final(State0),
                                            {reply, {ok, maps:get(brackets, NewState)}, NewState};
                                        _ ->
                                            PropagatedBracket = propagate_result(
                                                UpdatedBracket, MatchId, Result),
                                            NewBrackets = maps:put(
                                                BracketId, PropagatedBracket, maps:get(brackets, State)),
                                            NewState = State#{brackets => NewBrackets},
                                            {reply, {ok, PropagatedBracket},
                                             maybe_complete_single_elimination(
                                                 PropagatedBracket, NewState)}
                                    end
                            end;
                        error -> {reply, {error, match_not_found}, State}
                    end;
                error -> {reply, {error, bracket_not_found}, State}
            end;
        error -> {reply, {error, match_not_found}, State}
    end;

handle_call(get_upcoming_matches, _From, State) ->
    AllMatches = lists:flatmap(
        fun(B) -> maps:values(B#bracket.matches) end,
        maps:values(maps:get(brackets, State))
    ),
    Upcoming = lists:filter(
        fun(M) -> M#match.state =:= scheduled andalso
                       M#match.team1_id =/= undefined andalso
                       M#match.team2_id =/= undefined end,
        AllMatches
    ),
    {reply, {ok, Upcoming}, State};

handle_call(get_bracket_progress, _From, State) ->
    Brackets = maps:values(maps:get(brackets, State)),
    Progress = maps:from_list(lists:map(
        fun(B) ->
            Total = map_size(B#bracket.matches),
            Finished = length(lists:filter(
                fun(M) -> M#match.state =:= finished end,
                maps:values(B#bracket.matches)
            )),
            {B#bracket.id, if Total > 0 -> Finished / Total; true -> 0.0 end}
        end,
        Brackets
    )),
    {reply, {ok, Progress}, State};

handle_call(recalculate_bracket, _From, State) ->
    %% Recalculate all brackets from current match results
    Brackets = maps:get(brackets, State),
    %% Check if any bracket is double elimination
    HasDoubleElim = lists:any(
        fun(B) -> B#bracket.format =:= double_elim end,
        maps:values(Brackets)
    ),
    NewBrackets = if
        HasDoubleElim ->
            %% For double elimination, recalculate across all brackets
            recalculate_double_elim_full(Brackets);
        true ->
            %% For other formats, recalculate per bracket
            maps:map(
                fun(_Bid, Bracket) -> recalculate_bracket_from_results(Bracket) end,
                Brackets
            )
    end,
    NewState0 = State#{brackets => NewBrackets},
    NewState = maps:fold(
        fun(_BracketId, Bracket, AccState) ->
            maybe_complete_single_elimination(Bracket, AccState)
        end,
        NewState0,
        NewBrackets),
    {reply, {ok, NewBrackets}, NewState}.

handle_cast({match_finished, MatchId, Result}, State) ->
    case maps:find(MatchId, maps:get(match_to_bracket, State)) of
        {ok, BracketId} ->
            Brackets = maps:get(brackets, State),
            case maps:find(BracketId, Brackets) of
                {ok, Bracket} ->
                    case maps:find(MatchId, Bracket#bracket.matches) of
                        {ok, Match} ->
                            UpdatedMatch = Match#match{
                                state = finished,
                                result = Result,
                                finished_at = erlang:system_time(second)
                            },
                            UpdatedBracket = Bracket#bracket{
                                matches = maps:put(MatchId, UpdatedMatch, Bracket#bracket.matches)
                            },
                            NewBrackets1 = maps:put(BracketId, UpdatedBracket, Brackets),
                            Stage = maps:get(match_stage, Match#match.metadata, undefined),
                            State0 = State#{brackets => NewBrackets1},
                            State1 = case Stage of
                                grand_final -> maybe_create_grand_final_reset(State0, UpdatedMatch, Result);
                                grand_final_reset -> complete_tournament(
                                    Match#match.tournament_id, State0);
                                _ when Bracket#bracket.format =:= double_elim ->
                                    NewBrackets2 = recalculate_double_elim_full(NewBrackets1),
                                    maybe_create_grand_final(State0#{brackets => NewBrackets2});
                                _ ->
                                    Propagated = propagate_result(UpdatedBracket, MatchId, Result),
                                    NewState = State0#{brackets => maps:put(
                                        BracketId, Propagated, NewBrackets1)},
                                    maybe_complete_single_elimination(Propagated, NewState)
                            end,
                            {noreply, State1};
                        error -> {noreply, State}
                    end;
                error -> {noreply, State}
            end;
        error -> {noreply, State}
    end;
handle_cast({match_disputed, MatchId}, State) ->
    case maps:find(MatchId, maps:get(match_to_bracket, State)) of
        {ok, BracketId} ->
            Brackets = maps:get(brackets, State),
            Bracket = maps:get(BracketId, Brackets),
            Match = maps:get(MatchId, Bracket#bracket.matches),
            Updated = Match#match{state = disputed},
            UpdatedBracket = Bracket#bracket{
                matches = maps:put(MatchId, Updated, Bracket#bracket.matches)
            },
            NewBrackets = case UpdatedBracket#bracket.format of
                single_elim ->
                    maps:put(BracketId, recalculate_single_elimination(UpdatedBracket), Brackets);
                double_elim ->
                    recalculate_double_elim_full(maps:put(BracketId, UpdatedBracket, Brackets));
                _ -> maps:put(BracketId, UpdatedBracket, Brackets)
            end,
            NewState = State#{brackets => NewBrackets},
            %% An appeal on the final match must reopen a completed tournament;
            %% otherwise the resolution could no longer change the official state.
            {noreply, reopen_tournament_if_completed(Match#match.tournament_id, NewState)};
        error -> {noreply, State}
    end;
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% Helper to process multiple generated brackets
process_generated_brackets(State, TournamentId, {ok, BracketList}, _AccMatchToBracket) ->
    {NewState, CreatedBrackets} = lists:foldl(
        fun(Bracket, {StateAcc, BracketsAcc}) ->
            BracketId = maps:get(next_bracket_id, StateAcc),
            Bracket1 = Bracket#bracket{id = BracketId, tournament_id = TournamentId},
            {Bracket2, NewNextMatchId, NewMatchToBracket} = assign_match_ids(Bracket1, maps:get(next_match_id, StateAcc), #{}),
            NewBrackets = maps:put(BracketId, Bracket2, maps:get(brackets, StateAcc)),
            NewStateAcc = StateAcc#{
                brackets => NewBrackets,
                next_bracket_id => BracketId + 1,
                next_match_id => NewNextMatchId,
                match_to_bracket => maps:merge(maps:get(match_to_bracket, StateAcc), NewMatchToBracket)
            },
            {NewStateAcc, [Bracket2 | BracketsAcc]}
        end,
        {State, []},
        BracketList
    ),
    {NewState, lists:reverse(CreatedBrackets)}.

%%% Internal bracket generation functions

generate_single_elim_bracket(Teams, SeriesFormat, State) ->
    TeamList = lists:sort(fun(T1, T2) -> T1#team.seed =< T2#team.seed end, Teams),
    N = length(TeamList),
    TotalRounds = trunc(math:ceil(math:log2(N))),
    Byes = trunc(math:pow(2, TotalRounds)) - N,

    %% Build every round so match results can advance through the bracket.
    Matches = create_full_winners_bracket(
        TeamList, Byes, SeriesFormat, TotalRounds, maps:get(next_match_id, State)
    ),
    Bracket = #bracket{
        name = <<"Winners Bracket">>,
        format = single_elim,
        teams = TeamList,
        matches = #{},
        current_round = 1,
        total_rounds = TotalRounds,
        metadata = #{}
    },
    {ok, Bracket#bracket{matches = maps:from_list([{M#match.id, M} || M <- Matches])}}.

generate_double_elim_bracket(Teams, SeriesFormat, State) ->
    TeamList = lists:sort(fun(T1, T2) -> T1#team.seed =< T2#team.seed end, Teams),
    N = length(TeamList),
    TotalRoundsWinners = trunc(math:ceil(math:log2(N))),
    Byes = trunc(math:pow(2, TotalRoundsWinners)) - N,
    NextMatchId = maps:get(next_match_id, State),

    %% Winners bracket - full bracket with all rounds
    WB_Matches = create_full_winners_bracket(TeamList, Byes, SeriesFormat, TotalRoundsWinners, NextMatchId),
    WinnersBracket = #bracket{
        name = <<"Winners Bracket">>,
        format = double_elim,
        teams = TeamList,
        matches = lists:foldl(fun(M, Acc) -> maps:put(M#match.id, M, Acc) end, #{}, WB_Matches),
        current_round = 1,
        total_rounds = TotalRoundsWinners,
        metadata = #{bracket_type => winners}
    },

    %% Losers bracket - generate all rounds upfront
    TotalRoundsLosers = calculate_losers_bracket_rounds(N, TotalRoundsWinners),
    LB_Matches = create_losers_bracket_matches(TeamList, Byes, SeriesFormat, TotalRoundsWinners, TotalRoundsLosers, NextMatchId + length(WB_Matches)),
    LosersBracket = #bracket{
        name = <<"Losers Bracket">>,
        format = double_elim,
        teams = TeamList,
        matches = lists:foldl(fun(M, Acc) -> maps:put(M#match.id, M, Acc) end, #{}, LB_Matches),
        current_round = 1,
        total_rounds = TotalRoundsLosers,
        metadata = #{bracket_type => losers, wb_rounds => TotalRoundsWinners}
    },

    {ok, [WinnersBracket, LosersBracket]}.

generate_swiss_bracket(Teams, _SeriesFormat, _State) ->
    TeamList = lists:sort(fun(T1, T2) -> T1#team.seed =< T2#team.seed end, Teams),
    N = length(TeamList),
    TotalRounds = trunc(math:ceil(math:log2(N))),

    Bracket = #bracket{
        name = <<"Swiss">>,
        format = swiss,
        teams = TeamList,
        matches = #{},
        current_round = 1,
        total_rounds = TotalRounds,
        metadata = #{pairings => #{}}
    },
    {ok, Bracket}.

generate_groups_bracket(Teams, SeriesFormat, State) ->
    %% Split teams into groups of 4-5
    GroupSize = 4,
    Groups = chunk_list(Teams, GroupSize),
    {GroupBrackets, _NextMatchId} = lists:mapfoldl(
        fun({GroupTeams, GroupIdx}, NextMatchId) ->
            GroupName = <<"Group ", (GroupIdx + 1)/binary>>,
            Matches = create_round_robin_matches(GroupTeams, SeriesFormat, 1, NextMatchId),
            Bracket = #bracket{
                name = GroupName,
                format = groups,
                teams = GroupTeams,
                matches = maps:from_list([{M#match.id, M} || M <- Matches]),
                current_round = 1,
                total_rounds = length(GroupTeams) - 1,
                metadata = #{group_index => GroupIdx}
            },
            {Bracket, NextMatchId + length(Matches)}
        end,
        maps:get(next_match_id, State),
        lists:zip(Groups, lists:seq(0, length(Groups) - 1))
    ),
    {ok, GroupBrackets}.

%%% Double Elimination Helper Functions

%% Create full winners bracket with all rounds
create_full_winners_bracket(Teams, Byes, SeriesFormat, TotalRounds, StartMatchId) ->
    Round1Matches = create_first_round_matches(Teams, Byes, SeriesFormat, 1, StartMatchId),
    create_winners_bracket_rounds(Round1Matches, TotalRounds, 2, StartMatchId + length(Round1Matches), [], SeriesFormat).

create_winners_bracket_rounds(PrevRoundMatches, TotalRounds, CurrentRound, NextMatchId, AccMatches, SeriesFormat) ->
    if
        CurrentRound > TotalRounds ->
            lists:reverse(AccMatches) ++ PrevRoundMatches;
        true ->
            NumPrevMatches = length(PrevRoundMatches),
            NumCurrMatches = NumPrevMatches div 2,
            CurrMatches = lists:map(
                fun(I) ->
                    MatchId = NextMatchId + I - 1,
                    #match{
                        id = MatchId,
                        bracket_id = undefined,
                        round = CurrentRound,
                        position = I,
                        format = SeriesFormat,
                        team1_id = undefined,
                        team2_id = undefined,
                        state = scheduled,
                        result = undefined,
                        scheduled_at = undefined,
                        started_at = undefined,
                        finished_at = undefined,
                        table_id = undefined,
                        referee_id = undefined,
                        metadata = #{prev_match1 => (lists:nth(I * 2 - 1, PrevRoundMatches))#match.id,
                                   prev_match2 => (lists:nth(I * 2, PrevRoundMatches))#match.id}
                    }
                end,
                lists:seq(1, NumCurrMatches)
            ),
            create_winners_bracket_rounds(CurrMatches, TotalRounds, CurrentRound + 1, NextMatchId + NumCurrMatches, PrevRoundMatches ++ AccMatches, SeriesFormat)
    end.

%% Calculate total rounds in losers bracket
calculate_losers_bracket_rounds(N, WB_Rounds) ->
    _Byes = trunc(math:pow(2, WB_Rounds)) - N,
    max(1, 2 * WB_Rounds - 2).

%% Create all losers bracket matches
create_losers_bracket_matches(Teams, Byes, SeriesFormat, WB_Rounds, LB_TotalRounds, StartMatchId) ->
    %% First LB round: losers from WB Round 1
    %% Build round by round
    build_losers_bracket_rounds(Teams, Byes, SeriesFormat, WB_Rounds, LB_TotalRounds, 1, StartMatchId, [], []).

build_losers_bracket_rounds(_Teams, _Byes, _SeriesFormat, _WB_Rounds, LB_TotalRounds, CurrentRound, _NextMatchId, _PrevWBMatches, AccMatches) when CurrentRound > LB_TotalRounds ->
    lists:reverse(AccMatches);

build_losers_bracket_rounds(Teams, Byes, SeriesFormat, WB_Rounds, LB_TotalRounds, CurrentRound, NextMatchId, _PrevWBMatches, AccMatches) ->
    %% Determine which WB round losers drop into this LB round
    %% WB Round r drops into LB Round (2*r - 1) for r >= 2
    %% LB Round 1 gets losers from WB Round 1
    %% LB Round 2 gets losers from WB Round 2 + winners from LB Round 1
    %% etc.
    WBRoundForThisLB = case CurrentRound of
        1 -> 1;
        R when R rem 2 == 0 -> (R div 2) + 1;
        _ -> 0
    end,

    %% Get WB matches for the round that feeds this LB round
    WBMatchesForRound = case WBRoundForThisLB of
        0 -> [];
        WBRound -> get_wb_matches_for_round(Teams, Byes, SeriesFormat, WBRound, WB_Rounds)
    end,

    %% Number of matches in this LB round
    NumLBMatches = calculate_lb_round_matches(CurrentRound, WB_Rounds, length(Teams), Byes),

    %% Create matches for this round
    CurrMatches = lists:map(
        fun(I) ->
            MatchId = NextMatchId + I - 1,
            #match{
                id = MatchId,
                bracket_id = undefined,
                round = CurrentRound,
                position = I,
                format = SeriesFormat,
                team1_id = undefined,
                team2_id = undefined,
                state = scheduled,
                result = undefined,
                scheduled_at = undefined,
                started_at = undefined,
                finished_at = undefined,
                table_id = undefined,
                referee_id = undefined,
                metadata = #{lb_round_type => case WBRoundForThisLB > 0 of true -> feed_from_wb; false -> lb_only end,
                           feed_wb_round => WBRoundForThisLB}
            }
        end,
        lists:seq(1, NumLBMatches)
    ),

    build_losers_bracket_rounds(Teams, Byes, SeriesFormat, WB_Rounds, LB_TotalRounds, CurrentRound + 1,
                                NextMatchId + NumLBMatches, WBMatchesForRound, CurrMatches ++ AccMatches).

get_wb_matches_for_round(_Teams, _Byes, _SeriesFormat, _R, _WB_Rounds) ->
    %% This is a simplified version - in reality we'd look at the actual WB bracket
    %% For now, return empty and let propagation handle it
    [].

calculate_lb_round_matches(1, _WB_Rounds, N, Byes) ->
    %% Pair the losers from the first winners-bracket round.
    NumWBR1Actual = N - Byes,
    max(1, NumWBR1Actual div 4);
calculate_lb_round_matches(R, WB_Rounds, _N, _Byes) when R rem 2 == 1 ->
    %% Odd rounds after round one pair advancing losers-bracket teams.
    max(1, round_down(math:pow(2, WB_Rounds - ((R + 1) div 2) - 1)));
calculate_lb_round_matches(R, _WB_Rounds, _N, _Byes) ->
    %% Even LB rounds: same as previous round (winners from prev LB round)
    calculate_lb_round_matches(R - 1, _WB_Rounds, _N, _Byes).

round_down(X) when is_float(X) -> trunc(X);
round_down(X) -> X.

chunk_list(List, Size) ->
    chunk_list(List, Size, [], 0).

chunk_list([], _Size, Acc, _Idx) -> lists:reverse(Acc);
chunk_list(List, Size, Acc, Idx) ->
    {Chunk, Rest} = lists:split(Size, List),
    chunk_list(Rest, Size, [{Chunk, Idx} | Acc], Idx + 1).

%% Helper functions

create_first_round_matches(Teams, Byes, SeriesFormat, Round, StartMatchId) ->
    %% Pair teams: 1 vs N, 2 vs N-1, etc. with byes for top seeds
    Paired = pair_teams_with_byes(Teams, Byes),
    lists:map(
        fun({{Team1, Team2}, Idx}) ->
            MatchId = StartMatchId + Idx - 1,
            #match{
                id = MatchId,
                bracket_id = undefined,  %% Will be set later
                round = Round,
                position = Idx,
                format = SeriesFormat,
                team1_id = case Team1 of undefined -> undefined; _ -> Team1#team.id end,
                team2_id = case Team2 of undefined -> undefined; _ -> Team2#team.id end,
                state = case {Team1, Team2} of
                            {undefined, _} -> walkover;
                            {_, undefined} -> walkover;
                            _ -> scheduled
                        end,
                result = undefined,
                scheduled_at = undefined,
                started_at = undefined,
                finished_at = undefined,
                table_id = undefined,
                referee_id = undefined,
                metadata = #{}
            }
        end,
        lists:zip(Paired, lists:seq(1, length(Paired)))
    ).

pair_teams_with_byes(Teams, Byes) ->
    %% Top 'Byes' teams get byes (paired with undefined)
    ByesList = lists:sublist(Teams, Byes),
    RemainingTeams = lists:nthtail(Byes, Teams),
    PairedRemaining = pair_teams(RemainingTeams),
    ByesPairs = lists:map(fun(T) -> {T, undefined} end, ByesList),
    ByesPairs ++ PairedRemaining.

pair_teams(Teams) ->
    N = length(Teams),
    lists:map(
        fun(I) ->
            {lists:nth(I, Teams), lists:nth(N - I + 1, Teams)}
        end,
        lists:seq(1, N div 2)
    ).

create_round_robin_matches(Teams, SeriesFormat, Round, StartMatchId) ->
    %% Generate all pairings for round robin
    Pairs = round_robin_pairs(Teams),
    lists:map(
        fun({{T1, T2}, Idx}) ->
            MatchId = StartMatchId + Idx - 1,
            #match{
                id = MatchId,
                bracket_id = undefined,
                round = Round,
                position = Idx,
                format = SeriesFormat,
                team1_id = T1#team.id,
                team2_id = T2#team.id,
                state = scheduled,
                result = undefined,
                scheduled_at = undefined,
                started_at = undefined,
                finished_at = undefined,
                table_id = undefined,
                referee_id = undefined,
                metadata = #{}
            }
        end,
        lists:zip(Pairs, lists:seq(1, length(Pairs)))
    ).

round_robin_pairs(Teams) ->
    [{lists:nth(I, Teams), lists:nth(J, Teams)} ||
     I <- lists:seq(1, length(Teams) - 1),
     J <- lists:seq(I + 1, length(Teams))].

assign_match_ids(Bracket, NextId, AccMap) ->
    {Matches, FinalNextId, FinalAccMap} = maps:fold(
        fun(MatchId, Match, {MatchesAcc, NextIdAcc, AccMapAcc}) ->
            NewMatch = Match#match{
                bracket_id = Bracket#bracket.id,
                tournament_id = Bracket#bracket.tournament_id
            },
            NewNextId = max(NextIdAcc, MatchId + 1),
            {
                maps:put(MatchId, NewMatch, MatchesAcc),
                NewNextId,
                maps:put(MatchId, Bracket#bracket.id, AccMapAcc)
            }
        end,
        {#{}, NextId, AccMap},
        Bracket#bracket.matches
    ),
    {Bracket#bracket{matches = Matches}, FinalNextId, FinalAccMap}.

propagate_result(Bracket, FinishedMatchId, Result) ->
    WinnerId = Result#match_result.winner_team_id,
    LoserId = Result#match_result.loser_team_id,
    FinishedMatch = maps:get(FinishedMatchId, Bracket#bracket.matches),
    CurrentRound = FinishedMatch#match.round,
    Position = FinishedMatch#match.position,

    case Bracket#bracket.format of
        single_elim ->
            propagate_single_elim(Bracket, WinnerId, LoserId, CurrentRound, Position);
        double_elim ->
            propagate_double_elim(Bracket, WinnerId, LoserId, CurrentRound, Position,
                                  maps:get(bracket_type, Bracket#bracket.metadata, undefined));
        _ ->
            Bracket
    end.

propagate_single_elim(Bracket, WinnerId, _LoserId, Round, Position) ->
    NextRound = Round + 1,
    NextPosition = (Position + 1) div 2,
    %% Find match in next round at this position
    NextMatch = lists:search(
        fun(M) -> M#match.round =:= NextRound andalso M#match.position =:= NextPosition end,
        maps:values(Bracket#bracket.matches)
    ),
    case NextMatch of
        {value, Match} ->
            %% Determine if winner goes to team1 or team2 slot
            NewMatch = case Match#match.team1_id of
                undefined -> Match#match{team1_id = WinnerId};
                _ -> Match#match{team2_id = WinnerId}
            end,
            %% Check if both teams are now set -> schedule match
            FinalMatch = if
                NewMatch#match.team1_id =/= undefined andalso NewMatch#match.team2_id =/= undefined ->
                    NewMatch#match{state = scheduled};
                true -> NewMatch
            end,
            Bracket#bracket{matches = maps:put(FinalMatch#match.id, FinalMatch, Bracket#bracket.matches)};
        false ->
            Bracket
    end.

propagate_double_elim(Bracket, WinnerId, LoserId, Round, Position, winners) ->
    %% Winner advances in winners bracket
    B1 = propagate_single_elim(Bracket, WinnerId, LoserId, Round, Position),
    %% Loser drops to losers bracket
    LosersBracketId = find_losers_bracket(B1),
    case LosersBracketId of
        undefined -> B1;
        _LBid ->
            %% This would need access to the losers bracket - simplified for now
            B1
    end;
propagate_double_elim(Bracket, WinnerId, LoserId, Round, Position, losers) ->
    %% In losers bracket, loser is eliminated, winner advances
    propagate_single_elim(Bracket, WinnerId, LoserId, Round, Position).

find_losers_bracket(Bracket) ->
    case maps:get(bracket_type, Bracket#bracket.metadata, undefined) of
        winners -> undefined;  %% Would need tournament-level lookup
        _ -> undefined
    end.

%%% Double Elimination Full Tournament Propagation

%% Propagate result across all brackets for double elimination
%% Returns {UpdatedBrackets, GrandFinalMatch | undefined}
propagate_double_elim_full(AllBrackets, FinishedMatchId, Result, State) ->
    %% Find winners and losers brackets
    {ok, {WinnersBracketId, WinnersBracket}} = find_bracket_by_type(AllBrackets, winners),
    {ok, {LosersBracketId, LosersBracket}} = find_bracket_by_type(AllBrackets, losers),

    %% Determine which bracket the finished match is in
    FinishedBracketType = case maps:find(FinishedMatchId, WinnersBracket#bracket.matches) of
        {ok, _} -> winners;
        error -> losers
    end,

    WinnerId = Result#match_result.winner_team_id,
    LoserId = Result#match_result.loser_team_id,
    FinishedMatch = maps:get(FinishedMatchId,
        case FinishedBracketType of
            winners -> WinnersBracket#bracket.matches;
            losers -> LosersBracket#bracket.matches
        end),
    CurrentRound = FinishedMatch#match.round,
    Position = FinishedMatch#match.position,

    case FinishedBracketType of
        winners ->
            %% 1. Winner advances in winners bracket
            NewWinnersBracket = propagate_winners_bracket(WinnersBracket, WinnerId, LoserId, CurrentRound, Position),
            %% 2. Loser drops to losers bracket
            NewLosersBracket = case LoserId of
                undefined -> LosersBracket;
                _ -> place_loser_in_losers_bracket(LosersBracket, LoserId, Position, CurrentRound,
                      maps:get(wb_rounds, WinnersBracket#bracket.metadata, 0), State)
            end,
            %% 3. Check for grand final
            GrandFinal = check_grand_final(NewWinnersBracket, NewLosersBracket, State),
            {maps:put(WinnersBracketId, NewWinnersBracket,
                     maps:put(LosersBracketId, NewLosersBracket, AllBrackets)), GrandFinal};
        losers ->
            %% In losers bracket, loser is eliminated, winner advances
            NewLosersBracket = propagate_losers_bracket(LosersBracket, WinnerId, LoserId, CurrentRound, Position,
                                                        maps:get(wb_rounds, WinnersBracket#bracket.metadata, 0)),
            %% Check for grand final
            GrandFinal = check_grand_final(WinnersBracket, NewLosersBracket, State),
            {maps:put(LosersBracketId, NewLosersBracket, AllBrackets), GrandFinal}
    end.

find_bracket_by_type(Brackets, Type) ->
    lists:foldl(
        fun({_Id, B}, Acc) ->
            case Acc of
                {ok, _} -> Acc;
                not_found ->
                    case maps:get(bracket_type, B#bracket.metadata, undefined) of
                        Type -> {ok, {B#bracket.id, B}};
                        _ -> not_found
                    end
            end
        end,
        not_found,
        maps:to_list(Brackets)
    ).

%% Propagate winner in winners bracket (standard single elim within WB)
propagate_winners_bracket(Bracket, WinnerId, _LoserId, Round, Position) ->
    NextRound = Round + 1,
    NextPosition = (Position + 1) div 2,
    NextMatch = lists:search(
        fun(M) -> M#match.round =:= NextRound andalso M#match.position =:= NextPosition end,
        maps:values(Bracket#bracket.matches)
    ),
    case NextMatch of
        {value, Match} ->
            NewMatch = case Match#match.team1_id of
                undefined -> Match#match{team1_id = WinnerId};
                _ -> Match#match{team2_id = WinnerId}
            end,
            FinalMatch = if
                NewMatch#match.team1_id =/= undefined andalso NewMatch#match.team2_id =/= undefined ->
                    NewMatch#match{state = scheduled};
                true -> NewMatch
            end,
            Bracket#bracket{matches = maps:put(FinalMatch#match.id, FinalMatch, Bracket#bracket.matches)};
        false ->
            %% No next round match - this was the WB final
            Bracket
    end.

%% Place loser from WB into appropriate LB round
place_loser_in_losers_bracket(LBracket, LoserId, WB_Position, WB_Round, _WB_TotalRounds, _State) ->
    %% Determine which LB round this loser goes to
    %% WB Round 1 losers -> LB Round 1
    %% WB Round R (R>=2) losers -> LB Round (2*R - 2)
    LBRound = if
        WB_Round == 1 -> 1;
        WB_Round >= 2 -> 2 * WB_Round - 2
    end,

    %% Route to the slot paired with the corresponding WB match. In the first
    %% LB round, two adjacent WB losers meet; later they join the LB winner.
    {LBPosition, Slot} = case WB_Round of
        1 -> {(WB_Position + 1) div 2, case WB_Position rem 2 of 1 -> team1; _ -> team2 end};
        _ -> {WB_Position, team2}
    end,
    case lists:search(fun(M) -> M#match.round =:= LBRound andalso
                                  M#match.position =:= LBPosition end,
                      maps:values(LBracket#bracket.matches)) of
        {value, Match} ->
            NewMatch = case Slot of
                team1 when Match#match.team1_id =:= undefined -> Match#match{team1_id = LoserId};
                team2 when Match#match.team2_id =:= undefined -> Match#match{team2_id = LoserId};
                _ -> Match
            end,
            %% If both teams filled, schedule the match
            FinalMatch = if
                NewMatch#match.team1_id =/= undefined andalso NewMatch#match.team2_id =/= undefined ->
                    NewMatch#match{state = scheduled};
                true -> NewMatch
            end,
            LBracket#bracket{matches = maps:put(FinalMatch#match.id, FinalMatch, LBracket#bracket.matches)};
        false ->
            %% No space - this shouldn't happen if bracket generated correctly
            LBracket
    end.

%% Propagate in losers bracket
propagate_losers_bracket(Bracket, WinnerId, _LoserId, Round, Position, _WB_TotalRounds) ->
    %% Losers bracket structure:
    %% Round 1: WB R1 losers only
    %% Round 2: LB R1 winners
    %% Round 3: WB R2 losers + LB R2 winners
    %% Round 4: LB R3 winners
    %% Round 5: WB R3 losers + LB R4 winners
    %% ...
    %% Last LB round: WB final loser + LB previous winner

    NextRound = Round + 1,

    %% Determine if next round receives WB losers
    ReceivesWBLosers = NextRound rem 2 =:= 0,
    {NextPosition, Slot} = case ReceivesWBLosers of
        true -> {Position, team1};
        false -> {(Position + 1) div 2, case Position rem 2 of 1 -> team1; _ -> team2 end}
    end,
    NextMatch = lists:search(
        fun(M) -> M#match.round =:= NextRound andalso M#match.position =:= NextPosition end,
        maps:values(Bracket#bracket.matches)
    ),

    case NextMatch of
        {value, Match} ->
            %% If this LB round receives WB losers, only fill one slot (other gets WB loser)
            %% Otherwise fill normally
            NewMatch = case Slot of
                team1 when Match#match.team1_id =:= undefined -> Match#match{team1_id = WinnerId};
                team2 when Match#match.team2_id =:= undefined -> Match#match{team2_id = WinnerId};
                _ -> Match
            end,
            FinalMatch = if
                NewMatch#match.team1_id =/= undefined andalso NewMatch#match.team2_id =/= undefined ->
                    NewMatch#match{state = scheduled};
                true -> NewMatch
            end,
            Bracket#bracket{matches = maps:put(FinalMatch#match.id, FinalMatch, Bracket#bracket.matches)};
        false ->
            %% No next round - this was LB final
            Bracket
    end.

%% Check if we have both WB winner and LB winner for grand final
check_grand_final(WinnersBracket, LosersBracket, _State) ->
    %% Find WB final match (last round of WB)
    WBTotalRounds = WinnersBracket#bracket.total_rounds,
    WBFinalMatches = lists:filter(
        fun(M) -> M#match.round =:= WBTotalRounds end,
        maps:values(WinnersBracket#bracket.matches)
    ),

    %% Find LB final match (last round of LB)
    LBTotalRounds = LosersBracket#bracket.total_rounds,
    LBFinalMatches = lists:filter(
        fun(M) -> M#match.round =:= LBTotalRounds end,
        maps:values(LosersBracket#bracket.matches)
    ),

    %% Check if both have finished matches with winners
    WBWinner = case lists:search(fun(M) -> M#match.state =:= finished andalso M#match.result =/= undefined end, WBFinalMatches) of
        {value, WBM} -> (WBM#match.result)#match_result.winner_team_id;
        false -> undefined
    end,

    LBWinner = case lists:search(fun(M) -> M#match.state =:= finished andalso M#match.result =/= undefined end, LBFinalMatches) of
        {value, LBM} -> (LBM#match.result)#match_result.winner_team_id;
        false -> undefined
    end,

    if
        WBWinner =/= undefined andalso LBWinner =/= undefined ->
            %% Both winners determined - grand final should be created/scheduled
            %% Check if grand final match already exists (round = WBTotalRounds + 1, or special)
            {grand_final, WBWinner, LBWinner};
        true ->
            not_ready
    end.

maybe_create_grand_final(State) ->
    Brackets = maps:get(brackets, State),
    case {find_bracket_by_type(Brackets, winners), find_bracket_by_type(Brackets, losers)} of
        {{ok, {WinnersId, Winners}}, {ok, {_LosersId, Losers}}} ->
            HasFinal = lists:any(
                fun(M) -> maps:get(match_stage, M#match.metadata, undefined) =:= grand_final orelse
                          maps:get(match_stage, M#match.metadata, undefined) =:= grand_final_reset
                end,
                maps:values(Winners#bracket.matches)
            ),
            case {HasFinal, final_winner(Winners), final_winner(Losers)} of
                {false, {ok, WinnersTeam}, {ok, LosersTeam}} ->
                    FinalSource = final_match(Winners),
                    MatchId = maps:get(next_match_id, State),
                    GrandFinal = #match{
                        id = MatchId,
                        tournament_id = Winners#bracket.tournament_id,
                        bracket_id = WinnersId,
                        round = Winners#bracket.total_rounds + 1,
                        position = 1,
                        format = FinalSource#match.format,
                        team1_id = WinnersTeam,
                        team2_id = LosersTeam,
                        state = scheduled,
                        result = undefined,
                        scheduled_at = undefined,
                        started_at = undefined,
                        finished_at = undefined,
                        table_id = undefined,
                        referee_id = undefined,
                        metadata = #{match_stage => grand_final}
                    },
                    UpdatedWinners = Winners#bracket{matches = maps:put(
                        MatchId, GrandFinal, Winners#bracket.matches)},
                    State#{
                        brackets => maps:put(WinnersId, UpdatedWinners, Brackets),
                        match_to_bracket => maps:put(MatchId, WinnersId,
                            maps:get(match_to_bracket, State)),
                        next_match_id => MatchId + 1
                    };
                _ -> State
            end;
        _ -> State
    end.

maybe_create_grand_final_reset(State, #match{} = GrandFinal, #match_result{} = Result) ->
    Brackets = maps:get(brackets, State),
    WinnersId = GrandFinal#match.bracket_id,
    Winners = maps:get(WinnersId, Brackets),
    case Result#match_result.winner_team_id =:= GrandFinal#match.team2_id of
        true ->
            MatchId = maps:get(next_match_id, State),
            Reset = GrandFinal#match{
                id = MatchId,
                round = GrandFinal#match.round + 1,
                state = scheduled,
                result = undefined,
                started_at = undefined,
                finished_at = undefined,
                metadata = #{match_stage => grand_final_reset}
            },
            UpdatedWinners = Winners#bracket{matches = maps:put(
                MatchId, Reset, Winners#bracket.matches)},
            State#{
                brackets => maps:put(WinnersId, UpdatedWinners, Brackets),
                match_to_bracket => maps:put(MatchId, WinnersId,
                    maps:get(match_to_bracket, State)),
                next_match_id => MatchId + 1
            };
        false -> complete_tournament(GrandFinal#match.tournament_id, State)
    end;
maybe_create_grand_final_reset(State, _Match, _Result) -> State.

maybe_complete_single_elimination(
        #bracket{format = single_elim, tournament_id = TournamentId} = Bracket, State)
  when is_integer(TournamentId) ->
    case {final_winner(Bracket), has_disputed_matches(Bracket)} of
        {{ok, _Winner}, false} -> complete_tournament(TournamentId, State);
        _ -> State
    end;
maybe_complete_single_elimination(_Bracket, State) ->
    State.

has_disputed_matches(Bracket) ->
    lists:any(fun(M) -> M#match.state =:= disputed end,
              maps:values(Bracket#bracket.matches)).

reopen_tournament_if_completed(TournamentId, State) ->
    case catch p72_tournament_process:get_state(TournamentId) of
        completed ->
            _ = catch p72_tournament_process:reopen_tournament(TournamentId),
            _ = catch p72_tournament_registry:update_tournament(
                TournamentId,
                fun(Tournament) ->
                    Tournament#tournament{state = in_progress, finished_at = undefined}
                end),
            State;
        _ ->
            State
    end.

complete_tournament(TournamentId, State) ->
    _ = catch p72_tournament_process:finish_tournament(TournamentId),
    _ = catch p72_tournament_registry:update_tournament(TournamentId, fun(Tournament) ->
        Tournament#tournament{state = completed, finished_at = erlang:system_time(second)}
    end),
    State.

final_winner(Bracket) ->
    case final_match(Bracket) of
        #match{state = finished, result = #match_result{winner_team_id = Winner}} -> {ok, Winner};
        _ -> not_ready
    end.

final_match(Bracket) ->
    FinalRound = Bracket#bracket.total_rounds,
    case lists:sort(fun(A, B) -> A#match.position =< B#match.position end,
         [M || M <- maps:values(Bracket#bracket.matches), M#match.round =:= FinalRound]) of
        [Match | _] -> Match;
        [] -> undefined
    end.

%%% Full Double Elimination Recalculation

%% Recalculate entire double elimination tournament from all finished match results
recalculate_double_elim_full(AllBrackets) ->
    {ok, {WinnersBracketId, WinnersBracket}} = find_bracket_by_type(AllBrackets, winners),
    {ok, {LosersBracketId, LosersBracket}} = find_bracket_by_type(AllBrackets, losers),
    OldResults = lists:flatmap(
        fun({BracketId, Bracket}) ->
            [{BracketId, Match} || Match <- maps:values(Bracket#bracket.matches),
                Match#match.result =/= undefined,
                (Match#match.state =:= finished orelse Match#match.state =:= disputed)]
        end,
        [{WinnersBracketId, WinnersBracket}, {LosersBracketId, LosersBracket}]
    ),
    BaseWinners = reset_double_bracket(WinnersBracket, true),
    BaseLosers = reset_double_bracket(LosersBracket, false),
    BaseBrackets = maps:merge(AllBrackets, #{
        WinnersBracketId => BaseWinners,
        LosersBracketId => BaseLosers
    }),
    replay_double_elim_results(BaseBrackets, OldResults, 0).

reset_double_bracket(Bracket, KeepRoundOneTeams) ->
    Matches = maps:map(
        fun(_MatchId, Match) ->
            KeepTeams = KeepRoundOneTeams andalso Match#match.round =:= 1,
            Team1 = case KeepTeams of true -> Match#match.team1_id; false -> undefined end,
            Team2 = case KeepTeams of true -> Match#match.team2_id; false -> undefined end,
            Match#match{
                team1_id = Team1,
                team2_id = Team2,
                state = case {Team1, Team2} of
                    {undefined, _} when KeepTeams -> walkover;
                    {_, undefined} when KeepTeams -> walkover;
                    _ -> scheduled
                end,
                result = undefined,
                finished_at = undefined
            }
        end,
        Bracket#bracket.matches
    ),
    Bracket#bracket{matches = Matches, current_round = 1}.

replay_double_elim_results(Brackets, [], _Pass) -> Brackets;
replay_double_elim_results(Brackets, Pending, Pass) when Pass < 1000 ->
    {NextBrackets, Remaining, Applied} = lists:foldl(
        fun({BracketId, OldMatch} = Item, {AccBrackets, AccPending, Changed}) ->
            Bracket = maps:get(BracketId, AccBrackets),
            Current = maps:get(OldMatch#match.id, Bracket#bracket.matches),
            case replayable_result(Current, OldMatch) of
                {ok, Result} ->
                    Finished = Current#match{state = finished, result = Result,
                        finished_at = OldMatch#match.finished_at},
                    UpdatedBracket = Bracket#bracket{matches = maps:put(
                        Current#match.id, Finished, Bracket#bracket.matches)},
                    WithMatch = maps:put(BracketId, UpdatedBracket, AccBrackets),
                    {Propagated, _} = propagate_double_elim_full(
                        WithMatch, Current#match.id, Result, #{}),
                    {Propagated, AccPending, true};
                not_ready -> {AccBrackets, [Item | AccPending], Changed}
            end
        end,
        {Brackets, [], false},
        Pending
    ),
    case {Applied, Remaining} of
        {false, _} -> NextBrackets;
        {true, _} -> replay_double_elim_results(NextBrackets, lists:reverse(Remaining), Pass + 1)
    end;
replay_double_elim_results(Brackets, _Pending, _Pass) -> Brackets.

replayable_result(Current, Old) ->
    SameTeams = Current#match.team1_id =:= Old#match.team1_id andalso
                Current#match.team2_id =:= Old#match.team2_id,
    case {SameTeams, Old#match.state, Old#match.result} of
        {true, finished, #match_result{} = Result} ->
            {ok, Result};
        {true, disputed, _} -> not_ready;
        _ -> not_ready
    end.

recalculate_bracket_from_results(Bracket) ->
    case Bracket#bracket.format of
        single_elim -> recalculate_single_elimination(Bracket);
        _ -> recalculate_bracket_from_results_legacy(Bracket)
    end.

recalculate_single_elimination(Bracket) ->
    OldMatches = Bracket#bracket.matches,
    BaseMatches = maps:map(
        fun(_MatchId, Match) ->
            case Match#match.round of
                1 ->
                    InitialState = case {Match#match.team1_id, Match#match.team2_id} of
                        {undefined, _} -> walkover;
                        {_, undefined} -> walkover;
                        _ -> scheduled
                    end,
                    Match#match{state = InitialState, result = undefined,
                                finished_at = undefined};
                _ ->
                    Match#match{team1_id = undefined, team2_id = undefined,
                                state = scheduled, result = undefined,
                                finished_at = undefined}
            end
        end,
        OldMatches
    ),
    BaseBracket = Bracket#bracket{matches = BaseMatches, current_round = 1},
    OrderedMatches = lists:sort(
        fun(A, B) -> {A#match.round, A#match.position} =<
                     {B#match.round, B#match.position} end,
        maps:values(OldMatches)
    ),
    lists:foldl(
        fun(OldMatch, AccBracket) ->
            MatchId = OldMatch#match.id,
            CurrentMatch = maps:get(MatchId, AccBracket#bracket.matches),
            case {CurrentMatch#match.state, OldMatch#match.state,
                  OldMatch#match.result} of
                {walkover, _, _} -> handle_walkover(AccBracket, CurrentMatch);
                {scheduled, finished, #match_result{} = Result} ->
                    ParticipantsMatch =
                        CurrentMatch#match.team1_id =:= OldMatch#match.team1_id andalso
                        CurrentMatch#match.team2_id =:= OldMatch#match.team2_id,
                    WinnerPresent = Result#match_result.winner_team_id =:= CurrentMatch#match.team1_id orelse
                                    Result#match_result.winner_team_id =:= CurrentMatch#match.team2_id,
                    LoserPresent = Result#match_result.loser_team_id =:= CurrentMatch#match.team1_id orelse
                                   Result#match_result.loser_team_id =:= CurrentMatch#match.team2_id,
                    case ParticipantsMatch andalso WinnerPresent andalso LoserPresent of
                        true ->
                            Finished = CurrentMatch#match{state = finished, result = Result,
                                finished_at = OldMatch#match.finished_at},
                            B1 = AccBracket#bracket{matches = maps:put(
                                MatchId, Finished, AccBracket#bracket.matches)},
                            propagate_result(B1, MatchId, Result);
                        false -> AccBracket
                    end;
                _ -> AccBracket
            end
        end,
        BaseBracket,
        OrderedMatches
    ).

recalculate_bracket_from_results_legacy(Bracket) ->
    %% Walk through matches in round order, propagate finished results
    MatchesByRound = maps:fold(
        fun(_, M, Acc) ->
            Round = M#match.round,
            maps:update_with(Round, fun(L) -> [M | L] end, [M], Acc)
        end,
        #{},
        Bracket#bracket.matches
    ),
    lists:foldl(
        fun(Round, B) ->
            lists:foldl(
                fun(M, B1) ->
                    case M#match.state of
                        finished when M#match.result =/= undefined ->
                            propagate_result(B1, M#match.id, M#match.result);
                        walkover ->
                            %% Handle walkover as automatic win
                            handle_walkover(B1, M);
                        _ -> B1
                    end
                end,
                B,
                maps:get(Round, MatchesByRound, [])
            )
        end,
        Bracket,
        lists:sort(maps:keys(MatchesByRound))
    ).

handle_walkover(Bracket, Match) ->
    WinnerId = case {Match#match.team1_id, Match#match.team2_id} of
        {undefined, T2} -> T2;
        {T1, undefined} -> T1;
        _ -> Match#match.team1_id  %% default
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
    UpdatedMatch = Match#match{state = finished, result = Result, finished_at = erlang:system_time(second)},
    propagate_result(Bracket#bracket{matches = maps:put(Match#match.id, UpdatedMatch, Bracket#bracket.matches)},
                     Match#match.id, Result).
