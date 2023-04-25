-module(h2_stream_set).
-include("http2.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
%-compile([export_all]).

%% This module exists to manage a set of all streams for a given
%% connection. When a connection starts, a stream set logically
%% contains streams from id 1 to 2^31-1. In practicality, storing that
%% many idle streams in a collection of any type would be more memory
%% intensive. We're going to manage that here in this module, but to
%% the outside, it will behave as if they all exist

-define(RECV_WINDOW_SIZE, 1).
-define(SEND_WINDOW_SIZE, 2).
-define(SEND_LOCK, 3).
-define(SETTINGS_LOCK, 4).
-define(STREAMS_LOCK, 5).
-define(ENCODER_LOCK, 6).
-define(MY_NEXT_AVAILABLE_STREAM_ID, 7).
-define(MY_LOWEST_STREAM_ID, 8).
-define(THEIR_LOWEST_STREAM_ID, 9).

-define(UNLOCKED, 0).
-define(SHARED_LOCK, 1).
-define(EXCLUSIVE_LOCK, 2).
-define(EDITING_LOCK, 3).

-record(
   stream_set,
   {
     %% Type determines which streams are mine, and which are theirs
     type :: client | server,

     atomics = atomics:new(9, []),

     socket :: sock:socket(),

     connection :: pid(),

     table = ets:new(?MODULE, [public, {keypos, 2}, {read_concurrency, true}, {write_concurrency, true}]) :: ets:tab(),
     %% Streams initiated by this peer
     %% mine :: peer_subset(),
     %% Streams initiated by the other peer
     %% theirs :: peer_subset()
     callback_mod = undefined :: atom(),
     callback_opts = [] :: list()
   }).
-type stream_set() :: #stream_set{}.
-export_type([stream_set/0]).

-record(connection_settings, {
          type :: self_settings | peer_settings,
          settings = #settings{} :: settings()
         }).

-record(context, {
          type = encode_context :: encode_context,
          context = hpack:new_context() :: hpack:context()
         }).


-record(lock, {
          id :: {lock, non_neg_integer()},
          holders = [] :: [pid()],
          waiters = [] :: [{pid(), reference()}]
         }
       ).

%% The stream_set needs to keep track of two subsets of streams, one
%% for the streams that it has initiated, and one for the streams that
%% have been initiated on the other side of the connection. It is this
%% peer_subset that will try to optimize the set of stream metadata
%% that we're storing in memory. For each side of the connection, we
%% also need an accurate count of how many are currently active

-record(
   peer_subset,
   {
     type :: mine | theirs,
     %% Provided by the connection settings, we can check against this
     %% every time we try to add a stream to this subset
     max_active = unlimited :: unlimited | pos_integer(),
     %% A counter that's an accurate reflection of the number of
     %% active streams
     active_count = 0 :: non_neg_integer(),

     %% lowest_stream_id is the lowest stream id that we're currently
     %% managing in memory. Any stream with an id lower than this is
     %% automatically of type closed.
     lowest_stream_id = 0 :: stream_id(),

     %% Next available stream id will be the stream id of the next
     %% stream that can be added to this subset. That means if asked
     %% for a stream with this id or higher, the stream type returned
     %% must be idle. Any stream id lower than this that isn't active
     %% must be of type closed.
     next_available_stream_id :: stream_id()
   }).
-type peer_subset() :: #peer_subset{}.


%% Streams all have stream_ids. It is the only thing all three types
%% have. It *MUST* be the first field in *ALL* *_stream{} records.

%% The metadata for an active stream is, unsurprisingly, the most
%% complex.
-record(
   active_stream, {
     id                    :: stream_id(),
     % Pid running the http2_stream gen_statem
     pid                   :: pid(),
     % The process to notify with events on this stream
     notify_pid            :: pid() | undefined,
     % The stream's flow control send window size
     send_window_size      :: non_neg_integer(),
     % The stream's flow control recv window size
     recv_window_size      :: non_neg_integer(),
     % Data that is in queue to send on this stream, if flow control
     % hasn't allowed it to be sent yet
     queued_data           :: undefined | done | binary(),
     % Has the body been completely recieved.
     body_complete = false :: boolean(),
     trailers = undefined  :: [h2_frame:frame()] | undefined
    }).
-type active_stream() :: #active_stream{}.

%% The closed_stream record is way more important to a client than a
%% server. It's a way of holding on to a response that has been
%% recieved, but not processed by the client yet.
-record(
   closed_stream, {
     id               :: stream_id(),
     % The pid to notify about events on this stream
     notify_pid       :: pid() | undefined,
     % The response headers received
     response_headers :: hpack:headers() | undefined,
     % The response body
     response_body    :: binary() | undefined,
     % The response trailers received
     response_trailers :: hpack:headers() | undefined,
     % Can this be thrown away?
     garbage = false  :: boolean() | undefined
     }).
-type closed_stream() :: #closed_stream{}.

%% An idle stream record isn't used for much. It's never stored,
%% unlike the other two types. It is always generated on the fly when
%% asked for a stream >= next_available_stream_id. But, we're able to
%% perform a rst_stream operation on it, and we need a stream_id to
%% make that happen.
-record(
   idle_stream, {
     id :: stream_id()
    }).
-type idle_stream() :: #idle_stream{}.

%% So a stream can be any of these things. And it will be something
%% that you can pass back into serveral functions here in this module.
-type stream() :: active_stream()
                | closed_stream()
                | idle_stream().
-export_type([stream/0]).

%% Set Operations
-export(
   [
    new/4,
    new_stream/5,
    get/2,
    update/3,
    take_lock/3,
    take_exclusive_lock/3,
    get_callback/1,
    socket/1,
    connection/1
   ]).

%% Accessors
-export(
   [
    queued_data/1,
    update_trailers/2,
    update_data_queue/3,
    decrement_recv_window/2,
    recv_window_size/1,
    decrement_socket_recv_window/2,
    increment_socket_recv_window/2,
    socket_recv_window_size/1,
    set_socket_recv_window_size/2,
    decrement_socket_send_window/2,
    increment_socket_send_window/2,
    socket_send_window_size/1,
    set_socket_send_window_size/2,

    response/1,
    send_window_size/1,
    increment_send_window_size/2,
    pid/1,
    stream_id/1,
    stream_pid/1,
    notify_pid/1,
    type/1,
    stream_set_type/1,
    my_active_count/1,
    their_active_count/1,
    my_active_streams/1,
    their_active_streams/1,
    my_max_active/1,
    their_max_active/1,
    get_next_available_stream_id/1,
    get_settings/1,
    update_self_settings/2,
    update_peer_settings/2,
    get_encode_context/1,
    update_encode_context/2
   ]
  ).

-export(
   [
    close/3,
    send_all_we_can/1,
    send_what_we_can/3,
    update_all_recv_windows/2,
    update_all_send_windows/2,
    update_their_max_active/2,
    update_my_max_active/2
   ]
  ).

%% new/1 returns a new stream_set. This is your constructor.
-spec new(
        client | server,
        sock:socket(),
        atom(), list()
       ) -> stream_set().
new(client, Socket, CallbackMod, CallbackOpts) ->
    StreamSet = #stream_set{
        callback_mod = CallbackMod,
        callback_opts = CallbackOpts,
        socket=Socket,
        connection=self(),
       type=client},
    ets:insert_new(StreamSet#stream_set.table, #lock{id={lock, ?SEND_LOCK}}),
    ets:insert_new(StreamSet#stream_set.table, #lock{id={lock, ?SETTINGS_LOCK}}),
    ets:insert_new(StreamSet#stream_set.table, #lock{id={lock, ?STREAMS_LOCK}}),
    ets:insert_new(StreamSet#stream_set.table, #lock{id={lock, ?ENCODER_LOCK}}),
    ets:insert_new(StreamSet#stream_set.table, #connection_settings{type=self_settings}),
    ets:insert_new(StreamSet#stream_set.table, #connection_settings{type=peer_settings}),
    ets:insert_new(StreamSet#stream_set.table, #context{}),
    atomics:put(StreamSet#stream_set.atomics, ?MY_NEXT_AVAILABLE_STREAM_ID, 1),
    atomics:put(StreamSet#stream_set.atomics, ?MY_LOWEST_STREAM_ID, 0),
    atomics:put(StreamSet#stream_set.atomics, ?THEIR_LOWEST_STREAM_ID, 0),
    %% I'm a client, so mine are always odd numbered
    ets:insert_new(StreamSet#stream_set.table,
                   #peer_subset{
                      type=mine,
                      lowest_stream_id=0,
                      next_available_stream_id=1
                     }),
    %% And theirs are always even
     ets:insert_new(StreamSet#stream_set.table, 
                    #peer_subset{
                       type=theirs,
                       lowest_stream_id=0,
                       next_available_stream_id=2
                      }),
    StreamSet;
new(server, Socket, CallbackMod, CallbackOpts) ->
    StreamSet = #stream_set{
       callback_mod = CallbackMod,
       callback_opts = CallbackOpts,
       socket=Socket,
       connection=self(),
       type=server},
    ets:insert_new(StreamSet#stream_set.table, #lock{id={lock, ?SEND_LOCK}}),
    ets:insert_new(StreamSet#stream_set.table, #lock{id={lock, ?SETTINGS_LOCK}}),
    ets:insert_new(StreamSet#stream_set.table, #lock{id={lock, ?STREAMS_LOCK}}),
    ets:insert_new(StreamSet#stream_set.table, #lock{id={lock, ?ENCODER_LOCK}}),
    ets:insert_new(StreamSet#stream_set.table, #connection_settings{type=self_settings}),
    ets:insert_new(StreamSet#stream_set.table, #connection_settings{type=peer_settings}),
    ets:insert_new(StreamSet#stream_set.table, #context{}),
    %% I'm a server, so mine are always even numbered
    atomics:put(StreamSet#stream_set.atomics, ?MY_NEXT_AVAILABLE_STREAM_ID, 2),
    atomics:put(StreamSet#stream_set.atomics, ?MY_LOWEST_STREAM_ID, 0),
    atomics:put(StreamSet#stream_set.atomics, ?THEIR_LOWEST_STREAM_ID, 0),
    ets:insert_new(StreamSet#stream_set.table,
                   #peer_subset{
                      type=mine,
                      lowest_stream_id=0,
                      next_available_stream_id=2
                     }),
    %% And theirs are always odd
     ets:insert_new(StreamSet#stream_set.table, 
                    #peer_subset{
                       type=theirs,
                       lowest_stream_id=0,
                       next_available_stream_id=1
                      }),
    StreamSet.

-spec new_stream(
        StreamId :: stream_id() | next,
        NotifyPid :: pid(),
        CBMod :: module(),
        CBOpts :: list(),
        StreamSet :: stream_set()) ->
                        {pid(), stream_id(), stream_set()}
                            | {error, error_code(), closed_stream()}.
new_stream(
          StreamId0,
          NotifyPid,
          CBMod,
          CBOpts,
          StreamSet) ->

    {SelfSettings, PeerSettings} = get_settings(StreamSet),
    InitialSendWindow = PeerSettings#settings.initial_window_size,
    InitialRecvWindow = SelfSettings#settings.initial_window_size,
    {PeerSubset, StreamId} = case StreamId0 of 
                                 next ->
                                     Next = atomics:add_get(StreamSet#stream_set.atomics, ?MY_NEXT_AVAILABLE_STREAM_ID, 2),
                                     P0 = get_my_peers(StreamSet),
                                     {P0, Next - 2};
                                 Id ->
                                     {get_peer_subset(Id, StreamSet), Id}
                             end,

    ct:pal("~p spawning stream ~p", [StreamSet#stream_set.type, StreamId]),
    case PeerSubset#peer_subset.max_active =/= unlimited andalso
         PeerSubset#peer_subset.active_count >= PeerSubset#peer_subset.max_active
    of
        true ->
            ct:pal("refused stream ~p because of max active", [StreamId]),
            {error, ?REFUSED_STREAM, #closed_stream{id=StreamId}};
        false ->
            {ok, Pid} = case self() == StreamSet#stream_set.connection of
                            true ->
                                h2_stream:start_link(
                                  StreamId,
                                  StreamSet,
                                  self(),
                                  CBMod,
                                  CBOpts
                                 );
                            false ->
                                h2_stream:start(
                                  StreamId,
                                  StreamSet,
                                  StreamSet#stream_set.connection,
                                  CBMod,
                                  CBOpts
                                 )
                        end,
                    NewStream = #active_stream{
                           id = StreamId,
                           pid = Pid,
                           notify_pid=NotifyPid,
                           send_window_size=InitialSendWindow,
                           recv_window_size=InitialRecvWindow
                          },
                   true = ets:insert_new(StreamSet#stream_set.table, NewStream),
            case upsert_peer_subset(#idle_stream{id=StreamId}, NewStream, get_peer_subset(StreamId, StreamSet), StreamSet) of
                {error, ?REFUSED_STREAM} ->
                    ct:pal("refused stream ~p", [StreamId]),
                    %% This should be very rare, if it ever happens at
                    %% all. The case clause above tests the same
                    %% condition that upsert/2 checks to return this
                    %% result. Still, we need this case statement
                    %% because returning an {error tuple here would be
                    %% catastrophic

                    %% If this did happen, we need to kill this
                    %% process, or it will just hang out there.
                    h2_stream:stop(Pid),
                    {error, ?REFUSED_STREAM, #closed_stream{id=StreamId}};
                ok ->
                    ct:pal("~p inserted stream ~p", [StreamSet#stream_set.type, StreamId]),
                    {Pid, StreamId, StreamSet}
            end
    end.

get_callback(#stream_set{callback_mod=CM, callback_opts = CO}) ->
    {CM, CO}.

socket(#stream_set{socket=Sock}) ->
    Sock.

connection(#stream_set{connection=Conn}) ->
    Conn.

get_settings(StreamSet) ->
    try {(hd(ets:lookup(StreamSet#stream_set.table, self_settings)))#connection_settings.settings, (hd(ets:lookup(StreamSet#stream_set.table, peer_settings)))#connection_settings.settings}
    catch _:_ ->
              {#settings{}, #settings{}}
    end.

update_self_settings(StreamSet, Settings) ->
    ets:insert(StreamSet#stream_set.table, #connection_settings{type=self_settings, settings=Settings}).

update_peer_settings(StreamSet, Settings) ->
    ets:insert(StreamSet#stream_set.table, #connection_settings{type=peer_settings, settings=Settings}).

get_encode_context(StreamSet) ->
    try (hd(ets:lookup(StreamSet#stream_set.table, encode_context)))#context.context
    catch _:_ -> hpack:new_context()
    end.

update_encode_context(StreamSet, Context) ->
    ets:insert(StreamSet#stream_set.table, #context{type=encode_context, context=Context}).

-spec get_peer_subset(
        stream_id(),
        stream_set()) ->
                               peer_subset().
get_peer_subset(Id, StreamSet) ->
    case {Id rem 2, StreamSet#stream_set.type} of
        {0, client} ->
            get_their_peers(StreamSet);
        {1, client} ->
            get_my_peers(StreamSet);
        {0, server} ->
            get_my_peers(StreamSet);
        {1, server} ->
            get_their_peers(StreamSet)
    end.

-spec get_my_peers(stream_set()) -> peer_subset().
get_my_peers(StreamSet) ->
    Next = atomics:get(StreamSet#stream_set.atomics, ?MY_NEXT_AVAILABLE_STREAM_ID),
    Lowest = atomics:get(StreamSet#stream_set.atomics, ?MY_LOWEST_STREAM_ID),
    try (hd(ets:lookup(StreamSet#stream_set.table, mine)))#peer_subset{next_available_stream_id=Next, lowest_stream_id = Lowest}
    catch _:_ -> #peer_subset{}
    end.

-spec get_their_peers(stream_set()) -> peer_subset().
get_their_peers(StreamSet) ->
    Lowest = atomics:get(StreamSet#stream_set.atomics, ?THEIR_LOWEST_STREAM_ID),
    try (hd(ets:lookup(StreamSet#stream_set.table, theirs)))#peer_subset{lowest_stream_id = Lowest}
    catch _:_ -> #peer_subset{}
    end.

get_my_active_streams(StreamSet) ->
    case StreamSet#stream_set.type of
        client ->
            ets:select(StreamSet#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 1 ->
                                                                      S
                                                              end));
        server ->
            ets:select(StreamSet#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 0 ->
                                                                      S
                                                              end))
    end.

get_their_active_streams(StreamSet) ->
    case StreamSet#stream_set.type of
        client ->
            ets:select(StreamSet#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 0 ->
                                                                      S
                                                              end));
        server ->
            ets:select(StreamSet#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 1 ->
                                                                      S
                                                              end))
    end.

%% get/2 gets a stream. The logic in here basically just chooses which
%% subset.
-spec get(Id :: stream_id(),
          Streams :: stream_set()) ->
                 stream().
get(Id, StreamSet) ->
    get_from_subset(Id,
                    get_peer_subset(
                      Id,
                      StreamSet), StreamSet).


-spec get_from_subset(
        Id :: stream_id(),
        PeerSubset :: peer_subset(),
        StreamSet :: stream_set())
                     ->
    stream().
get_from_subset(Id,
                #peer_subset{
                   lowest_stream_id=Lowest
                  }, _StreamSet)
  when Id < Lowest ->
    ct:pal("~p returning closed stream for ~p id < lowest", [_StreamSet#stream_set.type, Id]),
    #closed_stream{id=Id};
get_from_subset(Id,
                #peer_subset{
                   next_available_stream_id=Next
                  }, _StreamSet)
  when Id >= Next ->
    #idle_stream{id=Id};
get_from_subset(Id, _PeerSubset, StreamSet) ->
    try ets:lookup(StreamSet#stream_set.table, Id)  of
        [] ->
            ct:pal("~p returning idle stream ~p for unknown", [StreamSet#stream_set.type, Id]),
            timer:sleep(100),
            try ets:lookup(StreamSet#stream_set.table, Id)  of
                [] ->
                    #idle_stream{id=Id};
                [NewStream] ->
                    ct:pal("found missing stream ~p", [Id]),
                    NewStream
            catch _:_ ->
                      #idle_stream{id=Id}
            end;
        [Stream] ->
            Stream
    catch
        _:_ ->
            #idle_stream{id=Id}
    end.


update(StreamId, Fun, StreamSet) ->
    ct:pal("updating ~p with ~p", [StreamId, Fun]),
    case get(StreamId, StreamSet) of
        #idle_stream{} ->
            %ct:pal("~p was idle", [StreamId]),
            %ct:pal("transform ~p", [catch Fun(#idle_stream{id=StreamId})]),
            case Fun(#idle_stream{id=StreamId}) of
                {#idle_stream{}, _} ->
                    %% Can't store idle streams
                    ok;
                {NewStream, Data} ->
                    case ets:insert_new(StreamSet#stream_set.table, NewStream) of
                        true ->
                            PeerSubset = get_peer_subset(StreamId, StreamSet),
                            case upsert_peer_subset(#idle_stream{id=StreamId}, NewStream, PeerSubset, StreamSet) of
                                {error, Code} ->
                                    {error, Code};
                                ok ->
                                    {ok, Data}
                            end;
                        false ->
                            ct:pal("update retry 1"),
                            %% somebody beat us to it, try again
                            update(StreamId, Fun, StreamSet)
                    end;
                ignore ->
                    ok
            end;
        Stream ->
            %ct:pal("~p was ~p", [StreamId, Stream]),
            %ct:pal("transform ~p", [catch Fun(Stream)]),
            case Fun(Stream) of
                ignore ->
                    ok;
                {NewStream, Data} ->
                    case ets:select_replace(StreamSet#stream_set.table, [{Stream, [], [{const, NewStream}]}]) of
                        1 ->
                            PeerSubset = get_peer_subset(StreamId, StreamSet),
                            case upsert_peer_subset(Stream, NewStream, PeerSubset, StreamSet) of
                                {error, Code} ->
                                    {error, Code};
                                ok ->
                                    {ok, Data}
                            end;
                        0 ->
                            ct:pal("update retry 2"),
                            update(StreamId, Fun, StreamSet)
                    end
            end
    end.

-spec upsert_peer_subset(
        OldStream :: idle_stream() | closed_stream() | active_stream(),
        Stream :: closed_stream() | active_stream(),
        PeerSubset :: peer_subset(),
        StreamSet :: stream_set()
                      ) ->
                    ok
                  | {error, error_code()}.
%% Case 1: We're upserting a closed stream, it contains garbage we
%% don't care about and it's in the range of streams we're actively
%% tracking We remove it, and move the lowest_active pointer.
upsert_peer_subset(
  OldStream,
  #closed_stream{
     id=Id,
     garbage=true
    }=NewStream,
  PeerSubset, StreamSet)
  when Id >= PeerSubset#peer_subset.lowest_stream_id,
       Id < PeerSubset#peer_subset.next_available_stream_id ->
    OldType = type(OldStream),
    ActiveDiff =
        case OldType of
            closed -> 0;
            active -> -1
        end,

    %% NewActive could now have a #closed_stream with no information
    %% in it as the lowest active stream, so we should drop those.
    NewActive = drop_unneeded_streams(StreamSet, Id),

    NewPeerSubset =
    case NewActive of
        [] ->
            ct:pal("~p lowest stream is now ~p", [stream_set_type(StreamSet), PeerSubset#peer_subset.next_available_stream_id]),

            PeerSubset#peer_subset{
              lowest_stream_id=PeerSubset#peer_subset.next_available_stream_id,
              active_count=0
             };
        [NewLowestStream|_] ->
            NewLowest = stream_id(NewLowestStream),
            ct:pal("lowest stream is now ~p", [NewLowest]),
            PeerSubset#peer_subset{
              lowest_stream_id=NewLowest,
              active_count=max(0, PeerSubset#peer_subset.active_count+ActiveDiff)
             }
    end,
    case ets:select_replace(StreamSet#stream_set.table, [{PeerSubset, [], [{const, NewPeerSubset}]}]) of
        1 ->
            ok;
        0 ->
            ct:pal("upsert peer subset failed, retrying 1"),
            upsert_peer_subset(OldStream, NewStream, get_peer_subset(Id, StreamSet), StreamSet)
    end;
%% Case 2: Like case 1, but it's not garbage
upsert_peer_subset(
  OldStream,
  #closed_stream{
     id=Id,
     garbage=false
    }=NewStream,
  PeerSubset, StreamSet)
  when Id >= PeerSubset#peer_subset.lowest_stream_id,
       Id < PeerSubset#peer_subset.next_available_stream_id ->
    OldType = type(OldStream),
    case OldType of
        active when PeerSubset#peer_subset.active_count > 0 ->
            NewPeerSubset = PeerSubset#peer_subset{active_count=max(0, PeerSubset#peer_subset.active_count - 1)},
            case ets:select_replace(StreamSet#stream_set.table, [{PeerSubset, [], [{const, NewPeerSubset}]}]) of
                1 ->
                    ok;
                0 ->
                    ct:pal("old peer subset ~p", [PeerSubset]),
                    ct:pal("new peer subset ~p", [NewPeerSubset]),
                    ct:pal("upsert peer subset for ~p failed, retrying 2", [Id]),
                    upsert_peer_subset(OldStream, NewStream, get_peer_subset(Id, StreamSet), StreamSet)
            end;
        _ -> ok
    end;
%% Case 3: It's closed, but greater than or equal to next available:
upsert_peer_subset(
  OldStream,
  #closed_stream{
     id=Id
    }=NewStream,
  PeerSubset, StreamSet)
 when Id >= PeerSubset#peer_subset.next_available_stream_id ->

    case ets:select_replace(StreamSet#stream_set.table,
                            ets:fun2ms(fun(#peer_subset{type=T, next_available_stream_id=I}=PS) when T == PeerSubset#peer_subset.type, Id >= I  ->
                                               PS#peer_subset{next_available_stream_id=Id+2}
                                       end)) of
        1 ->
            ok;
        0 ->
            ct:pal("upsert peer subset failed, retrying 3"),
            upsert_peer_subset(OldStream, NewStream, get_peer_subset(Id, StreamSet), StreamSet)
    end;
%% Case 4: It's active, and in the range we're working with
upsert_peer_subset(
  _OldStream,
  #active_stream{
     id=Id
    },
  PeerSubset, _StreamSet)
  when Id >= PeerSubset#peer_subset.lowest_stream_id,
       Id < PeerSubset#peer_subset.next_available_stream_id ->
    ok;
%% Case 5: It's active, but it wasn't active before and activating it
%% would exceed our concurrent stream limits
upsert_peer_subset(
  _OldStream,
  #active_stream{},
  PeerSubset, _StreamSet)
  when PeerSubset#peer_subset.max_active =/= unlimited,
       PeerSubset#peer_subset.active_count >= PeerSubset#peer_subset.max_active ->
    {error, ?REFUSED_STREAM};
%% Case 6: It's active, and greater than the range we're tracking
upsert_peer_subset(
  OldStream,
  #active_stream{
     id=Id
    }=NewStream,
  PeerSubset, StreamSet)
 when Id >= PeerSubset#peer_subset.next_available_stream_id ->

    case ets:select_replace(StreamSet#stream_set.table,
                            ets:fun2ms(fun(#peer_subset{type=T, next_available_stream_id=I}=PS) when T == PeerSubset#peer_subset.type, Id >= I  ->
                                               PS#peer_subset{next_available_stream_id=Id+2, active_count=PS#peer_subset.active_count+1}
                                       end)) of
        1 ->
            ok;
        0 ->
            ct:pal("upsert peer subset failed, retrying 4"),
            upsert_peer_subset(OldStream, NewStream, get_peer_subset(Id, StreamSet), StreamSet)
    end;
%% Catch All
%% TODO: remove this match and crash instead?
upsert_peer_subset(
  _OldStream,
  _Stream,
  _PeerSubset, _StreamSet) ->
    ok.


drop_unneeded_streams(StreamSet, Id) ->
    {Streams, Key} = case {StreamSet#stream_set.type, Id rem 2} of
                  {client, 0} ->
                      %% their streams
                             {their_active_streams(StreamSet), ?THEIR_LOWEST_STREAM_ID};
                  {client, 1} ->
                      %% my streams
                             {my_active_streams(StreamSet), ?MY_LOWEST_STREAM_ID};
                  {server, 0} ->
                      %% my streams
                             {my_active_streams(StreamSet), ?MY_LOWEST_STREAM_ID};
                  {server, 1} ->
                      %% their streams
                             {their_active_streams(StreamSet), ?THEIR_LOWEST_STREAM_ID}
              end,
    SortedStreams = lists:keysort(2, Streams),
    drop_unneeded_streams_(SortedStreams, StreamSet, Key).

drop_unneeded_streams_([#closed_stream{garbage=true, id=Id}|T], StreamSet, Key) ->
    ct:pal("drop deleting stream ~p", [Id]),
    atomics:put(StreamSet#stream_set.atomics, Key, Id + 2),
    ets:delete(StreamSet#stream_set.table, Id),
    drop_unneeded_streams_(T, StreamSet, Key);
drop_unneeded_streams_(Other, _StreamSet, _Key) ->
    Other.

-spec close(
        Stream :: stream(),
        Response :: garbage | {hpack:headers(), iodata()},
        Streams :: stream_set()
                   ) ->
                   { stream(), stream_set()}.
close(Stream0,
      garbage,
      StreamSet) ->

    ct:pal("closing  with garbage ~p", [stream_id(Stream0)]),
    {ok, Closed} = update(stream_id(Stream0),
           fun(Stream) ->
                   NewStream = #closed_stream{
                      id = stream_id(Stream),
                      garbage=true
                     },
                   {NewStream, NewStream}
           end, StreamSet),
    {Closed, StreamSet};
close(Closed=#closed_stream{},
      _Response,
      Streams) ->
    {Closed, Streams};
close(_Idle=#idle_stream{id=StreamId},
      {Headers, Body, Trailers},
      Streams) ->
    ct:pal("closing idle stream ~p", [StreamId]),
    case update(StreamId,
                fun(#idle_stream{}) ->
                        NewStream = #closed_stream{
                                       id=StreamId,
                                       response_headers=Headers,
                                       response_body=Body,
                                       response_trailers=Trailers
                                      },
                        {NewStream, NewStream};
                   (#closed_stream{}=C) ->
                        {C, C};
                   (_) -> ignore
                end, Streams) of
        {ok, Closed} ->
            {Closed, Streams};
        ok ->
            close(get(StreamId, Streams), {Headers, Body, Trailers}, Streams)
    end;

close(#active_stream{
         id=Id
        },
      {Headers, Body, Trailers},
      Streams) ->
    ct:pal("closing active stream ~p", [Id]),
    case update(Id,
                fun(#active_stream{notify_pid=Pid}) ->
                        NewStream = #closed_stream{
                                       notify_pid=Pid,
                                       id=Id,
                                       response_headers=Headers,
                                       response_body=Body,
                                       response_trailers=Trailers
                                      },
                        {NewStream, NewStream};
                   (#closed_stream{}=C) ->
                        {C, C};
                   (_) -> ignore
                end, Streams) of
        {ok, Closed} ->
            {Closed, Streams};
        ok ->
            close(get(Id, Streams), {Headers, Body, Trailers}, Streams)
    end.

-spec update_all_recv_windows(Delta :: integer(),
                              Streams:: stream_set()) ->
                                     stream_set().
update_all_recv_windows(Delta, Streams) ->

    ets:select_replace(Streams#stream_set.table,
      ets:fun2ms(fun(S=#active_stream{recv_window_size=Size}) ->
                         S#active_stream{recv_window_size=Size+Delta}
                 end)),
    Streams.

-spec update_all_send_windows(Delta :: integer(),
                              Streams:: stream_set()) ->
                                     stream_set().
update_all_send_windows(Delta, Streams) ->
    ets:select_replace(Streams#stream_set.table,
      ets:fun2ms(fun(S=#active_stream{send_window_size=Size}) ->
                         S#active_stream{send_window_size=Size+Delta}
                 end)),
    Streams.

-spec update_their_max_active(NewMax :: non_neg_integer() | unlimited,
                             Streams :: stream_set()) ->
                                    stream_set().
update_their_max_active(NewMax, Streams) ->
    case ets:select_replace(Streams#stream_set.table, ets:fun2ms(fun(#peer_subset{type=theirs}=PS) -> PS#peer_subset{max_active=NewMax} end)) of
        1 ->
            Streams;
        0 ->
            update_their_max_active(NewMax, Streams)
    end.

get_next_available_stream_id(Streams) ->
    (get_my_peers(Streams))#peer_subset.next_available_stream_id.

-spec update_my_max_active(NewMax :: non_neg_integer() | unlimited,
                             Streams :: stream_set()) ->
                                    stream_set().
update_my_max_active(NewMax, Streams) ->
    case ets:select_replace(Streams#stream_set.table, ets:fun2ms(fun(#peer_subset{type=mine}=PS) -> PS#peer_subset{max_active=NewMax} end)) of
        1 ->
            Streams;
        0 ->
            update_their_max_active(NewMax, Streams)
    end.

-spec send_all_we_can(Streams :: stream_set()) ->
                              {NewConnSendWindowSize :: integer(),
                               NewStreams :: stream_set()}.
send_all_we_can(Streams) ->
    AfterAfterWindowSize = take_exclusive_lock(Streams, [socket], fun() ->
    ConnSendWindowSize = socket_send_window_size(Streams),
    {_SelfSettings, PeerSettings} = get_settings(Streams),
    MaxFrameSize = PeerSettings#settings.max_frame_size,
    AfterPeerWindowSize = c_send_what_we_can(
                            ConnSendWindowSize,
                            MaxFrameSize,
                            get_their_active_streams(Streams),
                            Streams),
    c_send_what_we_can(
                             AfterPeerWindowSize,
                             MaxFrameSize,
                             get_my_active_streams(Streams),
                             Streams)
                                           end),

    {AfterAfterWindowSize,
     Streams}.

-spec send_what_we_can(StreamId :: stream_id(),
                       StreamFun :: fun((#active_stream{}) -> #active_stream{}),
                       Streams :: stream_set()) ->
                              {NewConnSendWindowSize :: integer(),
                               NewStreams :: stream_set()}.

send_what_we_can(StreamId, StreamFun, Streams) ->
    NewConnSendWindowSize =
    take_exclusive_lock(Streams, [socket],
                        fun() ->
                                take_lock(Streams, [],
                                          fun() ->
                                                  {_SelfSettings, PeerSettings} = get_settings(Streams),
                                                  MaxFrameSize = PeerSettings#settings.max_frame_size,

                                                  s_send_what_we_can(MaxFrameSize,
                                                                     StreamId,
                                                                     StreamFun,
                                                                     Streams)
                                          end)
                        end),
    {NewConnSendWindowSize, Streams}.

%% Send at the connection level
-spec c_send_what_we_can(ConnSendWindowSize :: integer(),
                         MaxFrameSize :: non_neg_integer(),
                         Streams :: [stream()],
                         StreamSet :: stream_set()
                        ) ->
                                integer().
%% If we hit =< 0, done
c_send_what_we_can(ConnSendWindowSize, _MFS, _Streams, _StreamSet)
  when ConnSendWindowSize =< 0 ->
    ConnSendWindowSize;
%% If we hit end of streams list, done
c_send_what_we_can(SWS, _MFS, [], _StreamSet) ->
    SWS;
%% Otherwise, try sending on the working stream
c_send_what_we_can(_SWS, MFS, [S|Streams], StreamSet) ->
    NewSWS = s_send_what_we_can(MFS, stream_id(S), fun(Stream) -> Stream end, StreamSet),
    c_send_what_we_can(NewSWS, MFS, Streams, StreamSet).

%% Send at the stream level
-spec s_send_what_we_can(MFS :: non_neg_integer(),
                         StreamId :: stream_id(),
                         StreamFun :: fun((stream()) -> stream()),
                         StreamSet :: stream_set()) ->
                                {integer(), stream()}.
s_send_what_we_can(MFS, StreamId, StreamFun0, Streams) ->
    StreamFun = 
    fun(#active_stream{queued_data=Data, trailers=undefined}) when is_atom(Data) ->
            ignore;
       (#active_stream{queued_data=Data, pid=Pid, trailers=Trailers}=S) when is_atom(Data) ->
            NewS = S#active_stream{trailers=undefined},
            {NewS, {0, [{send_trailers, Pid, Trailers}]}};
       (#active_stream{}=Stream) ->

            %% We're coming in here with three numbers we need to look at:
            %% * Connection send window size
            %% * Stream send window size
            %% * Maximimum frame size

            %% If none of them are zero, we have to send something, so we're
            %% going to figure out what's the biggest number we can send. If
            %% that's more than we have to send, we'll send everything and put
            %% an END_STREAM flag on it. Otherwise, we'll send as much as we
            %% can. Then, based on which number was the limiting factor, we'll
            %% make another decision

            %% If it was connection send window size, we're blocked at the
            %% connection level and we should break out of this recursion

            %% If it was stream send_window size, we're blocked on this
            %% stream, but other streams can still go, so we'll break out of
            %% this recursion, but not the connection level

            SWS = socket_send_window_size(Streams),
            SSWS = Stream#active_stream.send_window_size,
            QueueSize = byte_size(Stream#active_stream.queued_data),

            {MaxToSend, _ExitStrategy} =
            case SWS < SSWS of
                %% take the smallest of SWS or SSWS, read that
                %% from the queue and break it up into MFS frames
                true ->
                    {max(0, SWS), connection};
                _ ->
                    {max(0, SSWS), stream}
            end,

            {Frames, SentBytes, NewS} =
            case MaxToSend >= QueueSize of
                _ when MaxToSend == 0 ->
                    {[], 0, Stream};
                true ->
                    EndStream = case Stream#active_stream.body_complete of
                                    true ->
                                        case Stream of
                                            #active_stream{trailers=undefined} ->
                                                true;
                                            _ ->
                                                false
                                        end;
                                    false -> false
                                end,
                    %% We have the power to send everything
                    {chunk_to_frames(Stream#active_stream.queued_data, MFS, Stream#active_stream.id, EndStream, []),
                     QueueSize,
                     Stream#active_stream{
                       queued_data=done,
                       send_window_size=SSWS-QueueSize}};
                false ->
                    ct:pal("taking ~p of ~p", [MaxToSend, byte_size(Stream#active_stream.queued_data)]),
                    <<BinToSend:MaxToSend/binary,Rest/binary>> = Stream#active_stream.queued_data,
                    {chunk_to_frames(BinToSend, MFS, Stream#active_stream.id, false, []),
                     MaxToSend,
                     Stream#active_stream{
                       queued_data=Rest,
                       send_window_size=SSWS-MaxToSend}}
            end,


            %h2_stream:send_data(Stream#active_stream.pid, Frame),
            Actions = case Frames of
                          [] ->
                              [];
                          _ ->
                              [{send_data, Stream#active_stream.pid, Frames}]
                      end,
            %sock:send(Socket, h2_frame:to_binary(Frame)),

            {NewS1, NewActions} =
            case NewS of
                #active_stream{pid=Pid,
                               queued_data=done,
                               trailers=Trailers1} when Trailers1 /= undefined ->
                    {NewS#active_stream{trailers=undefined}, Actions ++ [{send_trailers, Pid, Trailers1}]};
                _ ->
                    {NewS, Actions}
            end,

            {NewS1, {SentBytes, NewActions}};
       (_) ->
            ignore
    end,

    case update(StreamId, fun(Stream0) -> StreamFun(StreamFun0(Stream0)) end, Streams) of
        ok ->
            ct:pal("no send on ~p", [StreamId]),
            NewSWS = socket_send_window_size(Streams),
            NewSWS;
        {ok, {BytesSent, Actions}} ->
            ct:pal("sent ~p on ~p", [BytesSent, StreamId]),
            NewSWS = decrement_socket_send_window(BytesSent, Streams),
            %% ok, its now safe to apply these actions
            apply_stream_actions(Actions),
            NewSWS
    end.

apply_stream_actions([]) ->
    ok;
apply_stream_actions([{send_data, Pid, Frames}|Tail]) ->
    [ h2_stream:send_data(Pid, Frame) || Frame <- Frames ],
    apply_stream_actions(Tail);
apply_stream_actions([{send_trailers, Pid, Trailers}]) ->
    h2_stream:send_trailers(Pid, Trailers).

chunk_to_frames(Bin, MaxFrameSize, StreamId, EndStream, Acc) when byte_size(Bin) > MaxFrameSize ->
    <<BinToSend:MaxFrameSize/binary, Rest/binary>> = Bin,
    chunk_to_frames(Rest, MaxFrameSize, StreamId, EndStream,
                    [{#frame_header{
                         stream_id=StreamId,
                         type=?DATA,
                         length=MaxFrameSize
                        },
                      h2_frame_data:new(BinToSend)}|Acc]);
chunk_to_frames(BinToSend, _MaxFrameSize, StreamId, EndStream, Acc) ->
    lists:reverse([{#frame_header{
                       stream_id=StreamId,
                       type=?DATA,
                       flags= case EndStream of
                                  true -> ?FLAG_END_STREAM;
                                  _ -> 0
                              end,
                       length=byte_size(BinToSend)
                      },
                    h2_frame_data:new(BinToSend)}|Acc]).

%% Record Accessors
-spec stream_id(
        Stream :: stream()) ->
                       stream_id().
stream_id(#idle_stream{id=SID}) ->
    SID;
stream_id(#active_stream{id=SID}) ->
    SID;
stream_id(#closed_stream{id=SID}) ->
    SID.

-spec pid(stream()) -> pid() | undefined.
pid(#active_stream{pid=Pid}) ->
    Pid;
pid(_) ->
    undefined.

-spec stream_set_type(stream_set()) -> client | server.
stream_set_type(StreamSet) ->
    StreamSet#stream_set.type.

-spec type(stream()) -> idle | active | closed.
type(#idle_stream{}) ->
    idle;
type(#active_stream{}) ->
    active;
type(#closed_stream{}) ->
    closed.

queued_data(#active_stream{queued_data=QD}) ->
    QD;
queued_data(_) ->
    undefined.

update_trailers(Trailers, Stream=#active_stream{}) ->
    Stream#active_stream{trailers=Trailers}.

update_data_queue(
  NewBody,
  BodyComplete,
  #active_stream{} = Stream) ->
    Stream#active_stream{
      queued_data=NewBody,
      body_complete=BodyComplete
     };
update_data_queue(_, _, S) ->
    S.

response(#closed_stream{
            response_headers=Headers,
            response_trailers=Trailers,
            response_body=Body}) ->
    Encoding = case lists:keyfind(<<"content-encoding">>, 1, Headers) of
        false -> identity;
        {_, Encoding0} -> binary_to_atom(Encoding0, 'utf8')
    end,
    {Headers, decode_body(Body, Encoding), Trailers};
response(_) ->
    no_response.

decode_body(Body, identity) ->
    Body;
decode_body(Body, gzip) ->
    zlib:gunzip(Body);
decode_body(Body, zip) ->
    zlib:unzip(Body);
decode_body(Body, compress) ->
    zlib:uncompress(Body);
decode_body(Body, deflate) ->
    Z = zlib:open(),
    ok = zlib:inflateInit(Z, -15),
    Decompressed = try zlib:inflate(Z, Body) catch E:V -> {E,V} end,
    ok = zlib:inflateEnd(Z),
    ok = zlib:close(Z),
    iolist_to_binary(Decompressed).

recv_window_size(#active_stream{recv_window_size=RWS}) ->
    RWS;
recv_window_size(_) ->
    undefined.

decrement_recv_window(
  L,
  #active_stream{recv_window_size=RWS}=Stream
 ) ->
    Stream#active_stream{
      recv_window_size=RWS-L
     };
decrement_recv_window(_, S) ->
    S.

decrement_socket_recv_window(L, #stream_set{atomics = Atomics}) ->
    atomics:sub_get(Atomics, ?RECV_WINDOW_SIZE, L).

increment_socket_recv_window(L, #stream_set{atomics = Atomics}) ->
    atomics:add_get(Atomics, ?RECV_WINDOW_SIZE, L).

socket_recv_window_size(#stream_set{atomics = Atomics}) ->
    atomics:get(Atomics, ?RECV_WINDOW_SIZE).

set_socket_recv_window_size(Value, #stream_set{atomics = Atomics}) ->
    atomics:put(Atomics, ?RECV_WINDOW_SIZE, Value).

decrement_socket_send_window(L, #stream_set{atomics = Atomics}) ->
    atomics:sub_get(Atomics, ?SEND_WINDOW_SIZE, L).

increment_socket_send_window(L, #stream_set{atomics = Atomics}) ->
    atomics:add_get(Atomics, ?SEND_WINDOW_SIZE, L).

socket_send_window_size(#stream_set{atomics = Atomics}) ->
    atomics:get(Atomics, ?SEND_WINDOW_SIZE).

set_socket_send_window_size(Value, #stream_set{atomics = Atomics}) ->
    atomics:put(Atomics, ?SEND_WINDOW_SIZE, Value).


send_window_size(#active_stream{send_window_size=SWS}) ->
    SWS;
send_window_size(_) ->
    undefined.

increment_send_window_size(
  WSI,
  #active_stream{send_window_size=SWS}=Stream) ->
    Stream#active_stream{
      send_window_size=SWS+WSI
     };
increment_send_window_size(_WSI, Stream) ->
    Stream.

stream_pid(#active_stream{pid=Pid}) ->
    Pid;
stream_pid(_) ->
    undefined.

%% the false clause is here as an artifact of us using a simple
%% lists:keyfind
notify_pid(#idle_stream{}) ->
    undefined;
notify_pid(#active_stream{notify_pid=Pid}) ->
    Pid;
notify_pid(#closed_stream{notify_pid=Pid}) ->
    Pid.

%% The number of #active_stream records
-spec my_active_count(stream_set()) -> non_neg_integer().
my_active_count(SS) ->
    (get_my_peers(SS))#peer_subset.active_count.

%% The number of #active_stream records
-spec their_active_count(stream_set()) -> non_neg_integer().
their_active_count(SS) ->
    (get_their_peers(SS))#peer_subset.active_count.

%% The list of #active_streams, and un gc'd #closed_streams
-spec my_active_streams(stream_set()) -> [stream()].
my_active_streams(SS) ->
    case SS#stream_set.type of
        client ->
            ets:select(SS#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 1 -> S;
                                                          (S=#closed_stream{id=Id}) when Id rem 2 == 1 -> S
                                                       end));
        server ->
            ets:select(SS#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 0 -> S;
                                                          (S=#closed_stream{id=Id}) when Id rem 2 == 0 -> S
                                                       end))
    end.

%% The list of #active_streams, and un gc'd #closed_streams
-spec their_active_streams(stream_set()) -> [stream()].
their_active_streams(SS) ->
    case SS#stream_set.type of
        client ->
            ets:select(SS#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 0 -> S;
                                                          (S=#closed_stream{id=Id}) when Id rem 2 == 0 -> S
                                                       end));
        server ->
            ets:select(SS#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 1 -> S;
                                                          (S=#closed_stream{id=Id}) when Id rem 2 == 1 -> S
                                                       end))
    end.

%% My MCS (max_active)
-spec my_max_active(stream_set()) -> non_neg_integer().
my_max_active(SS) ->
    (get_my_peers(SS))#peer_subset.max_active.

%% Their MCS (max_active)
-spec their_max_active(stream_set()) -> non_neg_integer().
their_max_active(SS) ->
    (get_their_peers(SS))#peer_subset.max_active.

take_lock(StreamSet, Locks0, Fun) ->
    Locks = Locks0 -- [socket, streams],
    [ take_lock(lock_to_index(Lock), StreamSet) || Lock <- lists:sort(Locks) ],
    Res = Fun(),
    [ release_lock(lock_to_index(Lock), StreamSet) || Lock <- lists:sort(Locks) ],
    Res.

take_lock(Index, StreamSet=#stream_set{atomics=Atomics}) ->
    ct:pal("~p trying to take lock ~p", [self(), Index]),
    case atomics:compare_exchange(Atomics, Index, ?UNLOCKED, ?EDITING_LOCK) of
        ok ->
            ct:pal("~p got lock ~p", [self(), Index]),
            do_hold_lock(Index, StreamSet, ?SHARED_LOCK, ?SHARED_LOCK),
            ok;
        ?SHARED_LOCK ->
            ct:pal("~p got already shared lock ~p ~p", [self(), Index, get_holders(Index, StreamSet)]),
            %% someone else already has a shared lock, this is fine
            hold_lock(Index, StreamSet, ?SHARED_LOCK),
            ok;
        ?EXCLUSIVE_LOCK ->
            JustUs = [self()],
            case atomics:compare_exchange(Atomics, Index, ?EXCLUSIVE_LOCK, ?EDITING_LOCK) of
                ok ->
                    case ets:select_count(StreamSet#stream_set.table, ets:fun2ms(fun(#lock{id={lock, I}, holders=H}=Lock) when I == Index, H == JustUs -> true end)) of
                        1 ->
                            ct:pal("~p taking a shared lock ~p we already own exclusively", [self(), Index]),
                            do_hold_lock(Index, StreamSet, ?SHARED_LOCK, ?EXCLUSIVE_LOCK);
                        0 ->
                            ok = atomics:compare_exchange(Atomics, Index, ?EDITING_LOCK, ?EXCLUSIVE_LOCK),
                            ct:pal("~p waiting for exclusive lock ~p to release ~p", [self(), Index, get_holders(Index, StreamSet)]),
                            %% need to wait for the exclusive access to be released
                            wait_lock(Index, StreamSet),
                            take_lock(Index, StreamSet)
                    end;
                _ ->
                    take_lock(Index, StreamSet)
            end;
        ?EDITING_LOCK ->
            ct:pal("~p waiting for lock ~p to be edited ~p", [self(), Index, get_holders(Index, StreamSet)]),
            timer:sleep(10),
            take_lock(Index, StreamSet)
    end.

take_exclusive_lock(StreamSet, Locks0, Fun) ->
    Locks = Locks0 -- [socket, streams],
    LockRes = [ {take_exclusive_lock(lock_to_index(Lock), StreamSet), lock_to_index(Lock)} || Lock <- lists:sort(Locks) ],
    case lists:all(fun({Res, _Index}) -> Res == ok end, LockRes) of
        false ->
            %% release any we got
            [ release_exclusive_lock(Index, StreamSet) || {ok, Index} <- LockRes ],
            timer:sleep(10),
            take_exclusive_lock(StreamSet, Locks, Fun);
        true ->
            Res = Fun(),
            [ release_exclusive_lock(lock_to_index(Lock), StreamSet) || Lock <- lists:sort(Locks) ],
            Res
    end.


take_exclusive_lock(Index, StreamSet=#stream_set{atomics=Atomics}) ->
    ct:pal("~p trying to take exclusive lock ~p", [self(), Index]),
    case atomics:compare_exchange(Atomics, Index, ?UNLOCKED, ?EDITING_LOCK) of
        ok ->
            ct:pal("~p took exclusive lock ~p", [self(), Index]),
            do_hold_lock(Index, StreamSet, ?EXCLUSIVE_LOCK, ?EXCLUSIVE_LOCK),
            ok;
        ?SHARED_LOCK ->
            %% check if its only us holding the lock
            case atomics:compare_exchange(Atomics, Index, ?SHARED_LOCK, ?EDITING_LOCK) of
                ok ->
                    case lists:all(fun(E) -> E == self() end, get_holders(Index, StreamSet)) of
                        true ->
                            %%ok = atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EDITING_LOCK, ?EXCLUSIVE_LOCK),
                            %%push_lockstack(StreamSet, Index, ?EXCLUSIVE_LOCK),
                            do_hold_lock(Index, StreamSet, ?EXCLUSIVE_LOCK, ?EXCLUSIVE_LOCK),
                            ct:pal("~p lock ~p promoted to exclusive", [self(), Index]),
                            ok;
                        false ->
                            ok = atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EDITING_LOCK, ?SHARED_LOCK),
                            take_exclusive_lock(Index, StreamSet)
                    end;
                _ ->
                    take_exclusive_lock(Index, StreamSet)
            end;
        ?EXCLUSIVE_LOCK ->
            JustUs = [self()],
            case atomics:compare_exchange(Atomics, Index, ?EXCLUSIVE_LOCK, ?EDITING_LOCK) of
                ok ->
                    case ets:select_count(StreamSet#stream_set.table, ets:fun2ms(fun(#lock{id={lock, I}, holders=H}=Lock) when I == Index, H == JustUs -> true end)) of
                        1 ->
                            ct:pal("~p already held exclusive lock ~p", [self(), Index]),
                            do_hold_lock(Index, StreamSet, ?EXCLUSIVE_LOCK, ?EXCLUSIVE_LOCK),
                            ok;
                        0 ->
                            ok = atomics:compare_exchange(Atomics, Index, ?EDITING_LOCK, ?EXCLUSIVE_LOCK),
                            ct:pal("~p exclusive lock ~p is held by ~p", [self(), Index, get_holders(Index, StreamSet)]),
                            %% need to wait for the exclusive access to be released
                            wait_lock(Index, StreamSet),
                            take_exclusive_lock(Index, StreamSet)
                    end;
                _ ->
                    take_exclusive_lock(Index, StreamSet)
            end;
        ?EDITING_LOCK ->
            ct:pal("~p waiting for lock ~p to be edited ~p", [self(), Index, get_holders(Index, StreamSet)]),
            timer:sleep(10),
            take_exclusive_lock(Index, StreamSet)
    end.


hold_lock(Index, StreamSet, Type) ->
    ct:pal("~p hold lock ~p", [self(), Index]),
    OldState = atomics:get(StreamSet#stream_set.atomics, Index),
    case OldState /= ?EDITING_LOCK andalso atomics:compare_exchange(StreamSet#stream_set.atomics, Index, OldState, ?EDITING_LOCK) == ok of
        true ->
            do_hold_lock(Index, StreamSet, Type, OldState);
        _Other ->
            ct:pal("~p waiting to hold lock ~p", [self(), Index]),
            timer:sleep(10),
            hold_lock(Index, StreamSet, Type)
    end.

do_hold_lock(Index, StreamSet, Type, NextState) ->
    Self = self(),
    1 = ets:select_replace(StreamSet#stream_set.table,
                           ets:fun2ms(fun(#lock{id={lock, I}, holders=H}=Lock) when I == Index -> Lock#lock{holders=[Self|H]} end)),
    ok = atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EDITING_LOCK, NextState),
    push_lockstack(StreamSet, Index, Type),
    ct:pal("~p holding lock ~p", [self(), Index]),
    ok.


remove_holder(Index, Holder, StreamSet) ->
    ct:pal("~p remove holder lock ~p", [self(), Index]),
    OldState = atomics:get(StreamSet#stream_set.atomics, Index),
    case OldState /= ?EDITING_LOCK andalso atomics:compare_exchange(StreamSet#stream_set.atomics, Index, OldState, ?EDITING_LOCK) == ok of
        true ->
            Holders = get_holders(Index, StreamSet),
            NewHolders = Holders -- [Holder],
            case ets:select_replace(StreamSet#stream_set.table,
                                   ets:fun2ms(fun(#lock{id={lock, I}, holders=H}=Lock) when I == Index, H == Holders -> Lock#lock{holders=NewHolders} end)) of
                1 ->
                    case NewHolders of
                        [] ->
                            ok = atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EDITING_LOCK, ?UNLOCKED);
                        _ ->
                            ok = atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EDITING_LOCK, OldState)
                    end,
                    ct:pal("~p removed holder lock ~p", [self(), Index]),
                    ok;
                0 ->
                    ok = atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EDITING_LOCK, OldState),
                    timer:sleep(10),
                    remove_holder(Index, Holder, StreamSet)
            end;
        _Other ->
            timer:sleep(10),
            ct:pal("~p waiting remove holder ~p ~p", [self(), Index, Holder]),
            remove_holder(Index, Holder, StreamSet)
    end.


wait_lock(Index, StreamSet) ->
    ct:pal("~p wait lock ~p", [self(), Index]),
    OldState = atomics:get(StreamSet#stream_set.atomics, Index),
    case OldState /= ?EDITING_LOCK andalso  atomics:compare_exchange(StreamSet#stream_set.atomics, Index, OldState, ?EDITING_LOCK) == ok of
        true when OldState == ?UNLOCKED ->
            ok = atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EDITING_LOCK, OldState),
            ok;
        true ->
            case get_holders(Index, StreamSet) of
                [] ->
                    ok = atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EDITING_LOCK, OldState),
                    ct:pal("~p waiting for lock ~p to have holders to wait", [self(), Index]),
                    timer:sleep(10),
                    wait_lock(Index, StreamSet);
                Holders ->
                    Self = self(),
                    Ref = make_ref(),
                    1 = ets:select_replace(StreamSet#stream_set.table,
                                           ets:fun2ms(fun(#lock{id={lock, I}, waiters=H}=Lock) when I == Index -> Lock#lock{waiters=[{Self, Ref}|H]} end)),
                    Monitors = [ erlang:monitor(process, Holder) || Holder <- Holders ],
                    ok = atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EDITING_LOCK, OldState),
                    ct:pal("~p waiting on lock ~p", [self(), Index]),
                    wait_ref(Index, Ref, Monitors, StreamSet)
            end;
        _Other ->
            ct:pal("~p waiting for lock ~p to be edited to wait", [self(), Index]),
            timer:sleep(10),
            wait_lock(Index, StreamSet)
    end.

wait_ref(Index, _Ref, [], StreamSet) ->
    atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?SHARED_LOCK, ?UNLOCKED),
    atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EXCLUSIVE_LOCK, ?UNLOCKED),
    ct:pal("~p all holders for lock ~p died, try to get the lock again", [self(), Index]),
    ok;
wait_ref(Index, Ref, Monitors, StreamSet) ->
    receive
        {'DOWN', MRef, process, Handler, Reason}=Msg ->
            ct:pal("lock holder ~p ~p died with reason ~p", [Index, Handler, Reason]),
            case lists:member(MRef, Monitors) of
                true ->
                    remove_holder(Index, Handler, StreamSet),
                    wait_ref(Index, Ref, Monitors -- [MRef], StreamSet);
                false ->
                    self() ! Msg,
                    wait_ref(Index, Ref, Monitors, StreamSet)
            end;
        {Ref, unlocked} ->
            [erlang:demonitor(Monitor, [flush]) || Monitor <- Monitors ],
            ok
    after 1000 ->
              case ets:select_count(StreamSet#stream_set.table, ets:fun2ms(fun(#lock{id={lock, I}, holders=[]}=Lock) when I == Index -> true end)) of
                  1 ->
                      [erlang:demonitor(Monitor, [flush]) || Monitor <- Monitors ],
                      ok;
                  _ ->
                      ct:pal("~p deadlocked on ~p", [self(), Index]),
                      Lock = hd(ets:lookup(StreamSet#stream_set.table, {lock, Index})),
                      ct:pal("Lock ~p", [Lock]),
                      [ ct:pal("~p", [erlang:process_info(P)]) || P <- Lock#lock.holders ],
                      wait_ref(Index, Ref, Monitors, StreamSet)
              end
    end.

release_lock(Index, StreamSet) ->
    ct:pal("~p release lock ~p ~p", [self(), Index, get_lockstack(StreamSet, Index)]),
    OldState = atomics:get(StreamSet#stream_set.atomics, Index),
    case OldState /= ?EDITING_LOCK andalso atomics:compare_exchange(StreamSet#stream_set.atomics, Index, OldState, ?EDITING_LOCK) == ok of
        true ->
            case ets:lookup(StreamSet#stream_set.table, {lock, Index}) of
                [#lock{holders=Holders, waiters=Waiters}] ->
                    Self = self(),
                    %% filter out any dead holders and ourself (but just once)
                    case [ P || P <- Holders, erlang:is_process_alive(P)] -- [Self] of
                        [] ->
                            %% we were the last holder and not holding it re-entrantly
                            case ets:select_replace(StreamSet#stream_set.table, ets:fun2ms(fun(#lock{id={lock, I}, holders=H}=Lock) when I == Index, H == Holders -> Lock#lock{holders=[]} end)) of
                                1 ->
                                    [?SHARED_LOCK] = get_lockstack(StreamSet, Index),
                                    ?SHARED_LOCK = pop_lockstack(StreamSet, Index),
                                    ct:pal("~p oldstate for ~p was ~p, expect ~p", [self(), Index, OldState, ?SHARED_LOCK]),
                                    %OldState = ?SHARED_LOCK,
                                    ok = atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EDITING_LOCK, ?UNLOCKED),
                                    [ Pid ! {Ref, unlocked} || {Pid, Ref} <- Waiters ],
                                    ok;
                                _N ->
                                    ct:pal("~p failed to update holders on release lock ~p", [self(), Index]),
                                    ok = atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EDITING_LOCK, OldState),
                                    timer:sleep(10),
                                    release_lock(Index, StreamSet)
                            end;
                        OtherHolders ->
                            case ets:select_replace(StreamSet#stream_set.table, ets:fun2ms(fun(#lock{id={lock, I}, holders=H}=Lock) when I == Index, H == Holders -> Lock#lock{holders=OtherHolders} end)) of
                                1 ->
                                    ?SHARED_LOCK = pop_lockstack(StreamSet, Index),
                                    NewState = case get_lockstack(StreamSet, Index) of
                                                   [?EXCLUSIVE_LOCK|_] ->
                                                       ?EXCLUSIVE_LOCK;
                                                   _ when OldState == ?UNLOCKED ->
                                                       ?UNLOCKED;
                                                   _ ->
                                                       ?SHARED_LOCK
                                               end,
                                    ct:pal("~p oldstate for ~p was ~p, expect ~p", [self(), Index, OldState, NewState]),
                                    OldState = NewState,
                                    ok = atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EDITING_LOCK, NewState),
                                    ok;
                                _ ->
                                    ct:pal("~p failed to update holders on release lock ~p", [self(), Index]),
                                    ok = atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EDITING_LOCK, OldState),
                                    timer:sleep(10),
                                    release_lock(Index, StreamSet)
                            end
                    end
            end;
        _Other ->
            ct:pal("~p waiting for lock ~p to be edited to release ~p", [self(), Index, OldState]),
            timer:sleep(10),
            release_lock(Index, StreamSet)
    end.

release_exclusive_lock(Index, StreamSet) ->
    ct:pal("~p releasing exclusive lock ~p", [self(), Index]),
    OldState = atomics:get(StreamSet#stream_set.atomics, Index),
    case OldState /= ?EDITING_LOCK andalso atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EXCLUSIVE_LOCK, ?EDITING_LOCK) == ok of
        true ->
            Self = self(),
            case ets:lookup(StreamSet#stream_set.table, {lock, Index}) of
                [#lock{holders=H, waiters=Waiters}] when H /= [Self] ->
                    %% we're holding this lock more than once
                    NewHolders = H -- [Self],
                    ct:pal("~p other holders for lock ~p ~p", [self(), Index, NewHolders]),
                    CleanedHolders = [ P || P <- NewHolders, P == Self ],
                    %%true = lists:all(fun(E) -> E == Self end, NewHolders),
                    ct:pal("~p removed stale holders ~p from lock ~p", [self(), NewHolders -- CleanedHolders, Index]),
                    1 = ets:select_replace(StreamSet#stream_set.table, ets:fun2ms(fun(#lock{id={lock, I}}=Lock) when I == Index -> Lock#lock{waiters=Waiters, holders=CleanedHolders} end)),
                    ?EXCLUSIVE_LOCK = pop_lockstack(StreamSet, Index),
                    OldState = ?EXCLUSIVE_LOCK,

                    NewState = case CleanedHolders of
                                   [] ->
                                       ?UNLOCKED;
                                   _ ->
                                       %% should still be something in the stack
                                       hd(get_lockstack(StreamSet, Index))
                               end,
                    ok = atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EDITING_LOCK, NewState),
                    case NewState of
                        ?UNLOCKED ->
                            ct:pal("~p is released exclusive lock ~p", [self(), Index]);
                        ?EXCLUSIVE_LOCK ->
                            ct:pal("~p was holding exclusive lock ~p re-entranty", [self(), Index]);
                        ?SHARED_LOCK ->
                            ct:pal("~p was holding exclusive lock ~p re-entranty promoted from a shared lock", [self(), Index])
                    end,
                    ok;
                [#lock{waiters=Waiters}] ->
                    %% we should be holding this only once
                    ?EXCLUSIVE_LOCK = pop_lockstack(StreamSet, Index),
                    [] = get_lockstack(StreamSet, Index),
                    OldState = ?EXCLUSIVE_LOCK,
                    1 = ets:select_replace(StreamSet#stream_set.table, ets:fun2ms(fun(#lock{id={lock, I}}=Lock) when I == Index -> Lock#lock{waiters=[], holders=[]} end)),
                    ok = atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EDITING_LOCK, ?UNLOCKED),
                    ct:pal("~p released exclusive lock ~p", [self(), Index]),
                    [ Pid ! {Ref, unlocked} || {Pid, Ref} <- Waiters ],
                    ok
            end;
        _Other ->
            ct:pal("~p waiting for lock ~p to be edited to release exclusive", [self(), Index]),
            timer:sleep(10),
            release_exclusive_lock(Index, StreamSet)
    end.

lock_to_index(socket) -> ?SEND_LOCK;
lock_to_index(settings) -> ?SETTINGS_LOCK;
lock_to_index(streams) -> ?STREAMS_LOCK;
lock_to_index(encoder) -> ?ENCODER_LOCK.

get_holders(Index, StreamSet) ->
    [#lock{holders=Holders}] = ets:lookup(StreamSet#stream_set.table, {lock, Index}),
    Holders.

get_lockstack(StreamSet, Index) ->
    case erlang:get({StreamSet#stream_set.table, Index}) of
        undefined ->
            [];
        Other ->
            Other
    end.

push_lockstack(StreamSet, Index,  Type) ->
    erlang:put({StreamSet#stream_set.table, Index}, [Type|get_lockstack(StreamSet, Index)]).

pop_lockstack(StreamSet, Index) ->
    %% this will crash on no stack, and this is ok
    [Hd|Tl] = get_lockstack(StreamSet, Index),
    erlang:put({StreamSet#stream_set.table, Index}, Tl),
    Hd.

