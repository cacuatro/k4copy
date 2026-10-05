#property copyright "k4trader | Uso gratuito. Venda proibida."
#property version "3.17"
#property strict
#property link "https://copytrader-monitor.onrender.com/"
#property icon "assets\\k4_xauusd.ico"
#property description "K4 XAUUSD | k4trader"
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
void TrailPosition(const MqlTick &tick) {
   ulong ticket=OwnPosition();
   if(ticket==0 || !H4M30SelectOwnPosition(ticket,_Symbol,InpMagic)) return;
   int direction=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1);
   double old_sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP);
   long entry_msc=UTCMillis(PositionGetInteger(POSITION_TIME_MSC));
   double sl=core.Trail(entry_msc,direction,old_sl,tick.bid,tick.ask);
   if(MathAbs(sl-old_sl)<0.009 || !ValidProtection(direction,sl,tp,tick,true)) return;
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
   if(!signal.trend_ok) { Audit("FILTER_EMA",(string)signal.pivot_time); return; }
   EH4M30Exposure exposure=EntryExposure();
   if(exposure!=H4M30_EXPOSURE_NONE) {
      Audit(exposure==H4M30_EXPOSURE_OWN ? "BUSY" : "NETTING_CONFLICT",
            (string)signal.pivot_time+"; "+H4M30ExposureDetail(exposure,InpMagic)); return;
   }
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
      if(!license.CanOpen(K4LicenseNow()) || EntryExposure()!=H4M30_EXPOSURE_NONE) return;
      if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) return;
   }
   if(!ValidProtection(signal.direction,signal.sl,signal.tp,execution_tick,false)) {
      Audit("INVALID_STOPS","Oportunidade ignorada; sem ampliar SL nem alterar lote para atender corretora"); return;
   }
   string comment="k4trader";
   bool sent=(signal.direction==1 ? trade.Buy(InpLots,_Symbol,0,signal.sl,signal.tp,comment)
                                 : trade.Sell(InpLots,_Symbol,0,signal.sl,signal.tp,comment));
   if(!sent || !Successful()) { Audit("ORDER_REJECT",trade.ResultRetcodeDescription()); return; }
   ulong ticket=OwnPosition();
   if(ticket==0 || !PositionSelectByTicket(ticket)) { Audit("FILL","Execucao sem posicao aberta restante"); return; }
   double fill=PositionGetDouble(POSITION_PRICE_OPEN);
   double actual_sl=PositionGetDouble(POSITION_SL);
   double tp=Target3R(fill,actual_sl,signal.direction);
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
   core.Reset(); trade.LogLevel(LOG_LEVEL_NO); trade.SetExpertMagicNumber(InpMagic); trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetAsyncMode(false); trade.SetTypeFillingBySymbol(_Symbol);
   state_prefix="H4M30_"+(string)AccountInfoInteger(ACCOUNT_LOGIN)+"_"+(string)InpMagic+"_"+_Symbol+"_";
   if(StringLen(state_prefix)>38) { Print("Nome do simbolo/magic longo demais para persistencia."); return INIT_PARAMETERS_INCORRECT; }
   if(!tester && GlobalVariableCheck(state_prefix+"tp_ticket") && GlobalVariableCheck(state_prefix+"tp_value")) {
      pending_position=(ulong)GlobalVariableGet(state_prefix+"tp_ticket"); pending_tp=GlobalVariableGet(state_prefix+"tp_value");
      if(!PositionSelectByTicket(pending_position) || (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic || PositionGetString(POSITION_SYMBOL)!=_Symbol) pending_position=0;
   }
   if(CheckActivationWebRequest()!=INIT_SUCCEEDED) return INIT_FAILED;
   Audit("INIT","K4 XAUUSD v3.00 | gratuito | k4trader | desenvolvido para RoboForex");
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
   } else { live_bar.high=MathMax(live_bar.high,tick.bid); live_bar.low=MathMin(live_bar.low,tick.bid); live_bar.close=tick.bid; }
   core.Invalidate(tick.bid,tick.bid,now/1000); // Breach precedes any approach entry on this tick.
   if(new_m5 && target_ok) TrailPosition(tick);
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
   ulong ticket=OwnPosition();
   if(ticket>0 && PositionSelectByTicket(ticket)) {
      m.position=true; m.direction=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1;
      m.volume=PositionGetDouble(POSITION_VOLUME); m.entry=PositionGetDouble(POSITION_PRICE_OPEN);
      m.sl=PositionGetDouble(POSITION_SL); m.tp=PositionGetDouble(POSITION_TP);
      m.floating=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      m.stop_value_ok=m.sl>0 && OrderCalcProfit(m.direction==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,m.volume,m.entry,m.sl,m.stop_value);
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
   else if(m.position) { m.status="GERENCIANDO "+(m.direction==1 ? "COMPRA" : "VENDA"); m.detail="Acompanhando a posicao deste robo"; m.tone=1; }
   else if(!web_permission.Allowed(tester)) {
      m.status="LIBERAR WEBREQUEST"; m.detail="Confira Ferramentas > Opcoes > Expert Advisors"; m.tone=-1;
   }
   else if(exposure==H4M30_EXPOSURE_OWN) { m.status="ORDEM DESTE ROBO ATIVA"; m.detail=H4M30ExposureDetail(exposure,InpMagic); }
   else if(exposure==H4M30_EXPOSURE_NETTING) { m.status="CONFLITO EM CONTA NETTING"; m.detail=H4M30ExposureDetail(exposure,InpMagic); m.tone=-1; }
   else if(!entries_armed) { m.status="AGUARDANDO INICIO"; m.detail="Aguardando proximo candle para iniciar"; }
   else if((now%86400)/60<InpEntryStartUTC || (now%86400)/60>=InpEntryEndUTC) { m.status="AGUARDANDO HORARIO"; m.detail="Monitoramento ativo"; }
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
