-module(stream_handler).

-export([init/4]).
-export([stream/3]).
-export([info/3]).
-export([terminate/2]).

-record(state, {
          active,
          token,
          connection
         }).

init(_Transport, Req, _Opts, Active) ->

    ConnectionPid = case Active of
                        once ->
                            init_xhr_get(Req);
                        false ->
                            init_xhr_post(Req);
                        true -> 
                            init_long_lived()
                    end,
    {ok, Req, #state{active = Active, token = undefined, connection = ConnectionPid}}.

stream(Data, Req, State = #state{connection = Connection}) ->
    gen_server:cast(Connection, {process_message, Data}),
    {ok, Req, State}.

info({text, Msg}, Req, State) ->
    {reply, Msg, Req, State};
info({send_token, Token}, Req, State) ->
    Req2 = cowboy_req:set_resp_header(<<"connection-id">>, Token, Req),
    Msg = "connection-id",
    {reply, Msg, Req2, State#state{token = Token}};
info(_Info, Req, State) ->
    {ok, Req, State}.

terminate(_Req, #state{connection = ConnectionPid}) ->

    ConnectionPid ! connection_hiatus,
    ok.

%%
% Internal functions
%%

create_connection() ->
    Token = list_to_binary(uuid:to_string(uuid:v4())),
    self() ! {send_token, Token},
    {ok, CPid} = supervisor:start_child(carotene_connection_sup, [self(), intermitent]),
    ets:insert(carotene_connections, {Token, CPid}),
    CPid.

init_xhr_get(Req) ->
    case cowboy_req:header(<<"connection-id">>, Req) of
        {undefined, _Req2} ->
            create_connection();
        {ConnId, _Req2} -> 
            case ets:lookup(carotene_connections, ConnId) of
                [{_, Conn}] -> 
                    case is_process_alive(Conn) of
                        true ->
                            gen_server:call(Conn, {keepalive, self()}),
                            Conn;
                        false ->
                            create_connection()
                    end;
                [] ->
                    create_connection()
            end
    end.

init_xhr_post(Req) ->
    case cowboy_req:header(<<"connection-id">>, Req) of
        {undefined, _Req2} ->
            create_connection();
        {ConnId, _Req2} -> 
            case ets:lookup(carotene_connections, ConnId) of
                [{_, Conn}] -> Conn;
                [] -> create_connection()
            end
    end.

init_long_lived() ->
    {ok, CPid} = supervisor:start_child(carotene_connection_sup, [self(), permanent]),
    CPid.