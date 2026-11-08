%% -*- mode: erlang -*-
-module(p72_http_handler).
-behaviour(cowboy_handler).

-include("p72_torneo_de_esports.hrl").

-export([init/2, handle/2, terminate/3]).

%% Cowboy handler callbacks
init(Req, Opts) ->
    case handle(Req, Opts) of
        {ok, Req2} -> {ok, Req2, Opts};
        {ok, Req2, State2} -> {ok, Req2, State2}
    end.

handle(Req, _State) ->
    Method = cowboy_req:method(Req),
    PathTokens = [
        Token || Token <- binary:split(cowboy_req:path(Req), <<"/">>, [global]),
        Token =/= <<>>
    ],

    case {Method, PathTokens} of
        %% Tournament endpoints
        {<<"POST">>, [<<"api">>, <<"torneos">>]} ->
            handle_create_tournament(Req);
        {<<"GET">>, [<<"api">>, <<"torneos">>]} ->
            handle_list_tournaments(Req);
        {<<"GET">>, [<<"api">>, <<"torneos">>, TournamentId]} ->
            handle_get_tournament(Req, TournamentId);
        {<<"DELETE">>, [<<"api">>, <<"torneos">>, TournamentId]} ->
            handle_delete_tournament(Req, TournamentId);
        {<<"POST">>, [<<"api">>, <<"torneos">>, TournamentId, <<"start">>]} ->
            handle_start_tournament(Req, TournamentId);
        {<<"POST">>, [<<"api">>, <<"torneos">>, TournamentId, <<"finish">>]} ->
            handle_finish_tournament(Req, TournamentId);

        %% Team registration
        {<<"POST">>, [<<"api">>, <<"torneos">>, TournamentId, <<"equipos">>]} ->
            handle_register_team(Req, TournamentId);
        {<<"GET">>, [<<"api">>, <<"torneos">>, TournamentId, <<"equipos">>]} ->
            handle_list_teams(Req, TournamentId);

        %% Bracket endpoints
        {<<"GET">>, [<<"api">>, <<"torneos">>, TournamentId, <<"bracket">>]} ->
            handle_get_bracket(Req, TournamentId);
        {<<"GET">>, [<<"api">>, <<"torneos">>, TournamentId, <<"bracket">>, <<"progress">>]} ->
            handle_get_bracket_progress(Req, TournamentId);
        {<<"GET">>, [<<"api">>, <<"torneos">>, TournamentId, <<"bracket">>, BracketId]} ->
            handle_get_bracket_detail(Req, TournamentId, BracketId);

        %% Match endpoints
        {<<"GET">>, [<<"api">>, <<"torneos">>, TournamentId, <<"partidas">>]} ->
            handle_list_matches(Req, TournamentId);
        {<<"GET">>, [<<"api">>, <<"torneos">>, TournamentId, <<"partidas">>, MatchId]} ->
            handle_get_match(Req, TournamentId, MatchId);
        {<<"POST">>, [<<"api">>, <<"torneos">>, TournamentId, <<"partidas">>, MatchId, <<"marcador">>]} ->
            handle_update_score(Req, TournamentId, MatchId);
        {<<"POST">>, [<<"api">>, <<"torneos">>, TournamentId, <<"partidas">>, MatchId, <<"resultado">>]} ->
            handle_submit_result(Req, TournamentId, MatchId);
        {<<"POST">>, [<<"api">>, <<"torneos">>, TournamentId, <<"partidas">>, MatchId, <<"start">>]} ->
            handle_start_match(Req, TournamentId, MatchId);
        {<<"POST">>, [<<"api">>, <<"torneos">>, TournamentId, <<"partidas">>, MatchId, <<"dq">>]} ->
            handle_disqualify_team(Req, TournamentId, MatchId);
        {<<"POST">>, [<<"api">>, <<"torneos">>, TournamentId, <<"partidas">>, MatchId, <<"no_show">>]} ->
            handle_no_show(Req, TournamentId, MatchId);

        %% Dispute endpoints
        {<<"POST">>, [<<"api">>, <<"torneos">>, TournamentId, <<"partidas">>, MatchId, <<"disputa">>]} ->
            handle_submit_dispute(Req, TournamentId, MatchId);
        {<<"GET">>, [<<"api">>, <<"torneos">>, TournamentId, <<"disputas">>]} ->
            handle_list_disputes(Req, TournamentId);
        {<<"POST">>, [<<"api">>, <<"torneos">>, TournamentId, <<"disputas">>, DisputeId, <<"resolver">>]} ->
            handle_resolve_dispute(Req, TournamentId, DisputeId);
        {<<"POST">>, [<<"api">>, <<"torneos">>, TournamentId, <<"disputas">>, DisputeId, <<"resolver_recalc">>]} ->
            handle_resolve_and_recalculate(Req, TournamentId, DisputeId);

        %% Metrics endpoint
        {<<"GET">>, [<<"metrics">>]} ->
            handle_metrics(Req);

        %% Health check
        {<<"GET">>, [<<"health">>]} ->
            handle_health(Req);

        _ ->
            {ok, cowboy_req:reply(404, #{<<"content-type">> => <<"application/json">>}, <<"{\"error\":\"Not found\"}">>, Req)}
    end.

terminate(_Reason, _Req, _State) -> ok.

%%% Handler implementations

handle_create_tournament(Req) ->
    case parse_json_body(Req) of
        {ok, Body} ->
            case validate_create_tournament(Body) of
                {ok, Validated} ->
                    case p72_tournament_registry:create_tournament(Validated) of
                        {ok, Tournament} ->
                            gen_server:cast(p72_metrics_collector,
                                           {tournament_started, Tournament#tournament.id}),
                            json_reply(201, Req, tournament_to_json(Tournament));
                        {error, Reason} ->
                            json_reply(400, Req, #{error => Reason})
                    end;
                {error, Reason} ->
                    json_reply(400, Req, #{error => Reason})
            end;
        {error, Reason} ->
            json_reply(400, Req, #{error => Reason})
    end.

handle_list_tournaments(Req) ->
    case p72_tournament_registry:list_tournaments() of
        {ok, Tournaments} ->
            json_reply(200, Req,
                       #{tournaments => [tournament_to_json(T) || T <- Tournaments]});
        {error, Reason} ->
            json_reply(500, Req, #{error => Reason})
    end.

handle_get_tournament(Req, TournamentId) ->
    Id = binary_to_integer(TournamentId),
    case p72_tournament_registry:get_tournament(Id) of
        {ok, Tournament} -> json_reply(200, Req, tournament_to_json(Tournament));
        {error, not_found} -> json_reply(404, Req, #{error => <<"Tournament not found">>})
    end.

handle_delete_tournament(Req, TournamentId) ->
    Id = binary_to_integer(TournamentId),
    case p72_tournament_registry:delete_tournament(Id) of
        ok -> json_reply(204, Req, <<>>);
        {error, not_found} -> json_reply(404, Req, #{error => <<"Tournament not found">>})
    end.

handle_start_tournament(Req, TournamentId) ->
    Id = binary_to_integer(TournamentId),
    case p72_tournament_process:start_tournament(Id) of
        ok ->
            _ = p72_tournament_registry:update_tournament(Id, fun(Tournament) ->
                Tournament#tournament{state = in_progress, started_at = erlang:system_time(second)}
            end),
            json_reply(200, Req, #{status => <<"started">>});
        {error, Reason} -> json_reply(400, Req, #{error => Reason})
    end.

handle_finish_tournament(Req, TournamentId) ->
    Id = binary_to_integer(TournamentId),
    case p72_tournament_process:finish_tournament(Id) of
        ok ->
            _ = p72_tournament_registry:update_tournament(Id, fun(Tournament) ->
                Tournament#tournament{state = completed, finished_at = erlang:system_time(second)}
            end),
            gen_server:cast(p72_metrics_collector, {tournament_finished, Id}),
            json_reply(200, Req, #{status => <<"finished">>});
        {error, Reason} -> json_reply(400, Req, #{error => Reason})
    end.

handle_register_team(Req, TournamentId) ->
    Id = binary_to_integer(TournamentId),
    case parse_json_body(Req) of
        {ok, Body} ->
            TeamData = #{
                name => maps:get(<<"name">>, Body),
                players => maps:get(<<"players">>, Body, []),
                seed => maps:get(<<"seed">>, Body, 0)
            },
            case p72_tournament_process:register_team(Id, TeamData) of
                {ok, Team} -> json_reply(201, Req, team_to_json(Team));
                {error, Reason} -> json_reply(400, Req, #{error => Reason})
            end;
        {error, Reason} ->
            json_reply(400, Req, #{error => Reason})
    end.

handle_list_teams(Req, TournamentId) ->
    Id = binary_to_integer(TournamentId),
    try p72_tournament_process:get_teams(Id) of
        Teams -> json_reply(200, Req, #{teams => [team_to_json(T) || T <- Teams]})
    catch
        exit:_ -> json_reply(404, Req, #{error => <<"Tournament not found">>})
    end.

handle_get_bracket(Req, TournamentId) ->
    Id = binary_to_integer(TournamentId),
    case p72_bracket_server:get_bracket(Id) of
        {ok, Brackets} -> json_reply(200, Req, #{brackets => [bracket_to_json(B) || B <- Brackets]});
        {error, Reason} -> json_reply(404, Req, #{error => Reason})
    end.

handle_get_bracket_detail(Req, TournamentId, BracketId) ->
    TId = binary_to_integer(TournamentId),
    BId = binary_to_integer(BracketId),
    case p72_bracket_server:get_bracket(TId) of
        {ok, Brackets} ->
            case lists:keyfind(BId, #bracket.id, Brackets) of
                false -> json_reply(404, Req, #{error => <<"Bracket not found">>});
                Bracket -> json_reply(200, Req, bracket_to_json(Bracket))
            end;
        {error, Reason} -> json_reply(404, Req, #{error => Reason})
    end.

handle_get_bracket_progress(Req, TournamentId) ->
    Id = binary_to_integer(TournamentId),
    case p72_bracket_server:get_bracket_progress(Id) of
        {ok, Progress} ->
            Items = [#{bracket_id => K, progress => V} || {K, V} <- maps:to_list(Progress)],
            json_reply(200, Req, #{progress => Items});
        {error, Reason} -> json_reply(404, Req, #{error => Reason})
    end.

handle_list_matches(Req, TournamentId) ->
    Id = binary_to_integer(TournamentId),
    case p72_bracket_server:get_upcoming_matches(Id) of
        {ok, Matches} -> json_reply(200, Req, #{matches => [match_to_json(M) || M <- Matches]});
        {error, Reason} -> json_reply(404, Req, #{error => Reason})
    end.

handle_get_match(Req, TournamentId, MatchId) ->
    TId = binary_to_integer(TournamentId),
    MId = binary_to_integer(MatchId),
    case p72_bracket_server:get_match(TId, MId) of
        {ok, Match} -> json_reply(200, Req, match_to_json(Match));
        {error, not_found} -> json_reply(404, Req, #{error => <<"Match not found">>})
    end.

handle_update_score(Req, TournamentId, MatchId) ->
    TId = binary_to_integer(TournamentId),
    MId = binary_to_integer(MatchId),
    case parse_json_body(Req) of
        {ok, Body} ->
            ScoreUpdate = #score_update{
                match_id = MId,
                tournament_id = TId,
                team_scores = numeric_map(maps:get(<<"team_scores">>, Body, #{})),
                current_map = maps:get(<<"current_map">>, Body, 1),
                maps_won = numeric_map(maps:get(<<"maps_won">>, Body, #{})),
                timestamp = erlang:system_time(second)
            },
            p72_live_score_server:update_score(TId, MId, ScoreUpdate),
            json_reply(202, Req, #{status => <<"score_broadcast">>});
        {error, Reason} -> json_reply(400, Req, #{error => Reason})
    end.

handle_submit_result(Req, TournamentId, MatchId) ->
    TId = binary_to_integer(TournamentId),
    MId = binary_to_integer(MatchId),
    case parse_json_body(Req) of
        {ok, Body} ->
            Result = #match_result{
                winner_team_id = to_integer(maps:get(<<"winner_team_id">>, Body)),
                loser_team_id = to_integer(maps:get(<<"loser_team_id">>, Body)),
                scores = parse_scores(maps:get(<<"scores">>, Body)),
                submitted_by = to_integer(maps:get(<<"team_id">>, Body)),
                submitted_at = erlang:system_time(second),
                disputed = false,
                dispute_reason = undefined
            },
            case p72_bracket_server:get_match(TId, MId) of
                {ok, Match} ->
                    case ensure_match_started(TId, MId, Match) of
                        ok ->
                            case p72_match_server:submit_result(MId, Result) of
                                {ok, _} -> json_reply(200, Req, #{status => <<"updated">>});
                                {disputed, DisputeResult} ->
                                    json_reply(202, Req, #{status => <<"disputed">>,
                                                          result => result_to_json(DisputeResult)});
                                {error, Reason} -> json_reply(409, Req, #{error => Reason})
                            end;
                        {error, Reason} -> json_reply(409, Req, #{error => Reason})
                    end;
                {error, not_found} -> json_reply(404, Req, #{error => <<"Match not found">>})
            end;
        {error, Reason} ->
            json_reply(400, Req, #{error => Reason})
    end.

handle_start_match(Req, TournamentId, MatchId) ->
    TId = binary_to_integer(TournamentId),
    MId = binary_to_integer(MatchId),
    case p72_bracket_server:get_match(TId, MId) of
        {ok, #match{team1_id = Team1, team2_id = Team2} = Match}
          when is_integer(Team1), is_integer(Team2) ->
            case ensure_match_process(TId, MId, Match) of
                ok ->
                    try p72_match_server:start_match(MId) of
                        ok -> json_reply(200, Req, #{status => <<"started">>});
                        {error, Reason} -> json_reply(400, Req, #{error => Reason})
                    catch
                        exit:Reason -> json_reply(404, Req, #{error => {match_process_unavailable, Reason}})
                    end;
                {error, Reason} -> json_reply(400, Req, #{error => Reason})
            end;
        {ok, _Match} -> json_reply(409, Req, #{error => <<"Match is waiting for both teams">>});
        {error, not_found} -> json_reply(404, Req, #{error => <<"Match not found">>})
    end.

ensure_match_process(TournamentId, MatchId, Match) ->
    case p72_match_sup:get_match_pid(MatchId) of
        {ok, _Pid} -> ok;
        {error, not_found} ->
            case p72_match_sup:start_match(TournamentId, MatchId, Match) of
                {ok, _Pid} -> ok;
                {error, {already_started, _Pid}} -> ok;
                {error, Reason} -> {error, Reason}
            end
    end.

ensure_match_started(TournamentId, MatchId, Match) ->
    case ensure_match_process(TournamentId, MatchId, Match) of
        ok ->
            case p72_match_server:get_state(MatchId) of
                scheduled -> p72_match_server:start_match(MatchId);
                in_play -> ok;
                finished -> ok;
                disputed -> ok;
                Other -> {error, {invalid_match_state, Other}}
            end;
        Error -> Error
    end.

handle_submit_dispute(Req, TournamentId, MatchId) ->
    TId = binary_to_integer(TournamentId),
    MId = binary_to_integer(MatchId),
    case parse_json_body(Req) of
        {ok, Body} ->
            Reporter = to_integer(maps:get(<<"team_id">>, Body)),
            ClaimedWinner = to_integer(maps:get(<<"claimed_winner">>, Body)),
            ReasonText = maps:get(<<"reason">>, Body, <<>>),
            DisputeData = #{
                reported_by => Reporter,
                claimed_winner => ClaimedWinner,
                claimed_scores => parse_scores(maps:get(<<"scores">>, Body, [])),
                reason => ReasonText
            },
            case p72_bracket_server:get_match(TId, MId) of
                {ok, #match{team1_id = Team1, team2_id = Team2} = Match} ->
                    Participant = Reporter =:= Team1 orelse Reporter =:= Team2,
                    WinnerIsParticipant = ClaimedWinner =:= Team1 orelse ClaimedWinner =:= Team2,
                    case Participant andalso WinnerIsParticipant of
                        false -> json_reply(400, Req, #{error => <<"Reporter and claimed winner must be participants">>});
                        true ->
                            case ensure_match_process(TId, MId, Match) of
                                ok ->
                                    case p72_match_server:mark_disputed(MId, ReasonText) of
                                        ok ->
                                            case p72_dispute_resolver:submit_dispute(TId, MId, DisputeData) of
                                                {ok, Dispute} -> json_reply(201, Req, dispute_to_json(Dispute));
                                                {error, Reason} -> json_reply(400, Req, #{error => Reason})
                                            end;
                                        {error, Reason} -> json_reply(409, Req, #{error => Reason})
                                    end;
                                {error, Reason} -> json_reply(409, Req, #{error => Reason})
                            end
                    end;
                {error, not_found} -> json_reply(404, Req, #{error => <<"Match not found">>})
            end;
        {error, Reason} ->
            json_reply(400, Req, #{error => Reason})
    end.

handle_list_disputes(Req, TournamentId) ->
    TId = binary_to_integer(TournamentId),
    case p72_dispute_resolver:get_open_disputes(TId) of
        {ok, Disputes} -> json_reply(200, Req, #{disputes => [dispute_to_json(D) || D <- Disputes]});
        {error, Reason} -> json_reply(404, Req, #{error => Reason})
    end.

handle_resolve_dispute(Req, TournamentId, DisputeId) ->
    TId = binary_to_integer(TournamentId),
    DId = binary_to_integer(DisputeId),
    case parse_json_body(Req) of
        {ok, Body} ->
            Resolution = maps:get(<<"resolution">>, Body, <<"Resolved by administrator">>),
            case official_result_from_body(Body) of
                {ok, OfficialResult} ->
                    case p72_dispute_resolver:resolve_and_recalculate(
                           TId, DId, Resolution, OfficialResult) of
                        {ok, Dispute, recalculated} ->
                            json_reply(200, Req, #{dispute => dispute_to_json(Dispute),
                                                   recalculated => true});
                        {ok, Dispute, {recalc_failed, Reason}} ->
                            json_reply(200, Req, #{dispute => dispute_to_json(Dispute),
                                                   recalculated => false, reason => Reason});
                        {error, Reason} -> json_reply(400, Req, #{error => Reason})
                    end;
                {error, Reason} -> json_reply(400, Req, #{error => Reason})
            end;
        {error, Reason} ->
            json_reply(400, Req, #{error => Reason})
    end.

handle_resolve_and_recalculate(Req, TournamentId, DisputeId) ->
    TId = binary_to_integer(TournamentId),
    DId = binary_to_integer(DisputeId),
    case parse_json_body(Req) of
        {ok, Body} ->
            Resolution = maps:get(<<"resolution">>, Body),
            case official_result_from_body(Body) of
                {ok, OfficialResult} ->
                    case p72_dispute_resolver:resolve_and_recalculate(
                           TId, DId, Resolution, OfficialResult) of
                        {ok, Dispute, recalculated} -> json_reply(200, Req, #{dispute => dispute_to_json(Dispute), recalculated => true});
                        {ok, Dispute, {recalc_failed, Reason}} -> json_reply(200, Req, #{dispute => dispute_to_json(Dispute), recalculated => false, reason => Reason});
                        {error, Reason} -> json_reply(400, Req, #{error => Reason})
                    end;
                {error, Reason} -> json_reply(400, Req, #{error => Reason})
            end;
        {error, Reason} ->
            json_reply(400, Req, #{error => Reason})
    end.

handle_disqualify_team(Req, TournamentId, MatchId) ->
    handle_disqualify_team(Req, TournamentId, MatchId, <<"Disqualified">>).

handle_no_show(Req, TournamentId, MatchId) ->
    handle_disqualify_team(Req, TournamentId, MatchId, <<"No-show">>).

handle_disqualify_team(Req, TournamentId, MatchId, DefaultReason) ->
    TId = binary_to_integer(TournamentId),
    MId = binary_to_integer(MatchId),
    case parse_json_body(Req) of
        {ok, Body} ->
            DisqualifiedTeamId = to_integer(maps:get(<<"team_id">>, Body)),
            Reason = maps:get(<<"reason">>, Body, DefaultReason),
            case p72_bracket_server:get_match(TId, MId) of
                {ok, Match} ->
                    case ensure_match_process(TId, MId, Match) of
                        ok ->
                            case p72_match_server:disqualify_team(MId, DisqualifiedTeamId, Reason) of
                                {ok, Result} -> json_reply(200, Req, #{status => <<"disqualified">>, result => result_to_json(Result)});
                                {error, ErrorReason} -> json_reply(409, Req, #{error => ErrorReason})
                            end;
                        {error, ErrorReason} -> json_reply(409, Req, #{error => ErrorReason})
                    end;
                {error, not_found} -> json_reply(404, Req, #{error => <<"Match not found">>})
            end;
        {error, Reason} ->
            json_reply(400, Req, #{error => Reason})
    end.

handle_metrics(Req) ->
    case p72_metrics_collector:get_metrics() of
        Metrics -> json_reply(200, Req, metrics_to_json(Metrics))
    end.

handle_health(Req) ->
    json_reply(200, Req, #{status => <<"ok">>, timestamp => erlang:system_time(second)}).

%%% Helper functions

parse_json_body(Req) ->
    case cowboy_req:read_body(Req) of
        {ok, Body, _Req2} ->
            try jiffy:decode(Body, [return_maps]) of
                Map when is_map(Map) -> {ok, Map};
                _ -> {error, <<"Invalid JSON object">>}
            catch
                error:_ -> {error, <<"Invalid JSON">>}
            end;
        {error, _} -> {error, <<"Failed to read body">>}
    end.

validate_create_tournament(Body) ->
    try
        Name = maps:get(<<"name">>, Body),
        Format = tournament_format(maps:get(<<"format">>, Body)),
        SeriesFormat = series_format(maps:get(<<"series_format">>, Body)),
        MaxTeams = maps:get(<<"max_teams">>, Body),
        true = is_binary(Name),
        true = is_integer(MaxTeams) andalso MaxTeams >= 2,
        Config = normalize_config(maps:get(<<"config">>, Body, #{})),
        {ok, #{name => Name, format => Format, series_format => SeriesFormat,
               max_teams => MaxTeams, config => Config}}
    catch
        error:{badkey, _} -> {error, <<"Missing required fields">>};
        error:{invalid_format, _} -> {error, <<"Invalid tournament format">>};
        error:{invalid_series_format, _} -> {error, <<"Invalid series format">>};
        error:{badmatch, false} -> {error, <<"Invalid tournament data">>}
    end.

tournament_format(<<"single_elim">>) -> single_elim;
tournament_format(<<"double_elim">>) -> double_elim;
tournament_format(<<"swiss">>) -> swiss;
tournament_format(<<"groups">>) -> groups;
tournament_format(Value) -> erlang:error({invalid_format, Value}).

series_format(<<"bo1">>) -> bo1;
series_format(<<"bo3">>) -> bo3;
series_format(<<"bo5">>) -> bo5;
series_format(Value) -> erlang:error({invalid_series_format, Value}).

normalize_config(Config) ->
    #{
        tables_count => maps:get(<<"tables_count">>, Config, 8),
        match_duration_estimate => maps:get(<<"match_duration_estimate">>, Config, 45),
        allow_disputes => maps:get(<<"allow_disputes">>, Config, true),
        dispute_timeout => maps:get(<<"dispute_timeout">>, Config, 300)
    }.

tournament_to_json(Tournament) ->
    #{
        id => Tournament#tournament.id,
        name => Tournament#tournament.name,
        format => atom_to_binary(Tournament#tournament.format, utf8),
        series_format => atom_to_binary(Tournament#tournament.series_format, utf8),
        max_teams => Tournament#tournament.max_teams,
        teams_count => tournament_team_count(Tournament),
        state => atom_to_binary(Tournament#tournament.state, utf8),
        created_at => Tournament#tournament.created_at
    }.

tournament_team_count(Tournament) ->
    try length(p72_tournament_process:get_teams(Tournament#tournament.id))
    catch exit:_ -> map_size(Tournament#tournament.teams)
    end.

team_to_json(Team) ->
    #{id => Team#team.id, name => Team#team.name, players => Team#team.players,
      seed => Team#team.seed}.

bracket_to_json(Bracket) ->
    #{id => Bracket#bracket.id, tournament_id => Bracket#bracket.tournament_id,
      name => Bracket#bracket.name, format => atom_to_binary(Bracket#bracket.format, utf8),
      current_round => Bracket#bracket.current_round, total_rounds => Bracket#bracket.total_rounds,
      teams => [team_to_json(T) || T <- Bracket#bracket.teams],
      matches => [match_to_json(M) || M <- maps:values(Bracket#bracket.matches)]}.

match_to_json(Match) ->
    #{id => Match#match.id, tournament_id => Match#match.tournament_id,
      bracket_id => Match#match.bracket_id, round => Match#match.round,
      position => Match#match.position, format => atom_to_binary(Match#match.format, utf8),
      team1_id => json_nullable(Match#match.team1_id),
      team2_id => json_nullable(Match#match.team2_id),
      state => atom_to_binary(Match#match.state, utf8),
      result => result_to_json(Match#match.result),
      scheduled_at => json_nullable(Match#match.scheduled_at),
      started_at => json_nullable(Match#match.started_at),
      finished_at => json_nullable(Match#match.finished_at)}.

result_to_json(undefined) -> null;
result_to_json(Result) ->
    #{winner_team_id => json_nullable(Result#match_result.winner_team_id),
      loser_team_id => json_nullable(Result#match_result.loser_team_id),
      scores => [#{team_id => TeamId, score => Score} || {TeamId, Score} <- Result#match_result.scores],
      submitted_by => json_nullable(Result#match_result.submitted_by),
      submitted_at => Result#match_result.submitted_at,
      disputed => Result#match_result.disputed,
      dispute_reason => json_nullable(Result#match_result.dispute_reason)}.

dispute_to_json(Dispute) ->
    #{id => Dispute#dispute.id, match_id => Dispute#dispute.match_id,
      tournament_id => Dispute#dispute.tournament_id,
      reported_by => Dispute#dispute.reported_by,
      claimed_winner => Dispute#dispute.claimed_winner,
      claimed_scores => [#{team_id => TeamId, score => Score} || {TeamId, Score} <- Dispute#dispute.claimed_scores],
      reason => Dispute#dispute.reason,
      reported_at => Dispute#dispute.reported_at,
      status => atom_to_binary(Dispute#dispute.status, utf8),
      resolution => json_nullable(Dispute#dispute.resolution),
      resolved_at => json_nullable(Dispute#dispute.resolved_at)}.

metrics_to_json(Metrics) ->
    #{timestamp => Metrics#metrics.timestamp,
      tournaments_total => Metrics#metrics.tournaments_total,
      tournaments_active => Metrics#metrics.tournaments_active,
      matches_total => Metrics#metrics.matches_total,
      matches_in_progress => Metrics#metrics.matches_in_progress,
      matches_finished => Metrics#metrics.matches_finished,
      matches_disputed => Metrics#metrics.matches_disputed,
      viewers_total => Metrics#metrics.viewers_total,
      viewers_per_match => [#{match_id => Id, viewers => Count} ||
                              {Id, Count} <- maps:to_list(Metrics#metrics.viewers_per_match)],
      bracket_progress => [#{tournament_id => Id, progress => Progress} ||
                             {Id, Progress} <- maps:to_list(Metrics#metrics.bracket_progress)]}.

json_nullable(undefined) -> null;
json_nullable(Value) -> Value.

parse_scores(Scores) ->
    case Scores of
        List when is_list(List) ->
            lists:map(
                fun([TeamId, Score]) -> {to_integer(TeamId), to_integer(Score)} end,
                List
            );
        _ -> []
    end.

official_result_from_body(Body) ->
    try
        {ok, #match_result{
            winner_team_id = to_integer(maps:get(<<"winner_team_id">>, Body)),
            loser_team_id = to_integer(maps:get(<<"loser_team_id">>, Body)),
            scores = parse_scores(maps:get(<<"scores">>, Body)),
            submitted_by = system,
            submitted_at = erlang:system_time(second),
            disputed = false,
            dispute_reason = undefined
        }}
    catch
        error:{badkey, _} -> {error, <<"Official winner, loser and scores are required">>};
        error:_ -> {error, <<"Invalid official result">>}
    end.

to_integer(Value) when is_integer(Value) -> Value;
to_integer(Value) when is_binary(Value) -> binary_to_integer(Value).

numeric_map(Map) when is_map(Map) ->
    maps:fold(fun(Key, Value, Acc) -> maps:put(to_integer(Key), to_integer(Value), Acc) end, #{}, Map);
numeric_map(_) -> #{}.

json_reply(Status, Req, Data) ->
    Body = case Data of
        <<>> -> <<>>;
        _ -> jiffy:encode(Data)
    end,
    {ok, cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>},
        Body, Req)}.
