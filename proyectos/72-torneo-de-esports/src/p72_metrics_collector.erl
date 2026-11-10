%% -*- mode: erlang -*-
-module(p72_metrics_collector).
-behaviour(gen_server).

-include("p72_torneo_de_esports.hrl").

-export([start_link/0, get_metrics/0, record_match_start/1, record_match_finish/1,
         record_match_disputed/1,
         record_viewer_connect/2, record_viewer_disconnect/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% API
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_metrics() ->
    gen_server:call(?MODULE, get_metrics).

record_match_start(MatchId) ->
    gen_server:cast(?MODULE, {match_started, MatchId}).

record_match_finish(MatchId) ->
    gen_server:cast(?MODULE, {match_finished, MatchId}).

record_match_disputed(MatchId) ->
    gen_server:cast(?MODULE, {match_disputed, MatchId}).

record_viewer_connect(TournamentId, ViewerPid) ->
    gen_server:cast(?MODULE, {viewer_connect, TournamentId, ViewerPid}).

record_viewer_disconnect(TournamentId, ViewerPid) ->
    gen_server:cast(?MODULE, {viewer_disconnect, TournamentId, ViewerPid}).

%% Callbacks
init([]) ->
    logger:info("~s iniciado", [?MODULE]),
    {ok, #{
        tournaments_total => 0,
        tournaments_active => 0,
        matches_total => 0,
        matches_in_progress => 0,
        matches_finished => 0,
        matches_disputed => 0,
        matches_seen => #{},
        matches_started => #{},
        matches_finished_ids => #{},
        matches_disputed_ids => #{},
        viewers_by_tournament => #{},    %% tournament_id => count
        viewers_by_match => #{},         %% match_id => count
        bracket_progress => #{},         %% tournament_id => 0.0-1.0
        last_updated => erlang:system_time(second)
    }}.

handle_call(get_metrics, _From, State) ->
    Metrics = #metrics{
        timestamp = maps:get(last_updated, State),
        tournaments_total = maps:get(tournaments_total, State),
        tournaments_active = maps:get(tournaments_active, State),
        matches_total = maps:get(matches_total, State),
        matches_in_progress = maps:get(matches_in_progress, State),
        matches_finished = maps:get(matches_finished, State),
        matches_disputed = maps:get(matches_disputed, State),
        viewers_total = lists:sum(maps:values(maps:get(viewers_by_tournament, State))),
        viewers_per_match = maps:get(viewers_by_match, State),
        bracket_progress = maps:get(bracket_progress, State)
    },
    {reply, Metrics, State}.

handle_cast({match_started, MatchId}, State) ->
    Started = maps:get(matches_started, State),
    case maps:is_key(MatchId, Started) of
        true -> {noreply, State};
        false ->
            Seen = maps:get(matches_seen, State),
            NewState = State#{
                matches_total := maps:get(matches_total, State) + bool_int(not maps:is_key(MatchId, Seen)),
                matches_in_progress := maps:get(matches_in_progress, State) + 1,
                matches_seen := maps:put(MatchId, true, Seen),
                matches_started := maps:put(MatchId, true, Started),
                last_updated := erlang:system_time(second)
            },
            {noreply, NewState}
    end;

handle_cast({match_finished, MatchId}, State) ->
    Finished = maps:get(matches_finished_ids, State),
    case maps:is_key(MatchId, Finished) of
        true -> {noreply, State};
        false ->
            Seen = maps:get(matches_seen, State),
            Started = maps:get(matches_started, State),
            Disputed = maps:get(matches_disputed_ids, State),
            WasActive = maps:is_key(MatchId, Started) andalso not maps:is_key(MatchId, Disputed),
            NewState = State#{
                matches_total := maps:get(matches_total, State) + bool_int(not maps:is_key(MatchId, Seen)),
                matches_in_progress := max(0, maps:get(matches_in_progress, State) - bool_int(WasActive)),
                matches_finished := maps:get(matches_finished, State) + 1,
                matches_seen := maps:put(MatchId, true, Seen),
                matches_finished_ids := maps:put(MatchId, true, Finished),
                last_updated := erlang:system_time(second)
            },
            {noreply, NewState}
    end;

handle_cast({match_disputed, MatchId}, State) ->
    Disputed = maps:get(matches_disputed_ids, State),
    case maps:is_key(MatchId, Disputed) of
        true -> {noreply, State};
        false ->
            Seen = maps:get(matches_seen, State),
            Started = maps:get(matches_started, State),
            Finished = maps:get(matches_finished_ids, State),
            WasActive = maps:is_key(MatchId, Started) andalso not maps:is_key(MatchId, Finished),
            NewState = State#{
                matches_total := maps:get(matches_total, State) + bool_int(not maps:is_key(MatchId, Seen)),
                matches_in_progress := max(0, maps:get(matches_in_progress, State) - bool_int(WasActive)),
                matches_disputed := maps:get(matches_disputed, State) + 1,
                matches_seen := maps:put(MatchId, true, Seen),
                matches_disputed_ids := maps:put(MatchId, true, Disputed),
                last_updated := erlang:system_time(second)
            },
            {noreply, NewState}
    end;

handle_cast({viewer_connect, TournamentId, _ViewerPid}, State) ->
    NewTCount = maps:get(TournamentId, maps:get(viewers_by_tournament, State), 0) + 1,
    NewState = State#{
        viewers_by_tournament => maps:put(TournamentId, NewTCount, maps:get(viewers_by_tournament, State)),
        last_updated := erlang:system_time(second)
    },
    {noreply, NewState};

handle_cast({viewer_disconnect, TournamentId, _ViewerPid}, State) ->
    Current = maps:get(TournamentId, maps:get(viewers_by_tournament, State), 0),
    NewTCount = max(0, Current - 1),
    NewViewersByT = if
        NewTCount =:= 0 -> maps:remove(TournamentId, maps:get(viewers_by_tournament, State));
        true -> maps:put(TournamentId, NewTCount, maps:get(viewers_by_tournament, State))
    end,
    NewState = State#{
        viewers_by_tournament => NewViewersByT,
        last_updated := erlang:system_time(second)
    },
    {noreply, NewState};

handle_cast({update_bracket_progress, TournamentId, Progress}, State) ->
    NewState = State#{
        bracket_progress => maps:put(TournamentId, Progress, maps:get(bracket_progress, State)),
        last_updated := erlang:system_time(second)
    },
    {noreply, NewState};

handle_cast({tournament_started, _TournamentId}, State) ->
    NewState = State#{
        tournaments_total := maps:get(tournaments_total, State) + 1,
        tournaments_active := maps:get(tournaments_active, State) + 1,
        last_updated := erlang:system_time(second)
    },
    {noreply, NewState};

handle_cast({tournament_finished, _TournamentId}, State) ->
    NewState = State#{
        tournaments_active := max(0, maps:get(tournaments_active, State) - 1),
        last_updated := erlang:system_time(second)
    },
    {noreply, NewState}.

bool_int(true) -> 1;
bool_int(false) -> 0.

handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
