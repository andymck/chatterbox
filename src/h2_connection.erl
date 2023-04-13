-module(h2_connection).
-include("http2.hrl").
-behaviour(gen_statem).

%% Start/Stop API
-export([
         start_client/2,
         start_client/6,
         start_client_link/2,
         start_client_link/6,
         start_ssl_upgrade_link/6,
         start_server_link/3,
         become/1,
         become/2,
         become/3,
         stop/1
        ]).

%% HTTP Operations
-export([
         send_headers/3,
         send_headers/4,
         send_trailers/3,
         send_trailers/4,
         actually_send_trailers/3,
         send_body/3,
         send_body/4,
         send_request/3,
         send_request/5,
         send_ping/1,
         is_push/1,
         new_stream/1,
         new_stream/2,
         new_stream/4,
         new_stream/6,
         new_stream/7,
         send_promise/4,
         get_response/2,
         get_peer/1,
         get_peercert/1,
         get_streams/1,
         send_window_update/2,
         update_settings/2,
         send_frame/2,
         rst_stream/3
        ]).

%% gen_statem callbacks
-export(
   [
    init/1,
    callback_mode/0,
    code_change/4,
    terminate/3
   ]).

%% gen_statem states
-export([
         listen/3,
         handshake/3,
         connected/3,
         continuation/3,
         closing/3
        ]).

-export([
         go_away/3
        ]).

-record(h2_listening_state, {
          ssl_options   :: [ssl:tls_option()],
          listen_socket :: ssl:sslsocket() | inet:socket(),
          transport     :: gen_tcp | ssl,
          listen_ref    :: non_neg_integer(),
          acceptor_callback = fun chatterbox_sup:start_socket/0 :: fun(),
          server_settings = #settings{} :: settings()
         }).

-record(continuation_state, {
          stream_id                 :: stream_id(),
          promised_id = undefined   :: undefined | stream_id(),
          frames      = []          :: [h2_frame:frame()],
          type                      :: headers | push_promise | trailers,
          end_stream  = false       :: boolean(),
          end_headers = false       :: boolean()
}).

-record(connection, {
          type = undefined :: client | server | undefined,
          receiver :: pid() | undefined,
          ssl_options = [],
          listen_ref :: non_neg_integer() | undefined,
          socket = undefined :: sock:socket(),
          peer_settings = #settings{} :: settings(),
          self_settings = #settings{} :: settings(),
          send_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE :: integer(),
          decode_context = hpack:new_context() :: hpack:context(),
          encode_context = hpack:new_context() :: hpack:context(),
          settings_sent = queue:new() :: queue:queue(),
          streams :: h2_stream_set:stream_set(),
          stream_callback_mod :: module() | undefined,
          stream_callback_opts :: list() | undefined,
          buffer = empty :: empty | {binary, binary()} | {frame, h2_frame:header(), binary()},
          continuation = undefined :: undefined | #continuation_state{},
          pings = #{} :: #{binary() => {pid(), non_neg_integer()}},
          %% if true then set a stream as garbage in the stream_set
          garbage_on_end = false :: boolean()
}).

-define(HIBERNATE_AFTER_DEFAULT_MS, infinity).

-type connection() :: #connection{}.

-type send_option() :: {send_end_stream, boolean()}.
-type send_opts() :: [send_option()].

-export_type([send_option/0, send_opts/0]).

-ifdef(OTP_RELEASE).
-define(ssl_accept(ClientSocket, SSLOptions), ssl:handshake(ClientSocket, SSLOptions)).
-else.
-define(ssl_accept(ClientSocket, SSLOptions), ssl:ssl_accept(ClientSocket, SSLOptions)).
-endif.

-spec start_client_link(gen_tcp | ssl,
                        inet:ip_address() | inet:hostname(),
                        inet:port_number(),
                        [ssl:tls_option()],
                        settings(),
                        map()
                       ) ->
                               {ok, pid()} | ignore | {error, term()}.
start_client_link(Transport, Host, Port, SSLOptions, Http2Settings, ConnectionSettings) ->
    HibernateAfterTimeout = maps:get(hibernate_after, ConnectionSettings, ?HIBERNATE_AFTER_DEFAULT_MS),
    gen_statem:start_link(?MODULE, {client, Transport, Host, Port, SSLOptions, Http2Settings, ConnectionSettings}, [{hibernate_after, HibernateAfterTimeout}]).

-spec start_client(gen_tcp | ssl,
                        inet:ip_address() | inet:hostname(),
                        inet:port_number(),
                        [ssl:tls_option()],
                        settings(),
                        map()
                       ) ->
                               {ok, pid()} | ignore | {error, term()}.
start_client(Transport, Host, Port, SSLOptions, Http2Settings, ConnectionSettings) ->
    HibernateAfterTimeout = maps:get(hibernate_after, ConnectionSettings, ?HIBERNATE_AFTER_DEFAULT_MS),
    gen_statem:start(?MODULE, {client, Transport, Host, Port, SSLOptions, Http2Settings, ConnectionSettings}, [{hibernate_after, HibernateAfterTimeout}]).

-spec start_client_link(socket(),
                        settings()
                       ) ->
                               {ok, pid()} | ignore | {error, term()}.
start_client_link({Transport, Socket}, Http2Settings) ->
    HibernateAfterTimeout = ?HIBERNATE_AFTER_DEFAULT_MS,
    gen_statem:start_link(?MODULE, {client, {Transport, Socket}, Http2Settings}, [{hibernate_after, HibernateAfterTimeout}]).

-spec start_client(socket(),
                        settings()
                       ) ->
                               {ok, pid()} | ignore | {error, term()}.
start_client({Transport, Socket}, Http2Settings) ->
    HibernateAfterTimeout = ?HIBERNATE_AFTER_DEFAULT_MS,
    gen_statem:start(?MODULE, {client, {Transport, Socket}, Http2Settings}, [{hibernate_after, HibernateAfterTimeout}]).

-spec start_ssl_upgrade_link(inet:ip_address() | inet:hostname(),
                             inet:port_number(),
                             binary(),
                             [ssl:tls_option()],
                             settings(),
                             map()
                            ) ->
                                    {ok, pid()} | ignore | {error, term()}.
start_ssl_upgrade_link(Host, Port, InitialMessage, SSLOptions, Http2Settings, ConnectionSettings) ->
    HibernateAfterTimeout = maps:get(hibernate_after, ConnectionSettings, ?HIBERNATE_AFTER_DEFAULT_MS),
    gen_statem:start_link(?MODULE, {client_ssl_upgrade, Host, Port, InitialMessage, SSLOptions, Http2Settings, ConnectionSettings}, [{hibernate_after, HibernateAfterTimeout}]).

-spec start_server_link(socket(),
                        [ssl:tls_option()],
                        settings()) ->
                               {ok, pid()} | ignore | {error, term()}.
start_server_link({Transport, ListenSocket}, SSLOptions, Http2Settings) ->
    HibernateAfterTimeout = ?HIBERNATE_AFTER_DEFAULT_MS,
    gen_statem:start_link(?MODULE, {server, {Transport, ListenSocket}, SSLOptions, Http2Settings}, [{hibernate_after, HibernateAfterTimeout}]).

-spec become(socket()) -> no_return().
become(Socket) ->
    become(Socket, chatterbox:settings(server)).

-spec become(socket(), settings()) -> no_return().
become(Socket, Http2Settings) ->
    become(Socket, Http2Settings, #{}).

-spec become(socket(), settings(), map()) -> no_return().
become({Transport, Socket}, Http2Settings, ConnectionSettings) ->
    ok = sock:setopts({Transport, Socket}, [{packet, raw}, binary]),
    case start_http2_server(Http2Settings,
                           #connection{
                              stream_callback_mod =
                                  maps:get(stream_callback_mod, ConnectionSettings,
                                           application:get_env(chatterbox, stream_callback_mod, chatterbox_static_stream)),
                              stream_callback_opts =
                                  maps:get(stream_callback_opts, ConnectionSettings,
                                           application:get_env(chatterbox, stream_callback_opts, [])),
                              streams = h2_stream_set:new(server),
                              socket = {Transport, Socket}
                             }) of
        {_, handshake, NewState} ->
            gen_statem:enter_loop(?MODULE,
                                  [],
                                  handshake,
                                  NewState);
        {_, closing, _NewState} ->
            sock:close({Transport, Socket}),
            exit(normal)
    end.

%% Init callback
init({client, Transport, Host, Port, SSLOptions, Http2Settings, ConnectionSettings}) ->
    ConnectTimeout = maps:get(connect_timeout, ConnectionSettings, 5000),
    TcpUserTimeout = maps:get(tcp_user_timeout, ConnectionSettings, 0),
    SocketOptions = maps:get(socket_options, ConnectionSettings, []),
    case Transport:connect(Host, Port, client_options(Transport, SSLOptions, SocketOptions), ConnectTimeout) of
        {ok, Socket} ->
            ok = sock:setopts({Transport, Socket}, [{packet, raw}, binary, {active, false}]),
            case TcpUserTimeout of
                0 -> ok;
                _ -> sock:setopts({Transport, Socket}, [{raw,6,18,<<TcpUserTimeout:32/native>>}])
            end,
            Transport:send(Socket, <<?PREFACE>>),
            Streams = h2_stream_set:new(client),
            Flow = application:get_env(chatterbox, client_flow_control, auto),
            Receiver = spawn_data_receiver({Transport, Socket}, Streams, Flow),
            InitialState =
                #connection{
                   type = client,
                   receiver=Receiver,
                   garbage_on_end = maps:get(garbage_on_end, ConnectionSettings, false),
                   stream_callback_mod = maps:get(stream_callback_mod, ConnectionSettings, undefined),
                   stream_callback_opts = maps:get(stream_callback_opts, ConnectionSettings, []),
                   streams = Streams,
                   socket = {Transport, Socket}
                  },
            {ok,
             handshake,
             send_settings(Http2Settings, InitialState),
             4500};
        {error, Reason} ->
            {stop, {shutdown, Reason}}
    end;
init({client_ssl_upgrade, Host, Port, InitialMessage, SSLOptions, Http2Settings, ConnectionSettings}) ->
    ConnectTimeout = maps:get(connect_timeout, ConnectionSettings, 5000),
    SocketOptions = maps:get(socket_options, ConnectionSettings, []),
    case gen_tcp:connect(Host, Port, [{active, false}], ConnectTimeout) of
        {ok, TCP} ->
            gen_tcp:send(TCP, InitialMessage),
            case ssl:connect(TCP, client_options(ssl, SSLOptions, SocketOptions)) of
                {ok, Socket} ->
                    ok = ssl:setopts(Socket, [{packet, raw}, binary, {active, false}]),
                    ssl:send(Socket, <<?PREFACE>>),
                    Streams = h2_stream_set:new(client),
                    Flow = application:get_env(chatterbox, client_flow_control, auto),
                    Receiver = spawn_data_receiver({ssl, Socket}, Streams, Flow),
                    InitialState =
                        #connection{
                           type = client,
                           receiver=Receiver,
                           garbage_on_end = maps:get(garbage_on_end, ConnectionSettings, false),
                           stream_callback_mod = maps:get(stream_callback_mod, ConnectionSettings, undefined),
                           stream_callback_opts = maps:get(stream_callback_opts, ConnectionSettings, []),
                           streams = Streams,
                           socket = {ssl, Socket}
                          },
                    {ok,
                     handshake,
                     send_settings(Http2Settings, InitialState),
                     4500};
                {error, Reason} ->
                    {stop, {shutdown, Reason}}
            end;
        {error, Reason} ->
            {stop, {shutdown, Reason}}
    end;
init({server, {Transport, ListenSocket}, SSLOptions, Http2Settings}) ->
    %% prim_inet:async_accept is dope. It says just hang out here and
    %% wait for a message that a client has connected. That message
    %% looks like:
    %% {inet_async, ListenSocket, Ref, {ok, ClientSocket}}
    case prim_inet:async_accept(ListenSocket, -1) of
        {ok, Ref} ->
            {ok,
             listen,
             #h2_listening_state{
                ssl_options = SSLOptions,
                listen_socket = ListenSocket,
                listen_ref = Ref,
                transport = Transport,
                server_settings = Http2Settings
               }}; %% No timeout here, it's just a listener
        {error, Reason} ->
            {stop, {shutdown, Reason}}
    end.

callback_mode() ->
    state_functions.

send_frame(Pid, Bin)
  when is_binary(Bin); is_list(Bin) ->
    gen_statem:cast(Pid, {send_bin, Bin});
send_frame(Pid, Frame) ->
    gen_statem:cast(Pid, {send_frame, Frame}).

-spec send_headers(pid(), stream_id(), hpack:headers()) -> ok.
send_headers(Pid, StreamId, Headers) ->
    gen_statem:cast(Pid, {send_headers, StreamId, Headers, []}),
    ok.

-spec send_headers(pid(), stream_id(), hpack:headers(), send_opts()) -> ok.
send_headers(Pid, StreamId, Headers, Opts) ->
    gen_statem:cast(Pid, {send_headers, StreamId, Headers, Opts}),
    ok.

-spec rst_stream(pid(), stream_id(), error_code()) -> ok.
rst_stream(Pid, StreamId, ErrorCode) ->
    gen_statem:cast(Pid, {rst_stream, StreamId, ErrorCode}),
    ok.

-spec send_trailers(pid(), stream_id(), hpack:headers()) -> ok.
send_trailers(Pid, StreamId, Trailers) ->
    gen_statem:cast(Pid, {send_trailers, StreamId, Trailers, []}),
    ok.

-spec send_trailers(pid(), stream_id(), hpack:headers(), send_opts()) -> ok.
send_trailers(Pid, StreamId, Trailers, Opts) ->
    gen_statem:cast(Pid, {send_trailers, StreamId, Trailers, Opts}),
    ok.

actually_send_trailers(Pid, StreamId, Trailers) ->
    gen_statem:cast(Pid, {actually_send_trailers, StreamId, Trailers}),
    ok.

-spec send_body(pid(), stream_id(), binary()) -> ok.
send_body(Pid, StreamId, Body) ->
    gen_statem:cast(Pid, {send_body, StreamId, Body, []}),
    ok.
-spec send_body(pid(), stream_id(), binary(), send_opts()) -> ok.
send_body(Pid, StreamId, Body, Opts) ->
    gen_statem:cast(Pid, {send_body, StreamId, Body, Opts}),
    ok.

-spec send_request(pid(), hpack:headers(), binary()) -> ok.
send_request(Pid, Headers, Body) ->
    gen_statem:call(Pid, {send_request, self(), Headers, Body}, infinity),
    ok.

-spec send_request(pid(), hpack:headers(), binary(), atom(), list()) -> ok.
send_request(Pid, Headers, Body, CallbackMod, CallbackOpts) ->
    gen_statem:call(Pid, {send_request, self(), Headers, Body, CallbackMod, CallbackOpts}, infinity),
    ok.

-spec send_ping(pid()) -> ok.
send_ping(Pid) ->
    gen_statem:call(Pid, {send_ping, self()}, infinity),
    ok.

-spec get_peer(pid()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
get_peer(Pid) ->
    gen_statem:call(Pid, get_peer).

-spec get_peercert(pid()) ->
    {ok, binary()} | {error, term()}.
get_peercert(Pid) ->
    gen_statem:call(Pid, get_peercert).

-spec is_push(pid()) -> boolean().
is_push(Pid) ->
    gen_statem:call(Pid, is_push).

-spec new_stream(pid()) -> {stream_id(), pid()} | {error, error_code()}.
new_stream(Pid) ->
    new_stream(Pid, self()).

-spec new_stream(pid(), pid()) ->
                        {stream_id(), pid()}
                      | {error, error_code()}.
new_stream(Pid, NotifyPid) ->
    gen_statem:call(Pid, {new_stream, NotifyPid}).

new_stream(Pid, CallbackMod, CallbackOpts, NotifyPid) ->
    gen_statem:call(Pid, {new_stream, CallbackMod, CallbackOpts, NotifyPid}).

%% @doc `new_stream/6' accepts Headers so they can be sent within the connection process
%% when a stream id is assigned. This ensures that another process couldn't also have
%% requested a new stream and send its headers before the stream with a lower id, which
%% results in the server closing the connection when it gets headers for the lower id stream.
-spec new_stream(pid(), module(), term(), hpack:headers(), send_opts(), pid()) -> {stream_id(), pid()} | {error, error_code()}.
new_stream(Pid, CallbackMod, CallbackOpts, Headers, Opts, NotifyPid) ->
    gen_statem:call(Pid, {new_stream, CallbackMod, CallbackOpts, Headers, Opts, NotifyPid}).

-spec new_stream(pid(), module(), term(), hpack:headers(), any(), send_opts(), pid()) -> {stream_id(), pid()} | {error, error_code()}.
new_stream(Pid, CallbackMod, CallbackOpts, Headers, Body, Opts, NotifyPid) ->
    gen_statem:call(Pid, {new_stream, CallbackMod, CallbackOpts, Headers, Body, Opts, NotifyPid}).

-spec send_promise(pid(), stream_id(), stream_id(), hpack:headers()) -> ok.
send_promise(Pid, StreamId, NewStreamId, Headers) ->
    gen_statem:cast(Pid, {send_promise, StreamId, NewStreamId, Headers}),
    ok.

-spec get_response(pid(), stream_id()) ->
                          {ok, {hpack:headers(), iodata(), iodata()}}
                           | not_ready.
get_response(Pid, StreamId) ->
    gen_statem:call(Pid, {get_response, StreamId}).

-spec get_streams(pid()) -> h2_stream_set:stream_set().
get_streams(Pid) ->
    gen_statem:call(Pid, streams).

-spec send_window_update(pid(), non_neg_integer()) -> ok.
send_window_update(Pid, Size) ->
    gen_statem:cast(Pid, {send_window_update, Size}).

-spec update_settings(pid(), h2_frame_settings:payload()) -> ok.
update_settings(Pid, Payload) ->
    gen_statem:cast(Pid, {update_settings, Payload}).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:cast(Pid, stop).

%% The listen state only exists to wait around for new prim_inet
%% connections
listen(info, {inet_async, ListenSocket, Ref, {ok, ClientSocket}},
            #h2_listening_state{
               listen_socket = ListenSocket,
               listen_ref = Ref,
               transport = Transport,
               ssl_options = SSLOptions,
               acceptor_callback = AcceptorCallback,
               server_settings = Http2Settings
              }) ->

    %If anything crashes in here, at least there's another acceptor ready
    AcceptorCallback(),

    inet_db:register_socket(ClientSocket, inet_tcp),

    Socket = case Transport of
        gen_tcp ->
            ClientSocket;
        ssl ->
            {ok, AcceptSocket} = ?ssl_accept(ClientSocket, SSLOptions),
            {ok, <<"h2">>} = ssl:negotiated_protocol(AcceptSocket),
            AcceptSocket
    end,
    start_http2_server(
      Http2Settings,
      #connection{
         streams = h2_stream_set:new(server),
         socket={Transport, Socket}
        });
listen(timeout, _, State) ->
    go_away(timeout, ?PROTOCOL_ERROR, State);
listen(Type, Msg, State) ->
    handle_event(Type, Msg, State).

-spec handshake(gen_statem:event_type(), {frame, h2_frame:frame()} | term(), connection()) ->
                    {next_state,
                     handshake|connected|closing,
                     connection()}.
handshake(timeout, _, State) ->
    go_away(timeout, ?PROTOCOL_ERROR, State);
handshake(Event, {frame, {FH, _Payload}=Frame}, State) ->
    %% The first frame should be the client settings as per
    %% RFC-7540#3.5
    case FH#frame_header.type of
        ?SETTINGS ->
            route_frame(Event, Frame, State);
        _ ->
            go_away(Event, ?PROTOCOL_ERROR, State)
    end;
handshake(Type, Msg, State) ->
    handle_event(Type, Msg, State).

connected(Event, {frame, Frame},
          #connection{}=Conn
         ) ->
    route_frame(Event, Frame, Conn);
connected(Type, Msg, State) ->
    handle_event(Type, Msg, State).

%% The continuation state in entered after receiving a HEADERS frame
%% with no ?END_HEADERS flag set, we're locked waiting for contiunation
%% frames on the same stream to preserve the decoding context state
continuation(Event, {frame,
              {#frame_header{
                  stream_id=StreamId,
                  type=?CONTINUATION
                 }, _}=Frame},
             #connection{
                continuation = #continuation_state{
                                  stream_id = StreamId
                                 }
               }=Conn) ->
    route_frame(Event, Frame, Conn);
continuation(Event, {frame, _}, Conn) ->
    %% got a frame that's not part of the continuation
    go_away(Event, ?PROTOCOL_ERROR, Conn);
continuation(Type, Msg, State) ->
    handle_event(Type, Msg, State).

%% The closing state should deal with frames on the wire still, I
%% think. But we should just close it up now.
closing(_, _Message,
        #connection{
           socket=Socket
          }=Conn) ->
    sock:close(Socket),
    {stop, normal, Conn};
closing(Type, Msg, State) ->
    handle_event(Type, Msg, State).

%% route_frame's job needs to be "now that we've read a frame off the
%% wire, do connection based things to it and/or forward it to the
%% http2 stream processor (h2_stream:recv_frame)
-spec route_frame(
        gen_statem:event_type(),
        h2_frame:frame() | {error, term()},
        connection()) ->
    {next_state,
     connected | continuation | closing ,
     connection()}.
%% Bad Length of frame, exceedes maximum allowed size
route_frame(Event, {#frame_header{length=L}, _},
            #connection{
               self_settings=#settings{max_frame_size=MFS}
              }=Conn)
    when L > MFS ->
    go_away(Event, ?FRAME_SIZE_ERROR, Conn);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Connection Level Frames
%%
%% Here we'll handle anything that belongs on stream 0.

%% SETTINGS, finally something that's ok on stream 0
%% This is the non-ACK case, where settings have actually arrived
route_frame(Event, {H, Payload},
            #connection{
               peer_settings=PS=#settings{
                                   initial_window_size=OldIWS,
                                   header_table_size=HTS
                                  },
               streams=Streams,
               encode_context=EncodeContext
              }=Conn)
    when H#frame_header.type == ?SETTINGS,
         ?NOT_FLAG((H#frame_header.flags), ?FLAG_ACK) ->
    %% Need a way of processing settings so I know which ones came in
    %% on this one payload.
    case h2_frame_settings:validate(Payload) of
        ok ->
            {settings, PList} = Payload,

            Delta =
                case proplists:get_value(?SETTINGS_INITIAL_WINDOW_SIZE, PList) of
                    undefined ->
                        0;
                    NewIWS ->
                        NewIWS - OldIWS
                end,
            NewPeerSettings = h2_frame_settings:overlay(PS, Payload),
            %% We've just got connection settings from a peer. He have a
            %% couple of jobs to do here w.r.t. flow control

            %% If Delta != 0, we need to change every stream's
            %% send_window_size in the state open or
            %% half_closed_remote. We'll just send the message
            %% everywhere. It's up to them if they need to do
            %% anything.
            UpdatedStreams1 =
                h2_stream_set:update_all_send_windows(Delta, Streams),

            UpdatedStreams2 =
                case proplists:get_value(?SETTINGS_MAX_CONCURRENT_STREAMS, PList) of
                    undefined ->
                        UpdatedStreams1;
                    NewMax ->
                        h2_stream_set:update_my_max_active(NewMax, UpdatedStreams1)
                end,

            NewEncodeContext = hpack:new_max_table_size(HTS, EncodeContext),

            socksend(Conn, h2_frame_settings:ack()),
            maybe_reply(Event, {next_state, connected, Conn#connection{
                                      peer_settings=NewPeerSettings,
                                      %% Why aren't we updating send_window_size here? Section 6.9.2 of
                                      %% the spec says: "The connection flow-control window can only be
                                      %% changed using WINDOW_UPDATE frames.",
                                      encode_context=NewEncodeContext,
                                      streams=UpdatedStreams2
                                     }}, ok);
        {error, Code} ->
            go_away(Event, Code, Conn)
    end;

%% This is the case where we got an ACK, so dequeue settings we're
%% waiting to apply
route_frame(Event, {H, _Payload},
            #connection{
               settings_sent=SS,
               streams=Streams,
               self_settings=#settings{
                                initial_window_size=OldIWS
                               }
              }=Conn)
    when H#frame_header.type == ?SETTINGS,
         ?IS_FLAG((H#frame_header.flags), ?FLAG_ACK) ->
    case queue:out(SS) of
        {{value, {_Ref, NewSettings}}, NewSS} ->

            UpdatedStreams1 =
                case NewSettings#settings.initial_window_size of
                    undefined ->
                        ok;
                    NewIWS ->
                        Delta = NewIWS - OldIWS,
                        case Delta > 0 of
                            true -> send_window_update(self(), Delta);
                            false -> ok
                        end,
                        h2_stream_set:update_all_recv_windows(Delta, Streams)
                end,

            UpdatedStreams2 =
                case NewSettings#settings.max_concurrent_streams of
                    undefined ->
                        UpdatedStreams1;
                    NewMax ->
                        h2_stream_set:update_their_max_active(NewMax, UpdatedStreams1)
                end,
            maybe_reply(Event, {next_state,
             connected,
             Conn#connection{
               streams=UpdatedStreams2,
               settings_sent=NewSS,
               self_settings=NewSettings
               %% Same thing here, section 6.9.2
              }}, ok);
        _X ->
            maybe_reply(Event, {next_state, closing, Conn}, ok)
    end;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Stream level frames
%%


route_frame(Event, {#frame_header{type=?HEADERS}=FH, _Payload},
            #connection{}=Conn)
  when Conn#connection.type == server,
       FH#frame_header.stream_id rem 2 == 0 ->
    go_away(Event, ?PROTOCOL_ERROR, Conn);
route_frame(Event, {#frame_header{type=?HEADERS}=FH, _Payload}=Frame,
            #connection{}=Conn) ->
    StreamId = FH#frame_header.stream_id,
    Streams = Conn#connection.streams,

    %% Four things could be happening here.

    %% If we're a server, these are either request headers or request
    %% trailers

    %% If we're a client, these are either headers in response to a
    %% client request, or headers in response to a push promise

    Stream = h2_stream_set:get(StreamId, Streams),
    {ContinuationType, NewConn} =
        case {h2_stream_set:type(Stream), Conn#connection.type} of
            {idle, server} ->
                case
                    h2_stream_set:new_stream(
                      StreamId,
                      self(),
                      Conn#connection.stream_callback_mod,
                      Conn#connection.stream_callback_opts,
                      Conn#connection.socket,
                      (Conn#connection.peer_settings)#settings.initial_window_size,
                      (Conn#connection.self_settings)#settings.initial_window_size,
                      Conn#connection.type,
                      Streams) of
                    {error, ErrorCode, NewStream} ->
                        rst_stream_(Event, NewStream, ErrorCode, Conn),
                        {none, Conn};
                    {_, _, NewStreams} ->
                        {headers, Conn#connection{streams=NewStreams}}
                end;
            {active, server} ->
                {trailers, Conn};
            {_, server} ->
                {headers, Conn}
        end,

    case ContinuationType of
        none ->
            maybe_reply(Event, {next_state,
             connected,
             NewConn}, ok);
        _ ->
            ContinuationState =
                #continuation_state{
                   type = ContinuationType,
                   frames = [Frame],
                   end_stream = ?IS_FLAG((FH#frame_header.flags), ?FLAG_END_STREAM),
                   end_headers = ?IS_FLAG((FH#frame_header.flags), ?FLAG_END_HEADERS),
                   stream_id = StreamId
                  },
            %% maybe_hpack/2 uses this #continuation_state to figure
            %% out what to do, which might include hpack
            maybe_hpack(Event, ContinuationState, NewConn)
    end;

route_frame(Event, F={H=#frame_header{
                    stream_id=_StreamId,
                    type=?CONTINUATION
                   }, _Payload},
            #connection{
               continuation = #continuation_state{
                                 frames = CFQ
                                } = Cont
              }=Conn) ->
    maybe_hpack(Event, Cont#continuation_state{
                  frames=[F|CFQ],
                  end_headers=?IS_FLAG((H#frame_header.flags), ?FLAG_END_HEADERS)
                 },
                Conn);

route_frame(Event, {H, _Payload},
            #connection{}=Conn)
    when H#frame_header.type == ?PRIORITY,
         H#frame_header.stream_id == 0 ->
    go_away(Event, ?PROTOCOL_ERROR, Conn);
route_frame(Event, {H, _Payload},
            #connection{} = Conn)
    when H#frame_header.type == ?PRIORITY ->
    maybe_reply(Event, {next_state, connected, Conn}, ok);

route_frame(
  Event,
  {#frame_header{
      stream_id=StreamId,
      type=?RST_STREAM
      },
   _Payload},
  #connection{} = Conn) ->
    %% TODO: anything with this?
    %% EC = h2_frame_rst_stream:error_code(Payload),
    Streams = Conn#connection.streams,
    Stream = h2_stream_set:get(StreamId, Streams),
    case h2_stream_set:type(Stream) of
        idle ->
            go_away(Event, ?PROTOCOL_ERROR, Conn);
        _Stream ->
            %% TODO: RST_STREAM support
            maybe_reply(Event, {next_state, connected, Conn}, ok)
    end;
route_frame(Event, {H=#frame_header{}, _P},
            #connection{} =Conn)
    when H#frame_header.type == ?PUSH_PROMISE,
         Conn#connection.type == server ->
    go_away(Event, ?PROTOCOL_ERROR, Conn);
route_frame(Event, {H=#frame_header{
                  stream_id=StreamId
                 },
             Payload}=Frame,
            #connection{}=Conn)
    when H#frame_header.type == ?PUSH_PROMISE,
         Conn#connection.type == client ->
    PSID = h2_frame_push_promise:promised_stream_id(Payload),

    Streams = Conn#connection.streams,

    Old = h2_stream_set:get(StreamId, Streams),
    NotifyPid = h2_stream_set:notify_pid(Old),

    %% TODO: Case statement here about execeding the number of
    %% pushed. Honestly I think it's a bigger problem with the
    %% h2_stream_set, but we can punt it for now. The idea is that
    %% reserved(local) and reserved(remote) aren't technically
    %% 'active', but they're being counted that way right now. Again,
    %% that only matters if Server Push is enabled.
    {_, _, NewStreams} =
        h2_stream_set:new_stream(
          PSID,
          NotifyPid,
          Conn#connection.stream_callback_mod,
          Conn#connection.stream_callback_opts,
          Conn#connection.socket,
          (Conn#connection.peer_settings)#settings.initial_window_size,
          (Conn#connection.self_settings)#settings.initial_window_size,
          Conn#connection.type,
          Streams),

    Continuation = #continuation_state{
                      stream_id=StreamId,
                      type=push_promise,
                      frames = [Frame],
                      end_headers=?IS_FLAG((H#frame_header.flags), ?FLAG_END_HEADERS),
                      promised_id=PSID
                     },
    maybe_hpack(Event, Continuation,
                Conn#connection{
                  streams = NewStreams
                 });
%% PING
%% If not stream 0, then connection error
route_frame(Event, {H, _Payload},
            #connection{} = Conn)
    when H#frame_header.type == ?PING,
         H#frame_header.stream_id =/= 0 ->
    go_away(Event, ?PROTOCOL_ERROR, Conn);
%% If length != 8, FRAME_SIZE_ERROR
%% TODO: I think this case is already covered in h2_frame now
route_frame(Event, {H, _Payload},
           #connection{}=Conn)
    when H#frame_header.type == ?PING,
         H#frame_header.length =/= 8 ->
    go_away(Event, ?FRAME_SIZE_ERROR, Conn);
%% If PING && !ACK, must ACK
route_frame(Event, {H, Ping},
            #connection{}=Conn)
    when H#frame_header.type == ?PING,
         ?NOT_FLAG((H#frame_header.flags), ?FLAG_ACK) ->
    Ack = h2_frame_ping:ack(Ping),
    socksend(Conn, h2_frame:to_binary(Ack)),
    maybe_reply(Event, {next_state, connected, Conn}, ok);
route_frame(Event, {H, Payload},
            #connection{pings = Pings}=Conn)
    when H#frame_header.type == ?PING,
         ?IS_FLAG((H#frame_header.flags), ?FLAG_ACK) ->
    case maps:get(h2_frame_ping:to_binary(Payload), Pings, undefined) of
        undefined ->
            ok;
        {NotifyPid, _} ->
            NotifyPid ! {'PONG', self()}
    end,
    NextPings = maps:remove(Payload, Pings),
    maybe_reply(Event, {next_state, connected, Conn#connection{pings = NextPings}}, ok);
route_frame(Event, {H=#frame_header{stream_id=0}, _Payload},
            #connection{}=Conn)
    when H#frame_header.type == ?GOAWAY ->
    go_away(Event, ?NO_ERROR, Conn);

%% Window Update
route_frame(Event,
  {#frame_header{
      stream_id=0,
      type=?WINDOW_UPDATE
     },
   Payload},
  #connection{
     send_window_size=SWS
    }=Conn) ->
    WSI = h2_frame_window_update:size_increment(Payload),
    NewSendWindow = SWS+WSI,
    case NewSendWindow > 2147483647 of
        true ->
            go_away(Event, ?FLOW_CONTROL_ERROR, Conn);
        false ->
            %% TODO: Priority Sort! Right now, it's just sorting on
            %% lowest stream_id first
            %Streams = h2_stream_set:sort(Conn#connection.streams),
            Streams = Conn#connection.streams,

            {RemainingSendWindow, UpdatedStreams} =
                h2_stream_set:send_what_we_can(
                  all,
                  NewSendWindow,
                  (Conn#connection.peer_settings)#settings.max_frame_size,
                  Streams
                 ),
            maybe_reply(Event, {next_state, connected,
             Conn#connection{
               send_window_size=RemainingSendWindow,
               streams=UpdatedStreams
              }}, ok)
    end;
route_frame(Event,
  {#frame_header{type=?WINDOW_UPDATE}=FH,
   Payload},
  #connection{}=Conn
 ) ->
    StreamId = FH#frame_header.stream_id,
    Streams = Conn#connection.streams,
    WSI = h2_frame_window_update:size_increment(Payload),
    Stream = h2_stream_set:get(StreamId, Streams),
    case h2_stream_set:type(Stream) of
        idle ->
            go_away(Event, ?PROTOCOL_ERROR, Conn);
        closed ->
            rst_stream_(Event, Stream, ?STREAM_CLOSED, Conn);
        active ->
            SWS = Conn#connection.send_window_size,
            NewSSWS = h2_stream_set:send_window_size(Stream)+WSI,

            case NewSSWS > 2147483647 of
                true ->
                    rst_stream_(Event, Stream, ?FLOW_CONTROL_ERROR, Conn);
                false ->
                    {RemainingSendWindow, NewStreams}
                        = h2_stream_set:send_what_we_can(
                            StreamId,
                            SWS,
                            (Conn#connection.peer_settings)#settings.max_frame_size,
                            h2_stream_set:upsert(
                              h2_stream_set:increment_send_window_size(WSI, Stream),
                              Streams)
                           ),
                    maybe_reply(Event, {next_state, connected,
                     Conn#connection{
                       send_window_size=RemainingSendWindow,
                       streams=NewStreams
                      }}, ok)
            end
    end;
route_frame(Event, {#frame_header{type=T}, _}, Conn)
  when T > ?CONTINUATION ->
    maybe_reply(Event, {next_state, connected, Conn}, ok);
route_frame(Event, Frame, #connection{}=Conn) ->
    error_logger:error_msg("Frame condition not covered by pattern match."
                           "Please open a github issue with this output: ~s",
                           [h2_frame:format(Frame)]),
    go_away(Event, ?PROTOCOL_ERROR, Conn).

handle_event(_, {stream_finished,
              StreamId,
              Headers,
              Body,
              Trailers},
             Conn) ->
    Stream = h2_stream_set:get(StreamId, Conn#connection.streams),
    case h2_stream_set:type(Stream) of
        active ->
            NotifyPid = h2_stream_set:notify_pid(Stream),
            Response =
                case {Conn#connection.type, Conn#connection.garbage_on_end} of
                    {server, _} -> garbage;
                    {client, false} -> {Headers, Body, Trailers};
                    {client, true} -> garbage
                end,
            {_NewStream, NewStreams} =
                h2_stream_set:close(
                  Stream,
                  Response,
                  Conn#connection.streams),

            NewConn =
                Conn#connection{
                  streams = NewStreams
                 },
            case {Conn#connection.type, is_pid(NotifyPid)} of
                {client, true} ->
                    NotifyPid ! {'END_STREAM', StreamId};
                _ ->
                    ok
            end,
            {keep_state, NewConn};
        _ ->
            %% stream finished multiple times
            {keep_state, Conn}
    end;
handle_event(_, {send_window_update, 0}, Conn) ->
    {keep_state, Conn};
handle_event(_, {send_window_update, Size},
             #connection{
                socket=Socket
                }=Conn) ->
    h2_frame_window_update:send(Socket, Size, 0),
    h2_stream_set:increment_socket_recv_window(Size, Conn#connection.streams),
    {keep_state, Conn};
handle_event(_, {update_settings, Http2Settings},
             #connection{}=Conn) ->
    {keep_state,
     send_settings(Http2Settings, Conn)};
handle_event(_, {send_headers, StreamId, Headers, Opts}, Conn) ->
    {keep_state, send_headers_(StreamId, Headers, Opts, Conn)};
handle_event(_, {actually_send_trailers, StreamId, Trailers}, Conn=#connection{encode_context=EncodeContext,
                                                                               streams=Streams,
                                                                               socket=Socket}) ->
    Stream = h2_stream_set:get(StreamId, Streams),
    {FramesToSend, NewContext} =
        h2_frame_headers:to_frames(h2_stream_set:stream_id(Stream),
                                   Trailers,
                                   EncodeContext,
                                   (Conn#connection.peer_settings)#settings.max_frame_size,
                                   true
                                  ),

    [sock:send(Socket, h2_frame:to_binary(Frame)) || Frame <- FramesToSend],
    {keep_state,
     Conn#connection{
       encode_context=NewContext
      }};
handle_event(Event, {rst_stream, StreamId, ErrorCode},
             #connection{
                streams = Streams,
                socket = _Socket
               }=Conn
            ) ->
    Stream = h2_stream_set:get(StreamId, Streams),
    rst_stream_(Event, Stream, ErrorCode, Conn);
handle_event(_, {send_trailers, StreamId, Headers, Opts},
             #connection{
                streams = Streams,
                socket = _Socket
               }=Conn
            ) ->
    BodyComplete = proplists:get_value(send_end_stream, Opts, true),

    Stream = h2_stream_set:get(StreamId, Streams),
    case h2_stream_set:type(Stream) of
        active ->
            NewS = h2_stream_set:update_trailers(Headers, Stream),
            {NewSWS, NewStreams} =
                h2_stream_set:send_what_we_can(
                  StreamId,
                  Conn#connection.send_window_size,
                  (Conn#connection.peer_settings)#settings.max_frame_size,
                  h2_stream_set:upsert(
                    h2_stream_set:update_data_queue(h2_stream_set:queued_data(Stream), BodyComplete, NewS),
                    Conn#connection.streams)),

            send_t(Stream, Headers),

            {keep_state,
             Conn#connection{
               send_window_size=NewSWS,
               streams=NewStreams
              }};
        idle ->
            %% In theory this is a client maybe activating a stream,
            %% but in practice, we've already activated the stream in
            %% new_stream/1
            {keep_state, Conn};
        closed ->
            {keep_state, Conn}
    end;
handle_event(_, {send_body, StreamId, Body, Opts},
             #connection{}=Conn) ->

    {keep_state, send_body_(StreamId, Body, Opts, Conn)};
handle_event(_, {send_request, NotifyPid, Headers, Body},
        #connection{
            streams=Streams
        }=Conn) ->
    case send_request_(NotifyPid, Conn, Streams, Headers, Body) of
        {ok, NewConn} ->
            {keep_state, NewConn};
        {error, _Code} ->
            {keep_state, Conn}
    end;
handle_event(_, {send_promise, StreamId, NewStreamId, Headers},
             #connection{
                streams=Streams,
                encode_context=OldContext
               }=Conn
            ) ->
    NewStream = h2_stream_set:get(NewStreamId, Streams),
    case h2_stream_set:type(NewStream) of
        active ->
            %% TODO: This could be a series of frames, not just one
            {PromiseFrame, NewContext} =
                h2_frame_push_promise:to_frame(
               StreamId,
               NewStreamId,
               Headers,
               OldContext
              ),

            %% Send the PP Frame
            Binary = h2_frame:to_binary(PromiseFrame),
            socksend(Conn, Binary),

            %% Get the promised stream rolling
            h2_stream:send_pp(h2_stream_set:stream_pid(NewStream), Headers),

            {keep_state,
             Conn#connection{
               encode_context=NewContext
              }};
        _ ->
            {keep_state, Conn}
    end;
handle_event(Event, {check_settings_ack, {Ref, NewSettings}},
             #connection{
                settings_sent=SS
               }=Conn) ->
    case queue:out(SS) of
        {{value, {Ref, NewSettings}}, _} ->
            %% This is still here!
            go_away(Event, ?SETTINGS_TIMEOUT, Conn);
        _ ->
            %% YAY!
            {keep_state, Conn}
    end;
handle_event(_, {send_bin, Binary},
             #connection{} = Conn) ->
    socksend(Conn, Binary),
    {keep_state, Conn};
handle_event(_, {send_frame, Frame},
             #connection{} =Conn) ->
    Binary = h2_frame:to_binary(Frame),
    socksend(Conn, Binary),
    {keep_state, Conn};
handle_event(stop, _StateName,
            #connection{}=Conn) ->
    go_away(stop, 0, Conn);
handle_event({call, From}, streams,
                  #connection{
                     streams=Streams
                    }=Conn) ->
    {keep_state, Conn, [{reply, From, Streams}]};
handle_event({call, From}, {get_response, StreamId},
                  #connection{}=Conn) ->
    Stream = h2_stream_set:get(StreamId, Conn#connection.streams),
    {Reply, NewStreams} =
        case h2_stream_set:type(Stream) of
            closed ->
                {_, NewStreams0} =
                    h2_stream_set:close(
                      Stream,
                      garbage,
                      Conn#connection.streams),
                {{ok, h2_stream_set:response(Stream)}, NewStreams0};
            active ->
                {not_ready, Conn#connection.streams}
        end,
    {keep_state, Conn#connection{streams=NewStreams}, [{reply, From, Reply}]};
handle_event({call, From}, {new_stream, NotifyPid},
                  #connection{
                     stream_callback_mod=CallbackMod,
                     stream_callback_opts=CallbackOpts
                    }=Conn) ->
    new_stream_(From, CallbackMod, CallbackOpts, NotifyPid, Conn);
handle_event({call, From}, {new_stream, CallbackMod, CallbackState, NotifyPid}, Conn) ->
    new_stream_(From, CallbackMod, CallbackState, NotifyPid, Conn);
handle_event({call, From}, {new_stream, CallbackMod, CallbackState, Headers, Opts, NotifyPid}, Conn) ->
    new_stream_(From, CallbackMod, CallbackState, Headers, Opts, NotifyPid, Conn);
handle_event({call, From}, {new_stream, CallbackMod, CallbackState, Headers, Body, Opts, NotifyPid}, Conn) ->
    new_stream_(From, CallbackMod, CallbackState, Headers, Body, Opts, NotifyPid, Conn);
handle_event({call, From}, is_push,
                  #connection{
                     peer_settings=#settings{enable_push=Push}
                    }=Conn) ->
    IsPush = case Push of
        1 -> true;
        _ -> false
    end,
    {keep_state, Conn, [{reply, From, IsPush}]};
handle_event({call, From}, get_peer,
                  #connection{
                     socket=Socket
                    }=Conn) ->
    case sock:peername(Socket) of
        {error, _}=Error ->
            {keep_state, Conn, [{reply, From, Error}]};
        {ok, _AddrPort}=OK ->
            {keep_state, Conn, [{reply, From, OK}]}
    end;
handle_event({call, From}, get_peercert,
                  #connection{
                     socket=Socket
                    }=Conn) ->
    case sock:peercert(Socket) of
        {error, _}=Error ->
            {keep_state, Conn, [{reply, From, Error}]};
        {ok, _Cert}=OK ->
            {keep_state, Conn, [{reply, From, OK}]}
    end;
handle_event({call, From}, {send_request, NotifyPid, Headers, Body},
        #connection{
            streams=Streams
        }=Conn) ->
    case send_request_(NotifyPid, Conn, Streams, Headers, Body) of
        {ok, NewConn} ->
            {keep_state, NewConn, [{reply, From, ok}]};
        {error, Code} ->
            {keep_state, Conn, [{reply, From, {error, Code}}]}
    end;
handle_event({call, From}, {send_request, NotifyPid, Headers, Body, CallbackMod, CallbackOpts},
        #connection{
            streams=Streams
        }=Conn) ->
    case send_request_(NotifyPid, Conn, Streams, Headers, Body, CallbackMod, CallbackOpts) of
        {ok, NewConn} ->
            {keep_state, NewConn, [{reply, From, ok}]};
        {error, Code} ->
            {keep_state, Conn, [{reply, From, {error, Code}}]}
    end;
handle_event({call, From}, {send_ping, NotifyPid},
             #connection{pings = Pings} = Conn) ->
    PingValue = crypto:strong_rand_bytes(8),
    Frame = h2_frame_ping:new(PingValue),
    Headers = #frame_header{stream_id = 0, flags = 16#0},
    Binary = h2_frame:to_binary({Headers, Frame}),

    case socksend(Conn, Binary) of
        ok ->
            NextPings = maps:put(PingValue, {NotifyPid, erlang:monotonic_time(milli_seconds)}, Pings),
            NextConn = Conn#connection{pings = NextPings},
            {keep_state, NextConn, [{reply, From, ok}]};
        {error, _Reason} = Err ->
            {keep_state, Conn, [{reply, From, Err}]}
    end;

%% Socket Messages
%% {tcp_passive, Socket}
handle_event(info, {tcp_passive, Socket},
            #connection{
               socket={gen_tcp, Socket}
              }=Conn) ->
    handle_socket_passive(Conn);
%% {tcp_closed, Socket}
handle_event(info, {tcp_closed, Socket},
            #connection{
              socket={gen_tcp, Socket}
             }=Conn) ->
    handle_socket_closed(Conn);
%% {ssl_closed, Socket}
handle_event(info, {ssl_closed, Socket},
            #connection{
               socket={ssl, Socket}
              }=Conn) ->
    handle_socket_closed(Conn);
%% {tcp_error, Socket, Reason}
handle_event(info, {tcp_error, Socket, Reason},
            #connection{
               socket={gen_tcp,Socket}
              }=Conn) ->
    handle_socket_error(Reason, Conn);
%% {ssl_error, Socket, Reason}
handle_event(info, {ssl_error, Socket, Reason},
            #connection{
               socket={ssl,Socket}
              }=Conn) ->
    handle_socket_error(Reason, Conn);
handle_event(info, {go_away, ErrorCode}, Conn) ->
    gen_statem:cast(self(), io_lib:format("GO_AWAY: ErrorCode ~p", [ErrorCode])),
    {next_state, closing, Conn};
%handle_event(info, {_,R},
%           #connection{}=Conn) ->
%    handle_socket_error(R, Conn);
handle_event(Event, Msg, Conn) ->
    error_logger:error_msg("h2_connection received unexpected event of type ~p : ~p", [Event, Msg]),
    %%go_away(Event, ?PROTOCOL_ERROR, Conn).
    {keep_state, Conn}.

code_change(_OldVsn, StateName, Conn, _Extra) ->
    {ok, StateName, Conn}.

terminate(normal, _StateName, _Conn) ->
    ok;
terminate(_Reason, _StateName, _Conn=#connection{}) ->
    ok;
terminate(_Reason, _StateName, _State) ->
    ok.

new_stream_(From, CallbackMod, CallbackState, NotifyPid, Conn=#connection{streams=Streams}) ->
    {Reply, NewStreams} =
        case
            h2_stream_set:new_stream(
              next,
              NotifyPid,
              CallbackMod,
              CallbackState,
              Conn#connection.socket,
              Conn#connection.peer_settings#settings.initial_window_size,
              Conn#connection.self_settings#settings.initial_window_size,
              Conn#connection.type,
              Streams)
        of
            {error, Code, _NewStream} ->
                %% TODO: probably want to have events like this available for metrics
                %% tried to create new_stream but there are too many
                {{error, Code}, Streams};
            {Pid, NextId, GoodStreamSet} ->
                {{NextId, Pid}, GoodStreamSet}
        end,
    {keep_state, Conn#connection{
                                 streams=NewStreams
                                }, [{reply, From, Reply}]}.

new_stream_(From, CallbackMod, CallbackState, Headers, Opts, NotifyPid, Conn=#connection{streams=Streams}) ->
    {Reply, NewStreams} =
        case
            h2_stream_set:new_stream(
              next,
              NotifyPid,
              CallbackMod,
              CallbackState,
              Conn#connection.socket,
              Conn#connection.peer_settings#settings.initial_window_size,
              Conn#connection.self_settings#settings.initial_window_size,
              Conn#connection.type,
              Streams)
        of
            {error, Code, _NewStream} ->
                %% TODO: probably want to have events like this available for metrics
                %% tried to create new_stream but there are too many
                {{error, Code}, Streams};
            {Pid, NextId, GoodStreamSet} ->
                {{NextId, Pid}, GoodStreamSet}
        end,

    Conn1 = Conn#connection{
              streams=NewStreams
             },
    Conn2 = case Reply of
                {error, _Code} ->
                    Conn1;
                {NextId0, _Pid} ->
                    NewConn = send_headers_(NextId0, Headers, Opts, Conn1),
                    NewConn
            end,
    {keep_state, Conn2, [{reply, From, Reply}]}.

new_stream_(From, CallbackMod, CallbackState, Headers, Body, Opts, NotifyPid, Conn=#connection{streams=Streams}) ->
    {Reply, NewStreams} =
        case
            h2_stream_set:new_stream(
              next,
              NotifyPid,
              CallbackMod,
              CallbackState,
              Conn#connection.socket,
              Conn#connection.peer_settings#settings.initial_window_size,
              Conn#connection.self_settings#settings.initial_window_size,
              Conn#connection.type,
              Streams)
        of
            {error, Code, _NewStream} ->
                %% TODO: probably want to have events like this available for metrics
                %% tried to create new_stream but there are too many
                {{error, Code}, Streams};
            {Pid, NextId, GoodStreamSet} ->
                {{NextId, Pid}, GoodStreamSet}
        end,

    Conn1 = Conn#connection{
              streams=NewStreams
             },
    Conn2 = case Reply of
                {error, _Code} ->
                    Conn1;
                {NextId0, _Pid} ->
                    NewConn = send_headers_(NextId0, Headers, Opts, Conn1),
                    NewConn1 = send_body_(NextId0, Body, Opts, NewConn),
                    NewConn1
            end,
    {keep_state, Conn2, [{reply, From, Reply}]}.


send_headers_(StreamId, Headers, Opts, #connection{encode_context=EncodeContext,
                                                   streams = Streams,
                                                   socket = Socket
                                                  }=Conn) ->
    StreamComplete = proplists:get_value(send_end_stream, Opts, false),

    Stream = h2_stream_set:get(StreamId, Streams),
    case h2_stream_set:type(Stream) of
        active ->
            {FramesToSend, NewContext} =
                h2_frame_headers:to_frames(h2_stream_set:stream_id(Stream),
                                           Headers,
                                           EncodeContext,
                                           (Conn#connection.peer_settings)#settings.max_frame_size,
                                           StreamComplete
                                          ),
            [sock:send(Socket, h2_frame:to_binary(Frame)) || Frame <- FramesToSend],
            send_h(Stream, Headers),
            Conn#connection{
               encode_context=NewContext
              };
        idle ->
            %% In theory this is a client maybe activating a stream,
            %% but in practice, we've already activated the stream in
            %% new_stream/1
            Conn;
        closed ->
            Conn
    end.

go_away(Event, ErrorCode, Conn) ->
    go_away_(ErrorCode, Conn#connection.socket, Conn#connection.streams),
    %% TODO: why is this sending a string?
    gen_statem:cast(self(), io_lib:format("GO_AWAY: ErrorCode ~p", [ErrorCode])),
    maybe_reply(Event, {next_state, closing, Conn}, ok).

-spec go_away_(error_code(), sock:socket(), h2_stream_set:stream_set()) -> ok.
go_away_(ErrorCode, Socket, Streams) ->
    NAS = h2_stream_set:get_next_available_stream_id(Streams),
    GoAway = h2_frame_goaway:new(NAS, ErrorCode),
    GoAwayBin = h2_frame:to_binary({#frame_header{
                                       stream_id=0
                                      }, GoAway}),
    sock:send(Socket, GoAwayBin),
    ok.

maybe_reply({call, From}, {next_state, NewState, NewData}, Msg) ->
    {next_state, NewState, NewData, [{reply, From, Msg}]};
maybe_reply(_, Return, _) ->
    Return.

%% rst_stream_/3 looks for a running process for the stream. If it
%% finds one, it delegates sending the rst_stream frame to it, but if
%% it doesn't, it seems like a waste to spawn one just to kill it
%% after sending that frame, so we send it from here.
-spec rst_stream_(
        gen_statem:event_type(),
        h2_stream_set:stream(),
        error_code(),
        connection()
       ) -> {next_state, connected, connection()}.
rst_stream_(Event, Stream, ErrorCode, Conn) ->
    rst_stream__(Stream, ErrorCode, Conn#connection.socket),
    maybe_reply(Event, {next_state, connected, Conn}, ok).

-spec rst_stream__(
        h2_stream_set:stream(),
        error_code(),
        sock:sock()
       ) -> ok.
rst_stream__(Stream, ErrorCode, Sock) ->
    case h2_stream_set:type(Stream) of
        active ->
            %% Can this ever be undefined?
            Pid = h2_stream_set:stream_pid(Stream),
            %% h2_stream's rst_stream will take care of letting us know
            %% this stream is closed and will send us a message to close the
            %% stream somewhere else
            h2_stream:rst_stream(Pid, ErrorCode);
        _ ->
            StreamId = h2_stream_set:stream_id(Stream),
            RstStream = h2_frame_rst_stream:new(ErrorCode),
            RstStreamBin = h2_frame:to_binary(
                          {#frame_header{
                              stream_id=StreamId
                             },
                           RstStream}),
            sock:send(Sock, RstStreamBin)
    end.

-spec send_settings(settings(), connection()) -> connection().
send_settings(SettingsToSend,
              #connection{
                 self_settings=CurrentSettings,
                 settings_sent=SS
                }=Conn) ->
    Ref = make_ref(),
    Bin = h2_frame_settings:send(CurrentSettings, SettingsToSend),
    socksend(Conn, Bin),
    send_ack_timeout({Ref,SettingsToSend}),
    Conn#connection{
      settings_sent=queue:in({Ref, SettingsToSend}, SS)
     }.

-spec send_ack_timeout({reference(), settings()}) -> pid().
send_ack_timeout(SS) ->
    Self = self(),
    SendAck = fun() ->
                  timer:sleep(5000),
                  gen_statem:cast(Self, {check_settings_ack,SS})
              end,
    spawn_link(SendAck).

%% private socket handling

spawn_data_receiver(Socket, Streams, Flow) ->
    Connection = self(),
    h2_stream_set:set_socket_recv_window_size(?DEFAULT_INITIAL_WINDOW_SIZE, Streams),
    Type = h2_stream_set:stream_set_type(Streams),
    spawn_link(fun() ->
                       fun F(S, St, First, Decoder) ->
                               case h2_frame:read(S, infinity) of
                                   {error, closed} ->
                                       Connection ! socket_closed(S);
                                   {error, Reason} ->
                                       Connection ! socket_error(S, Reason);
                                   {stream_error, 0, Code} ->
                                       %% Remaining Bytes don't matter, we're closing up shop.
                                       go_away_(Code, S, St),
                                       Connection ! {go_away, Code};
                                   {stream_error, StreamId, Code} ->
                                       Stream = h2_stream_set:get(StreamId, St),
                                       rst_stream__(Stream, Code, S),
                                       F(S, St, false, Decoder);
                                   {Header, Payload} = Frame ->
                                       %% TODO move some of the cases of route_frame into here
                                       %% so we can send frames directly to the stream pids
                                       StreamId = Header#frame_header.stream_id,
                                       case Header#frame_header.type of
                                           %% The first frame should be the client settings as per
                                           %% RFC-7540#3.5
                                           HType when HType /= ?SETTINGS andalso First ->
                                               go_away_(?PROTOCOL_ERROR, S, St),
                                               Connection ! {go_away, ?PROTOCOL_ERROR};
                                           ?DATA ->
                                               L = Header#frame_header.length,
                                               case L > h2_stream_set:socket_recv_window_size(St) of
                                                   true ->
                                                       go_away_(?FLOW_CONTROL_ERROR, S, St),
                                                       Connection ! {go_away, ?FLOW_CONTROL_ERROR};
                                                   false ->
                                                       Stream = h2_stream_set:get(Header#frame_header.stream_id, Streams),

                                                       case h2_stream_set:type(Stream) of
                                                           active ->
                                                               case {
                                                                 h2_stream_set:recv_window_size(Stream) < L,
                                                                 Flow,
                                                                 L > 0
                                                                } of
                                                                   {true, _, _} ->
                                                                       rst_stream__(Stream,
                                                                                   ?FLOW_CONTROL_ERROR,
                                                                                   S);
                                                                   %% If flow control is set to auto, and L > 0, send
                                                                   %% window updates back to the peer. If L == 0, we're
                                                                   %% not allowed to send window_updates of size 0, so we
                                                                   %% hit the next clause
                                                                   {false, auto, true} ->
                                                                       %% Make window size great again
                                                                       h2_frame_window_update:send(S,
                                                                                                   L, Header#frame_header.stream_id),
                                                                       %send_window_update(Connection, L),
                                                                       h2_stream_set:decrement_socket_recv_window(L, St),
                                                                       recv_data(Stream, Frame),
                                                                       h2_frame_window_update:send(S, L, 0),
                                                                       h2_stream_set:increment_socket_recv_window(L, St),
                                                                       F(S, St, false, Decoder);
                                                                   %% Either
                                                                   %% {false, auto, true} or
                                                                   %% {false, manual, _DoesntMatter}
                                                                   _Tried ->
                                                                       recv_data(Stream, Frame),
                                                                       h2_stream_set:decrement_socket_recv_window(L, St),
                                                                       h2_stream_set:upsert(
                                                                         h2_stream_set:decrement_recv_window(L, Stream),
                                                                         Streams),
                                                                       F(S, St, false, Decoder)
                                                               end;
                                                           _ ->
                                                               go_away_(?PROTOCOL_ERROR, S, St),
                                                               Connection ! {go_away, ?PROTOCOL_ERROR}
                                                       end
                                               end;
                                           ?HEADERS when Type == server, StreamId rem 2 == 0 ->
                                               go_away_(?PROTOCOL_ERROR, S, St),
                                               Connection ! {go_away, ?PROTOCOL_ERROR};
                                           ?HEADERS when Type == client ->
                                               Frames = case ?IS_FLAG((Header#frame_header.flags), ?FLAG_END_HEADERS) of
                                                            true ->
                                                                %% complete headers frame, just do it
                                                                [Frame];
                                                            false ->
                                                                read_continuations(Connection, S, StreamId, St, [Frame])
                                                        end,
                                               HeadersBin = h2_frame_headers:from_frames(Frames),
                                               case hpack:decode(HeadersBin, Decoder) of
                                                   {error, compression_error} ->
                                                       go_away_(?COMPRESSION_ERROR, S, St),
                                                       Connection ! {go_away, ?COMPRESSION_ERROR};
                                                   {ok, {Headers, NewDecoder}} ->
                                                       Stream = h2_stream_set:get(StreamId, St),
                                                       %% always headers or trailers!
                                                       recv_h_(Stream, S, Headers),
                                                       case ?IS_FLAG((Header#frame_header.flags), ?FLAG_END_STREAM) of
                                                           true ->
                                                               recv_es_(Stream, S);
                                                           false ->
                                                               ok
                                                       end,
                                                       F(S, St, false, NewDecoder)
                                               end;
                                           ?PRIORITY when StreamId == 0 ->
                                               go_away_(?PROTOCOL_ERROR, S, St),
                                               Connection ! {go_away, ?PROTOCOL_ERROR};
                                           ?PRIORITY ->
                                               %% seems unimplemented?
                                               F(S, St, false, Decoder);
                                           ?RST_STREAM when StreamId == 0 ->
                                               go_away_(?PROTOCOL_ERROR, S, St),
                                               Connection ! {go_away, ?PROTOCOL_ERROR};
                                           ?RST_STREAM ->
                                               Stream = h2_stream_set:get(StreamId, St),
                                               %% TODO: anything with this?
                                               %% EC = h2_frame_rst_stream:error_code(Payload),
                                               case h2_stream_set:type(Stream) of
                                                   idle ->
                                                       go_away_(?PROTOCOL_ERROR, S, St),
                                                       Connection ! {go_away, ?PROTOCOL_ERROR};
                                                   _Stream ->
                                                       %% TODO: RST_STREAM support
                                                       F(S, St, false, Decoder)
                                               end;
                                           ?PING when StreamId /= 0 ->
                                               go_away_(?PROTOCOL_ERROR, S, St),
                                               Connection ! {go_away, ?PROTOCOL_ERROR};
                                           ?PING when Header#frame_header.length /= 8 ->
                                               go_away_(?FRAME_SIZE_ERROR, S, St),
                                               Connection ! {go_away, ?FRAME_SIZE_ERROR};
                                           ?PING when ?NOT_FLAG((Header#frame_header.flags), ?FLAG_ACK) ->
                                               Ack = h2_frame_ping:ack(Payload),
                                               sock:send(S, h2_frame:to_binary(Ack)),
                                               F(S, St, false, Decoder);
                                           ?PUSH_PROMISE when Type == server ->
                                               go_away_(?PROTOCOL_ERROR, S, St),
                                               Connection ! {go_away, ?PROTOCOL_ERROR};
                                           %% TODO ACK'd pings
                                           %% TODO stream window updates (need to share send window size)
                                           _ ->
                                               gen_statem:call(Connection, {frame, Frame}),
                                               F(S, St, false, Decoder)
                                       end
                               end
                       end(Socket, Streams, true, hpack:new_context())
               end).

read_continuations(Connection, Socket, StreamId, Streams, Acc) ->
    case h2_frame:read(Socket, infinity) of
        {error, closed} ->
            Connection ! socket_closed(Socket),
            exit(normal);
        {error, Reason} ->
            Connection ! socket_error(Socket, Reason),
            exit(normal);
        {stream_error, _StreamId, _Code} ->
            go_away_(?PROTOCOL_ERROR, Socket, Streams),
            Connection ! {go_away, ?PROTOCOL_ERROR},
            exit(normal);
        {Header, _Payload} = Frame ->
            case Header#frame_header.type == ?CONTINUATION andalso Header#frame_header.stream_id == StreamId of
                false ->
                    go_away_(?PROTOCOL_ERROR, Socket, Streams),
                    Connection ! {go_away, ?PROTOCOL_ERROR},
                    exit(normal);
                true ->
                    case ?IS_FLAG((Header#frame_header.flags), ?FLAG_END_HEADERS) of
                        true ->
                            lists:reverse([Frame|Acc]);
                        false ->
                            read_continuations(Connection, Socket, StreamId, Streams, [Frame|Acc])
                    end
            end
    end.

socket_closed({gen_tcp, Socket}) ->
    {tcp_closed, Socket};
socket_closed({ssl, Socket}) ->
    {ssl_closed, Socket}.

socket_error({gen_tcp, Socket}, Reason) ->
    {tcp_error, Socket, Reason};
socket_error({ssl, Socket}, Reason) ->
    {ssl_error, Socket, Reason}.

client_options(Transport, SSLOptions, SocketOptions) ->
    DefaultSocketOptions = [
                           {mode, binary},
                           {packet, raw},
                           {active, false}
                          ],
    ClientSocketOptions = merge_options(DefaultSocketOptions, SocketOptions),
    case Transport of
        ssl ->
            [{alpn_advertised_protocols, [<<"h2">>]}|ClientSocketOptions ++ SSLOptions];
        gen_tcp ->
            ClientSocketOptions
    end.

merge_options(A, B) ->
    proplists:from_map(maps:merge(proplists:to_map(A), proplists:to_map(B))).

start_http2_server(
  Http2Settings,
  #connection{
     socket=Socket
    }=Conn) ->
    case accept_preface(Socket) of
        ok ->
            Flow = application:get_env(chatterbox, server_flow_control, auto),
            Receiver = spawn_data_receiver(Socket, Conn#connection.streams, Flow),
            NewState =
                Conn#connection{
                  type=server,
                  receiver=Receiver
                 },
            {next_state,
             handshake,
             send_settings(Http2Settings, NewState)
            };
        {error, invalid_preface} ->
            {next_state, closing, Conn}
    end.

%% We're going to iterate through the preface string until we're done
%% or hit a mismatch
accept_preface(Socket) ->
    accept_preface(Socket, <<?PREFACE>>).

accept_preface(_Socket, <<>>) ->
    ok;
accept_preface(Socket, <<Char:8,Rem/binary>>) ->
    case sock:recv(Socket, 1, 5000) of
        {ok, <<Char>>} ->
            accept_preface(Socket, Rem);
        _E ->
            sock:close(Socket),
            {error, invalid_preface}
    end.

%% Incoming data is a series of frames. With a passive socket we can just:
%% 1. read(9)
%% 2. turn that 9 into an http2 frame header
%% 3. use that header's length field L
%% 4. read(L), now we have a frame
%% 5. do something with it
%% 6. goto 1

%% Things will be different with an {active, true} socket, and also
%% different again with an {active, once} socket

%% with {active, true}, we'd have to maintain some kind of input queue
%% because it will be very likely that Data is not neatly just a frame

%% with {active, once}, we'd probably be in a situation where Data
%% starts with a frame header. But it's possible that we're here with
%% a partial frame left over from the last active stream

%% We're going to go with the {active, once} approach, because it
%% won't block the gen_server on Transport:read(L), but it will wake
%% up and do something every time Data comes in.


handle_socket_passive(Conn) ->
    {keep_state, Conn}.

handle_socket_closed(Conn) ->
    {stop, normal, Conn}.

handle_socket_error(Reason, Conn) ->
    {stop, {shutdown, Reason}, Conn}.

socksend(#connection{
            socket=Socket
           }, Data) ->
    case sock:send(Socket, Data) of
        ok ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

%% maybe_hpack will decode headers if it can, or tell the connection
%% to wait for CONTINUATION frames if it can't.
-spec maybe_hpack(gen_statem:event_type(), #continuation_state{}, connection()) ->
                         {next_state, atom(), connection()}.
%% If there's an END_HEADERS flag, we have a complete headers binary
%% to decode, let's do this!
maybe_hpack(Event, Continuation, Conn)
  when Continuation#continuation_state.end_headers ->
    Stream = h2_stream_set:get(
               Continuation#continuation_state.stream_id,
               Conn#connection.streams
              ),
    HeadersBin = h2_frame_headers:from_frames(
                lists:reverse(Continuation#continuation_state.frames)
               ),
    case hpack:decode(HeadersBin, Conn#connection.decode_context) of
        {error, compression_error} ->
            go_away(Event, ?COMPRESSION_ERROR, Conn);
        {ok, {Headers, NewDecodeContext}} ->
            case {Continuation#continuation_state.type,
                  Continuation#continuation_state.end_stream} of
                {push_promise, _} ->
                    Promised =
                        h2_stream_set:get(
                          Continuation#continuation_state.promised_id,
                          Conn#connection.streams
                         ),
                    recv_pp(Promised, Headers);
                {trailers, false} ->
                    rst_stream_(Event, Stream, ?PROTOCOL_ERROR, Conn);
                _ -> %% headers or trailers!
                    recv_h(Stream, Conn, Headers)
            end,
            case Continuation#continuation_state.end_stream of
                true ->
                    recv_es(Stream, Conn);
                false ->
                    ok
            end,
            maybe_reply(Event, {next_state, connected,
             Conn#connection{
               decode_context=NewDecodeContext,
               continuation=undefined
              }}, ok)
    end;
%% If not, we have to wait for all the CONTINUATIONS to roll in.
maybe_hpack(Event, Continuation, Conn) ->
    maybe_reply(Event, {next_state, continuation,
     Conn#connection{
       continuation = Continuation
      }}, ok).

%% Stream API: These will be moved
-spec recv_h(
        Stream :: h2_stream_set:stream(),
        Conn :: connection(),
        Headers :: hpack:headers()) ->
                    ok.
recv_h(Stream,
       Conn,
       Headers) ->
    case h2_stream_set:type(Stream) of
        active ->
            %% If the stream is active, let the process deal with it.
            Pid = h2_stream_set:pid(Stream),
            h2_stream:send_event(Pid, {recv_h, Headers});
        closed ->
            %% If the stream is closed, there's no running FSM
            rst_stream_(cast, Stream, ?STREAM_CLOSED, Conn);
        idle ->
            %% If we're calling this function, we've already activated
            %% a stream FSM (probably). On the off chance we didn't,
            %% we'll throw this
            rst_stream_(cast, Stream, ?STREAM_CLOSED, Conn)
    end.

recv_h_(Stream,
       Sock,
       Headers) ->
    case h2_stream_set:type(Stream) of
        active ->
            %% If the stream is active, let the process deal with it.
            Pid = h2_stream_set:pid(Stream),
            h2_stream:send_event(Pid, {recv_h, Headers});
        closed ->
            %% If the stream is closed, there's no running FSM
            rst_stream__(Stream, ?STREAM_CLOSED, Sock);
        idle ->
            %% If we're calling this function, we've already activated
            %% a stream FSM (probably). On the off chance we didn't,
            %% we'll throw this
            rst_stream__(Stream, ?STREAM_CLOSED, Sock)
    end.


-spec send_h(
        h2_stream_set:stream(),
        hpack:headers()) ->
                    ok.
send_h(Stream, Headers) ->
    case h2_stream_set:pid(Stream) of
        undefined ->
            %% TODO: Should this be some kind of error?
            ok;
        Pid ->
            h2_stream:send_event(Pid, {send_h, Headers})
    end.

-spec send_t(
        h2_stream_set:stream(),
        hpack:headers()) ->
                    ok.
send_t(Stream, Trailers) ->
    case h2_stream_set:pid(Stream) of
        undefined ->
            %% TODO:  Should this be some kind of error?
            ok;
        Pid ->
            h2_stream:send_event(Pid, {send_t, Trailers})
    end.

-spec recv_es(Stream :: h2_stream_set:stream(),
              Conn :: connection()) ->
                     ok | {rst_stream, error_code()}.

recv_es(Stream, Conn) ->
    case h2_stream_set:type(Stream) of
        active ->
            Pid = h2_stream_set:pid(Stream),
            h2_stream:send_event(Pid, recv_es);
        closed ->
            rst_stream_(cast, Stream, ?STREAM_CLOSED, Conn);
        idle ->
            rst_stream_(cast, Stream, ?STREAM_CLOSED, Conn)
    end.

recv_es_(Stream, Sock) ->
    case h2_stream_set:type(Stream) of
        active ->
            Pid = h2_stream_set:pid(Stream),
            h2_stream:send_event(Pid, recv_es);
        closed ->
            rst_stream__(Stream, ?STREAM_CLOSED, Sock);
        idle ->
            rst_stream__(Stream, ?STREAM_CLOSED, Sock)
    end.


-spec recv_pp(h2_stream_set:stream(),
              hpack:headers()) ->
                     ok.
recv_pp(Stream, Headers) ->
    case h2_stream_set:pid(Stream) of
        undefined ->
            %% Should this be an error?
            ok;
        Pid ->
            h2_stream:send_event(Pid, {recv_pp, Headers})
    end.

-spec recv_data(h2_stream_set:stream(),
                h2_frame:frame()) ->
                        ok.
recv_data(Stream, Frame) ->
    case h2_stream_set:pid(Stream) of
        undefined ->
            %% Again, error? These aren't errors now because the code
            %% isn't set up to handle errors when these are called
            %% anyway.
            ok;
        Pid ->
            h2_stream:send_event(Pid, {recv_data, Frame})
    end.

send_request_(NotifyPid, Conn, Streams, Headers, Body) ->
    send_request_(NotifyPid, Conn, Streams, Headers, Body, Conn#connection.stream_callback_mod, Conn#connection.stream_callback_opts).

send_request_(NotifyPid, Conn, Streams, Headers, Body, CallbackMod, CallbackOpts) ->
    case
        h2_stream_set:new_stream(
          next,
            NotifyPid,
            CallbackMod,
            CallbackOpts,
            Conn#connection.socket,
            Conn#connection.peer_settings#settings.initial_window_size,
            Conn#connection.self_settings#settings.initial_window_size,
            Conn#connection.type,
            Streams)
    of
        {error, Code, _NewStream} ->
            %% error creating new stream
            {error, Code};
        {_Pid, NextId, GoodStreamSet} ->
            Conn1 = send_headers_(NextId, Headers, [], Conn),
            Conn2 = send_body_(NextId, Body, [], Conn1),

            {ok, Conn2#connection{streams=GoodStreamSet}}
    end.

send_body_(StreamId, Body, Opts, Conn) ->
    BodyComplete = proplists:get_value(send_end_stream, Opts, true),

    Stream = h2_stream_set:get(StreamId, Conn#connection.streams),
    case h2_stream_set:type(Stream) of
        active ->
            OldBody = h2_stream_set:queued_data(Stream),
            NewBody = case is_binary(OldBody) of
                          true -> <<OldBody/binary, Body/binary>>;
                          false -> Body
                      end,
            {NewSWS, NewStreams} =
                h2_stream_set:send_what_we_can(
                  StreamId,
                  Conn#connection.send_window_size,
                  (Conn#connection.peer_settings)#settings.max_frame_size,
                  h2_stream_set:upsert(
                    h2_stream_set:update_data_queue(NewBody, BodyComplete, Stream),
                    Conn#connection.streams)),

             Conn#connection{
               send_window_size=NewSWS,
               streams=NewStreams
              };
        idle ->
            %% Sending DATA frames on an idle stream?  It's a
            %% Connection level protocol error on reciept, but If we
            %% have no active stream what can we even do?
            Conn;
        closed ->
            Conn
    end.

