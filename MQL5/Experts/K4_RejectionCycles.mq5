//+------------------------------------------------------------------+
//|                                           K4_RejectionCycles.mq5 |
//|  Robô de ciclos de entradas na recusa de topo/fundo relevante    |
//|  Pensado para XAUUSD em conta cent (MetaTrader 5, conta hedge)   |
//+------------------------------------------------------------------+
#property copyright "k4copy"
#property version   "2.20"
#property description "Detecta topos/fundos relevantes (ex.: M30) e entra na recusa do nível."
#property description "Cada ciclo faz até N entradas; a cesta fecha no alvo (X em dinheiro ou % topo-fundo)."
#property description "Completado o ciclo, aguarda o próximo topo/fundo relevante."

#include <Trade\Trade.mqh>

#define K4_PREFIX "K4RC_"
#define MAX_USED  10

//--- como adicionar as próximas ordens dentro do ciclo
enum ENUM_GRID_MODE
  {
   GRID_CONTRA   = 0, // Contra o preço (preço médio)
   GRID_FAVOR    = 1, // A favor do preço (pirâmide)
   GRID_INTERVAL = 2  // Por tempo, enquanto o nível segura
  };

//--- tipo de alvo (TP) da cesta
enum ENUM_TP_MODE
  {
   TP_MONEY = 0, // Valor em dinheiro (X)
   TP_RANGE = 1, // % da distância topo-fundo
   TP_FIRST = 2  // O que vier primeiro
  };

//--- como contar o limite de ciclos
enum ENUM_CYCLE_LIMIT
  {
   LIMIT_PER_DAY = 0, // Por dia (zera todo dia)
   LIMIT_TOTAL   = 1  // Total (zera com "Apagar estado salvo")
  };

//=== Topo/Fundo relevante ==========================================
input group "=== Topo/Fundo relevante ==="
input ENUM_TIMEFRAMES InpSwingTF       = PERIOD_M30; // Timeframe dos topos/fundos
input int             InpSwingStrength = 3;          // Candles à direita para confirmar o topo/fundo
input int             InpLeftBars      = 12;         // Deve ser o extremo dos N candles anteriores
input int             InpLookbackBars  = 200;        // Candles analisados para trás
input int             InpATRPeriod     = 14;         // Período do ATR (TF dos topos/fundos)
input double          InpMinSwingATR   = 1.5;        // Amplitude mínima do movimento (x ATR)
input double          InpZoneATR       = 0.30;       // Tolerância da zona do nível (x ATR)

//=== Confirmação da recusa =========================================
input group "=== Confirmação da recusa ==="
input ENUM_TIMEFRAMES InpConfirmTF    = PERIOD_M5;   // Timeframe do candle de recusa
input double          InpMinWickRatio = 0.40;        // Pavio mínimo / tamanho do candle
input bool            InpRequireColor = true;        // Candle de recusa com cor a favor
input double          InpMaxBreakATR  = 0.50;        // Rompimento máximo aceito do nível (x ATR)

//=== Ciclo de entradas =============================================
input group "=== Ciclo de entradas ==="
input int             InpEntriesPerCycle   = 10;          // Entradas por ciclo
input int             InpInitialOrders     = 1;           // Ordens abertas no sinal de recusa
input double          InpLot               = 0.01;        // Lote de cada ordem
input double          InpLotMultiplier     = 1.0;         // Multiplicador de lote (1.0 = fixo)
input ENUM_GRID_MODE  InpGridMode          = GRID_CONTRA; // Como adicionar as próximas ordens
input double          InpStepPrice         = 1.50;        // Distância entre ordens (US$ no preço do ouro)
input int             InpMinSecondsBetween = 30;          // Intervalo mínimo entre ordens (seg)

//=== Saída rápida ==================================================
input group "=== Saída rápida ==="
input ENUM_TP_MODE    InpTPMode            = TP_MONEY; // Tipo de alvo da cesta
input double          InpTPRangePct        = 30.0;  // Alvo: % da distância entre topo e fundo relevantes
input double          InpBasketTPMoney     = 100.0; // Alvo em dinheiro da cesta (moeda da conta; cent: 100 = US$1)
input double          InpTPPerExtraOrder   = 0.0;   // Lucro adicional por ordem extra na cesta
input double          InpBasketSLMoney     = 0.0;   // Prejuízo máx. da cesta (0 = desligado)
input double          InpInvalidateATR     = 1.0;   // Stop técnico: preço além do nível (x ATR; 0 = off)
input int             InpTimeExitMinutes   = 60;    // Após X min, sai com o lucro mínimo abaixo (0 = off)
input double          InpTimeExitMinProfit = 0.0;   // Lucro mínimo da saída por tempo
input double          InpOrderTPPrice      = 0.0;   // TP individual (US$ no preço; 0 = off)
input double          InpOrderSLPrice      = 0.0;   // SL individual (US$ no preço; 0 = off)

//=== Limite de ciclos ==============================================
input group "=== Limite de ciclos ==="
input int              InpMaxCycles       = 0;             // Parar após X ciclos (0 = sem limite)
input ENUM_CYCLE_LIMIT InpCycleLimitScope = LIMIT_PER_DAY; // Contagem dos ciclos

//=== Proteção da conta =============================================
input group "=== Proteção da conta ==="
input double          InpDailyTargetMoney  = 0.0;   // Meta diária: para até amanhã (0 = off)
input double          InpDailyMaxLossMoney = 0.0;   // Perda diária máx.: para até amanhã (0 = off)
input double          InpEquityTarget      = 0.0;   // Equity alvo: fecha tudo e para (0 = off)
input double          InpMaxSpreadPrice    = 0.60;  // Spread máximo para entrar (US$ no preço; 0 = off)
input int             InpStartHour         = 1;     // Hora inicial (servidor)
input int             InpEndHour           = 23;    // Hora final (servidor; igual à inicial = 24h)

//=== Geral =========================================================
input group "=== Geral ==="
input ulong           InpMagic       = 440030; // Número mágico
input int             InpSlippage    = 50;     // Desvio máximo (pontos)
input bool            InpDrawLevels  = true;   // Desenhar níveis no gráfico
input bool            InpResetState  = false;  // Apagar estado salvo do ciclo ao iniciar

//--- negociação
CTrade   trade;
int      g_atrHandle = INVALID_HANDLE;
string   g_pfx       = "";

//--- ciclo atual
bool     g_cycleActive    = false;
int      g_cycleDir       = 0;     // +1 compra (fundo), -1 venda (topo)
double   g_cycleLevel     = 0.0;
double   g_cycleATR       = 0.0;
datetime g_cycleSwingTime = 0;
int      g_cycleEntries   = 0;
double   g_cycleTPDist    = 0.0;   // distância do alvo topo-fundo (preço)
int      g_cyclesDone     = 0;     // ciclos concluídos (para o limite)
datetime g_usedTop[MAX_USED];      // topos já operados
datetime g_usedBot[MAX_USED];      // fundos já operados

//--- topos/fundos (recalculados a cada candle novo do TF dos topos/fundos)
datetime g_swingBar = 0;
double   g_atr      = 0.0;
bool     g_hasTop   = false;
bool     g_hasBot   = false;
double   g_topLevel = 0.0;
double   g_botLevel = 0.0;
datetime g_topTime  = 0;
datetime g_botTime  = 0;
double   g_topAmp   = 0.0;          // tamanho do movimento que formou o topo
double   g_botAmp   = 0.0;          // tamanho do movimento que formou o fundo

//--- controle
datetime g_lastConfirmBar   = 0;
datetime g_lastOrderFail    = 0;
bool     g_closing          = false;
bool     g_closingEndsCycle = false;
string   g_closeReason      = "";
int      g_dayKey           = 0;
double   g_dayStartEquity   = 0.0;
bool     g_haltDay          = false;
bool     g_haltAll          = false;
string   g_status           = "Aguardando recusa de topo/fundo relevante";

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpEntriesPerCycle < 1 || InpInitialOrders < 1 || InpLot <= 0.0 ||
      InpLotMultiplier <= 0.0 || InpSwingStrength < 1 || InpLeftBars < 1 ||
      InpLookbackBars <= InpSwingStrength)
     {
      Print("Parâmetros inválidos: verifique entradas, ordens iniciais, lote e candles.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints((ulong)InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_atrHandle = iATR(_Symbol, InpSwingTF, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("Falha ao criar ATR: ", GetLastError());
      return(INIT_FAILED);
     }

   for(int i = 0; i < MAX_USED; i++)
     {
      g_usedTop[i] = 0;
      g_usedBot[i] = 0;
     }

   g_pfx = K4_PREFIX + _Symbol + "_" + (string)InpMagic + "_";
   if(InpResetState)
      GlobalVariablesDeleteAll(g_pfx);
   LoadState();
   UpdateDay();

   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("Aviso: a conta não é HEDGE. Em conta netting as ordens se somam numa posição só.");
   if(StringFind(_Symbol, "XAU") < 0)
      Print("Aviso: robô pensado para XAUUSD, rodando em ", _Symbol);
   if(InpTPMode != TP_MONEY && InpTPRangePct <= 0.0)
     {
      Print("Parâmetros inválidos: com alvo topo-fundo, a % do alvo deve ser > 0.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpInvalidateATR > 0.0 && InpInvalidateATR <= InpMaxBreakATR)
      Print("Aviso: o stop técnico (", InpInvalidateATR, " ATR) deve ser maior que o rompimento máximo (",
            InpMaxBreakATR, " ATR).");

   // não entra em sinal antigo ao anexar o robô
   g_lastConfirmBar = iTime(_Symbol, InpConfirmTF, 0);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   SaveState();
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   ObjectsDeleteAll(0, K4_PREFIX);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateDay();
   RefreshSwings();

   //--- fechamento em andamento (ex.: fechamento parcial no tick anterior)
   if(ProcessClosing())
     {
      Render();
      return;
     }

   if(AccountGuards())
     {
      ProcessClosing();
      Render();
      return;
     }

   //--- 1) stop técnico (nível rompido) e saída rápida da cesta
   int n = CountPositions();
   if(g_cycleActive && LevelInvalidated())
     {
      if(n > 0)
         RequestCloseAll(StringFormat("Stop técnico: nível %.2f rompido", g_cycleLevel), true);
      else
         EndCycle("nível rompido");
     }
   else if(n > 0)
      ManageExit(n);

   if(ProcessClosing())
     {
      Render();
      return;
     }
   n = CountPositions();

   //--- 2) ciclo concluído: fez todas as entradas e a cesta já foi fechada
   if(g_cycleActive && n == 0 && g_cycleEntries >= InpEntriesPerCycle)
      EndCycle(StringFormat("ciclo de %d entradas concluído", g_cycleEntries));

   //--- 3) adicionar ordens dentro do ciclo
   if(g_cycleActive && n > 0 && g_cycleEntries < InpEntriesPerCycle && CanTrade())
      TryAddOrder(n);

   //--- 4) sinais de recusa, só no fechamento de um candle do TF de confirmação
   datetime confirmBar = iTime(_Symbol, InpConfirmTF, 0);
   if(confirmBar != 0 && confirmBar != g_lastConfirmBar)
     {
      bool firstBar = (g_lastConfirmBar == 0);
      g_lastConfirmBar = confirmBar;
      if(!firstBar && CountPositions() == 0 && g_atr > 0.0 && CanTrade())
         CheckSignals();
     }

   Render();
  }

//+------------------------------------------------------------------+
//| Sinais: novo topo/fundo relevante ou reentrada no nível do ciclo |
//+------------------------------------------------------------------+
void CheckSignals()
  {
   bool canStart = !CycleLimitReached();

   if(canStart && g_hasTop && !IsUsed(true, g_topTime) &&
      !(g_cycleActive && g_cycleDir < 0 && g_cycleSwingTime == g_topTime) &&
      SwingIntact(true, g_topLevel, g_atr) && IsRejection(true, g_topLevel, g_atr))
     {
      StartCycle(-1, g_topLevel, g_topTime);
      return;
     }

   if(canStart && g_hasBot && !IsUsed(false, g_botTime) &&
      !(g_cycleActive && g_cycleDir > 0 && g_cycleSwingTime == g_botTime) &&
      SwingIntact(false, g_botLevel, g_atr) && IsRejection(false, g_botLevel, g_atr))
     {
      StartCycle(+1, g_botLevel, g_botTime);
      return;
     }

   //--- o ciclo ainda não completou as entradas: nova recusa no mesmo nível
   if(g_cycleActive && g_cycleEntries < InpEntriesPerCycle &&
      IsRejection(g_cycleDir < 0, g_cycleLevel, g_cycleATR))
     {
      g_status = StringFormat("Reentrada no nível %.2f", g_cycleLevel);
      OpenInitialOrders();
     }
  }

//+------------------------------------------------------------------+
void StartCycle(int dir, double level, datetime swingTime)
  {
   if(g_cycleActive)
      EndCycle("substituído por novo topo/fundo relevante");

   g_cycleActive    = true;
   g_cycleDir       = dir;
   g_cycleLevel     = level;
   g_cycleATR       = g_atr;
   g_cycleSwingTime = swingTime;
   g_cycleEntries   = 0;
   g_cycleTPDist    = CycleRange(dir, level) * InpTPRangePct / 100.0;
   g_status = StringFormat("Novo ciclo de %s no %s %.2f (alvo topo-fundo: %.2f)",
                           dir > 0 ? "COMPRA" : "VENDA", dir > 0 ? "fundo" : "topo",
                           level, g_cycleTPDist);
   Print(g_status);
   SaveState();
   OpenInitialOrders();
  }

//+------------------------------------------------------------------+
void EndCycle(string reason)
  {
   if(!g_cycleActive)
      return;
   MarkUsed(g_cycleDir < 0, g_cycleSwingTime);
   if(g_cycleEntries > 0)
      g_cyclesDone++;
   Print("Fim do ciclo (", reason, "). Ciclos concluídos: ", g_cyclesDone,
         CycleLimitReached() ? ". Limite de ciclos atingido, robô parado."
                             : ". Aguardando o próximo topo/fundo relevante.");

   g_status         = "Fim do ciclo: " + reason;
   g_cycleActive    = false;
   g_cycleDir       = 0;
   g_cycleLevel     = 0.0;
   g_cycleATR       = 0.0;
   g_cycleSwingTime = 0;
   g_cycleEntries   = 0;
   g_cycleTPDist    = 0.0;
   SaveState();
  }

//+------------------------------------------------------------------+
bool CycleLimitReached()
  {
   return(InpMaxCycles > 0 && g_cyclesDone >= InpMaxCycles);
  }

//+------------------------------------------------------------------+
//| Distância entre o topo e o fundo relevantes. Usa no mínimo o      |
//| tamanho do movimento que formou o nível operado.                  |
//+------------------------------------------------------------------+
double CycleRange(int dir, double level)
  {
   double range = (dir < 0) ? g_topAmp : g_botAmp;
   if(dir < 0 && g_hasBot && g_botLevel < level)
      range = MathMax(range, level - g_botLevel);
   if(dir > 0 && g_hasTop && g_topLevel > level)
      range = MathMax(range, g_topLevel - level);
   return(range);
  }

//+------------------------------------------------------------------+
void OpenInitialOrders()
  {
   int toOpen = MathMin(InpInitialOrders, InpEntriesPerCycle - g_cycleEntries);
   for(int i = 0; i < toOpen; i++)
      if(!OpenOrder(g_cycleDir, CountPositions()))
         break;
  }

//+------------------------------------------------------------------+
void TryAddOrder(int n)
  {
   double   lastPrice = 0.0;
   datetime lastTime  = 0;
   if(!LastEntry(lastPrice, lastTime))
      return;
   if(TimeCurrent() - lastTime < InpMinSecondsBetween)
      return;

   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double price = (g_cycleDir > 0) ? ask : bid;
   bool   add   = false;

   switch(InpGridMode)
     {
      case GRID_CONTRA:
         add = (g_cycleDir > 0) ? (price <= lastPrice - InpStepPrice) : (price >= lastPrice + InpStepPrice);
         break;
      case GRID_FAVOR:
         add = (g_cycleDir > 0) ? (price >= lastPrice + InpStepPrice) : (price <= lastPrice - InpStepPrice);
         break;
      case GRID_INTERVAL:
         add = (g_cycleDir > 0) ? (bid > g_cycleLevel) : (bid < g_cycleLevel);
         break;
     }

   if(add)
      OpenOrder(g_cycleDir, n);
  }

//+------------------------------------------------------------------+
bool OpenOrder(int dir, int openCount)
  {
   if(TimeCurrent() - g_lastOrderFail < 10)
      return(false);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(InpMaxSpreadPrice > 0.0 && ask - bid > InpMaxSpreadPrice)
     {
      g_status = StringFormat("Spread alto (%.2f), entrada adiada", ask - bid);
      return(false);
     }

   double lot     = NormalizeLot(InpLot * MathPow(InpLotMultiplier, openCount));
   double minDist = MinStopDistance();
   double tp = 0.0, sl = 0.0;
   string cmt = StringFormat("K4RC %d/%d", g_cycleEntries + 1, InpEntriesPerCycle);
   bool   ok;

   if(dir > 0)
     {
      if(InpOrderTPPrice > 0.0) tp = NormalizeDouble(ask + MathMax(InpOrderTPPrice, minDist), _Digits);
      if(InpOrderSLPrice > 0.0) sl = NormalizeDouble(ask - MathMax(InpOrderSLPrice, minDist), _Digits);
      ok = trade.Buy(lot, _Symbol, ask, sl, tp, cmt);
     }
   else
     {
      if(InpOrderTPPrice > 0.0) tp = NormalizeDouble(bid - MathMax(InpOrderTPPrice, minDist), _Digits);
      if(InpOrderSLPrice > 0.0) sl = NormalizeDouble(bid + MathMax(InpOrderSLPrice, minDist), _Digits);
      ok = trade.Sell(lot, _Symbol, bid, sl, tp, cmt);
     }

   uint rc = trade.ResultRetcode();
   if(!ok || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL && rc != TRADE_RETCODE_PLACED))
     {
      g_lastOrderFail = TimeCurrent();
      Print("Falha ao abrir ordem: ", rc, " ", trade.ResultRetcodeDescription());
      return(false);
     }

   g_cycleEntries++;
   SaveState();
   return(true);
  }

//+------------------------------------------------------------------+
//| Saída rápida da cesta                                            |
//+------------------------------------------------------------------+
void ManageExit(int n)
  {
   double profit      = BasketProfit();
   double rangeTarget = RangeTargetPrice();
   // sem ciclo ativo (estado perdido) o alvo em dinheiro vale como reserva
   bool   useMoney    = (InpTPMode != TP_RANGE || rangeTarget <= 0.0);

   if(rangeTarget > 0.0 && profit > 0.0)
     {
      bool hit = (g_cycleDir < 0) ? (SymbolInfoDouble(_Symbol, SYMBOL_ASK) <= rangeTarget)
                                  : (SymbolInfoDouble(_Symbol, SYMBOL_BID) >= rangeTarget);
      if(hit)
        {
         RequestCloseAll(StringFormat("Alvo topo-fundo %.2f atingido: %.2f", rangeTarget, profit), false);
         return;
        }
     }

   if(useMoney && InpBasketTPMoney > 0.0 && profit >= BasketTarget(n))
     {
      RequestCloseAll(StringFormat("Alvo da cesta atingido: %.2f", profit), false);
      return;
     }

   if(InpBasketSLMoney > 0.0 && profit <= -InpBasketSLMoney)
     {
      RequestCloseAll(StringFormat("Stop da cesta atingido: %.2f", profit), true);
      return;
     }

   if(InpTimeExitMinutes > 0 && profit >= InpTimeExitMinProfit)
     {
      datetime oldest = OldestEntryTime();
      if(oldest > 0 && TimeCurrent() - oldest >= InpTimeExitMinutes * 60)
         RequestCloseAll(StringFormat("Saída por tempo: %.2f", profit), false);
     }
  }

double BasketTarget(int n)
  {
   return(InpBasketTPMoney + InpTPPerExtraOrder * MathMax(0, n - 1));
  }

//+------------------------------------------------------------------+
//| Alvo topo-fundo: a partir da 1ª ordem da cesta, anda X% da        |
//| distância entre o topo e o fundo relevantes. 0 = não se aplica.   |
//+------------------------------------------------------------------+
double RangeTargetPrice()
  {
   if(InpTPMode == TP_MONEY || !g_cycleActive || g_cycleTPDist <= 0.0)
      return(0.0);
   double firstPrice = FirstEntryPrice();
   if(firstPrice <= 0.0)
      return(0.0);
   return(NormalizeDouble(firstPrice + g_cycleDir * g_cycleTPDist, _Digits));
  }

//+------------------------------------------------------------------+
//| Stop técnico: o preço foi além do nível do ciclo                  |
//+------------------------------------------------------------------+
bool LevelInvalidated()
  {
   if(InpInvalidateATR <= 0.0 || g_cycleATR <= 0.0)
      return(false);
   double dist = InpInvalidateATR * g_cycleATR;
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(g_cycleDir < 0)
      return(bid >= g_cycleLevel + dist);
   return(bid <= g_cycleLevel - dist);
  }

//+------------------------------------------------------------------+
//| Proteções da conta. Retorna true se o robô deve ficar parado.     |
//+------------------------------------------------------------------+
bool AccountGuards()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   if(!g_haltAll && InpEquityTarget > 0.0 && eq >= InpEquityTarget)
     {
      g_haltAll = true;
      RequestCloseAll(StringFormat("Equity alvo atingido: %.2f", eq), true);
     }
   if(g_haltAll)
     {
      g_status = "PARADO: equity alvo atingido";
      return(true);
     }

   double dayPL = eq - g_dayStartEquity;
   if(!g_haltDay && InpDailyTargetMoney > 0.0 && dayPL >= InpDailyTargetMoney)
     {
      g_haltDay = true;
      RequestCloseAll(StringFormat("Meta diária atingida: %.2f", dayPL), false);
     }
   else if(!g_haltDay && InpDailyMaxLossMoney > 0.0 && -dayPL >= InpDailyMaxLossMoney)
     {
      g_haltDay = true;
      RequestCloseAll(StringFormat("Perda diária máxima: %.2f", dayPL), true);
     }
   if(g_haltDay)
      g_status = "PARADO até amanhã: limite diário atingido";
   return(g_haltDay);
  }

//+------------------------------------------------------------------+
void UpdateDay()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int key = dt.year * 1000 + dt.day_of_year;
   if(key == g_dayKey)
      return;
   g_dayKey         = key;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_haltDay        = false;
   if(InpCycleLimitScope == LIMIT_PER_DAY)
      g_cyclesDone = 0;
   SaveState();
  }

//+------------------------------------------------------------------+
//| Fechamento da cesta com nova tentativa nos próximos ticks         |
//+------------------------------------------------------------------+
void RequestCloseAll(string reason, bool endCycle)
  {
   Print("Fechando cesta: ", reason);
   g_status           = reason;
   g_closeReason      = reason;
   g_closing          = true;
   g_closingEndsCycle = g_closingEndsCycle || endCycle;
   CloseAllNow();
  }

// retorna true enquanto ainda houver posições para fechar
bool ProcessClosing()
  {
   if(!g_closing)
      return(false);
   if(CountPositions() > 0)
      CloseAllNow();
   if(CountPositions() > 0)
      return(true);

   g_closing = false;
   if(g_closingEndsCycle)
      EndCycle(g_closeReason);
   g_closingEndsCycle = false;
   return(false);
  }

void CloseAllNow()
  {
   for(int attempt = 0; attempt < 3; attempt++)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && IsOurPosition(ticket))
            trade.PositionClose(ticket, (ulong)InpSlippage);
        }
      if(CountPositions() == 0)
         break;
     }
  }

//+------------------------------------------------------------------+
//| Topos/fundos relevantes                                          |
//+------------------------------------------------------------------+
void RefreshSwings()
  {
   datetime bar = iTime(_Symbol, InpSwingTF, 0);
   if(bar == 0 || bar == g_swingBar)
      return;

   double atr = GetATR();
   if(atr <= 0.0)
      return;

   int need = InpLookbackBars + InpLeftBars + 1;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpSwingTF, 0, need, r) < need)
      return; // histórico ainda carregando, tenta no próximo tick

   g_atr    = atr;
   g_hasTop = FindSwing(r, true,  atr, g_topLevel, g_topTime, g_topAmp);
   g_hasBot = FindSwing(r, false, atr, g_botLevel, g_botTime, g_botAmp);
   g_swingBar = bar;
  }

//+------------------------------------------------------------------+
//| Topo/fundo relevante (o mais recente) em candles fechados:        |
//|  - é o extremo dos N candles anteriores a ele;                    |
//|  - nenhum candle depois dele o superou (até o candle 1);          |
//|  - tem pelo menos X candles depois dele (confirmação);            |
//|  - o movimento até ele ou a partir dele tem pelo menos Y x ATR.   |
//| Em tendência, isso pega os fundos/topos que vão se formando nos   |
//| recuos (fundos mais altos na alta, topos mais baixos na baixa).   |
//+------------------------------------------------------------------+
bool FindSwing(const MqlRates &r[], bool isTop, double atr,
               double &level, datetime &swingTime, double &amplitude)
  {
   level     = 0.0;
   swingTime = 0;
   amplitude = 0.0;

   // extremos dos candles mais novos que i (do candle 1 até i-1)
   double newerExt = isTop ? -DBL_MAX : DBL_MAX; // maior máxima / menor mínima depois de i
   double newerOpp = isTop ?  DBL_MAX : -DBL_MAX; // até onde o preço se afastou depois de i

   for(int i = 1; i <= InpLookbackBars; i++)
     {
      double v  = isTop ? r[i].high : r[i].low;
      // confirmado e ainda não superado (um candle mais novo igual também invalida)
      bool   ok = (i > InpSwingStrength) && (isTop ? (v > newerExt) : (v < newerExt));

      // extremo dos candles anteriores
      double leftOpp = v;
      for(int k = i + 1; k <= i + InpLeftBars && ok; k++)
        {
         if(isTop)
           {
            if(r[k].high > v) ok = false;
            leftOpp = MathMin(leftOpp, r[k].low);
           }
         else
           {
            if(r[k].low < v) ok = false;
            leftOpp = MathMax(leftOpp, r[k].high);
           }
        }

      if(ok)
        {
         double amp = MathMax(MathAbs(v - leftOpp), MathAbs(newerOpp - v));
         if(amp >= InpMinSwingATR * atr)
           {
            level     = v;
            swingTime = r[i].time;
            amplitude = amp;
            return(true);
           }
        }

      if(isTop)
        {
         newerExt = MathMax(newerExt, r[i].high);
         newerOpp = MathMin(newerOpp, r[i].low);
        }
      else
        {
         newerExt = MathMin(newerExt, r[i].low);
         newerOpp = MathMax(newerOpp, r[i].high);
        }
     }
   return(false);
  }

// o candle atual do TF dos topos/fundos não rompeu o nível além do limite
bool SwingIntact(bool isTop, double level, double atr)
  {
   double maxBreak = InpMaxBreakATR * atr;
   if(isTop)
      return(iHigh(_Symbol, InpSwingTF, 0) <= level + maxBreak);
   return(iLow(_Symbol, InpSwingTF, 0) >= level - maxBreak);
  }

//+------------------------------------------------------------------+
//| Último candle fechado do TF de confirmação recusando o nível     |
//+------------------------------------------------------------------+
bool IsRejection(bool atTop, double level, double atr)
  {
   if(level <= 0.0 || atr <= 0.0)
      return(false);

   MqlRates c[];
   ArraySetAsSeries(c, true);
   if(CopyRates(_Symbol, InpConfirmTF, 1, 1, c) != 1)
      return(false);

   double range = c[0].high - c[0].low;
   if(range <= _Point)
      return(false);

   double zone     = InpZoneATR * atr;
   double maxBreak = InpMaxBreakATR * atr;

   if(atTop)
     {
      if(c[0].high < level - zone)     return(false); // não chegou na zona
      if(c[0].high > level + maxBreak) return(false); // rompeu demais
      if(c[0].close >= level)          return(false); // não fechou abaixo do topo
      if(InpRequireColor && c[0].close >= c[0].open) return(false);
      double wick = c[0].high - MathMax(c[0].open, c[0].close);
      return(wick / range >= InpMinWickRatio);
     }

   if(c[0].low > level + zone)     return(false);
   if(c[0].low < level - maxBreak) return(false);
   if(c[0].close <= level)         return(false);
   if(InpRequireColor && c[0].close <= c[0].open) return(false);
   double wick = MathMin(c[0].open, c[0].close) - c[0].low;
   return(wick / range >= InpMinWickRatio);
  }

//+------------------------------------------------------------------+
//| Topos/fundos já operados                                         |
//+------------------------------------------------------------------+
bool IsUsed(bool isTop, datetime t)
  {
   for(int i = 0; i < MAX_USED; i++)
     {
      datetime u = isTop ? g_usedTop[i] : g_usedBot[i];
      if(u != 0 && u == t)
         return(true);
     }
   return(false);
  }

void MarkUsed(bool isTop, datetime t)
  {
   if(t == 0 || IsUsed(isTop, t))
      return;
   for(int i = MAX_USED - 1; i > 0; i--)
     {
      if(isTop) g_usedTop[i] = g_usedTop[i - 1];
      else      g_usedBot[i] = g_usedBot[i - 1];
     }
   if(isTop) g_usedTop[0] = t;
   else      g_usedBot[0] = t;
  }

//+------------------------------------------------------------------+
//| Posições do robô                                                 |
//+------------------------------------------------------------------+
bool IsOurPosition(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return(false);
   return(PositionGetString(POSITION_SYMBOL) == _Symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic);
  }

int CountPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(IsOurPosition(PositionGetTicket(i)))
         n++;
   return(n);
  }

double BasketProfit()
  {
   double p = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(IsOurPosition(PositionGetTicket(i)))
         p += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   return(p);
  }

bool LastEntry(double &price, datetime &time)
  {
   long best = -1;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!IsOurPosition(PositionGetTicket(i)))
         continue;
      long t = PositionGetInteger(POSITION_TIME_MSC);
      if(t > best)
        {
         best  = t;
         price = PositionGetDouble(POSITION_PRICE_OPEN);
         time  = (datetime)PositionGetInteger(POSITION_TIME);
        }
     }
   return(best >= 0);
  }

double FirstEntryPrice()
  {
   long   oldest = -1;
   double price  = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!IsOurPosition(PositionGetTicket(i)))
         continue;
      long t = PositionGetInteger(POSITION_TIME_MSC);
      if(oldest < 0 || t < oldest)
        {
         oldest = t;
         price  = PositionGetDouble(POSITION_PRICE_OPEN);
        }
     }
   return(price);
  }

datetime OldestEntryTime()
  {
   datetime oldest = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!IsOurPosition(PositionGetTicket(i)))
         continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(oldest == 0 || t < oldest)
         oldest = t;
     }
   return(oldest);
  }

//+------------------------------------------------------------------+
//| Utilitários                                                      |
//+------------------------------------------------------------------+
double GetATR()
  {
   double buf[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) != 1)
      return(0.0);
   return(buf[0]);
  }

double MinStopDistance()
  {
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return((stopsLevel + 1) * _Point);
  }

bool InTradingHours()
  {
   if(InpStartHour == InpEndHour)
      return(true);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpStartHour < InpEndHour)
      return(dt.hour >= InpStartHour && dt.hour < InpEndHour);
   return(dt.hour >= InpStartHour || dt.hour < InpEndHour);
  }

bool CanTrade()
  {
   if(!InTradingHours())
      return(false);
   return(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && MQLInfoInteger(MQL_TRADE_ALLOWED));
  }

double NormalizeLot(double lot)
  {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;
   lot = MathFloor(lot / step + 1e-9) * step;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   int digits = (int)MathMax(0.0, MathCeil(-MathLog10(step) - 1e-9));
   return(NormalizeDouble(lot, digits));
  }

//+------------------------------------------------------------------+
//| Estado salvo (sobrevive a reinício do MT5 / troca de timeframe)  |
//+------------------------------------------------------------------+
void SaveState()
  {
   if(g_pfx == "")
      return;
   GlobalVariableSet(g_pfx + "active",  g_cycleActive ? 1.0 : 0.0);
   GlobalVariableSet(g_pfx + "dir",     g_cycleDir);
   GlobalVariableSet(g_pfx + "level",   g_cycleLevel);
   GlobalVariableSet(g_pfx + "atr",     g_cycleATR);
   GlobalVariableSet(g_pfx + "swing",   (double)g_cycleSwingTime);
   GlobalVariableSet(g_pfx + "entries", g_cycleEntries);
   GlobalVariableSet(g_pfx + "tpDist",  g_cycleTPDist);
   GlobalVariableSet(g_pfx + "cycles",  g_cyclesDone);
   GlobalVariableSet(g_pfx + "dayKey",  g_dayKey);
   GlobalVariableSet(g_pfx + "dayEq",   g_dayStartEquity);
   for(int i = 0; i < MAX_USED; i++)
     {
      GlobalVariableSet(g_pfx + "uT" + (string)i, (double)g_usedTop[i]);
      GlobalVariableSet(g_pfx + "uB" + (string)i, (double)g_usedBot[i]);
     }
  }

void LoadState()
  {
   if(!GlobalVariableCheck(g_pfx + "active"))
      return;
   g_cycleActive    = GlobalVariableGet(g_pfx + "active") > 0.5;
   g_cycleDir       = (int)GlobalVariableGet(g_pfx + "dir");
   g_cycleLevel     = GlobalVariableGet(g_pfx + "level");
   g_cycleATR       = GlobalVariableGet(g_pfx + "atr");
   g_cycleSwingTime = (datetime)(long)GlobalVariableGet(g_pfx + "swing");
   g_cycleEntries   = (int)GlobalVariableGet(g_pfx + "entries");
   g_cycleTPDist    = GlobalVariableGet(g_pfx + "tpDist");
   g_cyclesDone     = (int)GlobalVariableGet(g_pfx + "cycles");
   g_dayKey         = (int)GlobalVariableGet(g_pfx + "dayKey");
   g_dayStartEquity = GlobalVariableGet(g_pfx + "dayEq");
   for(int i = 0; i < MAX_USED; i++)
     {
      g_usedTop[i] = (datetime)(long)GlobalVariableGet(g_pfx + "uT" + (string)i);
      g_usedBot[i] = (datetime)(long)GlobalVariableGet(g_pfx + "uB" + (string)i);
     }
   if(g_cycleActive)
      g_status = StringFormat("Ciclo restaurado: %d/%d entradas", g_cycleEntries, InpEntriesPerCycle);
  }

//+------------------------------------------------------------------+
//| Visual                                                           |
//+------------------------------------------------------------------+
void SetHLine(string name, double price, color clr, ENUM_LINE_STYLE style)
  {
   if(price <= 0.0)
     {
      ObjectDelete(0, name);
      return;
     }
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

void Render()
  {
   if(InpDrawLevels)
     {
      SetHLine(K4_PREFIX + "Top",    g_hasTop ? g_topLevel : 0.0, clrTomato,     STYLE_DASH);
      SetHLine(K4_PREFIX + "Bottom", g_hasBot ? g_botLevel : 0.0, clrDodgerBlue, STYLE_DASH);
      SetHLine(K4_PREFIX + "Cycle",  g_cycleActive ? g_cycleLevel : 0.0, clrGold, STYLE_SOLID);
      SetHLine(K4_PREFIX + "Target", RangeTargetPrice(), clrLimeGreen, STYLE_DOT);
     }

   int    n      = CountPositions();
   double profit = BasketProfit();
   double rangeTarget = RangeTargetPrice();
   string target;
   if(InpTPMode == TP_RANGE && rangeTarget > 0.0)
      target = StringFormat("preço %.2f", rangeTarget);
   else if(InpTPMode == TP_FIRST && rangeTarget > 0.0)
      target = StringFormat("preço %.2f ou %.2f", rangeTarget, BasketTarget(n));
   else
      target = StringFormat("%.2f", BasketTarget(n));

   string limit = (InpMaxCycles > 0)
                  ? StringFormat("%d/%d %s", g_cyclesDone, InpMaxCycles,
                                 InpCycleLimitScope == LIMIT_PER_DAY ? "hoje" : "no total")
                  : StringFormat("%d (sem limite)", g_cyclesDone);
   string status = (!g_cycleActive && n == 0 && CycleLimitReached())
                   ? "PARADO: limite de ciclos atingido"
                   : g_status;
   string cycle  = g_cycleActive
                   ? StringFormat("%s em %.2f | entradas %d/%d",
                                  g_cycleDir > 0 ? "COMPRA" : "VENDA", g_cycleLevel,
                                  g_cycleEntries, InpEntriesPerCycle)
                   : "nenhum (aguardando recusa)";

   Comment(StringFormat("K4 Rejection Cycles | %s\n"
                        "Topo relevante: %s | Fundo relevante: %s | ATR: %.2f\n"
                        "Ciclo: %s\n"
                        "Ciclos concluídos: %s\n"
                        "Posições: %d | Lucro cesta: %.2f | Alvo: %s\n"
                        "Resultado do dia: %.2f\n"
                        "%s",
                        _Symbol,
                        g_hasTop ? DoubleToString(g_topLevel, _Digits) : "-",
                        g_hasBot ? DoubleToString(g_botLevel, _Digits) : "-",
                        g_atr, cycle, limit, n, profit, target,
                        AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartEquity,
                        status));
  }
//+------------------------------------------------------------------+
