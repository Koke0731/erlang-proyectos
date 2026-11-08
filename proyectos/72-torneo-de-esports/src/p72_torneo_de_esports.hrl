%% -*- mode: erlang -*-
%% Domain records for esports tournament system

%% Tournament formats
-type tournament_format() :: single_elim | double_elim | swiss | groups.
-type series_format() :: bo1 | bo3 | bo5.

%% Tournament states
-type tournament_state() ::
    pending |
    registration_open |
    registration_closed |
    in_progress |
    completed |
    cancelled.

%% Team record
-record(team, {
    id :: pos_integer(),
    name :: binary(),
    players :: [binary()],           %% Player names/IDs
    seed :: non_neg_integer(),       %% Initial seeding (0 = unseeded)
    metadata :: #{}
}).

%% Match states (gen_statem states)
-type match_state() ::
    scheduled |
    in_play |
    finished |
    disputed |
    cancelled |
    walkover |
    disqualified.

%% Match result
-record(match_result, {
    winner_team_id :: pos_integer() | undefined,
    loser_team_id :: pos_integer() | undefined,
    scores :: [{pos_integer(), non_neg_integer()}],  %% [{team_id, score}, ...] per map
    submitted_by :: pos_integer() | system,          %% Team ID that submitted, or system
    submitted_at :: integer(),                        %% timestamp
    disputed :: boolean(),
    dispute_reason :: binary() | undefined
}).

%% Match record
-record(match, {
    id :: pos_integer(),
    tournament_id :: pos_integer(),
    bracket_id :: pos_integer(),
    round :: pos_integer(),
    position :: pos_integer(),           %% Position in bracket (1, 2, 3...)
    format :: series_format(),
    team1_id :: pos_integer() | undefined,  %% undefined = bye
    team2_id :: pos_integer() | undefined,
    state :: match_state(),
    result :: #match_result{} | undefined,
    scheduled_at :: integer() | undefined,  %% Unix timestamp
    started_at :: integer() | undefined,
    finished_at :: integer() | undefined,
    table_id :: pos_integer() | undefined,  %% Physical table/station
    referee_id :: pos_integer() | undefined,
    metadata :: #{}
}).

%% Bracket record
-record(bracket, {
    id :: pos_integer(),
    tournament_id :: pos_integer(),
    name :: binary(),                    %% "Winners Bracket", "Losers Bracket", "Groups A", etc.
    format :: tournament_format(),
    teams :: [#team{}],                  %% Teams in this bracket
    matches :: #{pos_integer() => #match{}},  %% match_id => match
    current_round :: pos_integer(),
    total_rounds :: pos_integer(),
    metadata :: #{}
}).

%% Tournament record
-record(tournament, {
    id :: pos_integer(),
    name :: binary(),
    format :: tournament_format(),
    series_format :: series_format(),
    max_teams :: pos_integer(),
    state :: tournament_state(),
    brackets :: #{pos_integer() => #bracket{}},
    teams :: #{pos_integer() => #team{}},  %% team_id => team
    created_at :: integer(),
    started_at :: integer() | undefined,
    finished_at :: integer() | undefined,
    config :: #{
        tables_count := pos_integer(),
        match_duration_estimate := pos_integer(),  %% minutes
        allow_disputes := boolean(),
        dispute_timeout := pos_integer()           %% seconds
    },
    metadata :: #{}
}).

%% Live score update (for WebSocket)
-record(score_update, {
    match_id :: pos_integer(),
    tournament_id :: pos_integer(),
    team_scores :: #{pos_integer() => non_neg_integer()},  %% team_id => current_score
    current_map :: pos_integer(),
    maps_won :: #{pos_integer() => pos_integer()},         %% team_id => maps_won
    timestamp :: integer()
}).

%% Viewer info (for metrics)
-record(viewer, {
    id :: pos_integer(),
    tournament_id :: pos_integer(),
    match_id :: pos_integer() | undefined,  %% undefined = watching tournament overview
    connected_at :: integer(),
    metadata :: #{}                         %% IP, user agent, etc.
}).

%% Dispute record
-record(dispute, {
    id :: pos_integer(),
    match_id :: pos_integer(),
    tournament_id :: pos_integer(),
    reported_by :: pos_integer(),          %% Team ID
    claimed_winner :: pos_integer(),
    claimed_scores :: [{pos_integer(), non_neg_integer()}],
    reason :: binary(),
    reported_at :: integer(),
    status :: open | resolved | escalated,
    resolution :: binary() | undefined,
    resolved_at :: integer() | undefined,
    resolved_by :: pos_integer() | system | undefined
}).

%% API request/response types
-type create_tournament_req() :: #{
    name => binary(),
    format => tournament_format(),
    series_format => series_format(),
    max_teams => pos_integer(),
    config => #{
        tables_count => pos_integer(),
        match_duration_estimate => pos_integer(),
        allow_disputes => boolean(),
        dispute_timeout => pos_integer()
    } | undefined
}.

-type register_team_req() :: #{
    tournament_id => pos_integer(),
    name => binary(),
    players => [binary()],
    seed => non_neg_integer() | undefined
}.

-type submit_result_req() :: #{
    match_id => pos_integer(),
    team_id => pos_integer(),
    winner_team_id => pos_integer(),
    scores => [{pos_integer(), non_neg_integer()}]
}.

%% Metrics snapshot
-record(metrics, {
    timestamp :: integer(),
    tournaments_total :: pos_integer(),
    tournaments_active :: pos_integer(),
    matches_total :: pos_integer(),
    matches_in_progress :: pos_integer(),
    matches_finished :: pos_integer(),
    matches_disputed :: pos_integer(),
    viewers_total :: pos_integer(),
    viewers_per_match :: #{pos_integer() => pos_integer()},
    bracket_progress :: #{pos_integer() => float()}  %% tournament_id => 0.0-1.0
}).
