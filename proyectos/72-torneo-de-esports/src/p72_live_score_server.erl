%% -*- mode: erlang -*-
-module(p72_live_score_server).
-behaviour(gen_server).

-include("p72_torneo_de_esports.hrl").

-export([start_link/1, subscribe/2, unsubscribe/2, update_score/3, get_match_score/2,
         get_tournament_viewers/1, broadcast/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% API
start_link(TournamentId) ->
    gen_server:start_link({global, {?MODULE, TournamentId}}, ?MODULE, TournamentId, []).

subscribe(TournamentId, ViewerPid) ->
    gen_server:call({global, {?MODULE, TournamentId}}, {subscribe, ViewerPid}).

unsubscribe(TournamentId, ViewerPid) ->
    %% Unsubscribe is cleanup: the tournament may already have stopped (or
    %% the server may be restarting) by the time a WebSocket terminates.
    %% Treat that case as an already-completed unsubscribe instead of letting
    %% the caller crash while cleaning up.
    try gen_server:call({global, {?MODULE, TournamentId}}, {unsubscribe, ViewerPid}) of
        Reply -> Reply
    catch
        exit:_ -> ok
    end.

update_score(TournamentId, MatchId, ScoreUpdate) ->
    gen_server:cast({global, {?MODULE, TournamentId}}, {update_score, MatchId, ScoreUpdate}).

get_match_score(TournamentId, MatchId) ->
    gen_server:call({global, {?MODULE, TournamentId}}, {get_match_score, MatchId}).

get_tournament_viewers(TournamentId) ->
    gen_server:call({global, {?MODULE, TournamentId}}, get_tournament_viewers).

broadcast(TournamentId, Message) ->
    gen_server:cast({global, {?MODULE, TournamentId}}, {broadcast, Message}).

%% Callbacks
init(TournamentId) ->
    logger:info("~s iniciado para torneo ~p", [?MODULE, TournamentId]),
    {ok, #{
        tournament_id => TournamentId,
        match_scores => #{},           %% match_id => #score_update{}
        viewers => #{},                %% viewer_pid => #viewer{}
        viewer_match => #{},           %% viewer_pid => match_id | tournament_overview
        next_viewer_id => 1
    }}.

handle_call({subscribe, ViewerPid}, _From, State) ->
    ViewerId = maps:get(next_viewer_id, State),
    Viewer = #viewer{
        id = ViewerId,
        tournament_id = maps:get(tournament_id, State),
        match_id = undefined,
        connected_at = erlang:system_time(second),
        metadata = #{pid => ViewerPid}
    },
    NewState = State#{
        viewers => maps:put(ViewerPid, Viewer, maps:get(viewers, State)),
        viewer_match => maps:put(ViewerPid, tournament_overview, maps:get(viewer_match, State)),
        next_viewer_id => ViewerId + 1
    },
    %% Send current tournament state
    ViewerPid ! {tournament_state, get_tournament_summary(State)},
    {reply, {ok, ViewerId}, NewState};

handle_call({unsubscribe, ViewerPid}, _From, State) ->
    NewViewers = maps:remove(ViewerPid, maps:get(viewers, State)),
    NewViewerMatch = maps:remove(ViewerPid, maps:get(viewer_match, State)),
    NewState = State#{viewers => NewViewers, viewer_match => NewViewerMatch},
    {reply, ok, NewState};

handle_call({get_match_score, MatchId}, _From, State) ->
    case maps:find(MatchId, maps:get(match_scores, State)) of
        {ok, Score} -> {reply, {ok, Score}, State};
        error -> {reply, {error, not_found}, State}
    end;

handle_call(get_tournament_viewers, _From, State) ->
    Viewers = maps:values(maps:get(viewers, State)),
    Counts = maps:fold(
        fun(Pid, _V, Acc) ->
            Match = maps:get(Pid, maps:get(viewer_match, State), tournament_overview),
            maps:update_with(Match, fun(C) -> C + 1 end, 1, Acc)
        end,
        #{},
        maps:get(viewers, State)
    ),
    {reply, {ok, #{total => length(Viewers), by_match => Counts}}, State}.

handle_cast({update_score, MatchId, ScoreUpdate}, State) ->
    %% Store updated score
    NewScores = maps:put(MatchId, ScoreUpdate, maps:get(match_scores, State)),

    %% Broadcast to viewers watching this match
    Viewers = maps:keys(maps:get(viewers, State)),
    lists:foreach(
        fun(ViewerPid) ->
            case maps:get(ViewerPid, maps:get(viewer_match, State)) of
                MatchId -> ViewerPid ! {score_update, ScoreUpdate};
                tournament_overview -> ViewerPid ! {score_update, ScoreUpdate};
                _ -> ok
            end
        end,
        Viewers
    ),

    {noreply, State#{match_scores => NewScores}};

handle_cast({broadcast, Message}, State) ->
    Viewers = maps:keys(maps:get(viewers, State)),
    lists:foreach(fun(Pid) -> Pid ! Message end, Viewers),
    {noreply, State};

handle_cast({match_finished, MatchId, Result}, State) ->
    Viewers = maps:keys(maps:get(viewers, State)),
    lists:foreach(
        fun(ViewerPid) ->
            case maps:get(ViewerPid, maps:get(viewer_match, State), tournament_overview) of
                tournament_overview -> ViewerPid ! {match_finished, MatchId, Result};
                MatchId -> ViewerPid ! {match_finished, MatchId, Result};
                _ -> ok
            end
        end,
        Viewers
    ),
    {noreply, State};

handle_cast({match_disputed, MatchId, Result}, State) ->
    Viewers = maps:keys(maps:get(viewers, State)),
    lists:foreach(fun(Pid) -> Pid ! {match_disputed, MatchId, Result} end, Viewers),
    {noreply, State};

handle_cast({match_status, MatchId, Status, Reason}, State) ->
    Viewers = maps:keys(maps:get(viewers, State)),
    lists:foreach(fun(Pid) -> Pid ! {match_status, MatchId, Status, Reason} end, Viewers),
    {noreply, State};

handle_cast(_Message, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% Internal
get_tournament_summary(State) ->
    Scores = maps:values(maps:get(match_scores, State)),
    #{matches_scores => [score_update_to_map(Score) || Score <- Scores]}.

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
        <<"team_scores">> => maps:from_list([
            {integer_to_binary(TeamId), Score} || {TeamId, Score} <- maps:to_list(TeamScores)
        ]),
        <<"current_map">> => CurrentMap,
        <<"maps_won">> => maps:from_list([
            {integer_to_binary(TeamId), Wins} || {TeamId, Wins} <- maps:to_list(MapsWon)
        ]),
        <<"timestamp">> => Timestamp
    }.
