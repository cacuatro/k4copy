#property copyright "k4trader | Uso gratuito. Venda proibida."
#property version "3.17"
#property strict
#property link "https://copytrader-monitor.onrender.com/"
#property description "K4 XAUUSD Multi | k4trader"
#property description "Variante com multiplas ordens e grade (conta cent)."
#property description "GRATUITO. Venda e revenda proibidas."
#property description "Desenvolvido para a corretora RoboForex."
#property description "Contato: @copytraderk4"
#property description "Estrategias, resultados e copys: abra o link desta pagina."
#include <Trade/Trade.mqh>
#include "H4M30_Core.mqh"
#include "H4M30_Dashboard.mqh"
#include "H4M30_PanelData.mqh"
#include "H4M30_Exposure.mqh"
#include "K4_License.mqh"
#include "K4_Volume.mqh"
#include "K4_MonitorBridge.mqh"

enum EServerClock { SERVER_EU_UTC2_UTC3=0, SERVER_FIXED_OFFSET=1 };
enum EGridStop {
   GRID_STOP_AFTER_LAST=0, // Apos o ultimo nivel da grade
   GRID_STOP_STRUCTURE=1   // Stop estrutural original (M30)
};
input group "K4 XAUUSD | gratuito | k4trader"
input double InpLots=0.01;                    // Lote fixo por operacao; respeita os limites da corretora
input ulong InpMagic=430301001;
input int InpDeviationPoints=20;              // Desvio solicitado; execucao depende da corretora
input group "Relogio do servidor e horario de operacao"
input EServerClock InpServerClock=SERVER_EU_UTC2_UTC3;
input int InpFixedOffsetMinutes=180;           // Usado somente em SERVER_FIXED_OFFSET
input int InpEntryStartUTC=10;                 // 00:10 UTC, minutos apos meia-noite
input int InpEntryEndUTC=1200;                 // 20:00 UTC exclusivo; nao liquida posicoes
input int InpWarmupDays=90;                    // Historico fechado antes de iniciar

input group "Mais operacoes e grade (conta hedging)"
input int InpMaxTrades=2;                      // Operacoes de sinal simultaneas (1 = original)
input bool InpUseTrendFilter=true;             // Filtro de tendencia EMA (false = mais sinais)
input bool InpGridEnable=true;                 // Abrir ordens extras quando o preco vai contra
input int InpGridMaxOrders=4;                  // Maximo de ordens por cesta, incluindo a do sinal
input double InpGridStepATR=1.0;               // Distancia entre ordens em ATR H1 (0 = so pontos)
input int InpGridStepPoints=500;               // Distancia minima entre ordens, em pontos
input double InpGridStepExpansion=1.2;         // Cada nova distancia e multiplicada por este fator
input double InpGridLotMultiplier=1.0;         // Multiplicador de lote (1.0 = sem martingale)
input double InpGridMaxLot=0.05;               // Lote maximo de uma ordem da grade
input int InpGridTargetPoints=300;             // Alvo da cesta alem do preco medio, em pontos
input EGridStop InpGridStop=GRID_STOP_AFTER_LAST; // Posicao do stop da cesta
input double InpGridStopAfterSteps=1.0;        // Stop apos o ultimo nivel, em distancias da grade
input double InpGridMaxRiskPct=20.0;           // Perda maxima somando os stops (% do saldo)

input group "Painel no grafico"
input bool InpShowPanel=true;
input int InpPanelScalePercent=100;          // 60 a 150; ajustado para caber no grafico
input int InpPanelX=18;
input int InpPanelY=28;

CK4License license;
CK4MonitorPresence monitor_presence;
CH4M30Core core;
CH4M30Dashboard dashboard;
CH4M30PanelStats panel_stats;
CTrade trade;
bool ready=false,tester=false,clock_error=false,entries_armed=false;
long live_bucket=-1,last_tick_msc=-1;
SBar live_bar;
string state_prefix;
ulong pending_position=0;
double pending_tp=0;
int atr_handle=INVALID_HANDLE;
double grid_atr=0;
long grid_block_bucket[2]={-1,-1};
long grid_sync_msc[2]={0,0};
string grid_notice_text[2];
long grid_notice_time[2]={0,0};

#include "K4_WebPermission.mqh"
#include "K4_IntegratedMonitor.mqh"
#include "K4_DllBridge.mqh"
#include "K4_AutoApply.mqh"
#define K4_FILE_READ_API_IMPORTED
#include "K4_RobotFiles.mqh"
CK4RobotFiles private_files;
bool K4PrivateFilesPoll() {
 return private_files.Poll(K4RemoteAccessToken,K4RemoteExpectedAccount,K4RemoteExpectedServer,
                          pending_position==0&&OwnPosition()==0&&!auto_apply.Paused(),web_permission.Allowed(false));
}

long UTCSeconds(const long server_time) {
   return server_time-ServerOffsetSeconds(server_time,InpServerClock==SERVER_EU_UTC2_UTC3,InpFixedOffsetMinutes);
}
long UTCMillis(const long server_msc) { return UTCSeconds(server_msc/1000)*1000+server_msc%1000; }
string UsedKey(const long stamp,const int kind) { return state_prefix+(string)stamp+"_"+(string)kind; }
void RestoreConsumed() {
   if(tester) return;
   for(int i=0;i<ArraySize(core.levels);i++)
      if(GlobalVariableCheck(UsedKey(core.levels[i].time,core.levels[i].kind))) core.levels[i].used=true;
}
// Distribution build: operational audit messages are intentionally suppressed.
void Audit(const string event,const string detail) {}
bool Successful() {
   uint code=trade.ResultRetcode();
   return code==TRADE_RETCODE_DONE || code==TRADE_RETCODE_DONE_PARTIAL;
}
EH4M30Exposure EntryExposure() {
   return H4M30EntryExposure(_Symbol,InpMagic,AccountInfoInteger(ACCOUNT_MARGIN_MODE));
}
ulong OwnPosition() {
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionGetString(POSITION_SYMBOL)==_Symbol && (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic)
         return ticket;
   }
   return 0;
}
bool ValidProtection(const int direction,const double sl,const double tp,const MqlTick &tick,const bool modification) {
   long stops=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   if(modification) stops=MathMax(stops,SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL));
   double minimum=MathMax(0.01,(double)stops*_Point);
   double quote=(direction==1 ? tick.bid : tick.ask);
   return sl>0 && tp>0 && direction*(quote-sl)>=minimum-1e-8 && direction*(tp-quote)>=minimum-1e-8;
}
// Same broker distances as ValidProtection, but a basket whose stop was removed by hand keeps it removed.
bool ValidLevels(const int direction,const double sl,const double tp,const MqlTick &tick,const bool modification) {
   if(sl>0) return ValidProtection(direction,sl,tp,tick,modification);
   long stops=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   if(modification) stops=MathMax(stops,SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL));
   double minimum=MathMax(0.01,(double)stops*_Point);
   double quote=(direction==1 ? tick.bid : tick.ask);
   return tp>0 && direction*(tp-quote)>=minimum-1e-8;
}

// ---- Multiple trades and grid ----
// A basket is every own position in one direction. All of its state is read back from the
// positions themselves, so a terminal restart or EA reload resumes the same management.
struct SBasket {
   int count;
   double volume;
   double weighted;   // sum(open price * volume)
   double worst;      // lowest buy / highest sell entry
   double sl;         // stop of the oldest position, shared by the basket
   long oldest_msc;
};
bool MultiMode() { return InpMaxTrades>1 || InpGridEnable; }
bool SelectedIsOwn(const ulong ticket) {
   return ticket>0 && PositionGetString(POSITION_SYMBOL)==_Symbol && (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic;
}
int SelectedDirection() { return PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1; }
int CountOwn(const int direction) {
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong ticket=PositionGetTicket(i);
      if(SelectedIsOwn(ticket) && (direction==0 || SelectedDirection()==direction)) n++;
   }
   return n;
}
int BasketTickets(const int direction,ulong &tickets[]) {
   int n=0;
   ArrayResize(tickets,0);
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong ticket=PositionGetTicket(i);
      if(!SelectedIsOwn(ticket) || SelectedDirection()!=direction) continue;
      ArrayResize(tickets,n+1); tickets[n++]=ticket;
   }
   return n;
}
bool ReadBasket(const int direction,SBasket &b) {
   b.count=0; b.volume=0; b.weighted=0; b.worst=0; b.sl=0; b.oldest_msc=LONG_MAX;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong ticket=PositionGetTicket(i);
      if(!SelectedIsOwn(ticket) || SelectedDirection()!=direction) continue;
      double entry=PositionGetDouble(POSITION_PRICE_OPEN),volume=PositionGetDouble(POSITION_VOLUME);
      long opened=PositionGetInteger(POSITION_TIME_MSC);
      if(b.count==0 || direction*(entry-b.worst)<0) b.worst=entry;
      if(opened<b.oldest_msc) { b.oldest_msc=opened; b.sl=PositionGetDouble(POSITION_SL); }
      b.count++; b.volume+=volume; b.weighted+=entry*volume;
   }
   return b.count>0 && b.volume>0;
}
// Without grid: up to InpMaxTrades independent trades. With grid: one basket per direction.
bool EntryAllowed(const int direction) {
   if(!MultiMode()) return EntryExposure()==H4M30_EXPOSURE_NONE;
   if(pending_position!=0) return false;
   if(!InpGridEnable) return CountOwn(0)<InpMaxTrades;
   int buys=CountOwn(1),sells=CountOwn(-1);
   if((direction==1 ? buys : sells)>0) return false;
   return (buys>0 ? 1 : 0)+(sells>0 ? 1 : 0)<MathMin(InpMaxTrades,2);
}
// The position opened by the last trade request; falls back to the single own position.
ulong OpenedPosition() {
   ulong deal=trade.ResultDeal(),order=trade.ResultOrder();
   if(deal>0 && HistoryDealSelect(deal)) {
      ulong id=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
      if(id>0 && H4M30SelectOwnPosition(id,_Symbol,InpMagic)) return id;
   }
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong ticket=PositionGetTicket(i);
      if(SelectedIsOwn(ticket) && (ulong)PositionGetInteger(POSITION_IDENTIFIER)==order) return ticket;
   }
   return CountOwn(0)==1 ? OwnPosition() : 0;
}
void GridNotice(const int direction,const string text) {
   int side=(direction==1 ? 0 : 1);
   long now=(long)TimeCurrent();
   if(text==grid_notice_text[side] && now-grid_notice_time[side]<3600) return;
   grid_notice_text[side]=text; grid_notice_time[side]=now;
   Print("K4 Multi | ",(direction==1 ? "compra" : "venda")," | ",text);
}
void UpdateGridATR() {
   if(atr_handle==INVALID_HANDLE) return;
   double value[];
   if(CopyBuffer(atr_handle,0,1,1,value)==1 && value[0]>0) grid_atr=value[0];
}
double GridBaseStep() {
   if(InpGridStepATR>0 && grid_atr<=0) return 0; // Wait for the ATR instead of silently using a narrower grid.
   return MathMax(InpGridStepPoints*_Point,InpGridStepATR*grid_atr);
}
// Distance from the worst entry to the next order when the basket already holds `count` orders.
double GridStep(const int count) { return GridBaseStep()*MathPow(InpGridStepExpansion,count-1); }
int VolumeDigits() {
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   int digits=0;
   while(digits<8 && MathAbs(step*MathPow(10,digits)-MathRound(step*MathPow(10,digits)))>1e-8) digits++;
   return digits;
}
// Lot of grid level `level` (0 = signal order).
double GridLot(const int level) {
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double maximum=MathMin(InpGridMaxLot,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX));
   double lots=MathMin(InpLots*MathPow(InpGridLotMultiplier,level),maximum);
   if(step>0) {
      lots=MathFloor(lots/step+0.5)*step;
      if(lots>maximum+1e-8) lots-=step;
   }
   lots=MathMax(lots,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN));
   return NormalizeDouble(lots,VolumeDigits());
}
bool LossTo(const int direction,const double lots,const double entry,const double stop,double &loss) {
   double profit=0;
   if(!OrderCalcProfit(direction==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,lots,entry,stop,profit)) return false;
   loss=MathMax(0.0,-profit);
   return true;
}
// Loss if every own position closes at its stop. False when some position has no stop (unbounded).
bool OpenWorstLoss(double &loss) {
   bool bounded=true;
   loss=0;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong ticket=PositionGetTicket(i);
      if(!SelectedIsOwn(ticket)) continue;
      double sl=PositionGetDouble(POSITION_SL),one=0;
      if(sl<=0 || !LossTo(SelectedDirection(),PositionGetDouble(POSITION_VOLUME),PositionGetDouble(POSITION_PRICE_OPEN),sl,one)) {
         bounded=false; continue;
      }
      loss+=one;
   }
   return bounded;
}
double RiskBudget() { return AccountInfoDouble(ACCOUNT_BALANCE)*InpGridMaxRiskPct/100.0; }
// Stop one InpGridStopAfterSteps distance beyond the last planned level (never tighter than the
// structural stop) and the loss of the full basket at that stop.
bool PlanGridStop(const int direction,const double price,const double structural_sl,double &stop,double &loss) {
   double base=GridBaseStep();
   if(base<=0 || price<=0) return false;
   double levels[];
   ArrayResize(levels,InpGridMaxOrders);
   double level=price;
   for(int k=0;k<InpGridMaxOrders;k++) {
      if(k>0) level-=direction*base*MathPow(InpGridStepExpansion,k-1);
      levels[k]=level;
   }
   stop=level-direction*InpGridStopAfterSteps*base*MathPow(InpGridStepExpansion,InpGridMaxOrders-1);
   if(structural_sl>0 && direction*(structural_sl-stop)<0) stop=structural_sl;
   stop=NormalizeDouble(stop,_Digits);
   if(stop<=0) return false;
   loss=0;
   for(int k=0;k<InpGridMaxOrders;k++) {
      double one=0;
      if(direction*(levels[k]-stop)<=0) break;
      if(!LossTo(direction,GridLot(k),levels[k],stop,one)) return false;
      loss+=one;
   }
   return true;
}
void CloseBasket(const int direction) {
   ulong tickets[];
   int n=BasketTickets(direction,tickets);
   for(int i=0;i<n;i++) trade.PositionClose(tickets[i],InpDeviationPoints);
}
// Every order of a basket with 2+ orders shares the oldest order's stop and a target past the
// average price. Returns true only when the basket is already in sync.
bool SyncBasket(const int direction,const SBasket &b,const MqlTick &tick,const long now) {
   int side=(direction==1 ? 0 : 1);
   double target=NormalizeDouble(b.weighted/b.volume+direction*InpGridTargetPoints*_Point,_Digits);
   double quote=(direction==1 ? tick.bid : tick.ask);
   if(direction*(quote-target)>=0 || (b.sl>0 && direction*(quote-b.sl)<=0)) {
      if(now-grid_sync_msc[side]>=1000) { grid_sync_msc[side]=now; CloseBasket(direction); }
      return false;
   }
   ulong tickets[];
   int n=BasketTickets(direction,tickets),pending=0;
   double stops[];
   ArrayResize(stops,n);
   for(int i=0;i<n;i++) {
      if(!H4M30SelectOwnPosition(tickets[i],_Symbol,InpMagic)) { tickets[i]=0; continue; }
      double sl=PositionGetDouble(POSITION_SL);
      stops[i]=(b.sl>0 ? b.sl : sl);
      if(MathAbs(PositionGetDouble(POSITION_TP)-target)<0.005 && MathAbs(sl-stops[i])<0.005) tickets[i]=0;
      else pending++;
   }
   if(pending==0) return true;
   if(now-grid_sync_msc[side]<1000) return false;
   grid_sync_msc[side]=now;
   for(int i=0;i<n;i++)
      if(tickets[i]>0 && ValidLevels(direction,stops[i],target,tick,true)) trade.PositionModify(tickets[i],stops[i],target);
   return false;
}
void TryGridAdd(const int direction,const SBasket &b,const MqlTick &tick,const long now) {
   int side=(direction==1 ? 0 : 1);
   if(!entries_armed || pending_position!=0 || b.count>=InpGridMaxOrders || grid_block_bucket[side]==live_bucket) return;
   int minute=(int)((now/1000%86400)/60);
   if(minute<InpEntryStartUTC || minute>=InpEntryEndUTC) return;
   double step=GridStep(b.count);
   double quote=(direction==1 ? tick.ask : tick.bid);
   if(step<=0 || direction*(b.worst-quote)<step-1e-8) return;
   if(b.sl<=0) { GridNotice(direction,"Cesta sem stop; nova ordem da grade bloqueada"); grid_block_bucket[side]=live_bucket; return; }
   if(direction*(quote-b.sl)<0.5*step) return; // Too close to the basket stop: the grid is complete.
   if(!license.CanOpen(K4LicenseNow()) || !web_permission.Allowed(tester) || (!tester && auto_apply.Paused())) return;
   double lots=GridLot(b.count),open_loss=0,add_loss=0,margin=0;
   if(!OpenWorstLoss(open_loss) || !LossTo(direction,lots,quote,b.sl,add_loss)) {
      GridNotice(direction,"Risco nao calculavel (ordem deste robo sem stop?); grade bloqueada");
      grid_block_bucket[side]=live_bucket; return;
   }
   if(open_loss+add_loss>RiskBudget()) {
      GridNotice(direction,StringFormat("Risco %.2f acima do limite %.2f; grade parada no nivel %d",open_loss+add_loss,RiskBudget(),b.count));
      grid_block_bucket[side]=live_bucket; return;
   }
   if(!OrderCalcMargin(direction==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,lots,quote,margin) || margin>=AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
      GridNotice(direction,"Margem livre insuficiente para a proxima ordem da grade");
      grid_block_bucket[side]=live_bucket; return;
   }
   MqlTick execution_tick=tick;
   if(!tester) {
      if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) return;
      if(!K4CheckWebPermission()) { grid_block_bucket[side]=live_bucket; return; } // Same rule as entries: no cached permission.
      if(!SymbolInfoTick(_Symbol,execution_tick) || execution_tick.bid<=0 || execution_tick.ask<execution_tick.bid) return;
      quote=(direction==1 ? execution_tick.ask : execution_tick.bid);
      if(direction*(b.worst-quote)<step-1e-8 || direction*(quote-b.sl)<0.5*step) return;
   }
   double target=NormalizeDouble((b.weighted+lots*quote)/(b.volume+lots)+direction*InpGridTargetPoints*_Point,_Digits);
   if(!ValidProtection(direction,b.sl,target,execution_tick,false)) { grid_block_bucket[side]=live_bucket; return; }
   string comment=StringFormat("k4trader g%d",b.count+1);
   bool sent=(direction==1 ? trade.Buy(lots,_Symbol,0,b.sl,target,comment)
                           : trade.Sell(lots,_Symbol,0,b.sl,target,comment));
   if(!sent || !Successful()) {
      GridNotice(direction,"Ordem da grade rejeitada: "+trade.ResultRetcodeDescription());
      grid_block_bucket[side]=live_bucket; return;
   }
   Audit("GRID",StringFormat("dir=%d; nivel=%d; lote=%.2f; SL=%.2f; alvo=%.2f",direction,b.count+1,lots,b.sl,target));
   SBasket updated;
   MqlTick after;
   grid_sync_msc[side]=0;
   if(ReadBasket(direction,updated) && updated.count>1 && SymbolInfoTick(_Symbol,after) && after.bid>0 && after.ask>=after.bid)
      SyncBasket(direction,updated,after,now);
}
void ManageBaskets(const MqlTick &tick,const long now) {
   if(!InpGridEnable) return;
   for(int side=0;side<2;side++) {
      int direction=(side==0 ? 1 : -1);
      SBasket b;
      if(!ReadBasket(direction,b)) continue;
      if(b.count>1 && !SyncBasket(direction,b,tick,now)) continue;
      TryGridAdd(direction,b,tick,now);
   }
}

bool Warmup(const MqlTick &tick) {
   long now=UTCMillis(tick.time_msc),bucket=now/300000*300;
   MqlRates rates[]; ArraySetAsSeries(rates,false);
   int n=CopyRates(_Symbol,PERIOD_M5,(datetime)(tick.time-InpWarmupDays*86400),(datetime)(tick.time-1),rates);
   if(n<1000) return false; // May be loading history; retry on a later tick.
   core.Reset();
   long first_utc=UTCSeconds((long)rates[0].time);
   long first_full_h4=(first_utc+14399)/14400*14400;
   for(int i=0;i<n;i++) {
      SBar b; b.time=UTCSeconds((long)rates[i].time);
      if(b.time<first_full_h4 || b.time+300>bucket || rates[i].tick_volume<=0) continue;
      b.open=rates[i].open; b.high=rates[i].high; b.low=rates[i].low; b.close=rates[i].close;
      if(!core.FeedClosed(b)) { Audit("ERROR","Historico M5 fora de ordem apos converter UTC"); return false; }
   }
   core.Advance(bucket);
   if(core.h4.count<150 || core.m30.count<125) return false;
   RestoreConsumed();
   live_bucket=bucket; live_bar.time=bucket;
   live_bar.open=tick.bid; live_bar.high=tick.bid; live_bar.low=tick.bid; live_bar.close=tick.bid;
   // On a mid-bar attachment, observe its full known prefix, then wait for next M5 to enter.
   MqlRates current[];
   if(CopyRates(_Symbol,PERIOD_M5,0,1,current)==1 && UTCSeconds((long)current[0].time)==bucket) {
      live_bar.open=current[0].open; live_bar.high=MathMax(current[0].high,tick.bid);
      live_bar.low=MathMin(current[0].low,tick.bid);
   }
   core.Invalidate(live_bar.high,live_bar.low,now/1000);
   Audit("READY",StringFormat("H4 UTC=%I64d; M30=%I64d; lote=%.2f; TP=3R; primeira entrada a partir do proximo M5",core.h4.count,core.m30.count,InpLots));
   return true;
}
// Clear only this account/symbol/magic's persisted reconciliation state.
void ClearPendingTarget() {
   pending_position=0;
   pending_tp=0;
   if(!tester) {
      GlobalVariableDel(state_prefix+"tp_ticket");
      GlobalVariableDel(state_prefix+"tp_value");
      GlobalVariablesFlush();
   }
}
bool PendingTargetApplied() {
   // OnInit accepts a 0.01 tick only. Half a tick absorbs floating point noise
   // without considering a one-tick target discrepancy already resolved.
   return pending_tp>0 && MathAbs(PositionGetDouble(POSITION_TP)-pending_tp)<0.005;
}
bool ReconcileTarget(const MqlTick &tick) {
   if(pending_position==0) return true;
   if(!H4M30SelectOwnPosition(pending_position,_Symbol,InpMagic)) {
      ClearPendingTarget();
      return true;
   }
   double sl=PositionGetDouble(POSITION_SL);
   int direction=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1);
   double quote=(direction==1 ? tick.bid : tick.ask);
   if(direction*(quote-pending_tp)>=0) {
      bool sent=trade.PositionClose(pending_position,InpDeviationPoints);
      if(sent && Successful()) {
         Audit("TP_FILL_RECONCILE","Alvo 3R do fill ja atingido; posicao encerrada");
         ClearPendingTarget();
         return true;
      }
      return false;
   }
   // A previously applied TP must not be resent or rejected by current freeze
   // distances. This also recovers persisted state after a terminal restart.
   if(PendingTargetApplied()) {
      ClearPendingTarget();
      return true;
   }
   if(!ValidProtection(direction,sl,pending_tp,tick,true)) return false;
   if(trade.PositionModify(pending_position,sl,pending_tp) && Successful()) {
      Audit("TP_FILL_RECONCILE",StringFormat("TP ajustado ao fill: %.2f",pending_tp));
      ClearPendingTarget();
      return true;
   }
   // NO_CHANGES/timeout alone is not proof of success. Refresh the exact owned
   // ticket and accept only its actual TP (or that it is no longer owned/open).
   if(!H4M30SelectOwnPosition(pending_position,_Symbol,InpMagic) || PendingTargetApplied()) {
      ClearPendingTarget();
      return true;
   }
   return false;
}
// Trails every independent trade; a grid basket with 2+ orders exits on its shared target/stop.
void TrailPositions(const MqlTick &tick) {
   ulong tickets[];
   int n=0,buys=0,sells=0;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong ticket=PositionGetTicket(i);
      if(!SelectedIsOwn(ticket)) continue;
      if(SelectedDirection()==1) buys++; else sells++;
      ArrayResize(tickets,n+1); tickets[n++]=ticket;
   }
   for(int i=0;i<n;i++) {
      if(!H4M30SelectOwnPosition(tickets[i],_Symbol,InpMagic)) continue;
      int direction=SelectedDirection();
      if(InpGridEnable && (direction==1 ? buys : sells)>1) continue;
      TrailTicket(tickets[i],direction,tick);
   }
}
void TrailTicket(const ulong ticket,const int direction,const MqlTick &tick) {
   double old_sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP),entry=PositionGetDouble(POSITION_PRICE_OPEN);
   long entry_msc=UTCMillis(PositionGetInteger(POSITION_TIME_MSC));
   double sl=core.Trail(entry_msc,direction,old_sl,tick.bid,tick.ask);
   if(MathAbs(sl-old_sl)<0.009 || !ValidProtection(direction,sl,tp,tick,true)) return;
   // The wide grid stop is only tightened once it locks the entry; an earlier pull would cancel the grid.
   if(InpGridEnable && InpGridStop==GRID_STOP_AFTER_LAST && direction*(sl-entry)<0) return;
   if(trade.PositionModify(ticket,sl,tp) && Successful())
      Audit("TRAIL",StringFormat("ticket=%I64u; SL %.2f -> %.2f; TP fixo %.2f",ticket,old_sl,sl,tp));
   else Audit("TRAIL_REJECT",trade.ResultRetcodeDescription());
}
// A permission check is synchronous; re-read the quote and keep the original setup boundaries.
bool K4FreshEntryQuote(const SSignal &signal,const MqlTick &before,MqlTick &fresh) {
   if(!SymbolInfoTick(_Symbol,fresh) || fresh.bid<=0 || fresh.ask<fresh.bid || fresh.time_msc<before.time_msc) return false;
   long now=UTCMillis(fresh.time_msc);
   if(now/300000!=UTCMillis(before.time_msc)/300000) return false;
   int minute=(int)((now/1000%86400)/60);
   if(minute<InpEntryStartUTC || minute>=InpEntryEndUTC) return false;
   core.Invalidate(fresh.bid,fresh.bid,now/1000);
   for(int i=0;i<ArraySize(core.levels);i++) {
      SPivot p=core.levels[i];
      if(p.time!=signal.pivot_time || p.kind!=signal.direction || p.price!=signal.level) continue;
      if(!p.intact || p.confirmed>now/1000) return false;
      double near=0.05*p.atr,quote=(p.kind==1 ? fresh.ask : fresh.bid);
      return p.kind==1 ? quote>=p.price-near && quote<=p.price && core.m5.close<p.price-near
                       : quote<=p.price+near && quote>=p.price && core.m5.close>p.price+near;
   }
   return false;
}
int CheckActivationWebRequest() {
   if(tester) return INIT_SUCCEEDED;
   bool permitted=K4CheckWebPermission();
   return permitted || OwnPosition()!=0 ? INIT_SUCCEEDED : INIT_FAILED;
}
void Enter(const SSignal &signal,const MqlTick &tick) {
   if(!tester && auto_apply.Paused()) return;
   license.Observe(K4LicenseNow(),tester);
   if(!license.CanOpen(K4LicenseNow())) return;
   if(InpUseTrendFilter && !signal.trend_ok) { Audit("FILTER_EMA",(string)signal.pivot_time); return; }
   if(!EntryAllowed(signal.direction)) { Audit("BUSY",(string)signal.pivot_time); return; }
   if(!tester && (!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))) {
      Audit("TRADE_DISABLED","Oportunidade consumida; negociacao automatica desabilitada"); return;
   }
   MqlTick execution_tick=tick;
   if(!tester) {
      long checked_login=AccountInfoInteger(ACCOUNT_LOGIN);
      string checked_server=AccountInfoString(ACCOUNT_SERVER);
      if(!K4CheckWebPermission()) return; // No cached permission is accepted for a new order.
      if(AccountInfoInteger(ACCOUNT_LOGIN)!=checked_login || AccountInfoString(ACCOUNT_SERVER)!=checked_server) return;
      if(!K4FreshEntryQuote(signal,tick,execution_tick)) return;
      license.Observe(K4LicenseNow(),tester);
      if(!license.CanOpen(K4LicenseNow()) || !EntryAllowed(signal.direction)) return;
      if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) return;
   }
   double sl=signal.sl;
   bool wide_stop=false;
   if(InpGridEnable && InpGridStop==GRID_STOP_AFTER_LAST) {
      double planned=0,plan_loss=0,open_loss=0;
      bool bounded=OpenWorstLoss(open_loss);
      if(!PlanGridStop(signal.direction,signal.direction==1 ? execution_tick.ask : execution_tick.bid,signal.sl,planned,plan_loss))
         GridNotice(signal.direction,"ATR da grade indisponivel; entrada com o stop original");
      else if(!bounded || open_loss+plan_loss>RiskBudget())
         GridNotice(signal.direction,StringFormat("Risco da grade %.2f acima do limite %.2f; entrada com o stop original",open_loss+plan_loss,RiskBudget()));
      else { sl=planned; wide_stop=MathAbs(planned-signal.sl)>0.009; }
   }
   if(!ValidProtection(signal.direction,sl,signal.tp,execution_tick,false)) {
      Audit("INVALID_STOPS","Oportunidade ignorada; sem ampliar SL nem alterar lote para atender corretora"); return;
   }
   string comment="k4trader";
   bool sent=(signal.direction==1 ? trade.Buy(InpLots,_Symbol,0,sl,signal.tp,comment)
                                 : trade.Sell(InpLots,_Symbol,0,sl,signal.tp,comment));
   if(!sent || !Successful()) { Audit("ORDER_REJECT",trade.ResultRetcodeDescription()); return; }
   ulong ticket=OpenedPosition();
   if(ticket==0 || !PositionSelectByTicket(ticket)) { Audit("FILL","Execucao sem posicao aberta restante"); return; }
   double fill=PositionGetDouble(POSITION_PRICE_OPEN);
   double actual_sl=PositionGetDouble(POSITION_SL);
   // 3R stays anchored to the structural stop even when the order carries the wider grid stop.
   double tp=Target3R(fill,wide_stop ? signal.sl : actual_sl,signal.direction);
   Audit("ENTRY",StringFormat("ticket=%I64u; dir=%d; lote=%.2f; fill=%.2f; SL=%.2f; TP3R=%.2f; H4=%I64d; SL_M30=%I64d",
         ticket,signal.direction,PositionGetDouble(POSITION_VOLUME),fill,actual_sl,tp,signal.pivot_time,signal.stop_pivot_time));
   if(MathAbs(PositionGetDouble(POSITION_TP)-tp)>0.009) {
      pending_position=ticket; pending_tp=tp;
      if(!tester) { GlobalVariableSet(state_prefix+"tp_ticket",(double)ticket); GlobalVariableSet(state_prefix+"tp_value",tp); GlobalVariablesFlush(); }
      ReconcileTarget(execution_tick);
   }
}
int CheckActivationLicense() {
   license.Observe(K4LicenseNow(),tester);
   if(license.Expired() && OwnPosition()==0) return INIT_FAILED;
   return INIT_SUCCEEDED;
}
int OnInit() {
   tester=(bool)MQLInfoInteger(MQL_TESTER);
   if(CheckActivationLicense()!=INIT_SUCCEEDED) return INIT_FAILED;
   if(InpPanelScalePercent<60 || InpPanelScalePercent>150 || InpPanelX<0 || InpPanelY<0) return INIT_PARAMETERS_INCORRECT;
   if(StringFind(_Symbol,"XAUUSD")!=0 ||
      MathAbs(SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE)-100.0)>1e-8 ||
      MathAbs(SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE)-0.01)>1e-8 ||
      !K4ValidVolume(InpLots,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)) ||
      InpWarmupDays<60 || InpWarmupDays>730 || InpEntryStartUTC<0 || InpEntryEndUTC>1440 ||
      InpEntryStartUTC>=InpEntryEndUTC || InpFixedOffsetMinutes< -720 || InpFixedOffsetMinutes>840 || InpDeviationPoints<0) {
      Print("Parametros invalidos. Confira o volume, o simbolo e o relogio do servidor.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpMaxTrades<1 || InpMaxTrades>10) { Print("InpMaxTrades deve ficar entre 1 e 10."); return INIT_PARAMETERS_INCORRECT; }
   if(InpGridEnable) {
      if(InpGridMaxOrders<2 || InpGridMaxOrders>20) { Print("InpGridMaxOrders deve ficar entre 2 e 20."); return INIT_PARAMETERS_INCORRECT; }
      if(InpGridStepATR<0 || InpGridStepPoints<0 || (InpGridStepATR<=0 && InpGridStepPoints<=0)) {
         Print("Defina a distancia da grade: InpGridStepATR e/ou InpGridStepPoints maior que zero."); return INIT_PARAMETERS_INCORRECT;
      }
      if(InpGridStepExpansion<1.0 || InpGridStepExpansion>3.0 || InpGridLotMultiplier<1.0 || InpGridLotMultiplier>3.0) {
         Print("InpGridStepExpansion e InpGridLotMultiplier devem ficar entre 1.0 e 3.0."); return INIT_PARAMETERS_INCORRECT;
      }
      if(InpGridMaxLot<InpLots) { Print("InpGridMaxLot nao pode ser menor que InpLots."); return INIT_PARAMETERS_INCORRECT; }
      if(InpGridTargetPoints<1 || InpGridStopAfterSteps<0.5 || InpGridStopAfterSteps>10.0 || InpGridMaxRiskPct<=0 || InpGridMaxRiskPct>100) {
         Print("Confira InpGridTargetPoints (>0), InpGridStopAfterSteps (0.5 a 10) e InpGridMaxRiskPct (0 a 100).");
         return INIT_PARAMETERS_INCORRECT;
      }
   }
   if(MultiMode() && AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) {
      Print("Multiplas ordens e grade exigem conta hedging. Em conta netting use InpMaxTrades=1 e InpGridEnable=false.");
      return INIT_PARAMETERS_INCORRECT;
   }
   core.Reset(); trade.LogLevel(LOG_LEVEL_NO); trade.SetExpertMagicNumber(InpMagic); trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetAsyncMode(false); trade.SetTypeFillingBySymbol(_Symbol);
   state_prefix="H4M30_"+(string)AccountInfoInteger(ACCOUNT_LOGIN)+"_"+(string)InpMagic+"_"+_Symbol+"_";
   if(StringLen(state_prefix)>38) { Print("Nome do simbolo/magic longo demais para persistencia."); return INIT_PARAMETERS_INCORRECT; }
   if(!tester && GlobalVariableCheck(state_prefix+"tp_ticket") && GlobalVariableCheck(state_prefix+"tp_value")) {
      pending_position=(ulong)GlobalVariableGet(state_prefix+"tp_ticket"); pending_tp=GlobalVariableGet(state_prefix+"tp_value");
      if(!PositionSelectByTicket(pending_position) || (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic || PositionGetString(POSITION_SYMBOL)!=_Symbol) pending_position=0;
   }
   if(CheckActivationWebRequest()!=INIT_SUCCEEDED) return INIT_FAILED;
   if(InpGridEnable && InpGridStepATR>0) {
      TesterHideIndicators(true);
      atr_handle=iATR(_Symbol,PERIOD_H1,14);
      if(atr_handle==INVALID_HANDLE) { Print("Nao foi possivel criar o ATR H1 usado pela grade."); return INIT_FAILED; }
   }
   Audit("INIT","K4 XAUUSD Multi v3.17 | gratuito | k4trader | desenvolvido para RoboForex");
   if(InpShowPanel && (!tester || MQLInfoInteger(MQL_VISUAL_MODE))) {
      if(dashboard.Create("K4Panel_"+(string)ChartID(),InpPanelX,InpPanelY,InpPanelScalePercent)) {
         EventSetTimer(tester ? 60 : 1); RefreshDashboard();
      } else Print("Nao foi possivel criar o painel. A estrategia continua ativa.");
   }
   if(tester) backtest_capture.Begin(_Symbol,InpMagic,InpLots);
   if(!tester) { EventSetTimer(1); PublishMonitorPresence(); K4RemoteInit(); }
   return INIT_SUCCEEDED;
}
void PublishMonitorPresence() {
   bool allowed=MQLInfoInteger(MQL_TRADE_ALLOWED) && TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
                AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) && AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
   monitor_presence.Publish(true,tester,_Symbol,InpMagic,InpLots,allowed);
}
void OnTick() {
   license.Observe(K4LicenseNow(),tester);
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick) || tick.bid<=0 || tick.ask<tick.bid) return;
   long now=UTCMillis(tick.time_msc);
   if(!tester && MathAbs((double)(UTCSeconds(tick.time)-(long)TimeGMT()))>180) {
      if(!clock_error) Audit("CLOCK_ERROR","Offset do servidor diverge do UTC observado; novas entradas bloqueadas");
      clock_error=true; return;
   }
   clock_error=false;
   if(last_tick_msc>now) { Audit("CLOCK_ERROR","Tick fora de ordem; ignorado"); return; }
   last_tick_msc=now;
   if(!ready) { ready=Warmup(tick); return; }
   bool target_ok=ReconcileTarget(tick);
   long bucket=now/300000*300;
   bool new_m5=(bucket>live_bucket);
   if(new_m5) {
      core.FeedClosed(live_bar); core.Advance(bucket); RestoreConsumed();
      live_bar.time=bucket; live_bar.open=tick.bid; live_bar.high=tick.bid; live_bar.low=tick.bid; live_bar.close=tick.bid;
      live_bucket=bucket;
      entries_armed=true;
      UpdateGridATR();
   } else { live_bar.high=MathMax(live_bar.high,tick.bid); live_bar.low=MathMin(live_bar.low,tick.bid); live_bar.close=tick.bid; }
   core.Invalidate(tick.bid,tick.bid,now/1000); // Breach precedes any approach entry on this tick.
   if(new_m5 && target_ok) TrailPositions(tick);
   ManageBaskets(tick,now);
   if(!entries_armed || !license.CanOpen(K4LicenseNow()) || !web_permission.Allowed(tester)) return;
   // Consume every simultaneous opportunity, including those skipped because another filled.
   for(int i=0;i<256;i++) {
      SSignal signal=core.NextSignal(now,tick.bid,tick.ask,InpEntryStartUTC,InpEntryEndUTC);
      if(!signal.found) break;
      if(!tester) { GlobalVariableSet(UsedKey(signal.pivot_time,signal.direction),(double)(now/1000)); GlobalVariablesFlush(); }
      Enter(signal,tick);
   }
}
void OnDeinit(const int reason) {
   monitor_presence.Clear();
   EventKillTimer(); dashboard.Destroy();
   if(atr_handle!=INVALID_HANDLE) { IndicatorRelease(atr_handle); atr_handle=INVALID_HANDLE; }
   Audit("DEINIT",StringFormat("reason=%d; nenhuma ordem de encerramento enviada pelo EA",reason));
}

// Panel callbacks read account/core state only. They never consume signals or send orders.
void RefreshDashboard() {
   if(!dashboard.IsVisible()) return;
   panel_stats.Refresh(_Symbol,InpMagic);
   SPanelModel m; ZeroMemory(m);
   m.installed_version="3.17"; m.latest_version=updater.latest_version;
   m.update_status=tester ? "Consulta desativada no testador" : updater.status;
   if(!tester && dll_bridge.status!="")m.update_status=dll_bridge.status;
   m.update_available=updater.update_available;
   m.notice_title=client_notice.Title(TimeGMT()); m.notice_message=client_notice.Message(TimeGMT());
   m.notice_active=client_notice.Active(TimeGMT());
   m.notice_key=m.notice_active ? K4MonitorPrefix(AccountInfoInteger(ACCOUNT_LOGIN),AccountInfoString(ACCOUNT_SERVER),"notice/"+_Symbol+"/"+client_notice.Id(TimeGMT()),InpMagic)+"read" : "";
   m.account=(tester ? "TESTE" : AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_REAL ? "REAL" : "DEMO");
   m.currency=AccountInfoString(ACCOUNT_CURRENCY); m.history_ok=panel_stats.valid;
   m.trades=panel_stats.trades; m.closed_net=panel_stats.net; m.win_rate=panel_stats.win_rate; m.profit_factor=panel_stats.profit_factor;
   m.day_net=panel_stats.day_net; m.week_net=panel_stats.week_net; m.month_net=panel_stats.month_net;
   m.day_trades=panel_stats.day_trades; m.week_trades=panel_stats.week_trades; m.month_trades=panel_stats.month_trades;
   m.symbol=_Symbol; m.magic=InpMagic; m.expired=license.Expired();
   MqlTick tick; bool tick_ok=SymbolInfoTick(_Symbol,tick) && tick.bid>0 && tick.ask>=tick.bid;
   long now=UTCSeconds((long)TimeCurrent());
   m.server_time=TimeToString(TimeCurrent(),TIME_SECONDS);
   if(tick_ok) m.spread=(tick.ask-tick.bid)/_Point;
   m.trend=core.Trend(1) ? 1 : core.Trend(-1) ? -1 : 0;
   // Aggregate every own position; the panel shows the side holding the larger volume.
   int side_count[2]={0,0};
   double side_volume[2]={0,0},side_weighted[2]={0,0},side_sl[2]={0,0},side_tp[2]={0,0};
   long side_time[2]={-1,-1};
   double floating=0,stop_value=0;
   bool stop_ok=true;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong ticket=PositionGetTicket(i);
      if(!SelectedIsOwn(ticket)) continue;
      int direction=SelectedDirection(),side=(direction==1 ? 0 : 1);
      double volume=PositionGetDouble(POSITION_VOLUME),entry=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL);
      side_count[side]++; side_volume[side]+=volume; side_weighted[side]+=entry*volume;
      floating+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      long opened=PositionGetInteger(POSITION_TIME_MSC);
      if(opened>side_time[side]) { side_time[side]=opened; side_sl[side]=sl; side_tp[side]=PositionGetDouble(POSITION_TP); }
      double value=0;
      if(sl>0 && OrderCalcProfit(direction==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,volume,entry,sl,value)) stop_value+=value;
      else stop_ok=false;
   }
   int total=side_count[0]+side_count[1];
   if(total>0) {
      int side=(side_volume[0]>=side_volume[1] ? 0 : 1);
      m.position=true; m.direction=(side==0 ? 1 : -1);
      m.volume=side_volume[side]; m.entry=side_weighted[side]/side_volume[side];
      m.sl=side_sl[side]; m.tp=side_tp[side];
      m.floating=floating;
      m.stop_value_ok=stop_ok; m.stop_value=stop_value;
   }
   EH4M30Exposure exposure=EntryExposure();
   m.status="AGUARDANDO SINAL"; m.detail="Monitorando o mercado"; m.tone=0;
   if(license.Expired()) { m.status="VALIDADE ENCERRADA"; m.detail=m.position ? "Somente gestao da posicao aberta" : "Contate o criador para atualizar"; m.tone=-1; }
   else if(!license.CanOpen(K4LicenseNow())) { m.status="AGUARDANDO SERVIDOR"; m.detail="Sincronizando o terminal"; }
   else if(!tester && !TerminalInfoInteger(TERMINAL_CONNECTED)) { m.status="SEM CONEXAO"; m.detail="Verifique a conexao do terminal"; m.tone=-1; }
   else if(clock_error) { m.status="REVISAR FUSO HORARIO"; m.detail="Offset do servidor diverge do UTC"; m.tone=-1; }
   else if(!tester && (!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))) {
      m.status="NEGOCIACAO DESATIVADA"; m.detail="Confira Algo Trading e permissoes da conta"; m.tone=-1;
   } else if(!ready) { m.status="CARREGANDO DADOS"; m.detail="Preparando o monitoramento"; }
   else if(m.position) {
      m.status="GERENCIANDO "+(m.direction==1 ? "COMPRA" : "VENDA");
      m.detail=total==1 ? "Acompanhando a posicao deste robo" : StringFormat("%d ordens abertas (%d C / %d V)",total,side_count[0],side_count[1]);
      m.tone=1;
   }
   else if(!web_permission.Allowed(tester)) {
      m.status="LIBERAR WEBREQUEST"; m.detail="Confira Ferramentas > Opcoes > Expert Advisors"; m.tone=-1;
   }
   else if(exposure==H4M30_EXPOSURE_OWN) { m.status="ORDEM DESTE ROBO ATIVA"; m.detail=H4M30ExposureDetail(exposure,InpMagic); }
   else if(exposure==H4M30_EXPOSURE_NETTING) { m.status="CONFLITO EM CONTA NETTING"; m.detail=H4M30ExposureDetail(exposure,InpMagic); m.tone=-1; }
   else if(!entries_armed) { m.status="AGUARDANDO INICIO"; m.detail="Aguardando proximo candle para iniciar"; }
   else if((now%86400)/60<InpEntryStartUTC || (now%86400)/60>=InpEntryEndUTC) { m.status="AGUARDANDO HORARIO"; m.detail="Monitoramento ativo"; }
   else if(!InpUseTrendFilter) { m.status="BUSCANDO OPORTUNIDADES"; m.detail="Filtro de tendencia desligado"; m.tone=1; }
   else if(m.trend==0) { m.status="AGUARDANDO TENDENCIA"; m.detail="Mercado sem alinhamento no momento"; }
   else { m.status=m.trend==1 ? "BUSCANDO COMPRA" : "BUSCANDO VENDA"; m.detail="Monitorando oportunidades"; m.tone=1; }
   if(!tester && auto_apply.Paused() && !m.position) { m.status="PREPARANDO ATUALIZACAO"; m.detail="Reinicio automatico em instantes"; m.tone=0; }
   dashboard.Draw(m);
}
void OnTimer() {
   if(!tester)dll_bridge.Tick(updater.update_available && updater.saved_path!="",updater.latest_version,web_permission.Allowed(false));
   if(!tester && auto_apply.Tick(pending_position==0 && dll_bridge.Permitted() && web_permission.Allowed(false))) return;
   license.Observe(K4LicenseNow(),tester); PublishMonitorPresence();
   if(!tester && pending_position==0) {
      if(web_permission.Due()) K4CheckWebPermission();
      else K4RemotePoll();
   }
   RefreshDashboard();
}
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam) {
   if(dashboard.Handle(id,lparam,dparam,sparam)) RefreshDashboard();
}
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result) {
   panel_stats.dirty=true; monitor_stats.dirty=true;
}

// Summary collection runs once, after the tester finishes.
double OnTester() { backtest_capture.Finish(); return TesterStatistics(STAT_PROFIT); }
