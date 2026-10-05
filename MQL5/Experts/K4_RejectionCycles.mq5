//+------------------------------------------------------------------+
//|                                           K4_RejectionCycles.mq5 |
//|  Robô de ciclos de entradas na recusa de topo/fundo relevante    |
//|  Pensado para XAUUSD em conta cent (MetaTrader 5, conta hedge)   |
//+------------------------------------------------------------------+
#property copyright "k4copy"
#property version   "3.10"
#property description "Cada topo/fundo relevante (ex.: M30) abre um ciclo de até N entradas (por recusa, pirâmide ou preço médio)."
#property description "Cada ciclo tem a sua cesta, alvo e trailing; termina quando a cesta fecha."
#property description "O próximo ciclo começa no próximo topo/fundo relevante (por padrão, depois que o atual completar as entradas)."

#include <Trade\Trade.mqh>

#define K4_PREFIX  "K4RC_"
#define MAX_USED   50
#define MAX_SLOTS  10    // ciclos simultâneos possíveis (cada um usa o mágico base + índice)
#define EXIT_COUNT 7

//--- como o ciclo abre as entradas depois da primeira
enum ENUM_ENTRY_MODE
  {
   ENTRY_REJECTION = 0, // Uma por recusa no nível
   ENTRY_PYRAMID   = 1, // Pirâmide: a cada X US$ a favor do preço
   ENTRY_AVERAGE   = 2  // Preço médio: a cada X US$ contra o preço
  };

//--- tipo de alvo (TP) da cesta
enum ENUM_TP_MODE
  {
   TP_MONEY = 0, // Valor em dinheiro (X)
   TP_RANGE = 1, // % da distância topo-fundo
   TP_FIRST = 2, // Dinheiro ou % topo-fundo (o que vier primeiro)
   TP_PRICE = 3  // US$ a favor do preço médio
  };

//--- trailing stop da cesta
enum ENUM_TRAIL_MODE
  {
   TRAIL_OFF      = 0, // Desligado
   TRAIL_AT_TP    = 1, // Ao atingir o alvo, deixa correr
   TRAIL_AT_PRICE = 2  // A partir de X US$ a favor do preço médio
  };

//--- como contar o limite de ciclos
enum ENUM_CYCLE_LIMIT
  {
   LIMIT_PER_DAY = 0, // Por dia (zera todo dia)
   LIMIT_TOTAL   = 1  // Total (zera com "Apagar estado salvo")
  };

//--- motivos de saída da cesta (contadores do painel)
enum ENUM_EXIT_REASON
  {
   EXIT_TARGET = 0, // alvo
   EXIT_TRAIL  = 1, // trailing stop
   EXIT_TIME   = 2, // tempo
   EXIT_LEVEL  = 3, // stop técnico
   EXIT_BASKET = 4, // stop da cesta
   EXIT_GUARD  = 5, // proteção da conta
   EXIT_OTHER  = 6  // outros (manual, stop out...)
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

//=== Ciclos ========================================================
input group "=== Ciclos ==="
input int              InpEntriesPerCycle    = 10;            // Entradas por ciclo (limite do ciclo)
input ENUM_ENTRY_MODE  InpEntryMode          = ENTRY_REJECTION; // Como abrir as próximas entradas do ciclo
input int              InpOrdersPerRejection = 1;             // Ordens abertas em cada candle de recusa
input double           InpStepPrice          = 1.50;          // Pirâmide/preço médio: distância entre ordens (US$)
input int              InpMinSecondsBetween  = 30;            // Pirâmide/preço médio: intervalo mínimo entre ordens (seg)
input double           InpLot                = 0.01;          // Lote de cada ordem
input double           InpLotMultiplier      = 1.0;           // Multiplicador de lote por entrada (1.0 = fixo)
input bool             InpNewCycleAfterLimit = true;          // Novo ciclo só depois que o atual completar as N entradas (ou fechar)
input int              InpMaxOpenCycles      = 3;             // Ciclos abertos ao mesmo tempo (máx. 10)
input int              InpMaxCycles          = 0;             // Parar após X ciclos iniciados (0 = sem limite)
input ENUM_CYCLE_LIMIT InpCycleLimitScope    = LIMIT_PER_DAY; // Contagem dos ciclos

//=== Saída =========================================================
input group "=== Saída (alvo da cesta de cada ciclo) ==="
input ENUM_TP_MODE    InpTPMode            = TP_PRICE; // Tipo de alvo da cesta
input double          InpTPRangePct        = 30.0;  // Alvo: % da distância entre topo e fundo relevantes
input double          InpTPPriceDist       = 3.0;   // Alvo: US$ a favor do preço médio (modo US$)
input double          InpBasketTPMoney     = 5.0;   // Alvo em dinheiro (moeda da conta; o painel mostra quanto vale US$1 no ouro)
input double          InpTPPerExtraOrder   = 0.0;   // Alvo em dinheiro: adicional por ordem extra na cesta
input bool            InpServerTP          = true;  // Enviar alvo/stop técnico/trailing como TP/SL real nas ordens
input bool            InpIncludeCommission = true;  // Descontar comissão (entrada + saída) do lucro da cesta
input double          InpBasketSLMoney     = 0.0;   // Prejuízo máx. da cesta (0 = desligado)
input double          InpInvalidateATR     = 1.0;   // Stop técnico: preço além do nível (x ATR; 0 = off)
input int             InpTimeExitMinutes   = 0;     // Após X min, sai com o lucro mínimo abaixo (0 = off)
input double          InpTimeExitMinProfit = 0.0;   // Lucro mínimo da saída por tempo

//=== Trailing stop da cesta ========================================
input group "=== Trailing stop da cesta ==="
input ENUM_TRAIL_MODE InpTrailMode       = TRAIL_OFF; // Trailing stop
input double          InpTrailStartPrice = 3.0;       // Ativa a X US$ a favor do zero a zero líquido (modo "A partir de X")
input double          InpTrailDistPrice  = 1.5;       // Sai quando o preço devolver X US$ do melhor ponto
input double          InpTrailLockPct    = 50.0;      // Ao ativar, garante X% do lucro daquele momento

//=== Proteção da conta =============================================
input group "=== Proteção da conta ==="
input double          InpDailyTargetMoney  = 0.0;   // Meta diária: fecha tudo e para até amanhã (0 = off)
input double          InpDailyMaxLossMoney = 0.0;   // Perda diária máx.: fecha tudo e para até amanhã (0 = off)
input double          InpEquityTarget      = 0.0;   // Equity alvo: fecha tudo e para (0 = off)
input double          InpMaxSpreadPrice    = 0.60;  // Spread máximo para entrar (US$ no preço; 0 = off)
input int             InpStartHour         = 1;     // Hora inicial (servidor)
input int             InpEndHour           = 23;    // Hora final (servidor; igual à inicial = 24h)

//=== Geral =========================================================
input group "=== Geral ==="
input ulong           InpMagic       = 440030; // Número mágico base (usa base..base+9; outra instância no mesmo símbolo: base+10 ou mais)
input int             InpSlippage    = 50;     // Desvio máximo (pontos)
input bool            InpDrawLevels  = true;   // Desenhar níveis no gráfico
input bool            InpResetState  = false;  // Apagar estado salvo ao iniciar

//--- estado de um ciclo (uma cesta por ciclo)
struct CycleState
  {
   bool     active;        // ciclo existe (aceitando entradas e/ou com posições)
   int      seq;           // número do ciclo (#1, #2, ...), não se repete
   int      dir;           // +1 compra (fundo), -1 venda (topo)
   double   level;         // topo/fundo operado
   double   atr;           // ATR no início do ciclo
   double   range;         // distância topo-fundo no início do ciclo
   datetime swingTime;     // candle do topo/fundo (identifica o nível)
   datetime startTime;
   int      entries;       // ordens abertas no ciclo
   datetime lastEntryTime;
   bool     acceptEntries; // ainda abre ordens em novas recusas
   bool     hadPositions;
   datetime zeroSince;     // quando a cesta apareceu vazia sem saída no histórico
   int      prevPositions;
   bool     trailActive;
   double   trailBest;     // melhor preço desde que o trailing ativou
   double   trailFloor;    // pior stop possível (lucro garantido ao ativar)
   bool     closing;
   string   closeReason;
  };

//--- negociação
CTrade   trade;
int      g_atrHandle = INVALID_HANDLE;
string   g_pfx       = "";
int      g_maxOpen   = 1;

//--- ciclos
CycleState g_cy[MAX_SLOTS];
int        g_cyclesStarted = 0;    // ciclos iniciados (para o limite)
int        g_cycleSeq      = 0;    // numeração dos ciclos
datetime   g_usedTop[MAX_USED];    // topos já operados
datetime   g_usedBot[MAX_USED];    // fundos já operados

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
datetime g_lastModifyFail   = 0;
datetime g_lastCloseFailLog = 0;
int      g_dayKey           = 0;
double   g_dayStartEquity   = 0.0;
bool     g_haltDay          = false;
bool     g_haltAll          = false;
int      g_exitCount[EXIT_COUNT];
ulong    g_commTicket[];             // cache: comissão de entrada por posição
double   g_commValue[];
string   g_status           = "Aguardando recusa de topo/fundo relevante";

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpEntriesPerCycle < 1 || InpOrdersPerRejection < 1 || InpLot <= 0.0 ||
      (InpEntryMode != ENTRY_REJECTION && InpStepPrice <= 0.0) ||
      InpLotMultiplier <= 0.0 || InpSwingStrength < 1 || InpLeftBars < 1 ||
      InpLookbackBars <= InpSwingStrength || InpMaxOpenCycles < 1)
     {
      Print("Parâmetros inválidos: verifique entradas, ordens por recusa, lote, ciclos abertos e candles.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if((InpTPMode == TP_RANGE || InpTPMode == TP_FIRST) && InpTPRangePct <= 0.0)
     {
      Print("Parâmetros inválidos: com alvo topo-fundo, a % do alvo deve ser > 0.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpTPMode == TP_PRICE && InpTPPriceDist <= 0.0)
     {
      Print("Parâmetros inválidos: com alvo em US$ do preço médio, a distância deve ser > 0.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpTrailMode != TRAIL_OFF && InpTrailDistPrice <= 0.0)
     {
      Print("Parâmetros inválidos: com trailing ligado, o recuo do trailing deve ser > 0.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpTrailMode == TRAIL_AT_PRICE && InpTrailStartPrice <= 0.0)
     {
      Print("Parâmetros inválidos: o início do trailing deve ser > 0.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpTrailLockPct < 0.0 || InpTrailLockPct >= 100.0)
     {
      Print("Parâmetros inválidos: o lucro garantido do trailing deve ficar entre 0 e 99%.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_maxOpen = MathMin(InpMaxOpenCycles, MAX_SLOTS);
   if(InpDrawLevels && !(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)))
      ChartSetInteger(0, CHART_SHOW_OBJECT_DESCR, true); // mostra o nome de cada linha
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
   for(int s = 0; s < MAX_SLOTS; s++)
      ResetSlot(s);
   for(int k = 0; k < EXIT_COUNT; k++)
      g_exitCount[k] = 0;

   g_pfx = K4_PREFIX + _Symbol + "_" + (string)InpMagic + "_";
   // no testador cada teste começa do zero (não herda ciclos do teste anterior)
   if(InpResetState || MQLInfoInteger(MQL_TESTER))
      GlobalVariablesDeleteAll(g_pfx);
   LoadState();
   for(int s = 0; s < MAX_SLOTS; s++)
      if(g_cy[s].active)
         g_cy[s].prevPositions = CountPositions(s);
   AdoptOrphanPositions();
   UpdateDay();

   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("Aviso: a conta não é HEDGE. Este robô precisa de conta hedge para manter uma cesta por ciclo.");
   if(StringFind(_Symbol, "XAU") < 0)
      Print("Aviso: robô pensado para XAUUSD, rodando em ", _Symbol);
   if(InpInvalidateATR > 0.0 && InpInvalidateATR <= InpMaxBreakATR)
      Print("Aviso: o stop técnico (", InpInvalidateATR, " ATR) deve ser maior que o rompimento máximo (",
            InpMaxBreakATR, " ATR).");

   string currency = AccountInfoString(ACCOUNT_CURRENCY);
   double perOrder = MoneyPerPriceUnit(NormalizeLot(InpLot));
   double spread   = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   if((InpTPMode == TP_MONEY || InpTPMode == TP_FIRST) && perOrder > 0.0 &&
      InpBasketTPMoney / perOrder < 2.0 * spread)
      PrintFormat("Aviso: o alvo em dinheiro (%.2f %s) equivale a só US$ %.2f de movimento com 1 ordem, menos que 2 spreads.",
                  InpBasketTPMoney, currency, InpBasketTPMoney / perOrder);
   PrintFormat("Conta em %s | US$ 1 no ouro com %.2f lote = %.2f %s | alvo: %s | trailing: %s | saída por tempo: %s",
               currency, NormalizeLot(InpLot), MoneyPerPriceUnit(NormalizeLot(InpLot)), currency,
               EnumToString(InpTPMode), EnumToString(InpTrailMode),
               InpTimeExitMinutes > 0 ? (string)InpTimeExitMinutes + " min" : "desligada");

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
   bool halted = AccountGuards();

   //--- posições sem ciclo (ex.: ordem que apareceu atrasada) passam a ser administradas
   AdoptOrphanPositions();

   //--- cada ciclo administra a sua cesta (alvo, trailing, stops, fechamento)
   for(int s = 0; s < MAX_SLOTS; s++)
      if(g_cy[s].active)
         ManageCycle(s);

   if(CountPositions(-1) == 0 && ArraySize(g_commTicket) > 0)
     {
      ArrayFree(g_commTicket);
      ArrayFree(g_commValue);
     }

   //--- entradas e novos ciclos: só no fechamento de um candle do TF de confirmação
   datetime confirmBar = iTime(_Symbol, InpConfirmTF, 0);
   if(confirmBar != 0 && confirmBar != g_lastConfirmBar)
     {
      bool firstBar = (g_lastConfirmBar == 0);
      g_lastConfirmBar = confirmBar;
      if(!firstBar && !halted && g_atr > 0.0 && CanTrade())
         CheckSignals();
     }

   Render();
  }

//+------------------------------------------------------------------+
//| Sinais do candle que acabou de fechar:                           |
//|  1) nova entrada nos ciclos que ainda aceitam ordens;            |
//|  2) novo ciclo no próximo topo/fundo relevante.                  |
//+------------------------------------------------------------------+
void CheckSignals()
  {
   for(int s = 0; s < MAX_SLOTS; s++)
     {
      if(!g_cy[s].active || g_cy[s].closing || !g_cy[s].acceptEntries || g_cy[s].trailActive)
         continue;
      if(g_cy[s].entries >= InpEntriesPerCycle)
        {
         g_cy[s].acceptEntries = false;
         continue;
        }
      if(InpEntryMode == ENTRY_REJECTION &&
         IsRejection(g_cy[s].dir < 0, g_cy[s].level, g_cy[s].atr) && OpenEntries(s) > 0)
         g_status = StringFormat("Ciclo #%d: nova recusa em %.2f, entrada %d/%d", g_cy[s].seq, g_cy[s].level,
                                 g_cy[s].entries, InpEntriesPerCycle);
     }

   // um "novo" topo/fundo criado pelo pavio que passou um pouco do nível de um ciclo aberto
   // é o mesmo nível: não abre outro ciclo nele
   AbsorbSameLevelSwing(true,  g_hasTop, g_topLevel, g_topTime);
   AbsorbSameLevelSwing(false, g_hasBot, g_botLevel, g_botTime);

   //--- recusa num topo/fundo relevante ainda não operado?
   int      dir   = 0;
   double   level = 0.0;
   datetime swing = 0;
   if(g_hasTop && CanStartAt(true, g_topTime) &&
      SwingIntact(true, g_topLevel, g_atr) && IsRejection(true, g_topLevel, g_atr))
     {
      dir   = -1;
      level = g_topLevel;
      swing = g_topTime;
     }
   else if(g_hasBot && CanStartAt(false, g_botTime) &&
           SwingIntact(false, g_botLevel, g_atr) && IsRejection(false, g_botLevel, g_atr))
     {
      dir   = +1;
      level = g_botLevel;
      swing = g_botTime;
     }
   if(dir == 0)
      return;

   //--- limites para abrir um novo ciclo
   string where = StringFormat("%s %.2f", dir > 0 ? "fundo" : "topo", level);
   if(CycleLimitReached())
     {
      g_status = StringFormat("Recusa no %s ignorada: limite de %d ciclos atingido", where, InpMaxCycles);
      return;
     }
   if(OpenCycles() >= g_maxOpen)
     {
      g_status = StringFormat("Recusa no %s ignorada: %d/%d ciclos abertos", where, OpenCycles(), g_maxOpen);
      return;
     }
   int filling = CycleStillFilling();
   if(InpNewCycleAfterLimit && filling >= 0)
     {
      g_status = StringFormat("Recusa no %s aguardando: ciclo #%d ainda não completou %d entradas", where,
                              g_cy[filling].seq, InpEntriesPerCycle);
      return;
     }
   StartCycle(dir, level, swing);
  }

// índice de um ciclo que ainda pode abrir ordens (-1 = nenhum)
int CycleStillFilling()
  {
   for(int s = 0; s < MAX_SLOTS; s++)
      if(g_cy[s].active && !g_cy[s].closing && g_cy[s].acceptEntries && !g_cy[s].trailActive &&
         g_cy[s].entries < InpEntriesPerCycle)
         return(s);
   return(-1);
  }

// marca como operado o topo/fundo que está praticamente no nível de um ciclo aberto do mesmo lado
void AbsorbSameLevelSwing(bool isTop, bool has, double level, datetime swingTime)
  {
   if(!has || swingTime == 0 || IsUsed(isTop, swingTime))
      return;
   for(int s = 0; s < MAX_SLOTS; s++)
      if(g_cy[s].active && (g_cy[s].dir < 0) == isTop && g_cy[s].swingTime != swingTime &&
         MathAbs(level - g_cy[s].level) <= InpMaxBreakATR * MathMax(g_cy[s].atr, g_atr))
        {
         MarkUsed(isTop, swingTime);
         return;
        }
  }

// o topo/fundo ainda não foi operado e não tem ciclo aberto nele
bool CanStartAt(bool isTop, datetime swingTime)
  {
   if(swingTime == 0 || IsUsed(isTop, swingTime))
      return(false);
   for(int s = 0; s < MAX_SLOTS; s++)
      if(g_cy[s].active && g_cy[s].swingTime == swingTime && (g_cy[s].dir < 0) == isTop)
         return(false);
   return(true);
  }

int OpenCycles()
  {
   int n = 0;
   for(int s = 0; s < MAX_SLOTS; s++)
      if(g_cy[s].active)
         n++;
   return(n);
  }

int FreeSlot()
  {
   for(int s = 0; s < MAX_SLOTS; s++)
      if(!g_cy[s].active && CountPositions(s) == 0)
         return(s);
   return(-1);
  }

//+------------------------------------------------------------------+
void StartCycle(int dir, double level, datetime swingTime)
  {
   int s = FreeSlot();
   if(s < 0)
      return;

   ResetSlot(s);
   g_cy[s].active        = true;
   g_cy[s].seq           = g_cycleSeq + 1;
   g_cy[s].dir           = dir;
   g_cy[s].level         = level;
   g_cy[s].atr           = g_atr;
   g_cy[s].range         = CycleRange(dir, level);
   g_cy[s].swingTime     = swingTime;
   g_cy[s].startTime     = TimeCurrent();
   g_cy[s].acceptEntries = true;

   if(OpenEntries(s) == 0)
     {
      ResetSlot(s); // a ordem não abriu (spread, margem...): tenta na próxima recusa
      return;
     }
   g_cycleSeq = g_cy[s].seq;

   // o ciclo anterior para de abrir ordens; as ordens dele seguem até o alvo/trailing/stop
   for(int k = 0; k < MAX_SLOTS; k++)
      if(k != s && g_cy[k].active && g_cy[k].acceptEntries)
        {
         g_cy[k].acceptEntries = false;
         Print("Ciclo #", g_cy[k].seq, ": não abre mais ordens (novo ciclo no próximo topo/fundo).");
        }

   g_cyclesStarted++;
   g_status = StringFormat("Ciclo #%d: %s no %s %.2f", g_cy[s].seq, dir > 0 ? "COMPRA" : "VENDA",
                           dir > 0 ? "fundo" : "topo", level);
   if(InpTPMode == TP_RANGE || InpTPMode == TP_FIRST)
      g_status += StringFormat(" | distância topo-fundo %.2f, alvo %.0f%% = %.2f",
                               g_cy[s].range, InpTPRangePct, g_cy[s].range * InpTPRangePct / 100.0);
   Print(g_status);
   SaveState();
  }

//+------------------------------------------------------------------+
//| Fim do ciclo: a cesta fechou. Marca o nível como operado e        |
//| registra o resultado líquido do ciclo.                            |
//+------------------------------------------------------------------+
void FinishCycle(int s, string reason)
  {
   if(!g_cy[s].active)
      return;
   MarkUsed(g_cy[s].dir < 0, g_cy[s].swingTime);
   string currency = AccountInfoString(ACCOUNT_CURRENCY);
   PrintFormat("Ciclo #%d encerrado (%s): %d entradas, resultado líquido %.2f %s", g_cy[s].seq, reason,
               g_cy[s].entries, CycleNetResult(s), currency);
   g_status = StringFormat("Ciclo #%d encerrado: %s", g_cy[s].seq, reason);
   ResetSlot(s);
   SaveState();
  }

void ResetSlot(int s)
  {
   g_cy[s].active        = false;
   g_cy[s].seq           = 0;
   g_cy[s].dir           = 0;
   g_cy[s].level         = 0.0;
   g_cy[s].atr           = 0.0;
   g_cy[s].range         = 0.0;
   g_cy[s].swingTime     = 0;
   g_cy[s].startTime     = 0;
   g_cy[s].entries       = 0;
   g_cy[s].lastEntryTime = 0;
   g_cy[s].acceptEntries = false;
   g_cy[s].hadPositions  = false;
   g_cy[s].zeroSince     = 0;
   g_cy[s].prevPositions = 0;
   g_cy[s].trailActive   = false;
   g_cy[s].trailBest     = 0.0;
   g_cy[s].trailFloor    = 0.0;
   g_cy[s].closing       = false;
   g_cy[s].closeReason   = "";
  }

bool CycleLimitReached()
  {
   return(InpMaxCycles > 0 && g_cyclesStarted >= InpMaxCycles);
  }

//+------------------------------------------------------------------+
//| Distância entre o topo e o fundo relevantes (as linhas tracejadas)|
//| no início do ciclo. Sem o nível oposto, usa o tamanho do          |
//| movimento que formou o nível operado.                             |
//+------------------------------------------------------------------+
double CycleRange(int dir, double level)
  {
   if(dir < 0 && g_hasBot && g_botLevel < level)
      return(level - g_botLevel);
   if(dir > 0 && g_hasTop && g_topLevel > level)
      return(g_topLevel - level);
   return((dir < 0) ? g_topAmp : g_botAmp);
  }

//+------------------------------------------------------------------+
//| Abre as ordens de uma recusa no ciclo. Retorna quantas abriu.     |
//+------------------------------------------------------------------+
int OpenEntries(int s)
  {
   int opened = 0;
   for(int i = 0; i < InpOrdersPerRejection && g_cy[s].entries < InpEntriesPerCycle; i++)
     {
      if(!OpenOrder(s))
         break;
      opened++;
     }
   if(g_cy[s].entries >= InpEntriesPerCycle)
      g_cy[s].acceptEntries = false;
   if(opened > 0)
      SaveState();
   return(opened);
  }

bool OpenOrder(int s)
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

   double lot = NormalizeLot(InpLot * MathPow(InpLotMultiplier, g_cy[s].entries));
   string cmt = StringFormat("K4 #%d %d/%d", g_cy[s].seq, g_cy[s].entries + 1, InpEntriesPerCycle);
   trade.SetExpertMagicNumber(InpMagic + (ulong)s);
   bool ok = (g_cy[s].dir > 0) ? trade.Buy(lot, _Symbol, ask, 0.0, 0.0, cmt)
                               : trade.Sell(lot, _Symbol, bid, 0.0, 0.0, cmt);
   trade.SetExpertMagicNumber(InpMagic);

   uint rc = trade.ResultRetcode();
   if(!ok || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL && rc != TRADE_RETCODE_PLACED))
     {
      g_lastOrderFail = TimeCurrent();
      Print("Falha ao abrir ordem: ", rc, " ", trade.ResultRetcodeDescription());
      return(false);
     }

   g_cy[s].entries++;
   g_cy[s].lastEntryTime = TimeCurrent();
   g_cy[s].hadPositions = true;
   g_cy[s].prevPositions++;
   return(true);
  }

//+------------------------------------------------------------------+
//| Administra a cesta de um ciclo                                   |
//+------------------------------------------------------------------+
void ManageCycle(int s)
  {
   int n = CountPositions(s);

   //--- fechamento pedido pelo robô em andamento
   if(g_cy[s].closing)
     {
      if(n > 0)
         CloseSlotNow(s);
      if(CountPositions(s) == 0)
         FinishCycle(s, g_cy[s].closeReason);
      return;
     }

   //--- a cesta fechou fora do robô (TP/SL na corretora, manual...): o ciclo termina.
   //    Só conta como fechada com a saída no histórico (uma ordem recém-aberta pode
   //    demorar um instante para aparecer na lista de posições).
   if(n == 0)
     {
      long reason = LastCloseDealReason(s);
      if(g_cy[s].hadPositions && reason >= 0)
        {
         ENUM_EXIT_REASON code = BrokerExitReason(s, reason);
         g_exitCount[code]++;
         FinishCycle(s, ExitText(code) + " (na corretora)");
         return;
        }
      if(!g_cy[s].hadPositions)
        {
         if(!g_cy[s].acceptEntries)
            FinishCycle(s, "sem posições");
         return;
        }
      if(g_cy[s].zeroSince == 0)
         g_cy[s].zeroSince = TimeCurrent();
      if(TimeCurrent() - g_cy[s].zeroSince > 15 && TimeCurrent() - g_cy[s].lastEntryTime > 60)
         FinishCycle(s, "sem posições");
      return;
     }

   //--- parte da cesta fechou na corretora: fecha o resto para o ciclo terminar inteiro.
   //    Sem a saída no histórico ainda, mantém a contagem anterior e confere no próximo tick.
   if(n < g_cy[s].prevPositions)
     {
      long reason = LastCloseDealReason(s);
      if(reason >= 0)
        {
         ENUM_EXIT_REASON code = BrokerExitReason(s, reason);
         RequestCloseCycle(s, ExitText(code) + " (parcial na corretora), fechando o restante", code);
         return;
        }
      if(TimeCurrent() - g_cy[s].lastEntryTime > 60)
         g_cy[s].prevPositions = n;   // sem saída no histórico depois de 1 min: aceita a nova contagem
     }
   else
      g_cy[s].prevPositions = n;
   g_cy[s].zeroSince = 0;
   g_cy[s].hadPositions  = true;

   if(LevelInvalidated(s))
     {
      RequestCloseCycle(s, StringFormat("Stop técnico: nível %.2f rompido", g_cy[s].level), EXIT_LEVEL);
      return;
     }

   ManageExit(s, n);
   if(g_cy[s].closing)
      return;
   if(TryGridEntry(s))
      n = CountPositions(s);
   SyncServerStops(s, n);
  }

//+------------------------------------------------------------------+
//| Pirâmide / preço médio: nova ordem quando o preço anda X US$ a    |
//| favor (pirâmide) ou contra (preço médio) desde a última entrada.  |
//+------------------------------------------------------------------+
bool TryGridEntry(int s)
  {
   if(InpEntryMode == ENTRY_REJECTION || !g_cy[s].acceptEntries || g_cy[s].trailActive ||
      g_haltDay || g_haltAll || !CanTrade())
      return(false);
   if(g_cy[s].entries >= InpEntriesPerCycle)
     {
      g_cy[s].acceptEntries = false;
      return(false);
     }

   // a ordem anterior ainda pode não aparecer na lista de posições: espera antes de somar outra
   if(TimeCurrent() - g_cy[s].lastEntryTime < MathMax(InpMinSecondsBetween, 1) ||
      CountPositions(s) < g_cy[s].prevPositions)
      return(false);

   double   lastPrice = 0.0;
   datetime lastTime  = 0;
   if(!LastEntry(s, lastPrice, lastTime) || TimeCurrent() - lastTime < InpMinSecondsBetween)
      return(false);

   int    dir   = g_cy[s].dir;
   double price = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double moved = dir * (price - lastPrice);          // > 0 = a favor, < 0 = contra
   bool   add   = (InpEntryMode == ENTRY_PYRAMID) ? (moved >= InpStepPrice) : (-moved >= InpStepPrice);
   if(!add || !OpenOrder(s))
      return(false);

   if(g_cy[s].entries >= InpEntriesPerCycle)
      g_cy[s].acceptEntries = false;
   g_status = StringFormat("Ciclo #%d: %s, entrada %d/%d", g_cy[s].seq,
                           InpEntryMode == ENTRY_PYRAMID ? "pirâmide" : "preço médio",
                           g_cy[s].entries, InpEntriesPerCycle);
   SaveState();
   return(true);
  }

// preço e hora da entrada mais recente do ciclo
bool LastEntry(int s, double &price, datetime &time)
  {
   long best = -1;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!InSlot(PositionGetTicket(i), s))
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

//+------------------------------------------------------------------+
//| Saída da cesta: alvo, trailing stop, stop da cesta e tempo        |
//+------------------------------------------------------------------+
void ManageExit(int s, int n)
  {
   int    dir = g_cy[s].dir;
   double avg = BasketAvgPrice(s);
   if(dir == 0 || avg <= 0.0)
      return;
   double profit = BasketProfit(s);
   double px     = ClosePrice(dir);

   //--- alvo: fecha, ou (trailing "ao atingir o alvo") passa a deixar correr.
   //    Com o trailing ativo, o alvo fixo não limita mais o movimento.
   string why   = "";
   bool   tpHit = TargetReached(s, n, dir, profit, avg, px, why);
   if(tpHit && InpTrailMode == TRAIL_OFF)
     {
      RequestCloseCycle(s, StringFormat("%s: %.2f", why, profit), EXIT_TARGET);
      return;
     }

   if(!g_cy[s].trailActive)
     {
      double be      = BreakevenPrice(s, dir, avg);
      bool   started = false;
      if(tpHit && dir * (px - be) > 0.0)
         started = StartTrail(s, px, avg, why);
      else if(InpTrailMode == TRAIL_AT_PRICE && dir * (px - be) >= InpTrailStartPrice)
         started = StartTrail(s, px, avg, StringFormat("US$ %.2f a favor do zero a zero", InpTrailStartPrice));
      if(started)
         return; // o stop começa a valer a partir do próximo tick
      if(tpHit)
        {
         RequestCloseCycle(s, StringFormat("%s: %.2f", why, profit), EXIT_TARGET);
         return;
        }
     }

   //--- trailing ativo: acompanha o melhor preço e sai quando devolver X US$
   if(g_cy[s].trailActive)
     {
      if(dir * (px - g_cy[s].trailBest) > 0.0)
         g_cy[s].trailBest = px;
      double stop = TrailStopPrice(s, dir, avg);
      if(dir * (px - stop) <= 0.0)
         RequestCloseCycle(s, StringFormat("Trailing stop %.2f (melhor %.2f): %.2f", stop,
                                           g_cy[s].trailBest, profit), EXIT_TRAIL);
      return; // com trailing ativo, stop da cesta e saída por tempo não se aplicam
     }

   if(InpBasketSLMoney > 0.0 && profit <= -InpBasketSLMoney)
     {
      RequestCloseCycle(s, StringFormat("Stop da cesta atingido: %.2f", profit), EXIT_BASKET);
      return;
     }

   if(InpTimeExitMinutes > 0 && profit >= InpTimeExitMinProfit)
     {
      datetime oldest = OldestEntryTime(s);
      if(oldest > 0 && TimeCurrent() - oldest >= InpTimeExitMinutes * 60)
         RequestCloseCycle(s, StringFormat("Saída por tempo (%d min): %.2f", InpTimeExitMinutes, profit), EXIT_TIME);
     }
  }

//+------------------------------------------------------------------+
//| O alvo da cesta foi atingido? (why = descrição para o Diário)     |
//+------------------------------------------------------------------+
bool TargetReached(int s, int n, int dir, double profit, double avg, double px, string &why)
  {
   double tp = TargetPrice(s, dir, avg);
   if(tp > 0.0 && profit > 0.0 && dir * (px - tp) >= 0.0)
     {
      why = StringFormat("Alvo de preço %.2f atingido", tp);
      return(true);
     }
   if(UsesMoneyTarget(tp) && InpBasketTPMoney > 0.0 && profit >= BasketTarget(n))
     {
      why = StringFormat("Alvo em dinheiro %.2f atingido", BasketTarget(n));
      return(true);
     }
   return(false);
  }

// o alvo em dinheiro vale nos modos dinheiro / "o que vier primeiro", ou como reserva sem alvo de preço
bool UsesMoneyTarget(double priceTarget)
  {
   return(InpTPMode == TP_MONEY || InpTPMode == TP_FIRST ||
          (InpTPMode == TP_RANGE && priceTarget <= 0.0));
  }

double BasketTarget(int n)
  {
   return(InpBasketTPMoney + InpTPPerExtraOrder * MathMax(0, n - 1));
  }

//+------------------------------------------------------------------+
//| Preço-alvo da cesta (0 = o modo atual não usa alvo em preço)      |
//+------------------------------------------------------------------+
double TargetPrice(int s, int dir, double avg)
  {
   if(InpTPMode == TP_PRICE)
      return((dir != 0 && avg > 0.0) ? NormalizePrice(avg + dir * InpTPPriceDist) : 0.0);
   if(InpTPMode == TP_RANGE || InpTPMode == TP_FIRST)
      return(RangeTargetPrice(s));
   return(0.0);
  }

//+------------------------------------------------------------------+
//| Alvo topo-fundo: a partir do nível (topo ou fundo operado), anda  |
//| X% da distância até o nível oposto. Se a 1ª ordem já entrou além  |
//| desse ponto, mede a partir dela.                                  |
//+------------------------------------------------------------------+
double RangeTargetPrice(int s)
  {
   if(!g_cy[s].active || g_cy[s].range <= 0.0 || g_cy[s].level <= 0.0)
      return(0.0);
   double dist  = g_cy[s].range * InpTPRangePct / 100.0;
   double tp    = g_cy[s].level + g_cy[s].dir * dist;
   double first = FirstEntryPrice(s);
   if(first > 0.0 && g_cy[s].dir * (tp - first) <= 0.0)
      tp = first + g_cy[s].dir * dist;
   return(NormalizePrice(tp));
  }

//+------------------------------------------------------------------+
//| Preço em que a cesta soma o alvo em dinheiro (líquido de custos)  |
//+------------------------------------------------------------------+
double MoneyTargetPrice(int s, int n, int dir, double avg)
  {
   double perUnit = MoneyPerPriceUnit(BasketVolume(s));
   if(InpBasketTPMoney <= 0.0 || perUnit <= 0.0 || dir == 0 || avg <= 0.0)
      return(0.0);
   double need = BasketTarget(n) - BasketCosts(s);
   return(NormalizePrice(avg + dir * need / perUnit));
  }

// preço em que o resultado líquido da cesta (com custos) é zero
double BreakevenPrice(int s, int dir, double avg)
  {
   double perUnit = MoneyPerPriceUnit(BasketVolume(s));
   if(perUnit <= 0.0)
      return(avg);
   return(avg - dir * BasketCosts(s) / perUnit);
  }

//+------------------------------------------------------------------+
//| TP enviado para a corretora: o alvo que vier primeiro.            |
//| Sem TP fixo quando o trailing deixa o movimento correr.           |
//+------------------------------------------------------------------+
double ServerTargetPrice(int s, int n, int dir, double avg)
  {
   if(InpTrailMode != TRAIL_OFF || g_cy[s].trailActive)
      return(0.0);
   double tp      = TargetPrice(s, dir, avg);
   double tpMoney = UsesMoneyTarget(tp) ? MoneyTargetPrice(s, n, dir, avg) : 0.0;
   double result;
   if(tp <= 0.0)
      result = tpMoney;
   else if(tpMoney <= 0.0)
      result = tp;
   else
      result = (dir > 0) ? MathMin(tp, tpMoney) : MathMax(tp, tpMoney);
   if(result <= 0.0)
      return(0.0);
   // nunca antes do zero a zero líquido (comissão e swap): o alvo virtual também exige lucro
   double be = BreakevenPrice(s, dir, avg) + dir * _Point;
   return(NormalizePrice(dir > 0 ? MathMax(result, be) : MathMin(result, be)));
  }

//+------------------------------------------------------------------+
//| Trailing stop da cesta                                           |
//+------------------------------------------------------------------+
bool StartTrail(int s, double px, double avg, string why)
  {
   int    dir = g_cy[s].dir;
   double be  = BreakevenPrice(s, dir, avg);
   g_cy[s].trailActive   = true;
   g_cy[s].acceptEntries = false; // com trailing o ciclo não abre mais ordens
   g_cy[s].trailBest     = px;
   // garante parte do lucro do momento da ativação (nunca pior que o zero a zero líquido)
   g_cy[s].trailFloor  = (dir * (px - be) > 0.0) ? be + (px - be) * InpTrailLockPct / 100.0 : be;
   g_status = StringFormat("Ciclo #%d: trailing ativado (%s)", g_cy[s].seq, why);
   Print(g_status, " preço ", DoubleToString(px, _Digits));
   SaveState();
   return(true);
  }

// stop = melhor preço menos o recuo, nunca pior que o lucro garantido na ativação
double TrailStopPrice(int s, int dir, double avg)
  {
   if(!g_cy[s].trailActive || g_cy[s].trailBest <= 0.0 || dir == 0)
      return(0.0);
   double stop   = g_cy[s].trailBest - dir * InpTrailDistPrice;
   double be     = BreakevenPrice(s, dir, avg);
   double lockPx = (g_cy[s].trailFloor > 0.0) ? g_cy[s].trailFloor : be;
   // nunca pior que o lucro travado na ativação nem que o zero a zero líquido de agora (swap)
   if(dir > 0)
      stop = MathMax(stop, MathMax(lockPx, be));
   else
      stop = MathMin(stop, MathMin(lockPx, be));
   return(NormalizePrice(stop));
  }

//+------------------------------------------------------------------+
//| Mantém TP (alvo) e SL (trailing) iguais em todas as ordens do     |
//| ciclo. A saída virtual do robô continua valendo como reserva.     |
//+------------------------------------------------------------------+
void SyncServerStops(int s, int n)
  {
   if(!InpServerTP || TimeCurrent() - g_lastModifyFail < 10)
      return;

   int    dir = g_cy[s].dir;
   double avg = BasketAvgPrice(s);
   if(dir == 0 || avg <= 0.0)
      return;
   double px      = ClosePrice(dir);
   double minDist = MinStopDistance();
   double tp      = ServerTargetPrice(s, n, dir, avg);
   double sl      = g_cy[s].trailActive ? TrailStopPrice(s, dir, avg) : TechStopPrice(s);
   bool   tpValid = (tp <= 0.0 || dir * (tp - px) >= minDist); // 0 = remover o TP
   bool   slValid = (sl > 0.0 && dir * (px - sl) >= minDist);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionSlot(ticket) != s)
         continue;
      double curTP = PositionGetDouble(POSITION_TP);
      double curSL = PositionGetDouble(POSITION_SL);
      double newTP = tpValid ? tp : curTP;  // perto demais do preço: mantém o TP atual
      double newSL = curSL;
      if(slValid && (curSL == 0.0 || dir * (sl - curSL) >= 10 * _Point))
         newSL = sl;                        // o stop só anda a favor
      if(MathAbs(curTP - newTP) < _Point / 2.0 && MathAbs(curSL - newSL) < _Point / 2.0)
         continue;
      if(!trade.PositionModify(ticket, newSL, newTP))
        {
         g_lastModifyFail = TimeCurrent();
         Print("Falha ao ajustar TP/SL da ordem ", ticket, ": ", trade.ResultRetcode(), " ",
               trade.ResultRetcodeDescription());
         return;
        }
     }
  }

//+------------------------------------------------------------------+
//| Stop técnico: o preço foi além do nível do ciclo                  |
//+------------------------------------------------------------------+
double TechStopPrice(int s)
  {
   if(InpInvalidateATR <= 0.0 || g_cy[s].atr <= 0.0 || g_cy[s].level <= 0.0)
      return(0.0);
   return(NormalizePrice(g_cy[s].level - g_cy[s].dir * InpInvalidateATR * g_cy[s].atr));
  }

bool LevelInvalidated(int s)
  {
   if(InpInvalidateATR <= 0.0 || g_cy[s].atr <= 0.0)
      return(false);
   double dist = InpInvalidateATR * g_cy[s].atr;
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(g_cy[s].dir < 0)
      return(bid >= g_cy[s].level + dist);
   return(bid <= g_cy[s].level - dist);
  }

//+------------------------------------------------------------------+
//| Proteções da conta. Retorna true se o robô não deve abrir ordens. |
//+------------------------------------------------------------------+
bool AccountGuards()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   if(!g_haltAll && InpEquityTarget > 0.0 && eq >= InpEquityTarget)
     {
      g_haltAll = true;
      CloseAllCycles(StringFormat("Equity alvo atingido: %.2f", eq));
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
      CloseAllCycles(StringFormat("Meta diária atingida: %.2f", dayPL));
     }
   else if(!g_haltDay && InpDailyMaxLossMoney > 0.0 && -dayPL >= InpDailyMaxLossMoney)
     {
      g_haltDay = true;
      CloseAllCycles(StringFormat("Perda diária máxima: %.2f", dayPL));
     }
   if(g_haltDay)
      g_status = "PARADO até amanhã: limite diário atingido";
   return(g_haltDay);
  }

void CloseAllCycles(string reason)
  {
   Print(reason);
   for(int s = 0; s < MAX_SLOTS; s++)
      if(g_cy[s].active)
        {
         if(CountPositions(s) > 0)
            RequestCloseCycle(s, reason, EXIT_GUARD);
         else
            FinishCycle(s, reason);
        }
  }

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
      g_cyclesStarted = 0;
   SaveState();
  }

//+------------------------------------------------------------------+
//| Fechamento da cesta de um ciclo (repete nos próximos ticks se     |
//| alguma ordem não fechar)                                          |
//+------------------------------------------------------------------+
void RequestCloseCycle(int s, string reason, ENUM_EXIT_REASON code)
  {
   if(!g_cy[s].closing)
     {
      g_exitCount[code]++;
      g_cy[s].closing     = true;
      g_cy[s].closeReason = reason;
      Print("Ciclo #", g_cy[s].seq, ": fechando cesta: ", reason);
     }
   CloseSlotNow(s);
   if(CountPositions(s) == 0)
      FinishCycle(s, reason);
  }

void CloseSlotNow(int s)
  {
   trade.SetExpertMagicNumber(InpMagic + (ulong)s);
   for(int attempt = 0; attempt < 3; attempt++)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || PositionSlot(ticket) != s)
            continue;
         if(!trade.PositionClose(ticket, (ulong)InpSlippage) && TimeCurrent() - g_lastCloseFailLog >= 60)
           {
            g_lastCloseFailLog = TimeCurrent();
            Print("Falha ao fechar a ordem ", ticket, ": ", trade.ResultRetcode(), " ",
                  trade.ResultRetcodeDescription());
           }
        }
      if(CountPositions(s) == 0)
         break;
     }
   trade.SetExpertMagicNumber(InpMagic);
  }

//+------------------------------------------------------------------+
//| Saídas feitas pela corretora: motivo e resultado do ciclo         |
//+------------------------------------------------------------------+
ENUM_EXIT_REASON BrokerExitReason(int s, long reason)
  {
   if(reason == DEAL_REASON_TP)
      return(EXIT_TARGET);
   if(reason == DEAL_REASON_SL)
      return(g_cy[s].trailActive ? EXIT_TRAIL : EXIT_LEVEL);
   return(EXIT_OTHER);
  }

string ExitText(ENUM_EXIT_REASON code)
  {
   switch(code)
     {
      case EXIT_TARGET: return("Alvo atingido");
      case EXIT_TRAIL:  return("Trailing stop atingido");
      case EXIT_TIME:   return("Saída por tempo");
      case EXIT_LEVEL:  return("Stop técnico");
      case EXIT_BASKET: return("Stop da cesta");
      case EXIT_GUARD:  return("Proteção da conta");
     }
   return("Fechada fora do robô");
  }

//+------------------------------------------------------------------+
//| Operações (deals) do ciclo no histórico: as entradas com o mágico |
//| do ciclo e todas as saídas dessas mesmas posições.                |
//| Retorna quantas encontrou; deals[] fica em ordem cronológica.     |
//+------------------------------------------------------------------+
int CycleDeals(int s, ulong &deals[])
  {
   ArrayResize(deals, 0);
   if(g_cy[s].startTime <= 0 || !HistorySelect(g_cy[s].startTime, TimeCurrent() + 60))
      return(0);

   long ids[];
   int  nIds  = 0;
   int  total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 || HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol ||
         HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN ||
         (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic + (ulong)s)
         continue;
      ArrayResize(ids, nIds + 1);
      ids[nIds++] = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
     }

   int n = 0;
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      long pos = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      for(int k = 0; k < nIds; k++)
         if(ids[k] == pos)
           {
            ArrayResize(deals, n + 1);
            deals[n++] = deal;
            break;
           }
     }
   return(n);
  }

// motivo (DEAL_REASON_*) da última saída de ordem do ciclo (-1 = nenhuma saída)
long LastCloseDealReason(int s)
  {
   ulong deals[];
   int   n = CycleDeals(s, deals);
   for(int i = n - 1; i >= 0; i--)
     {
      long entry = HistoryDealGetInteger(deals[i], DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
         return(HistoryDealGetInteger(deals[i], DEAL_REASON));
     }
   return(-1);
  }

// resultado líquido do ciclo (lucro + swap + comissão + taxas de todas as operações dele)
double CycleNetResult(int s)
  {
   ulong  deals[];
   int    n   = CycleDeals(s, deals);
   double sum = 0.0;
   for(int i = 0; i < n; i++)
      sum += HistoryDealGetDouble(deals[i], DEAL_PROFIT) + HistoryDealGetDouble(deals[i], DEAL_SWAP) +
             HistoryDealGetDouble(deals[i], DEAL_COMMISSION) + HistoryDealGetDouble(deals[i], DEAL_FEE);
   return(sum);
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
//| Posições do robô (mágico base + índice do ciclo)                 |
//+------------------------------------------------------------------+
// seleciona a posição e devolve o índice do ciclo dela (-1 = não é deste robô)
int PositionSlot(ulong ticket)
  {
   if(ticket == 0 || !PositionSelectByTicket(ticket) || PositionGetString(POSITION_SYMBOL) != _Symbol)
      return(-1);
   ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
   if(magic < InpMagic || magic >= InpMagic + MAX_SLOTS)
      return(-1);
   return((int)(magic - InpMagic));
  }

// s = -1: todas as posições do robô
bool InSlot(ulong ticket, int s)
  {
   int slot = PositionSlot(ticket);
   return(slot >= 0 && (s < 0 || slot == s));
  }

int CountPositions(int s)
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(InSlot(PositionGetTicket(i), s))
         n++;
   return(n);
  }

// lucro líquido da cesta: lucro + swap + comissão (entrada e saída estimada)
double BasketProfit(int s)
  {
   double p = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(InSlot(PositionGetTicket(i), s))
         p += PositionGetDouble(POSITION_PROFIT);
   return(p + BasketCosts(s));
  }

// swap + comissão estimada (valores negativos = custo)
double BasketCosts(int s)
  {
   double c = 0.0;
   ulong  tickets[];
   int    n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!InSlot(ticket, s))
         continue;
      c += PositionGetDouble(POSITION_SWAP);
      ArrayResize(tickets, n + 1);
      tickets[n++] = ticket;
     }
   if(InpIncludeCommission)
      for(int k = 0; k < n; k++)
         c += 2.0 * EntryCommission(tickets[k]);
   return(c);
  }

// comissão cobrada na entrada da posição (com cache)
double EntryCommission(ulong ticket)
  {
   int size = ArraySize(g_commTicket);
   for(int i = 0; i < size; i++)
      if(g_commTicket[i] == ticket)
         return(g_commValue[i]);

   if(!HistorySelectByPosition(ticket) || HistoryDealsTotal() == 0)
      return(0.0); // histórico ainda não disponível: tenta de novo no próximo tick
   double c = 0.0;
   for(int d = HistoryDealsTotal() - 1; d >= 0; d--)
     {
      ulong deal = HistoryDealGetTicket(d);
      if(deal > 0 && HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         c += HistoryDealGetDouble(deal, DEAL_COMMISSION);
     }
   ArrayResize(g_commTicket, size + 1);
   ArrayResize(g_commValue,  size + 1);
   g_commTicket[size] = ticket;
   g_commValue[size]  = c;
   return(c);
  }

// +1 = cesta comprada, -1 = cesta vendida, 0 = sem posições
int BasketDir(int s)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(InSlot(PositionGetTicket(i), s))
         return(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
   return(0);
  }

// preço médio ponderado pelo volume
double BasketAvgPrice(int s)
  {
   double vol = 0.0, sum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!InSlot(PositionGetTicket(i), s))
         continue;
      double v = PositionGetDouble(POSITION_VOLUME);
      vol += v;
      sum += v * PositionGetDouble(POSITION_PRICE_OPEN);
     }
   return(vol > 0.0 ? sum / vol : 0.0);
  }

double BasketVolume(int s)
  {
   double vol = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(InSlot(PositionGetTicket(i), s))
         vol += PositionGetDouble(POSITION_VOLUME);
   return(vol);
  }

double FirstEntryPrice(int s)
  {
   long   oldest = -1;
   double price  = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!InSlot(PositionGetTicket(i), s))
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

datetime OldestEntryTime(int s)
  {
   datetime oldest = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!InSlot(PositionGetTicket(i), s))
         continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(oldest == 0 || t < oldest)
         oldest = t;
     }
   return(oldest);
  }

// preço pelo qual a cesta fecharia agora (compra fecha no Bid, venda no Ask)
double ClosePrice(int dir)
  {
   return(dir > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK));
  }

// quanto a conta ganha/perde para cada US$ 1 de movimento do preço, com o volume informado
double MoneyPerPriceUnit(double volume)
  {
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      return(0.0);
   return(volume * tickValue / tickSize);
  }

//+------------------------------------------------------------------+
//| Posições sem ciclo salvo (ex.: estado apagado): viram um ciclo    |
//| que não abre mais ordens, só administra a saída.                  |
//+------------------------------------------------------------------+
void AdoptOrphanPositions()
  {
   for(int s = 0; s < MAX_SLOTS; s++)
     {
      if(g_cy[s].active)
         continue;
      int n = CountPositions(s);
      if(n == 0)
         continue;
      g_cy[s].active        = true;
      g_cy[s].seq           = ++g_cycleSeq;
      g_cy[s].dir           = BasketDir(s);
      g_cy[s].level         = FirstEntryPrice(s);
      g_cy[s].startTime     = OldestEntryTime(s);
      // ordem do topo/fundo atual que voltou sem confirmação: o ciclo fica preso a esse nível
      bool     isTop = (g_cy[s].dir < 0);
      datetime sw    = isTop ? g_topTime : g_botTime;
      if((isTop ? g_hasTop : g_hasBot) && sw > 0 && sw <= g_cy[s].startTime && !IsUsed(isTop, sw))
         g_cy[s].swingTime = sw;
      g_cy[s].entries       = n;
      g_cy[s].hadPositions  = true;
      g_cy[s].prevPositions = n;
      g_cy[s].lastEntryTime = TimeCurrent();
      Print("Ciclo #", g_cy[s].seq, ": ", n, " posições sem ciclo salvo; o robô só vai administrar a saída delas.");
      SaveState();
     }
  }

//+------------------------------------------------------------------+
//| Outros utilitários                                               |
//+------------------------------------------------------------------+
double GetATR()
  {
   double buf[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) != 1)
      return(0.0);
   return(buf[0]);
  }

double NormalizePrice(double price)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick > 0.0)
      price = MathRound(price / tick) * tick;
   return(NormalizeDouble(price, _Digits));
  }

// distância mínima entre o preço e um TP/SL (stops level e freeze level da corretora)
double MinStopDistance()
  {
   long stopsLevel  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return((MathMax(stopsLevel, freezeLevel) + 1) * _Point);
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
   GlobalVariableSet(g_pfx + "saved",  1.0);
   GlobalVariableSet(g_pfx + "dayKey", g_dayKey);
   GlobalVariableSet(g_pfx + "dayEq",  g_dayStartEquity);
   GlobalVariableSet(g_pfx + "cycles", g_cyclesStarted);
   GlobalVariableSet(g_pfx + "seq",    g_cycleSeq);
   for(int i = 0; i < MAX_USED; i++)
     {
      GlobalVariableSet(g_pfx + "uT" + (string)i, (double)g_usedTop[i]);
      GlobalVariableSet(g_pfx + "uB" + (string)i, (double)g_usedBot[i]);
     }
   for(int s = 0; s < MAX_SLOTS; s++)
     {
      string p = g_pfx + "c" + (string)s + "_";
      GlobalVariableSet(p + "on",     g_cy[s].active ? 1.0 : 0.0);
      GlobalVariableSet(p + "seq",    g_cy[s].seq);
      GlobalVariableSet(p + "dir",    g_cy[s].dir);
      GlobalVariableSet(p + "lvl",    g_cy[s].level);
      GlobalVariableSet(p + "atr",    g_cy[s].atr);
      GlobalVariableSet(p + "rng",    g_cy[s].range);
      GlobalVariableSet(p + "swing",  (double)g_cy[s].swingTime);
      GlobalVariableSet(p + "start",  (double)g_cy[s].startTime);
      GlobalVariableSet(p + "ent",    g_cy[s].entries);
      GlobalVariableSet(p + "last",   (double)g_cy[s].lastEntryTime);
      GlobalVariableSet(p + "acc",    g_cy[s].acceptEntries ? 1.0 : 0.0);
      GlobalVariableSet(p + "had",    g_cy[s].hadPositions ? 1.0 : 0.0);
      GlobalVariableSet(p + "trOn",   g_cy[s].trailActive ? 1.0 : 0.0);
      GlobalVariableSet(p + "trBest", g_cy[s].trailBest);
      GlobalVariableSet(p + "trFloor", g_cy[s].trailFloor);
     }
  }

void LoadState()
  {
   if(!GlobalVariableCheck(g_pfx + "saved"))
      return;
   g_dayKey         = (int)GlobalVariableGet(g_pfx + "dayKey");
   g_dayStartEquity = GlobalVariableGet(g_pfx + "dayEq");
   g_cyclesStarted  = (int)GlobalVariableGet(g_pfx + "cycles");
   g_cycleSeq       = (int)GlobalVariableGet(g_pfx + "seq");
   for(int i = 0; i < MAX_USED; i++)
     {
      g_usedTop[i] = (datetime)(long)GlobalVariableGet(g_pfx + "uT" + (string)i);
      g_usedBot[i] = (datetime)(long)GlobalVariableGet(g_pfx + "uB" + (string)i);
     }
   for(int s = 0; s < MAX_SLOTS; s++)
     {
      string p = g_pfx + "c" + (string)s + "_";
      if(GlobalVariableGet(p + "on") < 0.5)
         continue;
      g_cy[s].active        = true;
      g_cy[s].seq           = (int)GlobalVariableGet(p + "seq");
      g_cy[s].dir           = (int)GlobalVariableGet(p + "dir");
      g_cy[s].level         = GlobalVariableGet(p + "lvl");
      g_cy[s].atr           = GlobalVariableGet(p + "atr");
      g_cy[s].range         = GlobalVariableGet(p + "rng");
      g_cy[s].swingTime     = (datetime)(long)GlobalVariableGet(p + "swing");
      g_cy[s].startTime     = (datetime)(long)GlobalVariableGet(p + "start");
      g_cy[s].entries       = (int)GlobalVariableGet(p + "ent");
      g_cy[s].lastEntryTime = (datetime)(long)GlobalVariableGet(p + "last");
      g_cy[s].acceptEntries = GlobalVariableGet(p + "acc") > 0.5;
      g_cy[s].hadPositions  = GlobalVariableGet(p + "had") > 0.5;
      g_cy[s].trailActive   = GlobalVariableGet(p + "trOn") > 0.5;
      g_cy[s].trailBest     = GlobalVariableGet(p + "trBest");
      g_cy[s].trailFloor    = GlobalVariableGet(p + "trFloor");
     }
   for(int s = 0; s < MAX_SLOTS; s++)
      if(g_cy[s].active && g_cy[s].seq > g_cycleSeq)
         g_cycleSeq = g_cy[s].seq;
   for(int s = 0; s < MAX_SLOTS; s++)
      if(g_cy[s].active && g_cy[s].seq <= 0)
         g_cy[s].seq = ++g_cycleSeq;
  }

//+------------------------------------------------------------------+
//| Visual                                                           |
//+------------------------------------------------------------------+
void SetHLine(string name, double price, color clr, ENUM_LINE_STYLE style, string text)
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
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, text);
  }

void Render()
  {
   // no backtest sem visualização não há gráfico: economiza tempo
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))
      return;

   string currency = AccountInfoString(ACCOUNT_CURRENCY);
   string cycles   = "";
   bool   topUsed  = g_hasTop && IsUsed(true,  g_topTime);
   bool   botUsed  = g_hasBot && IsUsed(false, g_botTime);

   if(InpDrawLevels)
     {
      SetHLine(K4_PREFIX + "Top",    g_hasTop ? g_topLevel : 0.0, topUsed ? clrDimGray : clrTomato, STYLE_DASH,
               topUsed ? "Topo relevante (já operado)" : "Topo relevante");
      SetHLine(K4_PREFIX + "Bottom", g_hasBot ? g_botLevel : 0.0, botUsed ? clrDimGray : clrDodgerBlue, STYLE_DASH,
               botUsed ? "Fundo relevante (já operado)" : "Fundo relevante");
     }

   for(int s = 0; s < MAX_SLOTS; s++)
     {
      bool   on   = g_cy[s].active;
      int    n    = on ? CountPositions(s) : 0;
      int    dir  = g_cy[s].dir;
      double avg  = (n > 0) ? BasketAvgPrice(s) : 0.0;
      double tpPx = (n > 0 && !g_cy[s].trailActive) ? ShownTarget(s, n, dir, avg) : 0.0;
      double stop = (n > 0) ? TrailStopPrice(s, dir, avg) : 0.0;
      double tech = (on && !g_cy[s].trailActive) ? TechStopPrice(s) : 0.0;
      string id   = "#" + (string)g_cy[s].seq;

      if(InpDrawLevels)
        {
         string k = (string)(s + 1);
         SetHLine(K4_PREFIX + "Cycle"  + k, on ? g_cy[s].level : 0.0, clrGold,      STYLE_SOLID,   "Ciclo " + id + " nível");
         SetHLine(K4_PREFIX + "Target" + k, tpPx,                    clrLimeGreen, STYLE_DOT,     "Ciclo " + id + " alvo");
         SetHLine(K4_PREFIX + "Trail"  + k, stop,                    clrOrange,    STYLE_DASHDOT, "Ciclo " + id + " trailing");
         SetHLine(K4_PREFIX + "Stop"   + k, tech,                    clrRed,       STYLE_DOT,     "Ciclo " + id + " stop técnico");
        }
      if(!on)
         continue;

      string note = "";
      if(g_cy[s].trailActive)
         note = " (trailing: não abre mais ordens)";
      else if(!g_cy[s].acceptEntries)
         note = " (não abre mais ordens)";
      string line = StringFormat("Ciclo %s: %s no %s %.2f | entradas %d/%d%s", id,
                                 dir > 0 ? "COMPRA" : "VENDA", dir > 0 ? "fundo" : "topo", g_cy[s].level,
                                 g_cy[s].entries, InpEntriesPerCycle, note);
      if(n > 0)
        {
         line += StringFormat("\n   %d posições | médio %.2f | lucro %.2f %s", n, avg, BasketProfit(s), currency);
         if(g_cy[s].trailActive)
            line += StringFormat(" | trailing: melhor %.2f, stop %.2f", g_cy[s].trailBest, stop);
         else
            line += StringFormat(" | alvo %s | stop técnico %s",
                                 tpPx > 0.0 ? DoubleToString(tpPx, _Digits) : "-",
                                 tech > 0.0 ? DoubleToString(tech, _Digits) : "-");
        }
      cycles += line + "\n";
     }
   if(cycles == "")
      cycles = "Nenhum ciclo aberto (aguardando recusa em topo/fundo relevante)\n";

   //--- descrição do alvo e do trailing configurados
   double perOrder = MoneyPerPriceUnit(NormalizeLot(InpLot));
   string moneyTxt = StringFormat("%.2f %s", InpBasketTPMoney, currency);
   if(perOrder > 0.0)
      moneyTxt += StringFormat(" (≈ US$ %.2f de movimento com 1 ordem)", InpBasketTPMoney / perOrder);
   string target;
   if(InpTPMode == TP_MONEY)
      target = moneyTxt + " em dinheiro";
   else if(InpTPMode == TP_RANGE)
      target = StringFormat("%.0f%% da distância topo-fundo", InpTPRangePct);
   else if(InpTPMode == TP_FIRST)
      target = StringFormat("%.0f%% topo-fundo ou %s", InpTPRangePct, moneyTxt);
   else
      target = StringFormat("US$ %.2f a favor do preço médio", InpTPPriceDist);

   string entry;
   if(InpEntryMode == ENTRY_REJECTION)
      entry = StringFormat("%d por recusa no nível", InpOrdersPerRejection);
   else
      entry = StringFormat("%s a cada US$ %.2f", InpEntryMode == ENTRY_PYRAMID ? "pirâmide (a favor)" : "preço médio (contra)",
                           InpStepPrice);

   string trail;
   if(InpTrailMode == TRAIL_OFF)
      trail = "desligado";
   else if(InpTrailMode == TRAIL_AT_TP)
      trail = StringFormat("ao atingir o alvo, recuo US$ %.2f, garante %.0f%%", InpTrailDistPrice, InpTrailLockPct);
   else
      trail = StringFormat("a partir de US$ %.2f (ou no alvo), recuo US$ %.2f, garante %.0f%%", InpTrailStartPrice,
                           InpTrailDistPrice, InpTrailLockPct);

   string limit = (InpMaxCycles > 0)
                  ? StringFormat("%d/%d %s", g_cyclesStarted, InpMaxCycles,
                                 InpCycleLimitScope == LIMIT_PER_DAY ? "hoje" : "no total")
                  : StringFormat("%d (sem limite)", g_cyclesStarted);
   string status = (OpenCycles() == 0 && CycleLimitReached()) ? "PARADO: limite de ciclos atingido" : g_status;

   Comment(StringFormat("K4 Rejection Cycles | %s\n"
                        "Topo relevante: %s | Fundo relevante: %s | ATR: %.2f\n"
                        "Ciclos iniciados: %s | abertos: %d/%d | entradas: %s\n"
                        "%s"
                        "Alvo: %s\n"
                        "Trailing: %s\n"
                        "US$ 1 no ouro com %.2f lote = %.2f %s\n"
                        "Resultado do dia: %.2f %s\n"
                        "Saídas: alvo %d | trailing %d | tempo %d | stop técnico %d | stop cesta %d | proteção %d | outros %d\n"
                        "Último evento: %s",
                        _Symbol,
                        g_hasTop ? DoubleToString(g_topLevel, _Digits) + (topUsed ? " (já operado)" : "") : "-",
                        g_hasBot ? DoubleToString(g_botLevel, _Digits) + (botUsed ? " (já operado)" : "") : "-",
                        g_atr, limit, OpenCycles(), g_maxOpen, entry,
                        cycles, target, trail,
                        NormalizeLot(InpLot), perOrder, currency,
                        AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartEquity, currency,
                        g_exitCount[EXIT_TARGET], g_exitCount[EXIT_TRAIL], g_exitCount[EXIT_TIME],
                        g_exitCount[EXIT_LEVEL], g_exitCount[EXIT_BASKET], g_exitCount[EXIT_GUARD],
                        g_exitCount[EXIT_OTHER], status));
  }

// alvo mostrado no gráfico: o TP real (se houver) ou o alvo virtual em preço
double ShownTarget(int s, int n, int dir, double avg)
  {
   double tp = ServerTargetPrice(s, n, dir, avg);
   if(tp > 0.0)
      return(tp);
   double v = TargetPrice(s, dir, avg);
   return(v > 0.0 ? v : (UsesMoneyTarget(v) ? MoneyTargetPrice(s, n, dir, avg) : 0.0));
  }
//+------------------------------------------------------------------+
