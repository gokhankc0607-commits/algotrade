//+------------------------------------------------------------------+
//|             GridEA_V8_20_PreserveMainGrid.mq5                    |
//|    5$ Kar Kilitleme + Dinamik Lot + Zaman Filtresi + İyileştirme |
//|    ESKİ 15 BUY/SELL GRİDİNİ VE EMİRLERİNİ KORUYAN HASAT SÜRÜMÜ   |
//|                    Trade.mqh bağımlılığı kaldırıldı              |
//|                    Versiyon: 8.20 Preserve Main Grid             |
//+------------------------------------------------------------------+
#property copyright "Arena.ai - improved with user's Preserve Main Grid idea"
#property version   "8.20"
#property strict

//--- GİRİŞ AYARLARI -------------------------------------------------
input group "=== KAR / ZARAR (TÜM İŞLEMLERİ KAPATAN BÜYÜK ANA HEDEF) ==="
input bool     InpUseBasketProfit          = true;        // Sepet kar hedefini kullan
input bool     InpUseTrailingBasket        = false;       // Sepet Trailing stop
input double   InpBasketTargetUSD          = 7.0;         // Min. kilitlenecek ana sepet kar hedefi ($)
input double   InpBasketTrailingDrop       = 2.0;         // Tepe kardan geri verme ($)
input bool     InpUseBasketStopLoss        = false;       // Sepet stop loss kullan
input double   InpBasketStopLossUSD        = 49.0;        // Sepet zarar limiti ($)

input group "=== ZAMAN FİLTRESİ ==="
input bool     InpUseTimeFilter            = false;       // Zaman filtresi kullan
input int      InpStartHour                = 2;           // Başlangıç saati
input int      InpEndHour                  = 22;          // Bitiş saati

input group "=== DİNAMİK LOT ==="
input double   InpBaseLotSize              = 0.01;        // Referans lot (InpLotPerBalance bakiye için)
input bool     InpUseDynamicLot            = true;        // Dinamik lot kullan
input double   InpLotPerBalance            = 750.0;       // Her kaç $ bakiye için InpBaseLotSize açılacak

input group "=== GRİD AYARLARI (İLK KURULUM ANA GRİD) ==="
input int      InpGridLevels               = 15;          // Grid seviye sayısı (1-15)
input int      InpStepPoints               = 170;         // Adım aralığı (puan) [Örn: 170 puan = 17 pip]
input int      InpCheckCandles             = 46;          // Fiyat aralığı mum sayısı
input int      InpMinRangeLimit            = 2100;        // Minimum fiyat aralığı (puan) [Örn: 210 pip]
input int      InpWaitMinutes              = 0;           // Bekleme süresi (dakika)
input bool     InpOneGridAtATime           = true;        // Aynı anda tek ana grid

input group "=== SEVİYE 4 VE BAĞIMSIZ HASAT GRİDİ (CONTINUOUS SUB-GRID) ==="
input bool     InpUseLevelTriggerGrid      = true;        // 4. Seviye/Zarar gelince yeni çift yönlü grid kur
input int      InpLevelTriggerCount        = 4;           // Tek yönde VEYA toplam açılan pozisyon sayısı eşiği (Örn: 4)
input double   InpLevelTriggerMinLossUSD   = 2.0;         // Yeni gridi tetiklemek için gereken minimum sepet zararı ($)
input double   InpSubGridTargetUSD         = 3.0;         // SADECE YENİ GRİD kâr hedefi ($) [Ulaşınca sadece yeni grid kapanır, eski yaşar ve döngü tekrarlar!]
input bool     InpPreserveOldGridOrders    = true;        // YENİ GRİD AÇILINCA ESKİ 15 BUY/SELL BEKLEYEN EMİRLERİNİ SİLME (Aynen korunsun/kalsın)
input int      InpLevelGridLevels          = 6;           // Yeni oluşturulacak çift yönlü ara grid seviye sayısı
input int      InpLevelGridStepPoints      = 120;         // Yeni çift yönlü grid adım aralığı (puan) [Örn: 120 = 12 pip]
input double   InpLevelGridLotMultiplier   = 1.2;         // Yeni çift yönlü grid lot çarpanı (Örn: 1.2x)
input int      InpLevelCooldownSec         = 5;           // Hasat bittikten sonra yeni ara grid kurma beklemesi (sn)

input group "=== DİĞER ==="
input bool     InpUseReversal              = false;       // Ters işlem (pasif)
input int      InpReversalPositions        = 4;
input int      InpReversalPoints           = 300;
input bool     InpUseTrailingStop          = false;       // Bireysel trailing (kapalı)
input long     InpMagicNumber              = 77777;       // Ana ve Kurtarma emirleri Magic ID
input int      InpDeviationPoints          = 50;          // Piyasa emir kayması

input group "=== PERFORMANS ==="
input bool     InpUseAsyncPending          = true;        // Pending grid emirlerini hızlı gönder
input bool     InpUseAsyncDelete           = true;        // Pending silmeleri hızlı gönder
input bool     InpUseAsyncClose            = true;        // Pozisyon kapatmaları hızlı gönder
input int      InpMassCloseRetrySec        = 1;           // Toplu kapatma tekrar aralığı
input int      InpRebuildDelaySec          = 0;           // Kapanış sonrası yeni grid bekleme

input group "=== TELEGRAM ==="
input string   InpTelegramToken            = "";
input string   InpTelegramChatID           = "";

//--- GLOBAL DEĞİŞKENLER ----------------------------------------------
struct SPositionInfo
{
   ulong  ticket;
   long   type;
   double profit;
   double volume;
   double price;
};

datetime waitTimer               = 0;
double   highestBasketProfit     = 0.0;
double   lowestBasketProfit      = 0.0;
int      previousPositionCount   = 0;
bool     isOutsideTradingHours   = false;
double   currentDynamicLot       = 0.01;
bool     basketCloseRequested    = false;
datetime nextMassCloseAttempt    = 0;
string   pendingCloseType        = "";
double   pendingCloseProfit      = 0.0;

bool     levelGridDeployed       = false; // 4. seviye yeni gridi o an ekranda kurulu mu?
datetime nextLevelAttempt        = 0;
int      harvestCycleCount       = 0;     // Kaç kez 2., 3., 4. kez bağımsız hasat yapıldı?

//+------------------------------------------------------------------+
//| Lot Hassasiyet Basamakları                                       |
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
//| Lot Değerini Normalize Et                                        |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int volDigits  = VolumeDigits();
   if(lotStep <= 0.0) lotStep = 0.01;
   volume = MathMax(minLot, MathMin(maxLot, volume));
   volume = MathFloor(volume / lotStep) * lotStep;
   volume = NormalizeDouble(volume, volDigits);
   if(volume < minLot) volume = minLot;
   return volume;
}

//+------------------------------------------------------------------+
//| Girdi Parametrelerini Doğrula                                    |
//+------------------------------------------------------------------+
bool ValidateInputs()
{
   if(InpGridLevels < 1 || InpGridLevels > 15)
   {
      Print("HATA: InpGridLevels 1 ile 15 arasında olmalı.");
      return false;
   }
   if(InpLevelTriggerCount < 1)
   {
      Print("HATA: InpLevelTriggerCount en az 1 olmalı.");
      return false;
   }
   if(InpLevelGridLevels < 1 || InpLevelGridStepPoints <= 0 || InpSubGridTargetUSD <= 0.0)
   {
      Print("HATA: Yeni çift yönlü grid veya bağımsız kâr hedefinde geçersiz değer var.");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Hesap Modu Kontrolü                                              |
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
//| İşlem Sonucu Başarılı mı?                                        |
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
//| Retcode Çevirici                                                 |
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
//| Senkron & Asenkron Emir Gönderici                                |
//+------------------------------------------------------------------+
bool SendRequest(MqlTradeRequest &request, MqlTradeResult &result, string context)
{
   ResetLastError();
   ZeroMemory(result);
   bool ok = OrderSend(request, result);
   if(!ok || !IsTradeRetcodeSuccess(result.retcode))
   {
      PrintFormat("%s başarısız | ok=%s | retcode=%u (%s) | lastError=%d",
                  context, ok ? "true" : "false", result.retcode, RetcodeToString(result.retcode), GetLastError());
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
      PrintFormat("%s async başarısız | lastError=%d", context, GetLastError());
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Pending Order Yerleştirme                                        |
//+------------------------------------------------------------------+
bool PlacePendingOrder(ENUM_ORDER_TYPE orderType, double volume, double price, string comment)
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action       = TRADE_ACTION_PENDING;
   request.magic        = InpMagicNumber;
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
   if(InpUseAsyncDelete) return SendRequestAsync(request, result, StringFormat("OrderDelete #%I64u", ticket));
   return SendRequest(request, result, StringFormat("OrderDelete #%I64u", ticket));
}

//+------------------------------------------------------------------+
//| Bireysel Pozisyon Kapatma                                        |
//+------------------------------------------------------------------+
bool ClosePositionByTicket(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return false;
   string symbol   = PositionGetString(POSITION_SYMBOL);
   double volume   = PositionGetDouble(POSITION_VOLUME);
   long posType    = PositionGetInteger(POSITION_TYPE);
   double bid      = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask      = SymbolInfoDouble(symbol, SYMBOL_ASK);
   
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action       = TRADE_ACTION_DEAL;
   request.magic        = InpMagicNumber;
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
   if(InpUseAsyncClose) return SendRequestAsync(request, result, StringFormat("PositionClose #%I64u", ticket));
   return SendRequest(request, result, StringFormat("PositionClose #%I64u", ticket));
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
   
   CalculateDynamicLot();
   Print("------------------------------------------------------------------------");
   Print("GridEA v8.20 Preserve Main Grid | ESKİ 15 BUY/SELL GRİDİNİ KORUYAN HASAT SÜRÜMÜ");
   Print("1) Büyük Ana Sepet Karı (Tüm Eski+Yeni İşlemler Komple Kapanır): +$", DoubleToString(InpBasketTargetUSD, 2));
   Print("2) Bağımsız Ara-Grid Karı (Sadece LvlGrid Kapanır, Eski Yaşar ve Döngü Tekrarlar!): +$", DoubleToString(InpSubGridTargetUSD, 2));
   Print("3) Eski 15 Buy/Sell Bekleyen Emirleri Koruma: ", InpPreserveOldGridOrders ? "AÇIK (SİLİNMEZ, KORUNUR)" : "KAPALI (SİLİNİR)");
   Print("Ana Grid: ", InpGridLevels, " Seviye | Adım: ", InpStepPoints, " puan | Lot: ", DoubleToString(currentDynamicLot, VolumeDigits()));
   Print("------------------------------------------------------------------------");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Dinamik Lot Hesapla                                              |
//+------------------------------------------------------------------+
void CalculateDynamicLot()
{
   if(!InpUseDynamicLot)
   {
      currentDynamicLot = NormalizeVolume(InpBaseLotSize);
      return;
   }
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double capital = MathMin(balance, equity);
   double mult    = capital / InpLotPerBalance;
   currentDynamicLot = NormalizeVolume(InpBaseLotSize * mult);
}

//+------------------------------------------------------------------+
//| Saat Filtresi Kontrolü                                           |
//+------------------------------------------------------------------+
bool IsTradingHour(int hour)
{
   if(!InpUseTimeFilter) return true;
   if(InpStartHour == InpEndHour) return true;
   if(InpStartHour < InpEndHour) return (hour >= InpStartHour && hour < InpEndHour);
   return (hour >= InpStartHour || hour < InpEndHour);
}

//+------------------------------------------------------------------+
//| İşlem Saati İzin Kontrolü                                        |
//+------------------------------------------------------------------+
bool IsTradingTimeAllowed()
{
   if(!InpUseTimeFilter) return true;
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   bool allowed = IsTradingHour(tm.hour);
   if(!allowed && !isOutsideTradingHours)
   {
      isOutsideTradingHours = true;
      Print("İşlem saati bitti. Açık pozisyonlar ve ara gridler doğal kapanışını bekliyor...");
   }
   else if(allowed && isOutsideTradingHours)
   {
      isOutsideTradingHours = false;
      CalculateDynamicLot();
   }
   return allowed;
}

//+------------------------------------------------------------------+
//| Bizim Pozisyon Sayımız                                           |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Yönüne Göre Bizim Pozisyon Sayımız                               |
//+------------------------------------------------------------------+
int CountMyPositionsByType(long posType)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetInteger(POSITION_TYPE) == posType)
      {
         count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Belirli Önekle Başlayan Pozisyon Sayısı (Örn: "LvlGrid")         |
//+------------------------------------------------------------------+
int CountMyPositionsByCommentPrefix(string prefix)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         string comm = PositionGetString(POSITION_COMMENT);
         if(StringFind(comm, prefix) >= 0) count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Bizim Bekleyen Emir Sayımız                                      |
//+------------------------------------------------------------------+
int CountMyOrders()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Belirli Önekle Başlayan Bekleyen Emir Sayısı                    |
//+------------------------------------------------------------------+
int CountMyOrdersByCommentPrefix(string prefix)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
      {
         string comm = OrderGetString(ORDER_COMMENT);
         if(StringFind(comm, prefix) >= 0) count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Tüm Bizim Bekleyen Emirleri Sil                                  |
//+------------------------------------------------------------------+
bool DeleteAllPendingOrders()
{
   bool allOk = true;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
      {
         if(!DeletePendingOrder(ticket)) allOk = false;
      }
   }
   return allOk;
}

//+------------------------------------------------------------------+
//| SADECE Belirli Önekle Başlayan Bekleyen Emirleri Sil (LvlGrid)   |
//+------------------------------------------------------------------+
bool DeleteOrdersByCommentPrefix(string prefix)
{
   bool allOk = true;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
      {
         string comm = OrderGetString(ORDER_COMMENT);
         if(StringFind(comm, prefix) >= 0)
         {
            if(!DeletePendingOrder(ticket)) allOk = false;
         }
      }
   }
   return allOk;
}

//+------------------------------------------------------------------+
//| Tüm Pozisyonları Kapat                                           |
//+------------------------------------------------------------------+
bool CloseAllMyPositions()
{
   bool allOk = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         if(!ClosePositionByTicket(ticket)) allOk = false;
      }
   }
   return allOk;
}

//+------------------------------------------------------------------+
//| SADECE Belirli Önekle Başlayan Pozisyonları Kapat (LvlGrid)      |
//+------------------------------------------------------------------+
bool ClosePositionsByCommentPrefix(string prefix)
{
   bool allOk = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         string comm = PositionGetString(POSITION_COMMENT);
         if(StringFind(comm, prefix) >= 0)
         {
            if(!ClosePositionByTicket(ticket)) allOk = false;
         }
      }
   }
   return allOk;
}

//+------------------------------------------------------------------+
//| Değişkenleri Sıfırla                                             |
//+------------------------------------------------------------------+
void ResetAllVariables()
{
   highestBasketProfit  = 0.0;
   lowestBasketProfit   = 0.0;
   levelGridDeployed    = false;
   nextLevelAttempt     = 0;
   harvestCycleCount    = 0;
}

//+------------------------------------------------------------------+
//| Pozisyon Maliyetleri                                             |
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
//| Sepetin Toplam Net Kâr/Zararı (Eski + Yeni TÜM İşlemler Toplamı)|
//+------------------------------------------------------------------+
double GetBasketNetProfit()
{
   double totalProfit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         ulong positionId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
         totalProfit += PositionGetDouble(POSITION_PROFIT)
                     +  PositionGetDouble(POSITION_SWAP)
                     +  GetPositionCosts(positionId);
      }
   }
   return totalProfit;
}

//+------------------------------------------------------------------+
//| SADECE YENİ GRİD ("LvlGrid") Emirlerinin Toplam Net Kâr/Zararı    |
//+------------------------------------------------------------------+
double GetSubGridNetProfit()
{
   double totalProfit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         string comm = PositionGetString(POSITION_COMMENT);
         if(StringFind(comm, "LvlGrid") >= 0)
         {
            ulong positionId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
            totalProfit += PositionGetDouble(POSITION_PROFIT)
                        +  PositionGetDouble(POSITION_SWAP)
                        +  GetPositionCosts(positionId);
         }
      }
   }
   return totalProfit;
}

//+------------------------------------------------------------------+
//| Sepet Kapatma Sürecini Başlat (Tüm Hesap Sıfırlanır)             |
//+------------------------------------------------------------------+
void StartBasketClose(string closeType, double netProfit)
{
   basketCloseRequested = true;
   pendingCloseType     = closeType;
   pendingCloseProfit   = netProfit;
   nextMassCloseAttempt = 0;
   levelGridDeployed    = false;
   nextLevelAttempt     = 0;
   harvestCycleCount    = 0;
}

//+------------------------------------------------------------------+
//| Sepet Kapatmayı İşle                                             |
//+------------------------------------------------------------------+
bool ProcessBasketClose()
{
   if(!basketCloseRequested) return false;
   if(TimeCurrent() >= nextMassCloseAttempt)
   {
      DeleteAllPendingOrders();
      CloseAllMyPositions();
      nextMassCloseAttempt = TimeCurrent() + InpMassCloseRetrySec;
   }
   if(CountMyPositions() == 0 && CountMyOrders() == 0)
   {
      Print(pendingCloseType, " tamamlandı | Net: $", DoubleToString(pendingCloseProfit, 2));
      ResetAllVariables();
      basketCloseRequested = false;
      pendingCloseType     = "";
      pendingCloseProfit   = 0.0;
      waitTimer = TimeCurrent() + InpRebuildDelaySec;
   }
   return true;
}

//+------------------------------------------------------------------+
//| SADECE YENİ GRİDİN KÂRINI AL VE BAĞIMSIZ HASAT ET (DÖNGÜ TEKRARI)|
//| (Eski grid işlemleri ve 15 Buy/Sell emirleri aynen korunur!)     |
//+------------------------------------------------------------------+
bool CheckSubGridProfitAndHarvest()
{
   if(!InpUseLevelTriggerGrid) return false;
   int lvlPosCount = CountMyPositionsByCommentPrefix("LvlGrid");
   if(lvlPosCount == 0) return false;
   
   double subNet = GetSubGridNetProfit();
   if(subNet >= InpSubGridTargetUSD)
   {
      harvestCycleCount++;
      PrintFormat(">>> %d. KEZ BAĞIMSIZ HASAT (SUB-GRID HARVEST) BAŞARILI! Sadece yeni LvlGrid emirleri +%.2f$ ile kapatılıyor, Eski Grid ve 15 Buy/Sell bekleyen emirleri yaşama devam ediyor! <<<",
                  harvestCycleCount, subNet);
                  
      // Sadece LvlGrid pozisyonlarını ve LvlGrid bekleyen emirlerini sil! Eski Grid (Buy 1..15, Sell 1..15) duruyor!
      ClosePositionsByCommentPrefix("LvlGrid");
      DeleteOrdersByCommentPrefix("LvlGrid");
      
      levelGridDeployed = false; // BAYRAĞI SIFIRLA! Fiyat tekrar veya hala 4. seviyedeyse 2., 3., 4. kez yeniden LvlGrid dizebilsin!
      nextLevelAttempt  = TimeCurrent() + InpLevelCooldownSec;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| SEVİYE 4 & ZARAR TETİKLİ GÜNCEL FİYATA YENİ ÇİFT YÖNLÜ GRİD      |
//| (Eski 15 Buy/Sell bekleyen emirleri KORUNUR, silinmez!)          |
//+------------------------------------------------------------------+
bool CheckAndDeployAdaptiveLevelGrid()
{
   if(!InpUseLevelTriggerGrid) return false;
   if(!IsTradingTimeAllowed()) return false;
   if(levelGridDeployed)       return false; // Şu an ekranda kurulu aktif LvlGrid varsa tekrar kurma
   if(CountMyOrdersByCommentPrefix("LvlGrid") > 0) return false; // Zaten aktif LvlGrid bekleyen emirleri varsa açma
   if(CountMyPositionsByCommentPrefix("LvlGrid") > 0) return false; // Zaten açık LvlGrid işlemi varsa açma
   
   int buyPositions  = CountMyPositionsByType(POSITION_TYPE_BUY);
   int sellPositions = CountMyPositionsByType(POSITION_TYPE_SELL);
   double netProfit  = GetBasketNetProfit();
   
   // Kural: Buy VEYA Sell tarafı 4. Seviyeye (InpLevelTriggerCount) ulaştıysa VEYA toplam 8 emir olduysa
   // VE Sepet Zararı belirlediğimiz eşiğin (Örn: -$2.0) altına indiyse
   bool levelReached = (buyPositions >= InpLevelTriggerCount || sellPositions >= InpLevelTriggerCount || (buyPositions + sellPositions) >= (InpLevelTriggerCount * 2));
   bool lossReached  = (netProfit <= -InpLevelTriggerMinLossUSD);
   
   if(levelReached && lossReached)
   {
      PrintFormat(">>> SEVİYE %d VE ZARAR (-%.2f$) TETİKLENDİ! Güncel fiyata yeni çift yönlü LvlGrid açılıyor... <<<",
                  InpLevelTriggerCount, MathAbs(netProfit));
                  
      // KULLANICI İSTEĞİ: Eğer InpPreserveOldGridOrders = false ise eski emirleri temizle,
      // TRUE ise (senin istediğin) ESKİ 15 BUY / 15 SELL BEKLEYEN EMİRLERİNE KESİNLİKLE DOKUNMA, KORU!
      if(!InpPreserveOldGridOrders)
      {
         DeleteAllPendingOrders();
      }
      else
      {
         // Sadece daha önceden arta kalmış eski bir LvlGrid bekleyen emri varsa onları temizle
         DeleteOrdersByCommentPrefix("LvlGrid");
      }
      
      // GÜNCEL FİYATA ÇİFT YÖNLÜ (BUY STOP + SELL STOP) YENİ GRİD DÖŞE
      double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      
      int tradeStops  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
      int minDistance = MathMax(tradeStops, freezeLevel) + 1;
      int stepPts     = MathMax(InpLevelGridStepPoints, minDistance);
      
      double lvlLot   = NormalizeVolume(currentDynamicLot * InpLevelGridLotMultiplier);
      int created     = 0;
      
      for(int i = 1; i <= InpLevelGridLevels; i++)
      {
         double buyPrice  = NormalizeDouble(ask + (i * stepPts * point), digits);
         double sellPrice = NormalizeDouble(bid - (i * stepPts * point), digits);
         
         if(PlacePendingOrder(ORDER_TYPE_BUY_STOP,  lvlLot, buyPrice,  "LvlGrid Buy " + IntegerToString(i)))
            created++;
         if(PlacePendingOrder(ORDER_TYPE_SELL_STOP, lvlLot, sellPrice, "LvlGrid Sell " + IntegerToString(i)))
            created++;
      }
      
      if(created > 0)
      {
         PrintFormat("GÜNCEL MERKEZLİ YENİ ÇİFT YÖNLÜ GRİD (LvlGrid) KURULDU! Adım: %d puan | Lot: %.2f | Emir: %d | Eski 15 Buy/Sell bekleyen emirleri korundu!",
                     stepPts, lvlLot, created);
         levelGridDeployed = true;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Sepet Kâr Kontrolü (TÜM İŞLEMLERİ KAPATAN BÜYÜK ANA HEDEF)       |
//+------------------------------------------------------------------+
void CheckBasketProfitAndReset()
{
   if(!InpUseBasketProfit && !InpUseBasketStopLoss) return;
   if(isOutsideTradingHours) return;
   
   int openPositions = CountMyPositions();
   if(openPositions == 0)
   {
      ResetAllVariables();
      return;
   }
   
   double totalProfit = GetBasketNetProfit();
   if(totalProfit > highestBasketProfit) highestBasketProfit = totalProfit;
   if(totalProfit < lowestBasketProfit)  lowestBasketProfit  = totalProfit;
   
   bool triggerClose = false;
   string closeType  = "";
   
   if(InpUseBasketStopLoss && totalProfit <= -InpBasketStopLossUSD)
   {
      triggerClose = true;
      closeType = "Basket Stop Loss";
   }
   else if(InpUseBasketProfit && !InpUseTrailingBasket && totalProfit >= InpBasketTargetUSD)
   {
      triggerClose = true;
      closeType = "Basket Sabit Hedef ($" + DoubleToString(InpBasketTargetUSD, 2) + ")";
   }
   else if(InpUseBasketProfit && InpUseTrailingBasket && highestBasketProfit >= InpBasketTargetUSD)
   {
      double lockLevel = MathMax(InpBasketTargetUSD, highestBasketProfit - InpBasketTrailingDrop);
      if(totalProfit <= lockLevel)
      {
         triggerClose = true;
         closeType = StringFormat("Basket Trailing | Peak=%.2f | Lock=%.2f", highestBasketProfit, lockLevel);
      }
   }
   
   if(triggerClose)
   {
      Print(closeType, " tetiklendi | Net: $", DoubleToString(totalProfit, 2));
      StartBasketClose(closeType, totalProfit);
   }
}

//+------------------------------------------------------------------+
//| Etkin Adım Mesafesi                                              |
//+------------------------------------------------------------------+
int GetEffectiveStepPoints()
{
   int tradeStops  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   int minDistance = MathMax(tradeStops, freezeLevel) + 1;
   return MathMax(InpStepPoints, minDistance);
}

//+------------------------------------------------------------------+
//| Ana Grid Emirlerini Yerleştir                                    |
//+------------------------------------------------------------------+
void PlaceGridOrders()
{
   if(!IsTradingTimeAllowed()) return;
   if(CountMyPositions() > 0 && InpOneGridAtATime) return;
   
   DeleteAllPendingOrders();
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int    stepPts = GetEffectiveStepPoints();
   int    created = 0;
   
   for(int i = 1; i <= InpGridLevels; i++)
   {
      double buyPrice  = NormalizeDouble(ask + (i * stepPts * point), digits);
      double sellPrice = NormalizeDouble(bid - (i * stepPts * point), digits);
      
      if(PlacePendingOrder(ORDER_TYPE_BUY_STOP, currentDynamicLot, buyPrice, "Buy " + IntegerToString(i)))
         created++;
      if(PlacePendingOrder(ORDER_TYPE_SELL_STOP, currentDynamicLot, sellPrice, "Sell " + IntegerToString(i)))
         created++;
   }
   Print(InpGridLevels, " seviye ana grid yerleştirildi | Etkin adım: ", stepPts,
         " | Lot: ", DoubleToString(currentDynamicLot, VolumeDigits()), " | Emir sayısı: ", created);
}

//+------------------------------------------------------------------+
//| OnTick Ana Döngü                                                 |
//+------------------------------------------------------------------+
void OnTick()
{
   IsTradingTimeAllowed();
   
   // 1. Topyekün kapanış talebi varsa işle
   if(ProcessBasketClose()) return;
   
   int posCount = CountMyPositions();
   if(posCount > 0)
   {
      // 2. ÖNCE: SADECE Yeni Kurulan LvlGrid Emirleri İstenen Bağımsız Kâra (+3.0$ vb.) Ulaştı Mı Kontrol Et!
      // (Ulaştıysa SADECE LvlGrid emirleri kapanır, Eski Grid emirleri ve 15 Buy/Sell bekleyenleri KORUNUR!)
      if(CheckSubGridProfitAndHarvest())
      {
         return; // Hasat yapıldı, bir sonraki ticke geç
      }
      
      // 3. SONRA: Buy veya Sell 4. Seviyeye geldiyse VE LvlGrid o an ekranda YOKSA taze LvlGrid aç!
      if(TimeCurrent() >= nextLevelAttempt)
      {
         CheckAndDeployAdaptiveLevelGrid();
         nextLevelAttempt = TimeCurrent() + InpLevelCooldownSec;
      }
   }
   
   // 4. Global Büyük Sepet Hedefi ($7.0 vb.) Kontrolü -> İstenen ana sepet karına gelince TÜM eski/yeni işlemleri topyekün kapatır!
   CheckBasketProfitAndReset();
   if(ProcessBasketClose()) return;
   
   int orderCount = CountMyOrders();
   if(TimeCurrent() < waitTimer) return;
   if(isOutsideTradingHours)     return;
   
   // 5. Ana Grid Kurulumu İçin Aralık Kontrolü (Sadece hiçbir pozisyon yoksa geçerlidir!)
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   if(CopyHigh(_Symbol, _Period, 1, InpCheckCandles, high) <= 0) return;
   if(CopyLow(_Symbol, _Period, 1, InpCheckCandles, low)   <= 0) return;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double rangePoints = (high[ArrayMaximum(high)] - low[ArrayMinimum(low)]) / point;
   
   if(posCount == 0 && orderCount == 0)
   {
      if(rangePoints < InpMinRangeLimit)
      {
         waitTimer = TimeCurrent() + (InpWaitMinutes * 60);
         return;
      }
      CalculateDynamicLot();
      PlaceGridOrders();
      waitTimer = TimeCurrent() + InpRebuildDelaySec;
   }
   
   previousPositionCount = posCount;
}

//+------------------------------------------------------------------+
//| EA OnDeinit                                                      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("GridEA v8.20 Preserve Main Grid kapatıldı. Reason=", reason);
}
//+------------------------------------------------------------------+
