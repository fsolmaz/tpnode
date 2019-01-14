-module(genuml).

-export([bv/3, testz/1, block/3]).

% --------------------------------------------------------------------------------

-define(get_node(NodeKey), node_map(proplists:get_value(NodeKey, PL, File))).

-define(MAX_MESSAGES, 10000).
% --------------------------------------------------------------------------------


node_map(NodeName) when is_binary(NodeName) ->
  Map = #{
    <<"node_287nRpYV">> => <<"c4n1">>,
    <<"node_3NBx74Ed">> => <<"c4n2">>,
    <<"node_28AFpshz">> => <<"c4n3">>
  },
  maps:get(NodeName, Map, NodeName);

node_map(NodeName) ->
  node_map(utils:make_binary(NodeName)).


block(BLog,T1,T2) ->
  MapFun=fun(_T,mkblock_done, PL) ->
             PL;
            (_,N,_) ->
             io:format("N ~s~n",[N]),
             ignore
         end,
  {Done,Events1,MinT,MaxT}=stout_reader:fold(
    fun
      (T,_,_,Acc) when T1>0, T<T1 -> Acc;
      (T,_,_,Acc) when T2>0, T>T2 -> Acc;
      (_,_,_,{?MAX_MESSAGES,_,_,_}=Acc) -> Acc;
      (T,Kind, PL, {C,Acc,M1,M2}) ->
        R=MapFun(T,Kind,PL),
        if R==ignore ->
             {C,
              Acc,
              min(M1,T),
              max(M2,T)
             };
           is_list(R) ->
             {C+1,
              [Acc,R],
              min(M1,T),
              max(M2,T)
             }
        end
    end, {0,[],erlang:system_time(),0}, BLog),
  io:format("~w done T ~w ... ~w~n",[Done,MinT,MaxT]),
  Events1.

% --------------------------------------------------------------------------------

bv(BLog, T1, T2) ->
  MapFun =
    fun
      (T, sync_ticktimer, PL, File) ->
        Node = ?get_node(node),
        [{T, Node, Node, "sync_ticktimer", #{arrow_type => hnote}}];
    
      (T, txqueue_prepare, PL, File) ->
        Node = ?get_node(node),
        [{T, Node, Node, "txqueue_prepare"}];
    
      (T, mkblock_process, PL, File) ->
        Node = ?get_node(node),
        [{T, Node, Node, "mkblock_process"}];
      
      (T, mkblock_done, PL, File) ->
        Node = ?get_node(node_name),
        Hdr = proplists:get_value(block_hdr, PL, #{}),
        H = proplists:get_value(height, PL, -1),
        Hash = maps:get(hash, Hdr, <<>>),
        Tmp = maps:get(temporary, Hdr, -1),
        [{T, Node, Node,
          io_lib:format("mkblock_done ~s h=~w:~p", [blockchain:blkid(Hash), H, Tmp])}
        ];
  
      (T, runsync, PL, File) ->
        Node = ?get_node(node),
        Where = proplists:get_value(where, PL, -1),
        [ {T, Node, Node, io_lib:format("runsync ~s", [Where])} ];
      
      (T, got_new_block, PL, File) ->
        Node = ?get_node(node),
        H = proplists:get_value(height, PL, -1),
        Verify = proplists:get_value(verify, PL, -1),
        Hash = proplists:get_value(hash, PL, -1),
  
        IgnoreStr =
          case proplists:get_value(ignore, PL, undefined) of
            undefined ->
              <<>>;
            AnyStr ->
              io_lib:format("ignore=~p", [AnyStr])
          end,
        
        [{T, Node, Node,
          io_lib:format(
            "got_new_block ~s h=~w, verify=~p ~s",
            [blockchain:blkid(Hash), H, Verify, IgnoreStr]
          )}
        ];
  
      (T, sync_needed, PL, File) ->
        Hash=proplists:get_value(hash, PL, <<>>),
        H=proplists:get_value(height, PL, -1),
        S=proplists:get_value(sig, PL, 0),
        Tmp=proplists:get_value(temp, PL, -1),
        Node = ?get_node(node),
        LBlockHash = proplists:get_value(lblockhash, PL, 0),
        PHash = proplists:get_value(phash, PL, 0),
        [
          {
            T, Node, Node,
            io_lib:format(
              "sync_needed ~s h=~w:~p sig=~w lhash=~s phash=~s",
              [
                blockchain:blkid(Hash), H, Tmp, S,
                blockchain:blkid(LBlockHash), blockchain:blkid(PHash)
              ])
          }
        ];
      (T, inst_sync, PL, File) ->
        Node = ?get_node(node),
        Reason = proplists:get_value(reason, PL, unknown),
        Message =
          case Reason of
            block ->
              LedgerHash = proplists:get_value(lh, PL, <<>>),
              Height = proplists:get_value(height, PL, -1),
              io_lib:format(
                "sync block h=~w lhash=~s",
                [Height, blockchain:blkid(bin2hex:dbin2hex(LedgerHash))]
              );
            AnyOtherReason ->
              io_lib:format("sync ~p", [AnyOtherReason])
          end,
        [ T, Node, Node, Message ];
      
      (T, accept_block, PL, File) ->
        Hash=proplists:get_value(hash, PL, <<>>),
        H=proplists:get_value(height, PL, -1),
        S=proplists:get_value(sig, PL, 0),
        Tmp=proplists:get_value(temp, PL, -1),
        Node = ?get_node(node),
        [
          {
            T, Node, Node,
            io_lib:format("accept_block ~s h=~w:~p sig=~w", [blockchain:blkid(Hash), H, Tmp, S]),
            #{arrow_type => rnote}
          }
        ];
  
      (T, ck_sync, PL, File) ->
        Action = proplists:get_value(action, PL, unknown),
        MyHeight = proplists:get_value(myheight, PL, unknown),
        TheirHeight = proplists:get_value(theirheight, PL, unknown),
        TheirHash =
          case proplists:get_value(theirhash, PL, unknown) of
            unknown ->
              unknown;
            AnyValidHash ->
              blockchain:blkid(AnyValidHash)
          end,
        Options = proplists:get_value(options, PL, #{}),

        MyNode = node_map(maps:get(theirnode, Options, File)),
        TheirNode = node_map(maps:get(mynode, Options, unknown)),
        
        Message =
          if
            TheirHeight =:= unknown orelse TheirHash =:= unknown ->
              io_lib:format("ck_sync ~s my_h=~p", [Action, MyHeight]);
            
            true ->
              io_lib:format(
                "ck_sync ~s my_h=~p their_h=~p ~s",
                [Action, MyHeight, TheirHeight, TheirHash])
          end,
        
        [ {T, TheirNode, MyNode, Message} ];
        
      (T, bv_ready, PL, File) ->
        Hdr=proplists:get_value(header, PL, #{}),
        Hash = maps:get(hash, Hdr, <<>>),
        H = maps:get(height, Hdr, -1),
        Node = ?get_node(node),
        [
          {T, Node, Node, io_lib:format("bv_ready ~s h=~w", [hex:encode(Hash), H])}
        ];
      
    (T, bv_gotblock, PL, File) ->
      Hash = proplists:get_value(hash, PL, <<>>),
      H = proplists:get_value(height, PL, -1),
      Tmp = proplists:get_value(tmp, PL, -1),
      OurNodeName = node_map(proplists:get_value(node_name, PL, "blockvote_" ++ File)),
      Sig = [bsig2node(S) || S <- proplists:get_value(sig, PL, [])],
      lists:foldl(
        fun(Node0, Acc1) ->
          Node = node_map(Node0),
          
          case Acc1 of
            [] ->
              [
                {T, Node, OurNodeName,
                  io_lib:format("gotblock blk ~s h=~w:~p", [blockchain:blkid(Hash), H, Tmp])},
                {T, Node, OurNodeName,
                  io_lib:format("gotblock sig for ~s", [blockchain:blkid(Hash)])}];
            _ ->
              [{T, Node, OurNodeName,
                io_lib:format("gotblock blk ~s h=~w:~p", [blockchain:blkid(Hash), H, Tmp])} | Acc1]
          end
        end, [], Sig);
      
      (T, bv_gotsig, PL, File) ->
        Hash = proplists:get_value(hash, PL, <<>>),
        Sig = [bsig2node(S) || S <- proplists:get_value(sig, PL, [])],
        OurNodeName = node_map(proplists:get_value(node_name, PL, "blockvote_" ++ File)),
        
        lists:foldl(
          fun(Node, Acc1) ->
            [
              {T, node_map(Node), OurNodeName,
                io_lib:format("gotsig sig for ~s", [blockchain:blkid(Hash)])} | Acc1]
          end, [], Sig);
      (_, _, _, _) ->
        ignore
    end,

  FFun =
    fun
      (T, _, _, Acc, _) when T1 > 0, T < T1 -> Acc;
      (T, _, _, Acc, _) when T2 > 0, T > T2 -> Acc;
      (_, _, _, {?MAX_MESSAGES, _, _, _} = Acc, _) -> Acc;
      (T, Kind, PL, {C, Acc, M1, M2}, File) ->
        R = MapFun(T, Kind, PL, File),
        if R == ignore ->
          {C,
            Acc,
            M1,
            M2
          };
          is_list(R) ->
            {C + 1,
              [Acc, R],
              min(M1, T),
              max(M2, T)
            }
        end
    end,


  {Done, Events1, MinT, MaxT} =
    case BLog of
      [[_ | _] | _] ->
        stout_reader:mfold(FFun, {0, [], erlang:system_time(), 0}, BLog);
      _ ->
        stout_reader:fold(FFun, {0, [], erlang:system_time(), 0}, BLog)
    end,

  io:format("~w done T ~w ... ~w~n", [Done, MinT, MaxT]),
  Events = lists:flatten(Events1),
  
  Formater =
    fun
      ({TimestampData, FromData, ToData, MessageData, #{arrow_type := hnote}}) when FromData =:= ToData ->
        io_lib:format("hnote over ~s : ~s ~s~n", [FromData, fmt_t(TimestampData), MessageData]);

      ({TimestampData, FromData, ToData, MessageData, #{arrow_type := rnote}}) when FromData =:= ToData ->
        io_lib:format("rnote over ~s : ~s ~s~n", [FromData, fmt_t(TimestampData), MessageData]);
  
      ({TimestampData, FromData, ToData, MessageData}) ->
        io_lib:format("~s -> ~s : ~s ~s~n", [FromData, ToData, fmt_t(TimestampData), MessageData]);
    
      (InvalidEvent) ->
        io:format("invalid event: ~p~n", [InvalidEvent])
    end,
    
  Text = [
    "@startuml\n",
    [ Formater(Event) || Event <- Events],
    "@enduml\n"
  ],
  file:write_file("x.uml", Text),
  Comp = testz(Text),
  file:write_file("x.link", ["http://www.plantuml.com/plantuml/png/", Comp]).


% --------------------------------------------------------------------------------

fmt_t(T) ->
%%  io:format("T2: ~p~n", [T]),
  Sec=(T div 1000000000),
  Ms=T div 100000 rem 10000,
  {_,{H,M,S}}=calendar:gregorian_seconds_to_datetime(Sec + 62167230000),
  io_lib:format("[~2..0B:~2..0B:~2..0B.~4..0B]",[H,M,S,Ms]).

% --------------------------------------------------------------------------------

bsig2node(BSig) ->
  chainsettings:is_our_node(
  %nodekey:node_id(
    proplists:get_value(pubkey,maps:get(extra,bsig:unpacksig(BSig)))
   ).

% --------------------------------------------------------------------------------

testz(Data) ->
  Z = zlib:open(),
  ok = zlib:deflateInit(Z,default),
  Compressed = zlib:deflate(Z, Data),
  Last = zlib:deflate(Z, [], finish),
  ok = zlib:deflateEnd(Z),
  zlib:close(Z),
  enc64(list_to_binary([Compressed|Last])).

% --------------------------------------------------------------------------------

enc64(<<B1,B2,B3,Rest/binary>>) ->
  [ e3b(B1,B2,B3) | enc64(Rest) ];
enc64(<<B1,B2>>) ->
  e3b(B1,B2,0);
enc64(<<B1>>) ->
  e3b(B1,0,0);
enc64(<<>>) ->
  [].

% --------------------------------------------------------------------------------

e3b(B1,B2,B3) ->
  C1 = B1 bsr 2,
  C2 = ((B1 band 16#3) bsl 4) bor (B2 bsr 4),
  C3 = ((B2 band 16#F) bsl 2) bor (B3 bsr 6),
  C4 = B3 band 16#3F,
  [ e64(C1 band 16#3F),
    e64(C2 band 16#3F),
    e64(C3 band 16#3F),
    e64(C4 band 16#3F) ].

% --------------------------------------------------------------------------------

e64(B) when B<10 -> 48+B;
e64(B) when B-10<26 -> 65+B-10;
e64(B) when B-36<26 -> 97+B-36;
e64(B) when B-62==0 -> $-;
e64(B) when B-62==1 -> $_;
e64(_) -> $?.

