//+------------------------------------------------------------------+
//|                                                 NewsRider_EA.mq4 |
//|                                                                  |
//|  Opera noticias: entra a favor do movimento da noticia e         |
//|  protege o lucro com breakeven + trailing rapido.                |
//|                                                                  |
//|  Nao depende de biblioteca externa (substitui a libNewsFF.ex4):  |
//|  - Conta demo/real: baixa o calendario do ForexFactory           |
//|    (ff_calendar_thisweek.json) via WebRequest.                   |
//|  - Backtest: le as noticias do arquivo de historico CSV          |
//|    (pasta Common\Files) e/ou da lista de horarios manuais.       |
//+------------------------------------------------------------------+
#property copyright "k4copy"
#property version   "1.00"
#property strict
#property description "Opera noticias a favor do movimento com breakeven e trailing rapido."
#property description "Demo/real: baixa o calendario do ForexFactory (liberar a URL em Ferramentas > Opcoes > Expert Advisors)."
#property description "Backtest: usa o arquivo NewsHistory.csv (Common\\Files) ou os horarios manuais."

enum ENUM_ENTRY_MODE
  {
   ENTRY_STRADDLE = 0, // Pendentes Buy Stop + Sell Stop antes da noticia
   ENTRY_MOMENTUM = 1  // Ordem a mercado quando o preco anda X pontos apos a noticia
  };

enum ENUM_MIN_IMPACT
  {
   IMPACT_LOW    = 1, // Baixo, medio e alto
   IMPACT_MEDIUM = 2, // Medio e alto
   IMPACT_HIGH   = 3  // Somente alto
  };

enum ENUM_LOT_MODE
  {
   LOT_FIXED = 0, // Lote fixo
   LOT_RISK  = 1  // % do saldo arriscado no stop loss
  };

input  string          InpSep1             = "=====";            // ===== NOTICIAS =====
input  string          InpCurrencies       = "";                 // Moedas (vazio = automatico pelo simbolo, ex: XAUUSD -> USD)
input  ENUM_MIN_IMPACT InpMinImpact        = IMPACT_HIGH;        // Impacto minimo
input  string          InpTitleInclude     = "";                 // So noticias com estas palavras (separe com ;) vazio = todas
input  string          InpTitleExclude     = "Speaks;Testifies"; // Ignorar noticias com estas palavras (discursos nao tem horario exato)
input  int             InpServerGMTOffset  = 99;                 // Fuso do servidor GMT+x (99 = automatico)
input  string          InpManualTimes      = "";                 // Horarios manuais no horario do grafico (ex: 2026.10.03 15:30;2026.10.15 15:30)
input  string          InpNewsURL          = "https://nfs.faireconomy.media/ff_calendar_thisweek.json"; // URL do calendario
input  string          InpHistoryFile      = "NewsHistory.csv";  // Arquivo de historico (pasta Common\Files)
input  bool            InpSaveHistory      = true;               // Salvar as noticias baixadas no historico (para backtest)

input  string          InpSep2             = "=====";            // ===== ENTRADA =====
input  ENUM_ENTRY_MODE InpEntryMode        = ENTRY_STRADDLE;     // Modo de entrada
input  int             InpSecondsBefore    = 60;                 // Straddle: segundos antes da noticia para colocar as pendentes
input  int             InpEntryDistance    = 150;                // Straddle: distancia das pendentes (pontos)
input  int             InpPendingExpireSec = 120;                // Straddle: apagar pendentes X segundos apos a noticia
input  int             InpMomentumTrigger  = 150;                // Momentum: movimento minimo para entrar (pontos)
input  int             InpMomentumWindow   = 120;                // Momentum: janela apos a noticia (segundos)
input  int             InpMaxSpread        = 60;                 // Spread maximo para entrar (pontos, 0 = sem limite)
input  int             InpSlippage         = 30;                 // Slippage maximo (pontos)

input  string          InpSep3             = "=====";            // ===== RISCO =====
input  ENUM_LOT_MODE   InpLotMode          = LOT_FIXED;          // Tipo de lote
input  double          InpLots             = 0.01;               // Lote fixo
input  double          InpRiskPercent      = 1.0;                // Risco por operacao (% do saldo)
input  int             InpStopLoss         = 300;                // Stop Loss (pontos)
input  int             InpTakeProfit       = 0;                  // Take Profit (pontos, 0 = sem TP, o trailing fecha)

input  string          InpSep4             = "=====";            // ===== TRAILING =====
input  int             InpBETrigger        = 100;                // Breakeven: ativar com X pontos de lucro (0 = desliga)
input  int             InpBELock           = 10;                 // Breakeven: pontos de lucro garantidos
input  int             InpTrailStart       = 150;                // Trailing: comecar com X pontos de lucro (0 = desliga)
input  int             InpTrailDistance    = 100;                // Trailing: distancia do stop ao preco (pontos)
input  int             InpTrailStep        = 10;                 // Trailing: passo minimo para mover o stop (pontos)
input  int             InpMaxTradeMinutes  = 30;                 // Fechar a operacao apos X minutos (0 = desliga)

input  string          InpSep5             = "=====";            // ===== GERAL =====
input  int             InpMagic            = 20261015;           // Magic number
input  bool            InpShowPanel        = true;               // Mostrar painel no grafico

struct NewsEvent
  {
   datetime          utc;    // horario em UTC
   datetime          srv;    // horario do servidor (horario do grafico)
   string            cur;    // moeda (USD, EUR...)
   int               impact; // 0 feriado/outro, 1 baixo, 2 medio, 3 alto
   string            title;  // nome da noticia
  };

NewsEvent g_all[];               // todas as noticias conhecidas (historico + download)
int       g_allCount     = 0;
NewsEvent g_news[];              // noticias filtradas para este grafico, em ordem de horario do servidor
int       g_newsCount    = 0;
int       g_idx          = 0;    // proxima noticia a tratar

string    g_curList      = "";   // ex: ",XAU,USD,"
int       g_liveOffset   = INT_MIN; // fuso do servidor medido na conta (segundos)
datetime  g_lastDownload = 0;    // horario local do ultimo download com sucesso
datetime  g_lastAttempt  = 0;    // horario local da ultima tentativa de download
datetime  g_doneEvent    = 0;    // horario (servidor) da ultima noticia ja tratada
double    g_refPrice     = 0;    // momentum: preco antes da noticia
datetime  g_refEvent     = 0;
string    g_status       = "";
string    g_warning      = "";

//+------------------------------------------------------------------+
int OnInit()
  {
   BuildCurrencyList();
   LoadHistory();
   if(!IsTesting())
     {
      UpdateLiveOffset();
      DownloadNews();
      EventSetTimer(1);
     }
   BuildFiltered();

   PrintFormat("NewsRider: moedas %s | %d noticias no historico | %d noticias filtradas | servidor GMT%s",
               CurrencyListText(), g_allCount, g_newsCount, OffsetText(ServerOffsetSec(TimeCurrent())));
   if(g_newsCount == 0)
      Print("NewsRider: nenhuma noticia na lista. No backtest, preencha o arquivo ", InpHistoryFile,
            " (pasta Common\\Files) ou use os horarios manuais.");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // So no tick o TimeCurrent() e atual, entao o fuso do servidor e medido aqui
   if(!IsTesting() && UpdateLiveOffset())
      BuildFiltered();
   Engine();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   RefreshRates();
   Engine();
  }

//+------------------------------------------------------------------+
void Engine()
  {
   if(!IsTesting())
      MaybeDownload();
   ManageTrades();
   ProcessNews();
   UpdatePanel();
  }

//+------------------------------------------------------------------+
//| Decide o que fazer com a proxima noticia                          |
//+------------------------------------------------------------------+
void ProcessNews()
  {
   datetime now  = TimeCurrent();
   int      late = (InpEntryMode == ENTRY_MOMENTUM) ? InpMomentumWindow : 0;
   while(g_idx < g_newsCount && (g_news[g_idx].srv + late < now || g_news[g_idx].srv <= g_doneEvent))
      g_idx++;
   if(g_idx >= g_newsCount)
     {
      g_status = "Sem noticias futuras na lista";
      return;
     }

   datetime t = g_news[g_idx].srv;
   if(InpEntryMode == ENTRY_STRADDLE)
      DoStraddle(t, now);
   else
      DoMomentum(t, now);
  }

//+------------------------------------------------------------------+
void DoStraddle(datetime t, datetime now)
  {
   if(now < t - InpSecondsBefore)
     {
      g_status = "Aguardando a proxima noticia";
      return;
     }
   if(now >= t)
     {
      g_doneEvent = t;
      g_status    = "Noticia passou sem colocar ordens";
      return;
     }
   if(CountMyOrders() > 0)
     {
      g_doneEvent = t;
      g_status    = "Ja existe operacao aberta - noticia ignorada";
      return;
     }
   double spread = (Ask - Bid) / Point;
   if(InpMaxSpread > 0 && spread > InpMaxSpread)
     {
      g_status = StringFormat("Spread alto (%.0f) - aguardando", spread);
      return;
     }
   if(PlaceStraddle())
      g_status = "Pendentes colocadas para a noticia das " + TimeToString(t, TIME_MINUTES);
   else
      g_status = "Falha ao colocar as pendentes (veja a aba Experts)";
   g_doneEvent = t;
  }

//+------------------------------------------------------------------+
void DoMomentum(datetime t, datetime now)
  {
   if(now < t - 60)
     {
      g_status = "Aguardando a proxima noticia";
      return;
     }
   if(now < t)
     {
      // guarda o ultimo preco antes da noticia
      g_refPrice = Bid;
      g_refEvent = t;
      g_status   = "Preco de referencia: " + DoubleToString(Bid, Digits);
      return;
     }
   if(now > t + InpMomentumWindow)
     {
      g_doneEvent = t;
      g_status    = "Noticia sem movimento suficiente";
      return;
     }
   if(CountMyOrders() > 0)
     {
      g_doneEvent = t;
      g_status    = "Ja existe operacao aberta - noticia ignorada";
      return;
     }
   if(g_refEvent != t)
     {
      // nao houve tick antes da noticia: usa o primeiro preco depois dela
      g_refPrice = Bid;
      g_refEvent = t;
     }

   double move = (Bid - g_refPrice) / Point;
   g_status = StringFormat("Noticia saiu: movimento %.0f de %d pontos", move, InpMomentumTrigger);
   if(MathAbs(move) < InpMomentumTrigger)
      return;

   double spread = (Ask - Bid) / Point;
   if(InpMaxSpread > 0 && spread > InpMaxSpread)
     {
      g_status = StringFormat("Spread alto (%.0f) - aguardando", spread);
      return;
     }
   if(OpenMarket(move > 0 ? OP_BUY : OP_SELL))
     {
      g_doneEvent = t;
      g_status    = (move > 0 ? "Compra" : "Venda") + " aberta a favor da noticia";
     }
  }

//+------------------------------------------------------------------+
//| Breakeven, trailing, tempo maximo e OCO das pendentes             |
//+------------------------------------------------------------------+
void ManageTrades()
  {
   bool hasPosition = false;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != InpMagic)
         continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL)
         continue;
      if(InpMaxTradeMinutes > 0 && TimeCurrent() - OrderOpenTime() >= InpMaxTradeMinutes * 60)
        {
         if(CloseSelected())
            continue;
        }
      hasPosition = true;
      TrailSelected();
     }

   for(int j = OrdersTotal() - 1; j >= 0; j--)
     {
      if(!OrderSelect(j, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != InpMagic)
         continue;
      if(OrderType() != OP_BUYSTOP && OrderType() != OP_SELLSTOP)
         continue;
      // OCO: uma pendente executou, apaga a outra. Ou a pendente venceu.
      bool expired = (TimeCurrent() > OrderOpenTime() + InpSecondsBefore + InpPendingExpireSec);
      if(hasPosition || expired)
        {
         if(!OrderDelete(OrderTicket()))
            Print("NewsRider: erro ao apagar pendente #", OrderTicket(), " erro ", GetLastError());
        }
     }
  }

//+------------------------------------------------------------------+
void TrailSelected()
  {
   double pt        = Point;
   double minDist   = MathMax(MarketInfo(Symbol(), MODE_STOPLEVEL) * pt, pt);
   double freeze    = MarketInfo(Symbol(), MODE_FREEZELEVEL) * pt;
   double step      = MathMax(1, InpTrailStep) * pt;
   double open      = OrderOpenPrice();
   double cur       = OrderStopLoss();
   double newSL     = cur;

   if(OrderType() == OP_BUY)
     {
      double profit = (Bid - open) / pt;
      if(InpBETrigger > 0 && profit >= InpBETrigger)
         newSL = MathMax(newSL, open + InpBELock * pt);
      if(InpTrailStart > 0 && profit >= InpTrailStart)
         newSL = MathMax(newSL, Bid - InpTrailDistance * pt);
      newSL = NormalizeDouble(MathMin(newSL, Bid - minDist), Digits);
      if(newSL <= 0)
         return;
      if(cur > 0 && newSL < cur + step)
         return;
      if(cur > 0 && Bid - cur <= freeze)
         return;
      ModifySL(newSL);
     }
   else if(OrderType() == OP_SELL)
     {
      double profit = (open - Ask) / pt;
      bool   has    = (cur > 0);
      if(InpBETrigger > 0 && profit >= InpBETrigger)
        {
         double be = open - InpBELock * pt;
         newSL = has ? MathMin(newSL, be) : be;
         has   = true;
        }
      if(InpTrailStart > 0 && profit >= InpTrailStart)
        {
         double tr = Ask + InpTrailDistance * pt;
         newSL = has ? MathMin(newSL, tr) : tr;
         has   = true;
        }
      if(!has)
         return;
      newSL = NormalizeDouble(MathMax(newSL, Ask + minDist), Digits);
      if(cur > 0 && newSL > cur - step)
         return;
      if(cur > 0 && cur - Ask <= freeze)
         return;
      ModifySL(newSL);
     }
  }

//+------------------------------------------------------------------+
void ModifySL(double sl)
  {
   if(!OrderModify(OrderTicket(), OrderOpenPrice(), sl, OrderTakeProfit(), 0, clrNONE))
     {
      int err = GetLastError();
      if(err != 1) // 1 = nada mudou
         Print("NewsRider: erro ao mover o stop #", OrderTicket(), " para ", DoubleToString(sl, Digits), " erro ", err);
     }
  }

//+------------------------------------------------------------------+
bool CloseSelected()
  {
   RefreshRates();
   double price = (OrderType() == OP_BUY) ? Bid : Ask;
   if(OrderClose(OrderTicket(), OrderLots(), NormalizeDouble(price, Digits), InpSlippage, clrYellow))
      return true;
   Print("NewsRider: erro ao fechar #", OrderTicket(), " erro ", GetLastError());
   return false;
  }

//+------------------------------------------------------------------+
//| Envio de ordens                                                   |
//+------------------------------------------------------------------+
bool PlaceStraddle()
  {
   RefreshRates();
   double pt        = Point;
   int    stopLevel = (int)MarketInfo(Symbol(), MODE_STOPLEVEL);
   int    dist      = (int)MathMax(InpEntryDistance, stopLevel + 1);
   int    slPts     = (InpStopLoss > 0) ? (int)MathMax(InpStopLoss, stopLevel + 1) : 0;
   int    tpPts     = (InpTakeProfit > 0) ? (int)MathMax(InpTakeProfit, stopLevel + 1) : 0;
   double lots      = CalcLots();

   double buyPrice  = NormalizeDouble(Ask + dist * pt, Digits);
   double sellPrice = NormalizeDouble(Bid - dist * pt, Digits);
   double buySL     = (slPts > 0) ? buyPrice - slPts * pt : 0.0;
   double buyTP     = (tpPts > 0) ? buyPrice + tpPts * pt : 0.0;
   double sellSL    = (slPts > 0) ? sellPrice + slPts * pt : 0.0;
   double sellTP    = (tpPts > 0) ? sellPrice - tpPts * pt : 0.0;

   int tb = SendOrder(OP_BUYSTOP, lots, buyPrice, buySL, buyTP);
   int ts = SendOrder(OP_SELLSTOP, lots, sellPrice, sellSL, sellTP);
   if(tb > 0 && ts > 0)
      return true;

   // se so uma entrou, cancela para nao ficar apostando em um lado so
   if(tb > 0)
      DeleteTicket(tb);
   if(ts > 0)
      DeleteTicket(ts);
   return false;
  }

//+------------------------------------------------------------------+
bool OpenMarket(int type)
  {
   // Conta ECN (execucao a mercado): abre sem SL/TP e coloca logo em seguida
   int ticket = SendOrder(type, CalcLots(), 0, 0, 0);
   if(ticket <= 0)
      return false;
   if(InpStopLoss <= 0 && InpTakeProfit <= 0)
      return true;
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return true;

   RefreshRates();
   double pt      = Point;
   double minDist = MathMax(MarketInfo(Symbol(), MODE_STOPLEVEL) * pt, pt);
   double open    = OrderOpenPrice();
   double sl      = 0, tp = 0;
   if(type == OP_BUY)
     {
      if(InpStopLoss > 0)
         sl = MathMin(open - InpStopLoss * pt, Bid - minDist);
      if(InpTakeProfit > 0)
         tp = MathMax(open + InpTakeProfit * pt, Bid + minDist);
     }
   else
     {
      if(InpStopLoss > 0)
         sl = MathMax(open + InpStopLoss * pt, Ask + minDist);
      if(InpTakeProfit > 0)
         tp = MathMin(open - InpTakeProfit * pt, Ask - minDist);
     }
   if(!OrderModify(ticket, open, NormalizeDouble(sl, Digits), NormalizeDouble(tp, Digits), 0, clrNONE))
      Print("NewsRider: posicao aberta mas nao foi possivel colocar SL/TP, erro ", GetLastError());
   return true;
  }

//+------------------------------------------------------------------+
int SendOrder(int type, double lots, double price, double sl, double tp)
  {
   color clr = (type == OP_BUY || type == OP_BUYSTOP) ? clrDodgerBlue : clrTomato;
   for(int attempt = 0; attempt < 3; attempt++)
     {
      RefreshRates();
      if(type == OP_BUY)
         price = Ask;
      if(type == OP_SELL)
         price = Bid;
      ResetLastError();
      int ticket = OrderSend(Symbol(), type, lots, NormalizeDouble(price, Digits), InpSlippage,
                             NormalizeDouble(sl, Digits), NormalizeDouble(tp, Digits),
                             "NewsRider", InpMagic, 0, clr);
      if(ticket > 0)
         return ticket;
      int err = GetLastError();
      PrintFormat("NewsRider: OrderSend tipo %d preco %s falhou, erro %d (tentativa %d)",
                  type, DoubleToString(price, Digits), err, attempt + 1);
      // 4 servidor ocupado, 135 preco mudou, 136 sem cotacao, 138 requote, 146 contexto ocupado
      if(err != 4 && err != 135 && err != 136 && err != 138 && err != 146)
         break;
      Sleep(100);
     }
   return -1;
  }

//+------------------------------------------------------------------+
void DeleteTicket(int ticket)
  {
   if(OrderSelect(ticket, SELECT_BY_TICKET) && OrderCloseTime() == 0)
      if(!OrderDelete(ticket))
         Print("NewsRider: erro ao apagar #", ticket, " erro ", GetLastError());
  }

//+------------------------------------------------------------------+
int CountMyOrders()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && OrderSymbol() == Symbol() && OrderMagicNumber() == InpMagic)
         n++;
   return n;
  }

//+------------------------------------------------------------------+
double CalcLots()
  {
   double lots = InpLots;
   if(InpLotMode == LOT_RISK && InpStopLoss > 0)
     {
      double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
      double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
      if(tickValue > 0 && tickSize > 0)
        {
         double lossPerLot = InpStopLoss * Point * tickValue / tickSize;
         if(lossPerLot > 0)
            lots = AccountBalance() * InpRiskPercent / 100.0 / lossPerLot;
        }
     }
   double step   = MarketInfo(Symbol(), MODE_LOTSTEP);
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   if(step <= 0)
      step = 0.01;
   lots = MathFloor(lots / step + 0.000001) * step;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   int digits = (step >= 1.0) ? 0 : ((step >= 0.1) ? 1 : 2);
   return NormalizeDouble(lots, digits);
  }

//+------------------------------------------------------------------+
//| Calendario: download (demo/real)                                  |
//+------------------------------------------------------------------+
void MaybeDownload()
  {
   datetime nowLocal = TimeLocal();
   if(g_lastDownload > 0 && nowLocal - g_lastDownload < 3600)
      return;                       // o calendario so muda de hora em hora
   if(g_lastAttempt > 0 && nowLocal - g_lastAttempt < 300)
      return;                       // se falhou, tenta de novo em 5 minutos
   if(NewsNearby(600))
      return;                       // nao trava o EA perto de uma noticia
   DownloadNews();
  }

//+------------------------------------------------------------------+
bool DownloadNews()
  {
   g_lastAttempt = TimeLocal();
   char   post[], result[];
   string resultHeaders;
   string headers = "User-Agent: Mozilla/5.0 (NewsRider EA)\r\nAccept: application/json\r\n";

   ResetLastError();
   int code = WebRequest("GET", InpNewsURL, headers, 5000, post, result, resultHeaders);
   if(code == -1)
     {
      g_warning = StringFormat("WebRequest falhou (erro %d). Adicione %s em Ferramentas > Opcoes > Expert Advisors > Permitir WebRequest",
                               GetLastError(), UrlHost(InpNewsURL));
      Print("NewsRider: ", g_warning);
      return false;
     }
   if(code != 200)
     {
      g_warning = StringFormat("Calendario respondeu HTTP %d (tenta de novo em 5 min)", code);
      Print("NewsRider: ", g_warning);
      return false;
     }

   string json   = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   int    before = g_allCount;
   int    parsed = ParseCalendarJson(json);
   if(parsed == 0)
     {
      g_warning = "Calendario baixado, mas nenhuma noticia foi lida";
      Print("NewsRider: ", g_warning);
      return false;
     }

   g_lastDownload = TimeLocal();
   g_warning      = "";
   int added = g_allCount - before;
   if(added > 0)
     {
      SortEvents(g_all, g_allCount, false);
      if(InpSaveHistory)
         SaveHistory();
      BuildFiltered();
     }
   PrintFormat("NewsRider: calendario baixado, %d noticias (%d novas)", parsed, added);
   return true;
  }

//+------------------------------------------------------------------+
//| Le o JSON do ForexFactory:                                        |
//| [{"title":"..","country":"USD","date":"2026-10-15T08:30:00-04:00",|
//|   "impact":"High","forecast":"..","previous":".."}, ...]          |
//+------------------------------------------------------------------+
int ParseCalendarJson(const string json)
  {
   int parsed = 0;
   int pos    = 0;
   while(true)
     {
      int a = StringFind(json, "{", pos);
      if(a < 0)
         break;
      int b = StringFind(json, "}", a);
      if(b < 0)
         break;
      string obj = StringSubstr(json, a, b - a + 1);
      pos = b + 1;

      NewsEvent ev;
      bool ok = false;
      ev.utc    = ParseDateUtc(JsonGet(obj, "date"), ok);
      ev.srv    = 0;
      ev.cur    = Upper(Trim(JsonGet(obj, "country")));
      ev.impact = ImpactFromString(JsonGet(obj, "impact"));
      ev.title  = Trim(JsonGet(obj, "title"));
      if(!ok || StringLen(ev.cur) == 0)
         continue;
      parsed++;
      AddEvent(ev, true);
     }
   return parsed;
  }

//+------------------------------------------------------------------+
string JsonGet(const string obj, const string key)
  {
   string pat = "\"" + key + "\":";
   int    p   = StringFind(obj, pat);
   if(p < 0)
      return "";
   int len = StringLen(obj);
   p += StringLen(pat);
   while(p < len && StringGetCharacter(obj, p) == ' ')
      p++;
   if(p >= len)
      return "";

   if(StringGetCharacter(obj, p) != '"')
     {
      int e = p;
      while(e < len && StringGetCharacter(obj, e) != ',' && StringGetCharacter(obj, e) != '}')
         e++;
      return Trim(StringSubstr(obj, p, e - p));
     }

   string out = "";
   for(int i = p + 1; i < len; i++)
     {
      ushort c = StringGetCharacter(obj, i);
      if(c == '"')
         break;
      if(c == '\\' && i + 1 < len)
        {
         i++;
         c = StringGetCharacter(obj, i);
         if(c == 'u')
           {
            i += 4;
            c = '?';
           }
         else if(c == 'n' || c == 'r' || c == 't')
            c = ' ';
        }
      out += ShortToString(c);
     }
   return out;
  }

//+------------------------------------------------------------------+
//| "2026-10-15T08:30:00-04:00" ou "2026.10.15 12:30" (ja em UTC)     |
//+------------------------------------------------------------------+
datetime ParseDateUtc(string s, bool &ok)
  {
   ok = false;
   s  = Trim(s);
   if(StringLen(s) < 16)
      return 0;
   string datePart = StringSubstr(s, 0, 10);
   StringReplace(datePart, "-", ".");
   string   timePart = StringSubstr(s, 11, 8);
   datetime local    = StringToTime(datePart + " " + timePart);
   if(local <= 0)
      return 0;

   int off = 0;
   if(StringLen(s) >= 25)
     {
      string sign = StringSubstr(s, 19, 1);
      if(sign == "+" || sign == "-")
        {
         int oh = (int)StringToInteger(StringSubstr(s, 20, 2));
         int om = (int)StringToInteger(StringSubstr(s, 23, 2));
         off = oh * 3600 + om * 60;
         if(sign == "-")
            off = -off;
        }
     }
   ok = true;
   return local - off;
  }

//+------------------------------------------------------------------+
//| Historico CSV (pasta Common\Files, horarios em UTC):              |
//| 2026.10.03 12:30;USD;High;Non-Farm Employment Change              |
//+------------------------------------------------------------------+
void LoadHistory()
  {
   ArrayResize(g_all, 0);
   g_allCount = 0;
   if(StringLen(InpHistoryFile) == 0)
      return;
   if(!FileIsExist(InpHistoryFile, FILE_COMMON))
     {
      Print("NewsRider: arquivo de historico ", InpHistoryFile, " ainda nao existe (pasta Common\\Files)");
      return;
     }
   int h = FileOpen(InpHistoryFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      Print("NewsRider: nao foi possivel abrir ", InpHistoryFile, " erro ", GetLastError());
      return;
     }

   while(!FileIsEnding(h))
     {
      string line = Trim(FileReadString(h));
      // remove BOM / caracteres estranhos no inicio
      while(StringLen(line) > 0 && StringGetCharacter(line, 0) > 127)
         line = StringSubstr(line, 1);
      if(StringLen(line) < 10)
         continue;
      ushort first = StringGetCharacter(line, 0);
      if(first < '0' || first > '9')
         continue; // cabecalho ou comentario

      string parts[];
      int    n   = StringSplit(line, ';', parts);
      ushort sep = ';';
      if(n < 3)
        {
         n   = StringSplit(line, ',', parts);
         sep = ',';
        }
      if(n < 3)
         continue;

      NewsEvent ev;
      bool ok = false;
      ev.utc = ParseDateUtc(parts[0], ok);
      if(!ok)
         continue;
      ev.srv    = 0;
      ev.cur    = Upper(Trim(parts[1]));
      ev.impact = ImpactFromString(parts[2]);
      ev.title  = "";
      for(int i = 3; i < n; i++)
         ev.title += (i > 3 ? ShortToString(sep) : "") + parts[i];
      ev.title = Trim(ev.title);
      AddEvent(ev, false);
     }
   FileClose(h);
   SortEvents(g_all, g_allCount, false);
  }

//+------------------------------------------------------------------+
void SaveHistory()
  {
   int h = FileOpen(InpHistoryFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      Print("NewsRider: nao foi possivel salvar ", InpHistoryFile, " erro ", GetLastError());
      return;
     }
   FileWriteString(h, "# data_hora_utc;moeda;impacto;titulo\r\n");
   for(int i = 0; i < g_allCount; i++)
     {
      string title = g_all[i].title;
      StringReplace(title, ";", ",");
      FileWriteString(h, TimeToString(g_all[i].utc, TIME_DATE | TIME_MINUTES) + ";" + g_all[i].cur + ";" +
                      ImpactToString(g_all[i].impact) + ";" + title + "\r\n");
     }
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| Lista de noticias que este grafico vai operar                     |
//+------------------------------------------------------------------+
void BuildFiltered()
  {
   ArrayResize(g_news, 0);
   g_newsCount = 0;
   for(int i = 0; i < g_allCount; i++)
     {
      if(!IsRelevant(g_all[i]))
         continue;
      ArrayResize(g_news, g_newsCount + 1, 500);
      CopyEvent(g_news[g_newsCount], g_all[i]);
      g_news[g_newsCount].srv = g_all[i].utc + ServerOffsetSec(g_all[i].utc);
      g_newsCount++;
     }

   // horarios manuais: ja estao no horario do servidor (grafico)
   string parts[];
   int n = StringSplit(InpManualTimes, ';', parts);
   for(int j = 0; j < n; j++)
     {
      string s = Trim(parts[j]);
      if(StringLen(s) == 0)
         continue;
      StringReplace(s, "-", ".");
      datetime t = StringToTime(s);
      if(t <= 0)
        {
         Print("NewsRider: horario manual invalido: ", s);
         continue;
        }
      ArrayResize(g_news, g_newsCount + 1, 500);
      g_news[g_newsCount].srv    = t;
      g_news[g_newsCount].utc    = t - ServerOffsetSec(t);
      g_news[g_newsCount].cur    = "MANUAL";
      g_news[g_newsCount].impact = 3;
      g_news[g_newsCount].title  = "Horario manual";
      g_newsCount++;
     }

   SortEvents(g_news, g_newsCount, true);
   g_idx = 0;
  }

//+------------------------------------------------------------------+
bool IsRelevant(const NewsEvent &ev)
  {
   if(ev.impact < (int)InpMinImpact)
      return false;
   if(StringFind(g_curList, "," + ev.cur + ",") < 0)
      return false;
   if(StringLen(Trim(InpTitleInclude)) > 0 && !TitleHasAny(ev.title, InpTitleInclude))
      return false;
   if(StringLen(Trim(InpTitleExclude)) > 0 && TitleHasAny(ev.title, InpTitleExclude))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
bool TitleHasAny(const string title, const string list)
  {
   string t = Upper(title);
   string parts[];
   int    n = StringSplit(list, ';', parts);
   for(int i = 0; i < n; i++)
     {
      string p = Upper(Trim(parts[i]));
      if(StringLen(p) > 0 && StringFind(t, p) >= 0)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
bool AddEvent(const NewsEvent &ev, bool checkDup)
  {
   if(checkDup)
      for(int i = g_allCount - 1; i >= 0; i--)
         if(g_all[i].utc == ev.utc && g_all[i].cur == ev.cur && g_all[i].title == ev.title)
            return false;
   ArrayResize(g_all, g_allCount + 1, 1000);
   CopyEvent(g_all[g_allCount], ev);
   g_allCount++;
   return true;
  }

//+------------------------------------------------------------------+
void CopyEvent(NewsEvent &dst, const NewsEvent &src)
  {
   dst.utc    = src.utc;
   dst.srv    = src.srv;
   dst.cur    = src.cur;
   dst.impact = src.impact;
   dst.title  = src.title;
  }

//+------------------------------------------------------------------+
datetime EventKey(const NewsEvent &e, bool bySrv)
  {
   return bySrv ? e.srv : e.utc;
  }

//+------------------------------------------------------------------+
void SortEvents(NewsEvent &arr[], int n, bool bySrv)
  {
   NewsEvent tmp;
   for(int gap = n / 2; gap > 0; gap /= 2)
      for(int i = gap; i < n; i++)
        {
         CopyEvent(tmp, arr[i]);
         datetime key = EventKey(tmp, bySrv);
         int j = i;
         while(j >= gap && EventKey(arr[j - gap], bySrv) > key)
           {
            CopyEvent(arr[j], arr[j - gap]);
            j -= gap;
           }
         CopyEvent(arr[j], tmp);
        }
  }

//+------------------------------------------------------------------+
bool NewsNearby(int seconds)
  {
   datetime now = TimeCurrent();
   for(int i = 0; i < g_newsCount; i++)
      if(MathAbs((double)(g_news[i].srv - now)) <= seconds)
         return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Fuso horario do servidor                                          |
//+------------------------------------------------------------------+
int ServerOffsetSec(datetime utc)
  {
   if(InpServerGMTOffset != 99)
      return InpServerGMTOffset * 3600;
   if(!IsTesting() && g_liveOffset != INT_MIN)
      return g_liveOffset;
   // Padrao das corretoras "NY close" (ex: RoboForex): GMT+3 no horario de verao dos EUA, GMT+2 no resto do ano
   return IsUSDST(utc) ? 3 * 3600 : 2 * 3600;
  }

//+------------------------------------------------------------------+
bool UpdateLiveOffset()
  {
   if(InpServerGMTOffset != 99)
      return false;
   int diff = (int)(TimeCurrent() - TimeGMT());
   if(MathAbs(diff) > 14 * 3600)
      return false; // mercado fechado / horario desatualizado
   int off = (int)MathRound(diff / 1800.0) * 1800;
   if(off == g_liveOffset)
      return false;
   g_liveOffset = off;
   return true;
  }

//+------------------------------------------------------------------+
bool IsUSDST(datetime utc)
  {
   MqlDateTime dt;
   TimeToStruct(utc, dt);
   datetime start = NthSunday(dt.year, 3, 2) + 7 * 3600;  // 2o domingo de marco, 02:00 NY
   datetime end   = NthSunday(dt.year, 11, 1) + 6 * 3600; // 1o domingo de novembro, 02:00 NY
   return (utc >= start && utc < end);
  }

//+------------------------------------------------------------------+
datetime NthSunday(int year, int month, int n)
  {
   MqlDateTime dt;
   dt.year = year;
   dt.mon  = month;
   dt.day  = 1;
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime first = StructToTime(dt);
   TimeToStruct(first, dt);
   int add = (7 - dt.day_of_week) % 7;
   return first + (add + 7 * (n - 1)) * 86400;
  }

//+------------------------------------------------------------------+
//| Utilidades                                                        |
//+------------------------------------------------------------------+
void BuildCurrencyList()
  {
   string s = Trim(InpCurrencies);
   if(StringLen(s) == 0)
      s = StringSubstr(Symbol(), 0, 3) + "," + StringSubstr(Symbol(), 3, 3);
   s = Upper(s);
   StringReplace(s, " ", "");
   StringReplace(s, ";", ",");
   g_curList = "," + s + ",";
  }

string CurrencyListText()
  {
   return StringSubstr(g_curList, 1, StringLen(g_curList) - 2);
  }

string Trim(string s)
  {
   return StringTrimLeft(StringTrimRight(s));
  }

string Upper(string s)
  {
   StringToUpper(s);
   return s;
  }

int ImpactFromString(string s)
  {
   s = Upper(Trim(s));
   if(s == "HIGH" || s == "3" || s == "ALTO")
      return 3;
   if(s == "MEDIUM" || s == "2" || s == "MEDIO")
      return 2;
   if(s == "LOW" || s == "1" || s == "BAIXO")
      return 1;
   return 0;
  }

string ImpactToString(int impact)
  {
   switch(impact)
     {
      case 3:
         return "High";
      case 2:
         return "Medium";
      case 1:
         return "Low";
     }
   return "Holiday";
  }

string OffsetText(int seconds)
  {
   int h = seconds / 3600;
   return (h >= 0 ? "+" : "") + IntegerToString(h);
  }

string UrlHost(string url)
  {
   int p = StringFind(url, "://");
   if(p < 0)
      return url;
   int q = StringFind(url, "/", p + 3);
   return (q < 0) ? url : StringSubstr(url, 0, q);
  }

//+------------------------------------------------------------------+
void UpdatePanel()
  {
   if(!InpShowPanel)
      return;
   if(IsTesting() && !IsVisualMode())
      return;

   string s = "NewsRider EA  |  " + (InpEntryMode == ENTRY_STRADDLE ? "Straddle" : "Momentum") + "\n";
   s += "Moedas: " + CurrencyListText() + "   Impacto minimo: " + ImpactToString((int)InpMinImpact) + "\n";
   s += "Servidor: GMT" + OffsetText(ServerOffsetSec(TimeCurrent())) + "   Noticias na lista: " + IntegerToString(g_newsCount) + "\n";
   if(g_idx < g_newsCount)
     {
      int secs = (int)(g_news[g_idx].srv - TimeCurrent());
      s += "Proxima: " + TimeToString(g_news[g_idx].srv, TIME_DATE | TIME_MINUTES) + "  " +
           g_news[g_idx].cur + "  " + g_news[g_idx].title;
      if(secs > 0)
         s += StringFormat("  (em %dh%02dm)", secs / 3600, (secs % 3600) / 60);
      s += "\n";
     }
   else
      s += "Proxima: nenhuma noticia futura na lista\n";
   s += "Status: " + g_status;
   if(StringLen(g_warning) > 0)
      s += "\nAVISO: " + g_warning;
   Comment(s);
  }
//+------------------------------------------------------------------+
