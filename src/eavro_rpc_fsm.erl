-module(eavro_rpc_fsm).

-behaviour(gen_fsm).

-include("eavro.hrl").

%% API
-export([start_link/3]).

%% gen_fsm callbacks
-export([init/1,
	 handle_event/3,
	 handle_sync_event/4,
	 handle_info/3,
	 terminate/3,
	 code_change/4]).

%% gen_fsm states
-export([connect/2,
	 connect/3,
	 handshake_start/2,
	 handshake_start/3,
	 handshake_finish/2,
	 handshake_finish/3,
	 main/2,
	 main/3]).

-export([call/3, call/4]).

-record(state, { host,
		 port,
		 proto :: #avro_proto{},
		 socket,
		 cont,
		 serial = 0,
		 reply_list = [] }).
-record(call, { name, args}).

%%%===================================================================
%%% API
%%%===================================================================

-type fsm_ref() :: atom() |
		   {atom(), node()} |
		   {global, any()} |
		   {via, atom(),atom()} |
		   pid().

start_link(Host, Port, ProtoFilename) when is_integer(hd(ProtoFilename)) ->
    Proto = eavro_rpc_proto:parse_protocol_file(ProtoFilename),
    start_link(Host, Port, Proto);
start_link(Host, Port, Proto) ->
    gen_fsm:start_link(?MODULE, [Host, Port, Proto], []).

-spec call(FsmRef :: fsm_ref(), MethodName :: atom(), Args :: [any()]) ->
		  {ok, Result :: any()} | {error, any()}.
call(FsmRef, Name, Args) when is_list(Args) ->
    gen_fsm:sync_send_event(FsmRef, #call{name = Name, args = Args}, infinity).


-spec call(FsmRef :: fsm_ref(), MethodName :: atom(), Args :: [any()],
	   Timeout :: non_neg_integer() | infinity) ->
		  {ok, Result :: any()} | {error, any()}.
call(FsmRef, Name, Args, Timeout) when is_list(Args) ->
    gen_fsm:sync_send_event(FsmRef, #call{name = Name, args = Args}, Timeout).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

init([Host, Port, Proto]) ->
    ConnectFun =
	fun(State) ->
		{ok, Sock} = gen_tcp:connect(
			       Host, Port,
			       [inet, binary,
				{packet, 0},
				{active, true},
				{nodelay, true},
				{reuseaddr, true}], 3000),
		{cont, Cont} = eavro_rpc_proto:decode_frame_sequences(<<>>),
		{next_state, handshake_start,
		 State#state{ socket = Sock,
			      proto  = Proto,
			      serial = 0,
			      cont   = Cont }}
	end,
    gen_fsm:send_event_after(0, {connect, 0, ConnectFun}),
    {ok, connect, #state{ host = Host, port = Port}}.

%%
%% STATE: CONNECT
%%
connect({connect, N, Fun}, #state{ host = Host, port = Port} = State) ->
    try Fun(State)
    catch
	_:Reason ->
	    if N rem 3 == 0 ->
		    error_logger:error_msg(
		      "Failed to connect to Flume/AvroAPI endpoint ~p due to: ~p~n",
		      [{Host, Port}, Reason]);
	       true -> ok
	    end,
	    gen_fsm:send_event_after(5000, {connect, N + 1, Fun}),
	    {next_state, connect, State}
    end.

connect(_Event = #call{}, _From, State) ->
    {reply, {error, connecting}, connect, State}.

%%
%% STATE: HANDSHAKE-START
%%

handshake_start(_Event = #call{ name = Name, args = Args},
		#state{socket  = Sock, serial = Ser,
		       proto = #avro_proto{json = Json} = Proto} = State)
  when is_list(Args) ->
    HReq = eavro:encode(
	     eavro_rpc_proto:schema_HandshakeRequest(),
	     [erlang:md5(Json),
	      {string, Json},
	      <<0:128>>,
	      {#avro_map{ values = bytes}, []}]),
    EncCall = eavro_rpc_proto:encode_call(Proto, Name, Args),
    ok = gen_tcp:send(
	   Sock, make_frame_sequence(Ser, [HReq, EncCall]) ),
    {next_state, handshake_finish, State#state{serial = Ser + 1}}.

handshake_start(Event = #call{}, From, State) ->
    handshake_start(Event, track_caller(From, Event, State) ).


%%
%% STATE: HANDSHAKE-FINISH
%%
handshake_finish(_Event = #call{ name = Name, args = Args},
		#state{socket  = Sock, serial = Ser,
		       proto = Proto} = State)
  when is_list(Args) ->
    EncCall = eavro_rpc_proto:encode_call(Proto, Name, Args),
    ok = gen_tcp:send(
	   Sock, make_frame_sequence(Ser, [EncCall]) ),
    {next_state, handshake_finish, State#state{serial = Ser + 1}}.

handshake_finish(Event = #call{}, From, State) ->
    handshake_finish(Event, track_caller(From, Event, State) ).


%%
%% STATE: MAIN
%%
main(_Event = #call{ name = Name, args = Args},
     #state{socket  = Sock, serial = Ser,
	    proto = Proto} = State) when is_list(Args) ->
    EncCall = eavro_rpc_proto:encode_call(Proto, Name, Args),
    ok = gen_tcp:send(
	   Sock, make_frame_sequence(Ser, [EncCall])),
    {next_state, main, State#state{serial = Ser + 1}}.

main(Event = #call{}, From, State) ->
    main(Event, track_caller(From, Event, State)).

track_caller(Caller,
		  #call{ name = Name},
		  #state{serial = Ser,
			 reply_list =  RL} = State) ->
    State#state{serial = Ser,
		reply_list = [{Ser, Caller, Name} | RL] }.


%%
%%
%%
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

handle_info(_Info = {tcp, Sock, Data},
	    handshake_finish = CurrState,
	    #state{socket = Sock, cont = Cont} = State) ->
    case Cont(Data) of
	{cont, Cont1} ->
	    {next_state, CurrState, State#state{ cont = Cont1 } };
	{ [{0 = Ser0, [ HeadFrame | Frames ]} = _HeadSeq | Sequences], {cont, Cont1} } ->
	    { _HSResp = [Match|_], HeadFrameTail } =
		eavro_rpc_proto:decode_handshake_response(HeadFrame),
	    Match == 'NONE' andalso exit(server_not_support_protocol),
	    Sequences1 = [{Ser0, [HeadFrameTail|Frames]} | Sequences],
	    State1 = reply_to_clients(Sequences1, State),
	    {next_state, main, State1#state{ cont = Cont1 }}
    end;
handle_info(_Info = {tcp, Sock, Data}, main,
	    #state{socket = Sock, cont = Cont} = State) ->
    case Cont(Data) of
	{cont, Cont1} ->
	    {next_state, main, State#state{ cont = Cont1 } };
	{ Sequences, {cont, Cont1} } ->
	    State1 = reply_to_clients(Sequences, State),
	    {next_state, main, State1#state{ cont = Cont1 }}
    end;
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.



reply_to_clients([], State) ->
    State;
reply_to_clients([ {Ser, Frames} | Seqs],
		 #state{ proto = Proto, reply_list = Clis } = State) ->
    case lists:keytake(Ser, 1, Clis) of
	false -> Clis1 = Clis;
	{value, {Ser, Caller, MessageName}, Clis1 } ->
	    #avro_message{ return = RetType} =
		eavro_rpc_proto:get_message(Proto, MessageName),
	    Resp = eavro_rpc_proto:decode_call_response(RetType, iolist_to_binary(Frames)),
	    gen_fsm:reply(Caller, Resp)
    end,
    reply_to_clients(Seqs, State#state{ reply_list = Clis1 }).

terminate(_Reason, _StateName, _State) -> ok.
code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec make_frame( Data :: iolist()) -> iolist().
make_frame(Data) ->
    Size = iolist_size(Data),
    [<<Size:32>>, Data].

make_frame_sequence(Serial, EncodedCalls) when is_integer(Serial),
					       is_list(EncodedCalls) ->
    SequenceLength = length(EncodedCalls),
    [<<Serial:32, SequenceLength:32>> | [ make_frame(Call) || Call <- EncodedCalls ] ].
