%% -*- mode: erlang -*-
-module(p72_ws_handler).
-behaviour(cowboy_websocket).

-include("p72_torneo_de_esports.hrl").

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

%% Cowboy WebSocket callbacks
init(Req, _Opts) ->
    {cowboy_websocket, Req, #{tournament_id => get_tournament_id(Req)}}.

websocket_init(State) ->
    {ok, State#{subscribed => false}, hibernate}.

websocket_handle({text, Msg}, State) ->
    try jiffy:decode(Msg, [return_maps]) of
        #{<<"type">> := <<"subscribe">>, <<"match_id">> := MatchId} ->
            MId = match_id(MatchId),
            TId = maps:get(tournament_id, State),
            p72_live_score_server:subscribe(TId, self()),
            {ok, State#{subscribed => true, match_id => MId}, hibernate};
        #{<<"type">> := <<"subscribe_tournament">>} ->
            TId = maps:get(tournament_id, State),
            p72_live_score_server:subscribe(TId, self()),
            {ok, State#{subscribed => true, match_id => undefined}, hibernate};
        #{<<"type">> := <<"unsubscribe">>} ->
            TId = maps:get(tournament_id, State),
            p72_live_score_server:unsubscribe(TId, self()),
            {ok, State#{subscribed => false, match_id => undefined}, hibernate};
        #{<<"type">> := <<"ping">>} ->
            {reply, {text, jiffy:encode(#{<<"type">> => <<"pong">>, <<"timestamp">> => erlang:system_time(second)})}, State, hibernate};
        _ -> {ok, State, hibernate}
    catch
        error:_ -> {ok, State, hibernate}
    end;

websocket_handle(_Data, State) ->
    {ok, State, hibernate}.

websocket_info({score_update, ScoreUpdate}, State) ->
    %% Only send if subscribed to this match or tournament overview
    ShouldSend = case maps:get(match_id, State, undefined) of
        undefined -> true;  %% Tournament overview
        MatchId -> MatchId =:= ScoreUpdate#score_update.match_id
    end,
    if
        ShouldSend ->
            Msg = jiffy:encode(#{<<"type">> => <<"score_update">>, <<"data">> => score_update_to_map(ScoreUpdate)}),
            {reply, {text, Msg}, State, hibernate};
        true ->
            {ok, State, hibernate}
    end;

websocket_info({match_finished, MatchId, Result}, State) ->
    ShouldSend = case maps:get(match_id, State, undefined) of
        undefined -> true;
        MId -> MId =:= MatchId
    end,
    if
        ShouldSend ->
            Msg = jiffy:encode(#{<<"type">> => <<"match_finished">>, <<"match_id">> => MatchId, <<"result">> => result_to_map(Result)}),
            {reply, {text, Msg}, State, hibernate};
        true ->
            {ok, State, hibernate}
    end;

websocket_info({match_disputed, MatchId, Result}, State) ->
    ShouldSend = case maps:get(match_id, State, undefined) of
        undefined -> true;
        MId -> MId =:= MatchId
    end,
    if
        ShouldSend ->
            Msg = jiffy:encode(#{<<"type">> => <<"match_disputed">>,
                                 <<"match_id">> => MatchId,
                                 <<"result">> => result_to_map(Result)}),
            {reply, {text, Msg}, State, hibernate};
        true ->
            {ok, State, hibernate}
    end;

websocket_info({match_status, MatchId, Status, Reason}, State) ->
    ShouldSend = case maps:get(match_id, State, undefined) of
        undefined -> true;
        MId -> MId =:= MatchId
    end,
    if
        ShouldSend ->
            Msg = jiffy:encode(#{<<"type">> => <<"match_status">>,
                                 <<"match_id">> => MatchId,
                                 <<"status">> => atom_to_binary(Status, utf8),
                                 <<"reason">> => case Reason of undefined -> null; _ -> Reason end}),
            {reply, {text, Msg}, State, hibernate};
        true -> {ok, State, hibernate}
    end;

websocket_info({tournament_state, Summary}, State) ->
    Msg = jiffy:encode(#{<<"type">> => <<"tournament_state">>, <<"data">> => Summary}),
    {reply, {text, Msg}, State, hibernate};

websocket_info(_Info, State) ->
    {ok, State, hibernate}.

terminate(_Reason, _Req, State) ->
    case maps:get(subscribed, State, false) of
        true ->
            TId = maps:get(tournament_id, State),
            p72_live_score_server:unsubscribe(TId, self());
        false -> ok
    end,
    ok.

%%% Helper functions

get_tournament_id(Req) ->
    case cowboy_req:parse_qs(Req) of
        Qs ->
            case proplists:get_value(<<"tournament_id">>, Qs) of
                undefined -> 1;  %% Default
                Id -> binary_to_integer(Id)
            end
    end.

score_update_to_map(#score_update{
    match_id = MatchId,
    tournament_id = TournamentId,
    team_scores = TeamScores,
    current_map = CurrentMap,
    maps_won = MapsWon,
    timestamp = Timestamp
}) ->
    #{
        <<"match_id">> => MatchId,
        <<"tournament_id">> => TournamentId,
        <<"team_scores">> => maps:from_list([{integer_to_binary(K), V} || {K, V} <- maps:to_list(TeamScores)]),
        <<"current_map">> => CurrentMap,
        <<"maps_won">> => maps:from_list([{integer_to_binary(K), V} || {K, V} <- maps:to_list(MapsWon)]),
        <<"timestamp">> => Timestamp
    }.

match_id(Value) when is_integer(Value) -> Value;
match_id(Value) when is_binary(Value) -> binary_to_integer(Value).

result_to_map(#match_result{
    winner_team_id = Winner,
    loser_team_id = Loser,
    scores = Scores,
    submitted_by = SubmittedBy,
    submitted_at = SubmittedAt,
    disputed = Disputed,
    dispute_reason = DisputeReason
}) ->
    #{
        <<"winner_team_id">> => Winner,
        <<"loser_team_id">> => Loser,
        <<"scores">> => [#{<<"team_id">> => T, <<"score">> => S} || {T, S} <- Scores],
        <<"submitted_by">> => case SubmittedBy of system -> <<"system">>; _ -> SubmittedBy end,
        <<"submitted_at">> => SubmittedAt,
        <<"disputed">> => Disputed,
        <<"dispute_reason">> => case DisputeReason of undefined -> null; _ -> DisputeReason end
    }.
