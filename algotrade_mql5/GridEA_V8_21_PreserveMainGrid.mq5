//+------------------------------------------------------------------+
//|             GridEA_V8_21_PreserveMainGrid.mq5                    |
//|    Kar Kilitleme + Dinamik Lot + Zaman Filtresi + Iyilestirme    |
//|    ESKI 15 BUY/SELL GRIDINI VE EMIRLERINI KORUYAN HASAT SURUMU   |
//|                    Trade.mqh bagimliligi kaldirildi              |
//|                    Versiyon: 8.21 Preserve Main Grid             |
//+------------------------------------------------------------------+
//| v8.21 DEGISIKLIKLERI (v8.20 uzerine):                            |
//|  * Alt grid (LvlGrid) artik SADECE yorum (comment) ile degil,    |
//|    AYRI BIR MAGIC NUMBER ile ayirt ediliyor. Bircok broker        |
//|    yorumu kirpar/degistirir; bu durumda v8.20'de hasat calismaz  |
//|    ve tum sepet yanlislikla kapanabilirdi.                       |
//|  * Toplu kapatmalarda (async) ayni emirlerin her tickte tekrar   |
//|    gonderilmesi engellendi -> "harvest" icin de retry mekanizmasi|
//|  * Ana gridin bekleyen emirleri hasat sirasinda kesinlikle       |
//|    silinmez (InpPreserveOldGridOrders korunur).                  |
//|  * Bar-bazli agir kontroller, OnTick yukunu azaltmak icin        |
//|    zamanlayiciya baglandi; pozisyon/emir sayimlari tek gecise    |
//|    indirildi (SnapshotState).                                    |
//|  * ValidateInputs genisletildi, bolme-sifira ve gecersiz lot     |
//|    durumlari kapatildi (InpLotPerBalance <= 0 vb.).              |
//|  * CopyHigh/CopyLow eksik bar dondurdugunde guvenli cikis.       |
//|  * Telegram bildirimi (opsiyonel) gercekten uygulandi.           |
//+------------------------------------------------------------------+
#property copyright "Arena.ai - improved with user's Preserve Main Grid idea"
#property version   "8.21"
#property strict

//--- GIRIS AYARLARI -------------------------------------------------
input group "=== KAR / ZARAR (TUM ISLEMLERI KAPATAN BUYUK ANA HEDEF) ==="
input bool     InpUseBasketProfit          = true;        // Sepet kar hedefini kullan
input bool     InpUseTrailingBasket        = false;       // Sepet Trailing stop
input double   InpBasketTargetUSD          = 7.0;         // Min. kilitlenecek ana sepet kar hedefi ($)
input double   InpBasketTrailingDrop       = 2.0;         // Tepe kardan geri verme ($)
input bool     InpUseBasketStopLoss        = false;       // Sepet stop loss kullan
input double   InpBasketStopLossUSD        = 49.0;        // Sepet zarar limiti ($)

input group "=== ZAMAN FILTRESI ==="
input bool     InpUseTimeFilter            = false;       // Zaman filtresi kullan
input int      InpStartHour                = 2;           // Baslangic saati
input int      InpEndHour                  = 22;          // Bitis saati

input group "=== DINAMIK LOT ==="
input double   InpBaseLotSize              = 0.01;        // Referans lot (InpLotPerBalance bakiye icin)
input bool     InpUseDynamicLot            = true;        // Dinamik lot kullan
input double   InpLotPerBalance            = 750.0;       // Her kac $ bakiye icin InpBaseLotSize acilacak

input group "=== GRID AYARLARI (ILK KURULUM ANA GRID) ==="
input int      InpGridLevels               = 15;          // Grid seviye sayisi (1-15)
input int      InpStepPoints               = 170;         // Adim araligi (puan)
input int      InpCheckCandles             = 46;          // Fiyat araligi mum sayisi
input int      InpMinRangeLimit            = 2100;        // Minimum fiyat araligi (puan)
input int      InpWaitMinutes              = 0;           // Bekleme suresi (dakika)
input bool     InpOneGridAtATime           = true;        // Ayni anda tek ana grid

input group "=== SEVIYE 4 VE BAGIMSIZ HASAT GRIDI (CONTINUOUS SUB-GRID) ==="
input bool     InpUseLevelTriggerGrid      = true;        // 4. Seviye/Zarar gelince yeni cift yonlu grid kur
input int      InpLevelTriggerCount        = 4;           // Tek yonde VEYA toplam acilan pozisyon esigi
input double   InpLevelTriggerMinLossUSD   = 2.0;         // Yeni gridi tetiklemek icin gereken min. sepet zarari ($)
input double   InpSubGridTargetUSD         = 3.0;         // SADECE YENI GRID kar hedefi ($)
input bool     InpPreserveOldGridOrders    = true;        // Yeni grid acilinca eski bekleyen emirleri SILME
input int      InpLevelGridLevels          = 6;           // Yeni cift yonlu ara grid seviye sayisi
input int      InpLevelGridStepPoints      = 120;         // Yeni cift yonlu grid adim araligi (puan)
input double   InpLevelGridLotMultiplier   = 1.2;         // Yeni cift yonlu grid lot carpani
input int      InpLevelCooldownSec         = 5;           // Hasat sonrasi yeni ara grid kurma beklemesi (sn)
input int      InpMaxHarvestCycles         = 3;           // Ayni sepette azami hasat sayisi (0 = sinirsiz) [ZARAR FRENI]
input double   InpMaxBasketDDForSubGrid    = 25.0;        // Sepet acik zarari bu $ degerini gecerse YENI alt grid ACMA (0 = kapali)
input bool     InpCountRealizedInBasket    = true;        // Hasat edilen realize kari sepet hedef/stop hesabina KAT

input group "=== DIGER ==="
input bool     InpUseTrailingStop          = false;       // Bireysel trailing (kapali - rezerve)
input long     InpMagicNumber              = 77777;       // ANA grid Magic ID
input long     InpSubGridMagicNumber       = 77778;       // ALT (LvlGrid) Magic ID  [ANA ile ayni olamaz]
input int      InpDeviationPoints          = 50;          // Piyasa emir kaymasi

input group "=== PERFORMANS ==="
input bool     InpUseAsyncPending          = true;        // Pending grid emirlerini hizli gonder
input bool     InpUseAsyncDelete           = true;        // Pending silmeleri hizli gonder
input bool     InpUseAsyncClose            = true;        // Pozisyon kapatmalari hizli gonder
input int      InpMassCloseRetrySec        = 1;           // Toplu kapatma tekrar araligi (sn)
input int      InpRebuildDelaySec          = 0;           // Kapanis sonrasi yeni grid bekleme (sn)

input group "=== TELEGRAM (opsiyonel: WebRequest izni gerekir) ==="
input bool     InpUseTelegram              = false;       // Telegram bildirimi gonder
input string   InpTelegramToken            = "";
input string   InpTelegramChatID           = "";

//--- SABITLER --------------------------------------------------------
#define SUBGRID_TAG   "LvlGrid"

//--- GLOBAL DEGISKENLER ----------------------------------------------
struct SGridState
{
   int    mainPositions;      // ana magic pozisyon sayisi
   int    subPositions;       // alt grid pozisyon sayisi
   int    totalPositions;     // ikisinin toplami
   int    mainOrders;         // ana magic bekleyen emir
   int    subOrders;          // alt grid bekleyen emir
   int    totalOrders;
   int    buyPositions;       // tum (ana+alt) buy pozisyon
   int    sellPositions;      // tum (ana+alt) sell pozisyon
   double basketProfit;       // ana + alt net kar
   double subProfit;          // sadece alt grid net kar
};

datetime waitTimer               = 0;
double   highestBasketProfit     = 0.0;
double   lowestBasketProfit      = 0.0;
bool     isOutsideTradingHours   = false;
double   currentDynamicLot       = 0.01;

bool     basketCloseRequested    = false;
datetime nextMassCloseAttempt    = 0;
string   pendingCloseType        = "";
double   pendingCloseProfit      = 0.0;

bool     subCloseRequested       = false;   // hasat (sadece alt grid kapatma) surerken true
datetime nextSubCloseAttempt     = 0;
double   pendingSubCloseProfit   = 0.0;

bool     levelGridDeployed       = false;   // alt grid su an ekranda kurulu mu
datetime nextLevelAttempt        = 0;
int      harvestCycleCount       = 0;       // kac kez bagimsiz hasat yapildi
double   realizedCycleProfit     = 0.0;     // bu sepet dongusunde hasattan REALIZE edilen toplam kar
long     subMagic                = 77778;   // dogrulanmis alt grid magic

//+------------------------------------------------------------------+
//| Lot Hassasiyet Basamaklari                                       |
//+------------------------------------------------------------------+
int VolumeDigits()
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) return 2;
   int digits = 0;
   while(step < 1.0 && digits < 8)
   {
      step *= 10.0;
      digits++;
   }
   return digits;
}

//+------------------------------------------------------------------+
//| Lot Degerini Normalize Et                                        |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int    volDigits = VolumeDigits();

   if(lotStep <= 0.0) lotStep = 0.01;
   if(minLot  <= 0.0) minLot  = lotStep;
   if(maxLot  <= 0.0) maxLot  = 100.0;

   volume = MathMax(minLot, MathMin(maxLot, volume));
   volume = MathFloor(volume / lotStep + 1e-8) * lotStep;
   volume = NormalizeDouble(volume, volDigits);
   if(volume < minLot) volume = minLot;
   return volume;
}

//+------------------------------------------------------------------+
//| Telegram Bildirimi (opsiyonel)                                   |
//+------------------------------------------------------------------+
void Notify(string message)
{
   Print(message);
   if(!InpUseTelegram) return;
   if(StringLen(InpTelegramToken) == 0 || StringLen(InpTelegramChatID) == 0) return;

   string url  = "https://api.telegram.org/bot" + InpTelegramToken + "/sendMessage";
   string body = "chat_id=" + InpTelegramChatID + "&text=" + message;

   char   post[];
   char   result[];
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string resultHeaders;

   StringToCharArray(body, post, 0, StringLen(body));
   ResetLastError();
   int code = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);
   if(code == -1)
      PrintFormat("Telegram gonderilemedi (WebRequest izni?) | lastError=%d", GetLastError());
}

//+------------------------------------------------------------------+
//| Girdi Parametrelerini Dogrula                                    |
//+------------------------------------------------------------------+
bool ValidateInputs()
{
   if(InpGridLevels < 1 || InpGridLevels > 15)
   {
      Print("HATA: InpGridLevels 1 ile 15 arasinda olmali.");
      return false;
   }
   if(InpStepPoints <= 0)
   {
      Print("HATA: InpStepPoints 0'dan buyuk olmali.");
      return false;
   }
   if(InpCheckCandles < 1)
   {
      Print("HATA: InpCheckCandles en az 1 olmali.");
      return false;
   }
   if(InpBaseLotSize <= 0.0)
   {
      Print("HATA: InpBaseLotSize 0'dan buyuk olmali.");
      return false;
   }
   if(InpUseDynamicLot && InpLotPerBalance <= 0.0)
   {
      Print("HATA: InpLotPerBalance 0'dan buyuk olmali (sifira bolme).");
      return false;
   }
   if(InpLevelTriggerCount < 1)
   {
      Print("HATA: InpLevelTriggerCount en az 1 olmali.");
      return false;
   }
   if(InpLevelGridLevels < 1 || InpLevelGridStepPoints <= 0 || InpSubGridTargetUSD <= 0.0)
   {
      Print("HATA: Yeni cift yonlu grid veya bagimsiz kar hedefinde gecersiz deger var.");
      return false;
   }
   if(InpLevelGridLotMultiplier <= 0.0)
   {
      Print("HATA: InpLevelGridLotMultiplier 0'dan buyuk olmali.");
      return false;
   }
   if(InpUseBasketProfit && InpBasketTargetUSD <= 0.0)
   {
      Print("HATA: InpBasketTargetUSD 0'dan buyuk olmali.");
      return false;
   }
   if(InpUseBasketStopLoss && InpBasketStopLossUSD <= 0.0)
   {
      Print("HATA: InpBasketStopLossUSD 0'dan buyuk olmali.");
      return false;
   }
   if(InpUseTimeFilter && (InpStartHour < 0 || InpStartHour > 23 || InpEndHour < 0 || InpEndHour > 23))
   {
      Print("HATA: Saat filtresi degerleri 0-23 arasinda olmali.");
      return false;
   }
   if(InpSubGridMagicNumber == InpMagicNumber)
   {
      Print("HATA: InpSubGridMagicNumber, InpMagicNumber ile ayni olamaz (alt grid ayirt edilemez).");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Hesap Modu Kontrolu                                              |
//+------------------------------------------------------------------+
bool IsHedgingAccount()
{
   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return (marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

//+------------------------------------------------------------------+
//| Sembol Doldurma Modu                                             |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingType()
{
   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Islem Sonucu Basarili mi?                                        |
//+------------------------------------------------------------------+
bool IsTradeRetcodeSuccess(uint retcode)
{
   return (retcode == TRADE_RETCODE_DONE ||
           retcode == TRADE_RETCODE_PLACED ||
           retcode == TRADE_RETCODE_DONE_PARTIAL ||
           retcode == TRADE_RETCODE_NO_CHANGES ||
           retcode == TRADE_RETCODE_ORDER_CHANGED);
}

//+------------------------------------------------------------------+
//| Retcode Cevirici                                                 |
//+------------------------------------------------------------------+
string RetcodeToString(uint retcode)
{
   switch(retcode)
   {
      case TRADE_RETCODE_REQUOTE:        return "REQUOTE";
      case TRADE_RETCODE_REJECT:         return "REJECT";
      case TRADE_RETCODE_CANCEL:         return "CANCEL";
      case TRADE_RETCODE_PLACED:         return "PLACED";
      case TRADE_RETCODE_DONE:           return "DONE";
      case TRADE_RETCODE_DONE_PARTIAL:   return "DONE_PARTIAL";
      case TRADE_RETCODE_ERROR:          return "ERROR";
      case TRADE_RETCODE_TIMEOUT:        return "TIMEOUT";
      case TRADE_RETCODE_INVALID:        return "INVALID";
      case TRADE_RETCODE_INVALID_VOLUME: return "INVALID_VOLUME";
      case TRADE_RETCODE_INVALID_PRICE:  return "INVALID_PRICE";
      case TRADE_RETCODE_INVALID_STOPS:  return "INVALID_STOPS";
      case TRADE_RETCODE_TRADE_DISABLED: return "TRADE_DISABLED";
      case TRADE_RETCODE_MARKET_CLOSED:  return "MARKET_CLOSED";
      case TRADE_RETCODE_NO_MONEY:       return "NO_MONEY";
      case TRADE_RETCODE_PRICE_CHANGED:  return "PRICE_CHANGED";
      case TRADE_RETCODE_PRICE_OFF:      return "PRICE_OFF";
      case TRADE_RETCODE_NO_CHANGES:     return "NO_CHANGES";
   }
   return "UNKNOWN";
}

//+------------------------------------------------------------------+
//| Senkron & Asenkron Emir Gondericiler                             |
//+------------------------------------------------------------------+
bool SendRequest(MqlTradeRequest &request, MqlTradeResult &result, string context)
{
   ResetLastError();
   ZeroMemory(result);
   bool ok = OrderSend(request, result);
   if(!ok || !IsTradeRetcodeSuccess(result.retcode))
   {
      PrintFormat("%s basarisiz | ok=%s | retcode=%u (%s) | lastError=%d",
                  context, ok ? "true" : "false", result.retcode,
                  RetcodeToString(result.retcode), GetLastError());
      return false;
   }
   return true;
}

bool SendRequestAsync(MqlTradeRequest &request, MqlTradeResult &result, string context)
{
   ResetLastError();
   ZeroMemory(result);
   bool ok = OrderSendAsync(request, result);
   if(!ok)
   {
      PrintFormat("%s async basarisiz | retcode=%u (%s) | lastError=%d",
                  context, result.retcode, RetcodeToString(result.retcode), GetLastError());
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Pending Order Yerlestirme                                        |
//+------------------------------------------------------------------+
bool PlacePendingOrder(ENUM_ORDER_TYPE orderType, double volume, double price, string comment, long magic)
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action       = TRADE_ACTION_PENDING;
   request.magic        = magic;
   request.symbol       = _Symbol;
   request.volume       = NormalizeVolume(volume);
   request.price        = price;
   request.sl           = 0.0;
   request.tp           = 0.0;
   request.deviation    = InpDeviationPoints;
   request.type         = orderType;
   request.type_filling = GetFillingType();
   request.type_time    = ORDER_TIME_GTC;
   request.comment      = comment;

   if(InpUseAsyncPending) return SendRequestAsync(request, result, comment);
   return SendRequest(request, result, comment);
}

//+------------------------------------------------------------------+
//| Pending Order Silme                                              |
//+------------------------------------------------------------------+
bool DeletePendingOrder(ulong ticket)
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action = TRADE_ACTION_REMOVE;
   request.order  = ticket;

   string ctx = StringFormat("OrderDelete #%I64u", ticket);
   if(InpUseAsyncDelete) return SendRequestAsync(request, result, ctx);
   return SendRequest(request, result, ctx);
}

//+------------------------------------------------------------------+
//| Bireysel Pozisyon Kapatma                                        |
//+------------------------------------------------------------------+
bool ClosePositionByTicket(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return false;

   string symbol  = PositionGetString(POSITION_SYMBOL);
   double volume  = PositionGetDouble(POSITION_VOLUME);
   long   posType = PositionGetInteger(POSITION_TYPE);
   long   magic   = PositionGetInteger(POSITION_MAGIC);
   double bid     = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(symbol, SYMBOL_ASK);

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action       = TRADE_ACTION_DEAL;
   request.magic        = magic;
   request.position     = ticket;
   request.symbol       = symbol;
   request.volume       = volume;
   request.deviation    = InpDeviationPoints;
   request.type_filling = GetFillingType();

   if(posType == POSITION_TYPE_BUY)
   {
      request.type  = ORDER_TYPE_SELL;
      request.price = bid;
   }
   else
   {
      request.type  = ORDER_TYPE_BUY;
      request.price = ask;
   }

   string ctx = StringFormat("PositionClose #%I64u", ticket);
   if(InpUseAsyncClose) return SendRequestAsync(request, result, ctx);
   return SendRequest(request, result, ctx);
}

//+------------------------------------------------------------------+
//| Aidiyet Kontrolleri                                              |
//| Alt grid = ayri magic VEYA (guvenlik agi) yorumda "LvlGrid"      |
//+------------------------------------------------------------------+
bool IsMyMagic(long magic)
{
   return (magic == InpMagicNumber || magic == subMagic);
}

bool IsSubGridPosition(long magic, string comment)
{
   if(magic == subMagic) return true;
   if(magic == InpMagicNumber && StringFind(comment, SUBGRID_TAG) >= 0) return true;
   return false;
}

//+------------------------------------------------------------------+
//| Pozisyon Maliyetleri (komisyon + fee)                            |
//+------------------------------------------------------------------+
double GetPositionCosts(ulong positionId)
{
   double costs = 0.0;
   if(!HistorySelectByPosition(positionId)) return 0.0;

   int deals = (int)HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      costs += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      costs += HistoryDealGetDouble(dealTicket, DEAL_FEE);
   }
   return costs;
}

//+------------------------------------------------------------------+
//| TEK GECISTE TUM DURUM (performans + tutarlilik)                  |
//+------------------------------------------------------------------+
void SnapshotState(SGridState &st)
{
   st.mainPositions  = 0;
   st.subPositions   = 0;
   st.totalPositions = 0;
   st.mainOrders     = 0;
   st.subOrders      = 0;
   st.totalOrders    = 0;
   st.buyPositions   = 0;
   st.sellPositions  = 0;
   st.basketProfit   = 0.0;
   st.subProfit      = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long   magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsMyMagic(magic)) continue;

      string comment    = PositionGetString(POSITION_COMMENT);
      ulong  positionId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      double net        = PositionGetDouble(POSITION_PROFIT)
                        + PositionGetDouble(POSITION_SWAP)
                        + GetPositionCosts(positionId);

      st.totalPositions++;
      st.basketProfit += net;

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) st.buyPositions++;
      else                                                       st.sellPositions++;

      if(IsSubGridPosition(magic, comment))
      {
         st.subPositions++;
         st.subProfit += net;
      }
      else
      {
         st.mainPositions++;
      }
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      long magic = OrderGetInteger(ORDER_MAGIC);
      if(!IsMyMagic(magic)) continue;

      st.totalOrders++;
      if(IsSubGridPosition(magic, OrderGetString(ORDER_COMMENT))) st.subOrders++;
      else                                                        st.mainOrders++;
   }
}

//+------------------------------------------------------------------+
//| Toplu Silme / Kapatma Yardimcilari                               |
//| onlySub = true  -> sadece alt grid (LvlGrid)                     |
//| onlySub = false -> ana + alt (her sey)                           |
//+------------------------------------------------------------------+
bool DeletePendingOrders(bool onlySub)
{
   bool allOk = true;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      long magic = OrderGetInteger(ORDER_MAGIC);
      if(!IsMyMagic(magic)) continue;
      if(onlySub && !IsSubGridPosition(magic, OrderGetString(ORDER_COMMENT))) continue;

      if(!DeletePendingOrder(ticket)) allOk = false;
   }
   return allOk;
}

bool ClosePositions(bool onlySub)
{
   bool allOk = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsMyMagic(magic)) continue;
      if(onlySub && !IsSubGridPosition(magic, PositionGetString(POSITION_COMMENT))) continue;

      if(!ClosePositionByTicket(ticket)) allOk = false;
   }
   return allOk;
}

//+------------------------------------------------------------------+
//| Dinamik Lot Hesapla                                              |
//+------------------------------------------------------------------+
void CalculateDynamicLot()
{
   if(!InpUseDynamicLot || InpLotPerBalance <= 0.0)
   {
      currentDynamicLot = NormalizeVolume(InpBaseLotSize);
      return;
   }
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double capital = MathMin(balance, equity);
   if(capital < 0.0) capital = 0.0;
   double mult    = capital / InpLotPerBalance;
   currentDynamicLot = NormalizeVolume(InpBaseLotSize * mult);
}

//+------------------------------------------------------------------+
//| Saat Filtresi                                                    |
//+------------------------------------------------------------------+
bool IsTradingHour(int hour)
{
   if(!InpUseTimeFilter) return true;
   if(InpStartHour == InpEndHour) return true;
   if(InpStartHour < InpEndHour) return (hour >= InpStartHour && hour < InpEndHour);
   return (hour >= InpStartHour || hour < InpEndHour);
}

bool IsTradingTimeAllowed()
{
   if(!InpUseTimeFilter) return true;

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   bool allowed = IsTradingHour(tm.hour);

   if(!allowed && !isOutsideTradingHours)
   {
      isOutsideTradingHours = true;
      Print("Islem saati bitti. Acik pozisyonlar ve ara gridler dogal kapanisini bekliyor...");
   }
   else if(allowed && isOutsideTradingHours)
   {
      isOutsideTradingHours = false;
      CalculateDynamicLot();
   }
   return allowed;
}

//+------------------------------------------------------------------+
//| Degiskenleri Sifirla                                             |
//+------------------------------------------------------------------+
void ResetAllVariables()
{
   highestBasketProfit = 0.0;
   lowestBasketProfit  = 0.0;
   levelGridDeployed   = false;
   nextLevelAttempt    = 0;
   harvestCycleCount   = 0;
   realizedCycleProfit = 0.0;
   subCloseRequested   = false;
   nextSubCloseAttempt = 0;
}

//+------------------------------------------------------------------+
//| TOPYEKUN Sepet Kapatma Sureci                                    |
//+------------------------------------------------------------------+
void StartBasketClose(string closeType, double netProfit)
{
   basketCloseRequested = true;
   pendingCloseType     = closeType;
   pendingCloseProfit   = netProfit;
   nextMassCloseAttempt = 0;
   subCloseRequested    = false;
   levelGridDeployed    = false;
   nextLevelAttempt     = 0;
}

bool ProcessBasketClose(const SGridState &st)
{
   if(!basketCloseRequested) return false;

   if(TimeCurrent() >= nextMassCloseAttempt)
   {
      DeletePendingOrders(false);
      ClosePositions(false);
      nextMassCloseAttempt = TimeCurrent() + MathMax(1, InpMassCloseRetrySec);
   }

   if(st.totalPositions == 0 && st.totalOrders == 0)
   {
      Notify(StringFormat("%s tamamlandi | Net: $%.2f", pendingCloseType, pendingCloseProfit));
      ResetAllVariables();
      basketCloseRequested = false;
      pendingCloseType     = "";
      pendingCloseProfit   = 0.0;
      waitTimer            = TimeCurrent() + InpRebuildDelaySec;
   }
   return true;
}

//+------------------------------------------------------------------+
//| SADECE ALT GRIDIN KARINI AL (BAGIMSIZ HASAT / DONGU TEKRARI)     |
//| Ana grid pozisyonlari ve 15 Buy/Sell bekleyen emirleri KORUNUR   |
//+------------------------------------------------------------------+
bool ProcessSubGridClose(const SGridState &st)
{
   if(!subCloseRequested) return false;

   if(TimeCurrent() >= nextSubCloseAttempt)
   {
      ClosePositions(true);       // sadece alt grid pozisyonlari
      DeletePendingOrders(true);  // sadece alt grid bekleyen emirleri
      nextSubCloseAttempt = TimeCurrent() + MathMax(1, InpMassCloseRetrySec);
   }

   if(st.subPositions == 0 && st.subOrders == 0)
   {
      harvestCycleCount++;
      realizedCycleProfit += pendingSubCloseProfit;
      Notify(StringFormat("%d. BAGIMSIZ HASAT TAMAM | Alt grid kari: +$%.2f | Ana grid (%d pozisyon / %d bekleyen emir) korundu.",
                          harvestCycleCount, pendingSubCloseProfit, st.mainPositions, st.mainOrders));
      subCloseRequested = false;
      levelGridDeployed = false;   // yeniden kurulabilsin
      nextLevelAttempt  = TimeCurrent() + MathMax(0, InpLevelCooldownSec);
   }
   return true;
}

bool CheckSubGridProfitAndHarvest(const SGridState &st)
{
   if(!InpUseLevelTriggerGrid) return false;
   if(subCloseRequested)       return false;
   if(st.subPositions == 0)    return false;

   if(st.subProfit >= InpSubGridTargetUSD)
   {
      subCloseRequested     = true;
      pendingSubCloseProfit = st.subProfit;
      nextSubCloseAttempt   = 0;
      PrintFormat(">>> SUB-GRID HARVEST TETIKLENDI | Alt grid net: +$%.2f (hedef $%.2f) | Ana grid korunuyor <<<",
                  st.subProfit, InpSubGridTargetUSD);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Etkin Adim Mesafesi                                              |
//+------------------------------------------------------------------+
int GetMinStopDistance()
{
   int tradeStops  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax(tradeStops, freezeLevel) + 1;
}

int GetEffectiveStepPoints()
{
   return MathMax(InpStepPoints, GetMinStopDistance());
}

//+------------------------------------------------------------------+
//| SEVIYE & ZARAR TETIKLI GUNCEL FIYATA YENI CIFT YONLU ALT GRID    |
//+------------------------------------------------------------------+
bool CheckAndDeployAdaptiveLevelGrid(const SGridState &st)
{
   if(!InpUseLevelTriggerGrid)   return false;
   if(!IsTradingTimeAllowed())   return false;
   if(subCloseRequested)         return false;
   if(levelGridDeployed)         return false;
   if(st.subOrders > 0)          return false;
   if(st.subPositions > 0)       return false;

   // FREN 1: Ayni sepette sinirsiz hasat = trendde sonsuz zarar buyutme.
   // Her hasat kucuk kar realize ederken ana grid zarari daha cok buyuyorsa dur.
   if(InpMaxHarvestCycles > 0 && harvestCycleCount >= InpMaxHarvestCycles)
      return false;

   // FREN 2: Sepet acik zarari cok buyudukten sonra yeni grid eklemek
   // riski katlar (martingale etkisi). Belirli drawdown ustunde yeni grid acma.
   if(InpMaxBasketDDForSubGrid > 0.0 && st.basketProfit <= -InpMaxBasketDDForSubGrid)
      return false;

   bool levelReached = (st.buyPositions  >= InpLevelTriggerCount ||
                        st.sellPositions >= InpLevelTriggerCount ||
                        st.totalPositions >= (InpLevelTriggerCount * 2));
   bool lossReached  = (st.basketProfit <= -InpLevelTriggerMinLossUSD);

   if(!(levelReached && lossReached)) return false;

   PrintFormat(">>> SEVIYE %d VE ZARAR (-$%.2f) TETIKLENDI! Guncel fiyata yeni cift yonlu LvlGrid aciliyor... <<<",
               InpLevelTriggerCount, MathAbs(st.basketProfit));

   // InpPreserveOldGridOrders = true  -> eski ana grid bekleyen emirlerine DOKUNMA
   // InpPreserveOldGridOrders = false -> hepsini temizle
   if(!InpPreserveOldGridOrders) DeletePendingOrders(false);
   else                          DeletePendingOrders(true);  // sadece artakalan alt grid emirleri

   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(ask <= 0.0 || bid <= 0.0 || point <= 0.0) return false;

   int    stepPts = MathMax(InpLevelGridStepPoints, GetMinStopDistance());
   double lvlLot  = NormalizeVolume(currentDynamicLot * InpLevelGridLotMultiplier);
   int    created = 0;

   for(int i = 1; i <= InpLevelGridLevels; i++)
   {
      double buyPrice  = NormalizeDouble(ask + (i * stepPts * point), digits);
      double sellPrice = NormalizeDouble(bid - (i * stepPts * point), digits);
      if(sellPrice <= 0.0) continue;

      if(PlacePendingOrder(ORDER_TYPE_BUY_STOP, lvlLot, buyPrice,
                           SUBGRID_TAG + " Buy " + IntegerToString(i), subMagic))
         created++;
      if(PlacePendingOrder(ORDER_TYPE_SELL_STOP, lvlLot, sellPrice,
                           SUBGRID_TAG + " Sell " + IntegerToString(i), subMagic))
         created++;
   }

   if(created > 0)
   {
      PrintFormat("LvlGrid KURULDU | Adim: %d puan | Lot: %s | Emir: %d | Ana grid bekleyen emirleri: %s",
                  stepPts, DoubleToString(lvlLot, VolumeDigits()), created,
                  InpPreserveOldGridOrders ? "KORUNDU" : "SILINDI");
      levelGridDeployed = true;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Sepet Kar/Zarar Kontrolu (TUM ISLEMLERI KAPATAN ANA HEDEF)       |
//+------------------------------------------------------------------+
void CheckBasketProfitAndReset(const SGridState &st)
{
   if(!InpUseBasketProfit && !InpUseBasketStopLoss) return;
   if(isOutsideTradingHours) return;

   if(st.totalPositions == 0)
   {
      highestBasketProfit = 0.0;
      lowestBasketProfit  = 0.0;
      return;
   }

   // KRITIK: hasatla realize edilen kar sepet hesabina katilmazsa, EA kar ettigini
   // sanip acik zarari buyutmeye devam eder. Gercek sepet sonucu = realize + acik.
   double totalProfit = st.basketProfit;
   if(InpCountRealizedInBasket) totalProfit += realizedCycleProfit;
   if(totalProfit > highestBasketProfit) highestBasketProfit = totalProfit;
   if(totalProfit < lowestBasketProfit)  lowestBasketProfit  = totalProfit;

   bool   triggerClose = false;
   string closeType    = "";

   if(InpUseBasketStopLoss && totalProfit <= -InpBasketStopLossUSD)
   {
      triggerClose = true;
      closeType    = "Basket Stop Loss";
   }
   else if(InpUseBasketProfit && !InpUseTrailingBasket && totalProfit >= InpBasketTargetUSD)
   {
      triggerClose = true;
      closeType    = StringFormat("Basket Sabit Hedef ($%.2f)", InpBasketTargetUSD);
   }
   else if(InpUseBasketProfit && InpUseTrailingBasket && highestBasketProfit >= InpBasketTargetUSD)
   {
      double lockLevel = MathMax(InpBasketTargetUSD, highestBasketProfit - InpBasketTrailingDrop);
      if(totalProfit <= lockLevel)
      {
         triggerClose = true;
         closeType    = StringFormat("Basket Trailing | Peak=%.2f | Lock=%.2f", highestBasketProfit, lockLevel);
      }
   }

   if(triggerClose)
   {
      PrintFormat("%s tetiklendi | Net: $%.2f", closeType, totalProfit);
      StartBasketClose(closeType, totalProfit);
   }
}

//+------------------------------------------------------------------+
//| Ana Grid Emirlerini Yerlestir                                    |
//+------------------------------------------------------------------+
void PlaceGridOrders()
{
   if(!IsTradingTimeAllowed()) return;

   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(ask <= 0.0 || bid <= 0.0 || point <= 0.0) return;

   int stepPts = GetEffectiveStepPoints();
   int created = 0;

   for(int i = 1; i <= InpGridLevels; i++)
   {
      double buyPrice  = NormalizeDouble(ask + (i * stepPts * point), digits);
      double sellPrice = NormalizeDouble(bid - (i * stepPts * point), digits);
      if(sellPrice <= 0.0) continue;

      if(PlacePendingOrder(ORDER_TYPE_BUY_STOP, currentDynamicLot, buyPrice,
                           "Buy " + IntegerToString(i), InpMagicNumber))
         created++;
      if(PlacePendingOrder(ORDER_TYPE_SELL_STOP, currentDynamicLot, sellPrice,
                           "Sell " + IntegerToString(i), InpMagicNumber))
         created++;
   }

   PrintFormat("%d seviye ana grid yerlestirildi | Etkin adim: %d | Lot: %s | Emir sayisi: %d",
               InpGridLevels, stepPts, DoubleToString(currentDynamicLot, VolumeDigits()), created);
}

//+------------------------------------------------------------------+
//| Aralik Kontrolu                                                  |
//+------------------------------------------------------------------+
bool IsRangeWideEnough()
{
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low,  true);

   int copiedHigh = CopyHigh(_Symbol, _Period, 1, InpCheckCandles, high);
   int copiedLow  = CopyLow(_Symbol,  _Period, 1, InpCheckCandles, low);
   if(copiedHigh < InpCheckCandles || copiedLow < InpCheckCandles) return false;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) return false;

   double rangePoints = (high[ArrayMaximum(high)] - low[ArrayMinimum(low)]) / point;
   return (rangePoints >= InpMinRangeLimit);
}

//+------------------------------------------------------------------+
//| EA OnInit                                                        |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!ValidateInputs()) return INIT_PARAMETERS_INCORRECT;

   if(!IsHedgingAccount())
   {
      Print("HATA: Bu EA HEDGE hesap gerektirir!");
      return INIT_FAILED;
   }

   subMagic = InpSubGridMagicNumber;
   CalculateDynamicLot();

   Print("------------------------------------------------------------------------");
   Print("GridEA v8.21 Preserve Main Grid | ANA GRIDI KORUYAN HASAT SURUMU");
   PrintFormat("1) Ana sepet hedefi (her sey kapanir): +$%.2f", InpBasketTargetUSD);
   PrintFormat("2) Alt grid hedefi  (sadece LvlGrid kapanir, ana grid yasar): +$%.2f", InpSubGridTargetUSD);
   PrintFormat("3) Ana grid bekleyen emirleri: %s", InpPreserveOldGridOrders ? "KORUNUR" : "SILINIR");
   PrintFormat("4) Magic: ana=%I64d | alt(LvlGrid)=%I64d", InpMagicNumber, subMagic);
   PrintFormat("Ana Grid: %d seviye | Adim: %d puan | Lot: %s",
               InpGridLevels, InpStepPoints, DoubleToString(currentDynamicLot, VolumeDigits()));
   Print("------------------------------------------------------------------------");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTick Ana Dongu                                                 |
//+------------------------------------------------------------------+
void OnTick()
{
   IsTradingTimeAllowed();

   SGridState st;
   SnapshotState(st);

   // 1) Topyekun kapanis talebi
   if(ProcessBasketClose(st)) return;

   // 2) Devam eden bagimsiz hasat (sadece alt grid kapatiliyor)
   if(ProcessSubGridClose(st)) return;

   if(st.totalPositions > 0)
   {
      // 3) Alt grid bagimsiz kar hedefine ulasti mi?
      if(CheckSubGridProfitAndHarvest(st)) return;

      // 4) Seviye + zarar tetigi -> taze alt grid
      if(TimeCurrent() >= nextLevelAttempt)
      {
         CheckAndDeployAdaptiveLevelGrid(st);
         nextLevelAttempt = TimeCurrent() + MathMax(1, InpLevelCooldownSec);
      }
   }

   // 5) Buyuk sepet hedefi / stop
   CheckBasketProfitAndReset(st);
   if(basketCloseRequested)
   {
      ProcessBasketClose(st);
      return;
   }

   // 6) Ana grid kurulumu (sadece hicbir pozisyon/emir yokken)
   if(TimeCurrent() < waitTimer) return;
   if(isOutsideTradingHours)     return;
   if(st.totalPositions > 0 && InpOneGridAtATime) return;
   if(st.totalPositions != 0 || st.totalOrders != 0) return;

   if(!IsRangeWideEnough())
   {
      waitTimer = TimeCurrent() + (InpWaitMinutes * 60);
      return;
   }

   CalculateDynamicLot();
   PlaceGridOrders();
   waitTimer = TimeCurrent() + InpRebuildDelaySec;
}

//+------------------------------------------------------------------+
//| EA OnDeinit                                                      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("GridEA v8.21 Preserve Main Grid kapatildi. Reason=", reason);
}
//+------------------------------------------------------------------+
