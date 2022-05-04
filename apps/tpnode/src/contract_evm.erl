-module(contract_evm).
-behaviour(smartcontract2).

-export([deploy/5, handle_tx/5, getters/0, get/3, info/0, call/3]).
-export([transform_extra/1]).

info() ->
	{<<"evm">>, <<"EVM">>}.

convert_storage(Map) ->
  maps:fold(
    fun(K,0,A) ->
        maps:put(binary:encode_unsigned(K), <<>>, A);
       (K,V,A) ->
        maps:put(binary:encode_unsigned(K), binary:encode_unsigned(V), A)
    end,#{},Map).


deploy(#{from:=From,txext:=#{"code":=Code}=_TE}=Tx, Ledger, GasLimit, _GetFun, Opaque) ->
  %DefCur=maps:get("evmcur",TE,<<"SK">>),
  Value=case tx:get_payload(Tx, transfer) of
          undefined ->
            0;
          #{amount:=A,cur:= <<"SK">>} ->
            A;
          _ ->
            0
        end,

  Logger=fun(Message,Args) ->
             lager:info("EVM tx ~p log ~p ~p",[Tx,Message,Args])
         end,

  State=case maps:get(state,Ledger,#{}) of
          Map when is_map(Map) -> Map;
          _ -> #{}
        end,

  io:format("Run EVM~n"),
  EvalRes = eevm:eval(Code,
                      State,
                      #{
                        logger=>Logger,
                        gas=>GasLimit,
                        data=>#{
                                address=>binary:decode_unsigned(From),
                                callvalue=>Value,
                                caller=>binary:decode_unsigned(From),
                                gasprice=>1,
                                origin=>binary:decode_unsigned(From)
                               },
                        trace=>whereis(eevm_tracer)
                       }),
  io:format("EvalRes ~p~n",[EvalRes]),
  case EvalRes of
    {done, {return,NewCode}, #{ gas:=GasLeft, storage:=NewStorage }} ->
      io:format("Deploy -> OK~n",[]),
      {ok, #{null=>"exec",
             "code"=>NewCode,
             "state"=>convert_storage(NewStorage),
             "gas"=>GasLeft,
             "txs"=>[]
            }, Opaque};
    {done, 'stop', _} ->
      io:format("Deploy -> stop~n",[]),
      {error, deploy_stop};
    {done, 'invalid', _} ->
      io:format("Deploy -> invalid~n",[]),
      {error, deploy_invalid};
    {done, {revert, _}, _} ->
      io:format("Deploy -> revert~n",[]),
      {error, deploy_revert};
    {error, nogas, _} ->
      io:format("Deploy -> nogas~n",[]),
      {error, nogas};
    {error, {jump_to,_}, _} ->
      io:format("Deploy -> bad_jump~n",[]),
      {error, bad_jump};
    {error, {bad_instruction,_}, _} ->
      io:format("Deploy -> bad_instruction~n",[]),
      {error, bad_instruction}
%
% {done, [stop|invalid|{revert,Err}|{return,Data}], State1}
% {error,[nogas|{jump_to,Dst}|{bad_instruction,Instr}], State1}


    %{done,{revert,Data},#{gas:=G}=S2};
  end.

encode_arg(Arg,Acc) when is_integer(Arg) ->
  <<Acc/binary,Arg:256/big>>;
encode_arg(<<Arg:256/big>>,Acc) ->
  <<Acc/binary,Arg:256/big>>;
encode_arg(<<Arg:64/big>>,Acc) ->
  <<Acc/binary,Arg:256/big>>;
encode_arg(_,_) ->
  throw(arg_encoding_error).


handle_tx(#{to:=To,from:=From}=Tx, #{code:=Code}=Ledger,
          GasLimit, GetFun, Opaque) ->
  State=case maps:get(state,Ledger,#{}) of
          BinState when is_binary(BinState) ->
            {ok,MapState}=msgpack:unpack(BinState),
            MapState;
          MapState when is_map(MapState) ->
            MapState
        end,

  Value=case tx:get_payload(Tx, transfer) of
          undefined ->
            0;
          #{amount:=A,cur:= <<"SK">>} ->
            A;
          _ ->
            0
        end,
  
  Logger=fun(Message,Args) ->
             lager:info("EVM tx ~p log ~p ~p",[Tx,Message,Args])
         end,
  CD=case Tx of
       #{call:=#{function:="0x"++FunID,args:=CArgs}} ->
         FunHex=hex:decode(FunID),
         lists:foldl(fun encode_arg/2, <<FunHex:4/binary>>, CArgs);
       #{call:=#{function:=FunNameID,args:=CArgs}} when is_list(FunNameID) ->
         {ok,E}=ksha3:hash(256, list_to_binary(FunNameID)),
         <<X:4/binary,_/binary>> = E,
         lists:foldl(fun encode_arg/2, <<X:4/binary>>, CArgs);
       _ ->
         <<>>
     end,


  SLoad=fun(Addr, IKey, _Ex0=#{get_addr:=GAFun}) ->
            io:format("=== Load key ~p:~p ~p~n",[Addr,IKey,GAFun]),
            BKey=binary:encode_unsigned(IKey),
            binary:decode_unsigned(
              if Addr == To ->
                   case maps:is_key(BKey,State) of
                     true ->
                       maps:get(BKey, State, <<0>>);
                     false ->
                       GAFun({storage,binary:encode_unsigned(Addr),BKey})
                   end;
                 true ->
                   GAFun({storage,binary:encode_unsigned(Addr),BKey})
              end
             )
        end,
  CreateFun = fun(Value1, Code1, #{aalloc:=AAlloc}=Ex0) ->
                  io:format("Ex0 ~p~n",[Ex0]),
                  {ok, Addr0, AAlloc1}=generate_block:aalloc(AAlloc),
                  io:format("Address ~p~n",[Addr0]),
                  Addr=binary:decode_unsigned(Addr0),
                  Ex1=Ex0#{aalloc=>AAlloc1},
                  io:format("Ex1 ~p~n",[Ex1]),
                  Deploy=eevm:eval(Code1,#{},#{
                                               gas=>100000,
                                               extra=>Ex1,
                                               sload=>SLoad,
                                               data=>#{
                                                       address=>Addr,
                                                       callvalue=>Value,
                                                       caller=>binary:decode_unsigned(From),
                                                       gasprice=>1,
                                                       origin=>binary:decode_unsigned(From)
                                                      },
                                               logger=>Logger,
                                               trace=>whereis(eevm_tracer)
                                              }),
                  {done,{return,RX},#{storage:=StRet,extra:=Ex2}}=Deploy,
                  io:format("Ex2 ~p~n",[Ex2]),

                  St2=maps:merge(
                        maps:get({Addr,state},Ex2,#{}),
                        StRet),
                  Ex3=maps:merge(Ex2,
                                 #{
                                   {Addr,state} => St2,
                                   {Addr,code} => RX,
                                   {Addr,value} => Value1
                                  }
                                ),
                  io:format("Ex3 ~p~n",[Ex3]),
                  Ex4=maps:put(created,[Addr|maps:get(created,Ex3,[])],Ex3),

                  {#{ address => Addr },Ex4}
              end,
  GetCodeFun = fun(Addr,Ex0) ->
                   io:format(".: Get code for  ~p~n",[Addr]),
                   case maps:is_key({Addr,code},Ex0) of
                     true ->
                       maps:get({Addr,code},Ex0,<<>>);
                     false ->
                       GotCode=GetFun({addr,binary:encode_unsigned(Addr),code}),
                       {ok, GotCode, maps:put({Addr,code},GotCode,Ex0)}
                   end
               end,
  GetBalFun = fun(Addr,Ex0) ->
                  case maps:is_key({Addr,value},Ex0) of
                    true ->
                      maps:get({Addr,value},Ex0);
                    false ->
                      131071
                  end
              end,


  Result = eevm:eval(Code,
                 #{},
                 #{
                   gas=>GasLimit,
                   sload=>SLoad,
                   extra=>Opaque,
                   get=>#{
                          code => GetCodeFun,
                          balance => GetBalFun
                         },
                   create => CreateFun,
                   data=>#{
                           address=>binary:decode_unsigned(To),
                           callvalue=>Value,
                           caller=>binary:decode_unsigned(From),
                           gasprice=>1,
                           origin=>binary:decode_unsigned(From)
                          },
                   cd=>CD,
                   logger=>Logger,
                   trace=>whereis(eevm_tracer)
                  }),

  io:format("Call ~p -> {~p,~p,...}~n",[CD, element(1,Result),element(2,Result)]),
  case Result of
    {done, {return,RetVal}, RetState} ->
      returndata(RetState,#{"return"=>RetVal});
    {done, 'stop', RetState} ->
      returndata(RetState,#{});
    {done, 'invalid', _} ->
      {ok, #{null=>"exec",
             "state"=>unchanged,
             "gas"=>0,
             "txs"=>[]}, Opaque};
    {done, {revert, _}, #{ gas:=GasLeft}} ->
      {ok, #{null=>"exec",
             "state"=>unchanged,
             "gas"=>GasLeft,
             "txs"=>[]}, Opaque};
    {error, nogas, #{storage:=NewStorage}} ->
      io:format("St ~w keys~n",[maps:size(NewStorage)]),
      io:format("St ~p~n",[(NewStorage)]),
      {error, nogas, 0};
    {error, {jump_to,_}, _} ->
      {error, bad_jump, 0};
    {error, {bad_instruction,_}, _} ->
      {error, bad_instruction, 0}
  end.



call(#{state:=State,code:=Code}=_Ledger,Method,Args) ->
  SLoad=fun(IKey) ->
            %io:format("Load key ~p~n",[IKey]),
            BKey=binary:encode_unsigned(IKey),
            binary:decode_unsigned(maps:get(BKey, State, <<0>>))
        end,
  CD=case Method of
       "0x"++FunID ->
         FunHex=hex:decode(FunID),
         lists:foldl(fun encode_arg/2, <<FunHex:4/binary>>, Args);
       FunNameID when is_list(FunNameID) ->
         {ok,E}=ksha3:hash(256, list_to_binary(FunNameID)),
         <<X:4/binary,_/binary>> = E,
         lists:foldl(fun encode_arg/2, <<X:4/binary>>, Args)
     end,
  Logger=fun(Message,LArgs) ->
             lager:info("EVM log ~p ~p",[Message,LArgs])
         end,

  Result = eevm:eval(Code,
                     #{},
                     #{
                       gas=>20000,
                       sload=>SLoad,
                       value=>0,
                       cd=>CD,
                       caller=><<0>>,
                       logger=>Logger,
                       trace=>whereis(eevm_tracer)
                      }),
  case Result of
    {done, {return,RetVal}, _} ->
      {ok, RetVal};
    {done, 'stop', _} ->
      {ok, stop};
    {done, 'invalid', _} ->
      {ok, invalid};
    {done, {revert, Msg}, _} ->
      {ok, Msg};
    {error, nogas, _} ->
      {error, nogas, 0};
    {error, {jump_to,_}, _} ->
      {error, bad_jump, 0};
    {error, {bad_instruction,_}, _} ->
      {error, bad_instruction, 0}
  end.

transform_extra_created(#{created:=C}=Extra) ->
  M1=lists:foldl(
       fun(Addr, ExtraAcc) ->
           io:format("Created addr ~p~n",[Addr]),
           {Acc1, ToDel}=maps:fold(
           fun
             ({Addr1, state}=K,Value,{IAcc,IToDel}) when Addr==Addr1 ->
              {
               mbal:put(state,convert_storage(Value),IAcc),
               [K|IToDel]
              };
            ({Addr1, value}=K,Value,{IAcc,IToDel}) when Addr==Addr1 ->
              {
               mbal:put_cur(<<"SK">>,Value,IAcc),
               [K|IToDel]
              };
            ({Addr1, code}=K,Value,{IAcc,IToDel}) when Addr==Addr1 ->
              {
               mbal:put(code,Value,IAcc),
               [K|IToDel]
              };
            (_K,_V,A) ->
              A
                           end, {mbal:new(),[]}, ExtraAcc),
           maps:put(binary:encode_unsigned(Addr), Acc1,
                    maps:without(ToDel,ExtraAcc)
                   )
       end, Extra, C),
  M1#{created => [ binary:encode_unsigned(X) || X<-C ]};

transform_extra_created(Extra) ->
  Extra.

transform_extra_changed(#{changed:=C}=Extra) ->
  {Changed,ToRemove}=lists:foldl(fun(Addr,{Acc,Remove}) ->
                             case maps:is_key({Addr,state},Extra) of
                               true ->
                                 {
                                  [{{binary:encode_unsigned(Addr),mergestate},
                                    convert_storage(maps:get({Addr,state},Extra))}|Acc],
                                  [{Addr,state}|Remove]
                                 };
                               false ->
                                 {Acc,Remove}
                             end
                         end, {[],[]}, C),
  maps:put(changed, Changed,
           maps:without(ToRemove,Extra)
          );

transform_extra_changed(Extra) ->
  Extra.

transform_extra(Extra) ->
  io:format("Extra ~p~n",[Extra]),
  T1=transform_extra_created(Extra),
  T2=transform_extra_changed(T1),
  T2.

returndata(#{ gas:=GasLeft, storage:=NewStorage, extra:=Extra },Append) ->
  {ok,
   maps:merge(
     #{null=>"exec",
       "storage"=>convert_storage(NewStorage),
       "gas"=>GasLeft,
       "txs"=>[]},
     Append),
   transform_extra(Extra)}.

getters() ->
  [].

get(_,_,_Ledger) ->
  throw("unknown method").

