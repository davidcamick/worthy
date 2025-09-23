//
//  ContentView.swift
//  worthy
//
//  Created by GitHub Copilot
//

import SwiftUI
import LocalAuthentication
import UIKit
import Security
import UserNotifications

// MARK: - Models

enum AssetType: String, Codable, CaseIterable, Identifiable {
    case stock, crypto, manual, liability
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stock: return "Stocks"
        case .crypto: return "Crypto"
        case .manual: return "Manual"
        case .liability: return "Liabilities"
        }
    }
    var systemImage: String {
        switch self {
        case .stock: return "chart.line.uptrend.xyaxis"
        case .crypto: return "bitcoinsign.circle"
        case .manual: return "tray.full"
        case .liability: return "creditcard"
        }
    }
}

struct Holding: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var type: AssetType
    var name: String
    var symbol: String? // e.g., AAPL or BTC
    var quantity: Double? // shares/coins for stock/crypto
    var manualValue: Double? // used for manual and liability
    var currentPrice: Double? // price per unit for stock/crypto
    var lastUpdated: Date?
    var notes: String?
    
    var value: Double {
        switch type {
        case .stock, .crypto:
            let qty = quantity ?? 0
            let price = currentPrice ?? 0
            return qty * price
        case .manual:
            return manualValue ?? 0
        case .liability:
            return -(manualValue ?? 0)
        }
    }
}

// MARK: - Subscriptions Models

enum BillingFrequency: Codable, Equatable, Identifiable, CaseIterable, Hashable {
    case weekly
    case monthly
    case custom(days: Int)
    
    var id: String {
        switch self {
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .custom(let d): return "custom_\(d)"
        }
    }
    
    static var allCases: [BillingFrequency] { [.weekly, .monthly, .custom(days: 30)] }
    
    var title: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .custom(let d): return "Every \(d) days"
        }
    }
    
    var days: Int {
        switch self {
        case .weekly: return 7
        case .monthly: return 30 // approx
        case .custom(let d): return max(1, d)
        }
    }
}

struct Subscription: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var amount: Double
    var frequencyDays: Int
    var nextDueDate: Date
    var paymentMethod: String?
    var notes: String?
    
    // Normalized cost estimations
    var dailyCost: Double { amount / Double(max(1, frequencyDays)) }
    var monthlyCost: Double { dailyCost * 30.4375 }
    var yearlyCost: Double { dailyCost * 365.0 }
}

// MARK: - Storage & Networking

final class PortfolioStore: ObservableObject {
    @Published var holdings: [Holding] = [] { didSet { persist() } }
    @Published var isRefreshing: Bool = false
    @Published var errorMessage: String?
    private let lastRefreshKey = "worthy.lastRefresh"
    
    private let storageKey = "worthy.holdings"
    private let coinListCacheKey = "worthy.coingecko.list"
    
    // Settings
    @AppStorage("worthy.currencySymbol") var currencySymbol: String = "$"
    @AppStorage("worthy.refreshHours") var refreshHours: Int = 6
    @AppStorage("worthy.biometricLock") var biometricLock: Bool = false
    @AppStorage("worthy.alphaVantageKey") var alphaVantageKey: String = ""
    @AppStorage("worthy.hasOnboarded") var hasOnboarded: Bool = false
    
    // MARK: Lifecycle
    init() {
        load()
    }
    
    func load() {
        if let data = KeychainHelper.load(key: storageKey) ?? UserDefaults.standard.data(forKey: storageKey) {
            do {
                let decoded = try JSONDecoder().decode([Holding].self, from: data)
                self.holdings = decoded
            } catch {
                self.holdings = []
            }
        }
    }
    
    private func persist() {
        do {
            let data = try JSONEncoder().encode(holdings)
            _ = KeychainHelper.save(data: data, for: storageKey)
        } catch {
            print("Persist error: \(error)")
        }
    }
    
    // MARK: - CRUD
    func add(_ holding: Holding) {
        holdings.append(holding)
    }
    func update(_ holding: Holding) {
        if let idx = holdings.firstIndex(where: { $0.id == holding.id }) {
            holdings[idx] = holding
        }
    }
    func delete(at offsets: IndexSet) {
        holdings.remove(atOffsets: offsets)
    }
    
    // MARK: - Calculations
    var netWorth: Double { holdings.map { $0.value }.reduce(0, +) }
    func total(for type: AssetType) -> Double { holdings.filter { $0.type == type }.map { $0.value }.reduce(0, +) }
    
    // MARK: - Refresh Prices
    func refreshPrices() {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        
        let toUpdate = holdings.enumerated().map { (idx: $0.offset, item: $0.element) }
        let group = DispatchGroup()
        var updated = holdings
        var firstError: String?
        
        for pair in toUpdate {
            switch pair.item.type {
            case .stock:
                if let sym = pair.item.symbol, !sym.isEmpty {
                    group.enter()
                    fetchStockPrice(symbol: sym) { result in
                        switch result {
                        case .success(let price):
                            DispatchQueue.main.async {
                                updated[pair.idx].currentPrice = price
                                updated[pair.idx].lastUpdated = Date()
                            }
                        case .failure(let err):
                            if firstError == nil { firstError = err.localizedDescription }
                        }
                        group.leave()
                    }
                }
            case .crypto:
                if let sym = pair.item.symbol, !sym.isEmpty {
                    group.enter()
                    fetchCryptoPrice(symbol: sym) { result in
                        switch result {
                        case .success(let price):
                            DispatchQueue.main.async {
                                updated[pair.idx].currentPrice = price
                                updated[pair.idx].lastUpdated = Date()
                            }
                        case .failure(let err):
                            if firstError == nil { firstError = err.localizedDescription }
                        }
                        group.leave()
                    }
                }
            case .manual, .liability:
                continue
            }
        }
        
        group.notify(queue: .main) {
            self.holdings = updated
            self.isRefreshing = false
            self.errorMessage = firstError
            self.markRefreshed()
            haptic(.success)
        }
    }

    // MARK: - Symbol Search
    struct Suggestion: Identifiable { let id = UUID(); let symbol: String; let name: String }
    func searchStocks(query: String, completion: @escaping ([Suggestion]) -> Void) {
        searchYahoo(query: query) { quotes in
            let allowed: Set<String> = ["EQUITY", "ETF", "MUTUALFUND"]
            let mapped = quotes.filter {
                if let qt = ($0["quoteType"] as? String)?.uppercased() { return allowed.contains(qt) }
                return false
            }
                .compactMap { q -> Suggestion? in
                    guard let sym = q["symbol"] as? String else { return nil }
                    let name = (q["shortname"] as? String) ?? (q["longname"] as? String) ?? sym
                    return Suggestion(symbol: sym, name: name)
                }
            completion(Array(mapped.prefix(10)))
        }
    }
    func searchCrypto(query: String, completion: @escaping ([Suggestion]) -> Void) {
        searchYahoo(query: query) { quotes in
            let mapped = quotes.filter { ($0["quoteType"] as? String)?.uppercased() == "CRYPTOCURRENCY" }
                .compactMap { q -> Suggestion? in
                    guard let sym = q["symbol"] as? String else { return nil }
                    let base = sym.contains("-") ? String(sym.split(separator: "-").first!) : sym
                    let name = (q["shortname"] as? String) ?? (q["longname"] as? String) ?? base
                    return Suggestion(symbol: base.uppercased(), name: name)
                }
            completion(Array(mapped.prefix(10)))
        }
    }
    private func searchYahoo(query: String, completion: @escaping ([[String: Any]]) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { completion([]); return }
        guard var comps = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search") else { completion([]); return }
        comps.queryItems = [
            .init(name: "q", value: trimmed),
            .init(name: "lang", value: "en-US"),
            .init(name: "region", value: "US"),
            .init(name: "quotesCount", value: "10"),
            .init(name: "newsCount", value: "0")
        ]
        guard let url = comps.url else { completion([]); return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Worthy/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let quotes = json["quotes"] as? [[String: Any]] else { return completion([]) }
            DispatchQueue.main.async { completion(quotes) }
        }.resume()
    }
    
    private func fetchStockPrice(symbol: String, completion: @escaping (Result<Double, Error>) -> Void) {
        fetchYahooQuotePrice(symbol: symbol, completion: completion)
    }
    
    private func fetchCryptoPrice(symbol: String, completion: @escaping (Result<Double, Error>) -> Void) {
        // Use Yahoo Finance with USD pairing (e.g., BTC -> BTC-USD)
        let ySymbol = symbol.contains("-") ? symbol : "\(symbol.uppercased())-USD"
        fetchYahooQuotePrice(symbol: ySymbol, completion: completion)
    }

    private func fetchYahooQuotePrice(symbol: String, completion: @escaping (Result<Double, Error>) -> Void) {
        guard var comps = URLComponents(string: "https://query1.finance.yahoo.com/v7/finance/quote") else { return }
        comps.queryItems = [.init(name: "symbols", value: symbol)]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Worthy/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error = error { return completion(.failure(error)) }
            guard let data = data else { return completion(.failure(NSError(domain: "noData", code: -1))) }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let qr = json["quoteResponse"] as? [String: Any],
                   let results = qr["result"] as? [[String: Any]],
                   let first = results.first {
                    if let price = first["regularMarketPrice"] as? Double {
                        completion(.success(price))
                        return
                    }
                    if let any = first["regularMarketPrice"] as Any?, let n = any as? NSNumber {
                        completion(.success(n.doubleValue))
                        return
                    }
                }
                // Try chart fallback when quote doesn't give a price
                self.fetchYahooChartPrice(symbol: symbol, completion: completion)
            } catch {
                self.fetchYahooChartPrice(symbol: symbol, completion: completion)
            }
        }.resume()
    }

    private func fetchYahooChartPrice(symbol: String, completion: @escaping (Result<Double, Error>) -> Void) {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=1d&interval=1d") else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Worthy/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error = error { return completion(.failure(error)) }
            guard let data = data else { return completion(.failure(NSError(domain: "noData", code: -1))) }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let chart = json["chart"] as? [String: Any],
                   let results = chart["result"] as? [[String: Any]],
                   let first = results.first {
                    if let meta = first["meta"] as? [String: Any], let p = meta["regularMarketPrice"] as? Double {
                        completion(.success(p))
                        return
                    }
                    if let indicators = first["indicators"] as? [String: Any],
                       let quotes = indicators["quote"] as? [[String: Any]],
                       let q = quotes.first,
                       let closes = q["close"] as? [Double],
                       let last = closes.last(where: { $0.isFinite }) {
                        completion(.success(last))
                        return
                    }
                }
                completion(.failure(NSError(domain: "parseError", code: -2, userInfo: [NSLocalizedDescriptionKey: "Yahoo chart parse error for \(symbol)"])))
            } catch { completion(.failure(error)) }
        }.resume()
    }
    
    // CoinGecko resolution removed – Yahoo quote endpoint used for both stocks and crypto
    
    // MARK: - Refresh bookkeeping
    private func markRefreshed() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastRefreshKey)
    }
    func lastRefreshDate() -> Date? {
        let t = UserDefaults.standard.double(forKey: lastRefreshKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    func needsRefresh(intervalHours: Int) -> Bool {
        guard intervalHours > 0 else { return true }
        guard let last = lastRefreshDate() else { return true }
        let next = last.addingTimeInterval(TimeInterval(intervalHours) * 3600)
        return Date() >= next
    }
}

final class SubscriptionStore: ObservableObject {
    @Published var subscriptions: [Subscription] = [] { didSet { persist() } }
    @Published var paymentMethods: [String] = ["Credit Card", "Debit"] { didSet { persist() } }
    @Published var notificationsEnabled: Bool = false { didSet { if notificationsEnabled { requestNotificationAuth() } else { cancelAllNotifications() } } }
    @Published var reminderDaysBefore: Int = 3 { didSet { rescheduleAllNotifications() } }
    
    private let subsKey = "worthy.subscriptions"
    private let payMethodsKey = "worthy.paymentMethods"
    private let notifEnabledKey = "worthy.subs.notificationsEnabled"
    private let notifDaysKey = "worthy.subs.reminderDays"
    
    init() { load() }
    
    // Persistence
    private func load() {
        // subscriptions
        if let data = KeychainHelper.load(key: subsKey) ?? UserDefaults.standard.data(forKey: subsKey) {
            if let decoded = try? JSONDecoder().decode([Subscription].self, from: data) { self.subscriptions = decoded }
        }
        if let methodsData = KeychainHelper.load(key: payMethodsKey) ?? UserDefaults.standard.data(forKey: payMethodsKey) {
            if let decoded = try? JSONDecoder().decode([String].self, from: methodsData), !decoded.isEmpty { self.paymentMethods = decoded }
        }
        self.notificationsEnabled = UserDefaults.standard.bool(forKey: notifEnabledKey)
        let days = UserDefaults.standard.integer(forKey: notifDaysKey)
        if days > 0 { self.reminderDaysBefore = days }
        if notificationsEnabled { requestNotificationAuth() }
    }
    
    private func persist() {
        if let data = try? JSONEncoder().encode(subscriptions) { _ = KeychainHelper.save(data: data, for: subsKey) }
        if let data = try? JSONEncoder().encode(paymentMethods) { _ = KeychainHelper.save(data: data, for: payMethodsKey) }
        UserDefaults.standard.set(notificationsEnabled, forKey: notifEnabledKey)
        UserDefaults.standard.set(reminderDaysBefore, forKey: notifDaysKey)
    }
    
    // CRUD
    func add(_ sub: Subscription) { subscriptions.append(sub); scheduleNotification(for: sub) }
    func update(_ sub: Subscription) {
        if let idx = subscriptions.firstIndex(where: { $0.id == sub.id }) {
            subscriptions[idx] = sub
            scheduleNotification(for: sub)
        }
    }
    func delete(at offsets: IndexSet) {
        let ids = offsets.map { subscriptions[$0].id }
        subscriptions.remove(atOffsets: offsets)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids.map { notifId(for: $0) })
    }
    
    // Aggregations
    var totalDaily: Double { subscriptions.map { $0.dailyCost }.reduce(0, +) }
    var totalMonthly: Double { subscriptions.map { $0.monthlyCost }.reduce(0, +) }
    var totalYearly: Double { subscriptions.map { $0.yearlyCost }.reduce(0, +) }
    
    func totalMonthly(by method: String?) -> Double {
        subscriptions.filter { ($0.paymentMethod ?? "Unspecified") == (method ?? "Unspecified") }.map { $0.monthlyCost }.reduce(0, +)
    }
    
    var methodsWithTotalsMonthly: [(method: String, total: Double)] {
        let all = Set(subscriptions.map { $0.paymentMethod ?? "Unspecified" }).union(paymentMethods)
        return all.map { ($0, totalMonthly(by: $0)) }.sorted { $0.total > $1.total }
    }
    
    var topSubscriptionsByMonthly: [Subscription] {
        subscriptions.sorted { $0.monthlyCost > $1.monthlyCost }
    }
    
    // Notifications
    private func requestNotificationAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            DispatchQueue.main.async {
                if self.notificationsEnabled != granted { self.notificationsEnabled = granted }
            }
            if granted { self.rescheduleAllNotifications() }
        }
    }
    
    private func notifId(for id: UUID) -> String { "subscription_\(id.uuidString)" }
    
    func scheduleNotification(for sub: Subscription) {
        guard notificationsEnabled else { return }
        let triggerDate = Calendar.current.date(byAdding: .day, value: -max(0, reminderDaysBefore), to: sub.nextDueDate) ?? sub.nextDueDate
        guard triggerDate > Date() else { return } // don't schedule past
        let content = UNMutableNotificationContent()
        content.title = "Upcoming: \(sub.name)"
        content.body = String(format: "Due on %@ for $%.2f", formattedDate(sub.nextDueDate), sub.amount)
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: triggerDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let req = UNNotificationRequest(identifier: notifId(for: sub.id), content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
    
    func rescheduleAllNotifications() {
        guard notificationsEnabled else { return }
        // Advance any past-due subscriptions forward to the next cycle
        advancePastDueSubscriptions()
        cancelAllNotifications()
        subscriptions.forEach { scheduleNotification(for: $0) }
    }
    
    func cancelAllNotifications() {
        let ids = subscriptions.map { notifId(for: $0.id) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
    
    private func formattedDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: d)
    }
    
    private func advancePastDueSubscriptions() {
        let now = Date()
        var changed = false
        let cal = Calendar.current
        for i in subscriptions.indices {
            while subscriptions[i].nextDueDate < now {
                if let newDate = cal.date(byAdding: .day, value: max(1, subscriptions[i].frequencyDays), to: subscriptions[i].nextDueDate) {
                    subscriptions[i].nextDueDate = newDate
                    changed = true
                } else { break }
            }
        }
        if changed { persist() }
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var store = PortfolioStore()
    @StateObject private var subStore = SubscriptionStore()
    @State private var showingAdd = false
    @State private var editingHolding: Holding? = nil
    @State private var showingSettings = false
    @State private var showShare = false
    @State private var shareDataURL: URL? = nil
    @State private var isUnlocked: Bool = true
    @State private var alertError: SimpleError? = nil
    @State private var page: Int = 0
    
    var body: some View {
        ZStack {
            SpaceBackground()
                .ignoresSafeArea()
            TabView(selection: $page) {
                    // Home
                    NavigationView {
                        HomeView()
                            .environmentObject(store)
                            .environmentObject(subStore)
                    }
                    .tag(0)
                    
                    // Assets
                    NavigationView {
                        Group {
                            if isUnlocked { content } else { lockScreen }
                        }
                        .navigationTitle("Assets")
                        .toolbar {
                            ToolbarItemGroup(placement: .navigationBarTrailing) {
                                Button(action: { store.refreshPrices() }) {
                                    if store.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                                }
                                Button(action: { showingSettings = true }) { Image(systemName: "gearshape") }
                                Button(action: { exportData() }) { Image(systemName: "square.and.arrow.up") }
                                Button(action: { showingAdd = true }) { Image(systemName: "plus.circle.fill") }
                            }
                        }
                        .sheet(isPresented: $showingAdd) {
                            AddOrEditHoldingView(holding: nil) { newHolding in
                                store.add(newHolding)
                                if newHolding.type == .stock || newHolding.type == .crypto { store.refreshPrices() }
                                showingAdd = false
                            }
                            .environmentObject(store)
                        }
                        .sheet(item: $editingHolding) { hold in
                            AddOrEditHoldingView(holding: hold) { updated in
                                store.update(updated)
                                if updated.type == .stock || updated.type == .crypto { store.refreshPrices() }
                                editingHolding = nil
                            }
                            .environmentObject(store)
                        }
                        .sheet(isPresented: $showingSettings) { SettingsView().environmentObject(store) }
                        .sheet(isPresented: $showShare, onDismiss: { shareDataURL = nil }) {
                            if let url = shareDataURL { ActivityView(activityItems: [url]) } else { Text("Nothing to share") }
                        }
                        .onAppear {
                            authenticateIfNeeded()
                            if store.needsRefresh(intervalHours: store.refreshHours) { store.refreshPrices() }
                        }
                        .onChange(of: store.errorMessage) { _, newValue in if let msg = newValue { alertError = SimpleError(message: msg) } }
                        .alert(item: $alertError) { err in Alert(title: Text("Error"), message: Text(err.message), dismissButton: .default(Text("OK"))) }
                    }
                    .navigationViewStyle(StackNavigationViewStyle())
                    .tag(1)
                    
                    // Subscriptions
                    NavigationView {
                        SubscriptionsView()
                            .environmentObject(subStore)
                            .environmentObject(store)
                    }
                    .tag(2)
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            .animation(.spring(response: 0.4, dampingFraction: 0.9), value: page)
        }
        .safeAreaInset(edge: .bottom) {
            GlassDock(selection: $page)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .tint(.cyan)
    }
    
    private var content: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Net Worth")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text(formatCurrency(store.netWorth))
                        .font(.system(size: 40, weight: .bold))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    BreakdownBar(values: breakdownValues, colors: breakdownColors)
                        .frame(height: 12)
                        .clipShape(Capsule())
                        .padding(.top, 6)
                }.padding(.vertical, 6)
            }
            
            ForEach(AssetType.allCases) { type in
                let total = store.total(for: type)
                if abs(total) > 0.0001 || store.holdings.contains(where: { $0.type == type }) {
                    Section(header: HStack {
                        Image(systemName: type.systemImage)
                        Text("\(type.title) • \(formatCurrency(total))")
                    }) {
                        let filtered = store.holdings.filter { $0.type == type }
                        ForEach(filtered) { holding in
                            Button(action: { editingHolding = holding }) {
                                HoldingRow(holding: holding, currencySymbol: store.currencySymbol)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { filtered[$0].id }
                            store.holdings.removeAll { ids.contains($0.id) }
                            haptic(.warning)
                        }
                    }
                }
            }
        }
    .listStyle(InsetGroupedListStyle())
    .scrollBackgroundHiddenCompat()
        .overlay(alignment: .bottom) {
            if !store.hasOnboarded {
                OnboardingView { store.hasOnboarded = true }
                    .transition(.move(edge: .bottom))
            }
        }
    }
    
    private var lockScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.circle")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("Locked")
                .font(.title2)
            Button("Unlock") { authenticateIfNeeded(force: true) }
                .buttonStyle(.borderedProminent)
        }
    }
    
    private var breakdownValues: [Double] {
        AssetType.allCases.map { max(0, store.total(for: $0)) }
    }
    private var breakdownColors: [Color] { [.blue, .orange, .green, .red] }
    
    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = store.currencySymbol
        return formatter.string(from: NSNumber(value: value)) ?? "\(store.currencySymbol)0"
    }
    
    private func authenticateIfNeeded(force: Bool = false) {
        guard store.biometricLock else { isUnlocked = true; return }
        if !force && !isUnlocked { return }
        if store.biometricLock { isUnlocked = false }
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) ||
            context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            let reason = "Unlock Worthy"
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                DispatchQueue.main.async { self.isUnlocked = success }
            }
        } else {
            // Fallback: no biometrics, unlock
            isUnlocked = true
        }
    }
    
    // Legacy stub no longer used
    private func shouldAutoRefresh() -> Bool { store.needsRefresh(intervalHours: store.refreshHours) }
    
    private func exportData() {
        do {
            let data = try JSONEncoder().encode(store.holdings)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("worthy_export.json")
            try data.write(to: url, options: .atomic)
            shareDataURL = url
            showShare = true
            haptic(.success)
        } catch {
            // ignore silently
        }
    }
}

// MARK: - Subviews

struct HoldingRow: View {
    let holding: Holding
    let currencySymbol: String
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundColor(color)
                    Text(holding.name)
                        .font(.headline)
                    if let sym = holding.symbol, !sym.isEmpty {
                        Text(sym).foregroundColor(.secondary)
                    }
                }
                if let qty = holding.quantity, holding.type != .manual && holding.type != .liability {
                    Text("\(qty) @ \(currencySymbol)\(String(format: "%.2f", holding.currentPrice ?? 0))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if holding.type == .liability || holding.type == .manual {
                    Text("Balance: \(currencySymbol)\(String(format: "%.2f", abs(holding.manualValue ?? 0)))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Text(valueString)
                .font(.headline)
                .foregroundColor(holding.value >= 0 ? .primary : .red)
        }
        .padding(.vertical, 4)
    }
    private var icon: String {
        switch holding.type {
        case .stock: return "chart.line.uptrend.xyaxis"
        case .crypto: return "bitcoinsign.circle"
        case .manual: return "tray.full"
        case .liability: return "creditcard"
        }
    }
    private var color: Color {
        switch holding.type {
        case .stock: return .blue
        case .crypto: return .orange
        case .manual: return .green
        case .liability: return .red
        }
    }
    private var valueString: String {
        let v = holding.value
        let sign = v < 0 ? "-" : ""
        return "\(sign)\(currencySymbol)\(String(format: "%.2f", abs(v)))"
    }
}

// MARK: - Subscriptions Views

struct SubscriptionsView: View {
    @EnvironmentObject var subStore: SubscriptionStore
    @EnvironmentObject var store: PortfolioStore
    @State private var showingAdd = false
    @State private var editing: Subscription? = nil
    
    var body: some View {
        List {
            Section(header: Text("Summary")) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        statView(title: "Daily", value: store.currencySymbol + String(format: "%.2f", subStore.totalDaily))
                        Spacer()
                        statView(title: "Monthly", value: store.currencySymbol + String(format: "%.2f", subStore.totalMonthly))
                        Spacer()
                        statView(title: "Yearly", value: store.currencySymbol + String(format: "%.2f", subStore.totalYearly))
                    }
                    .padding(.vertical, 4)
                    Text("By Payment Method")
                        .font(.subheadline).foregroundColor(.secondary)
                    BreakdownBar(values: subStore.methodsWithTotalsMonthly.map { $0.total }, colors: [.purple, .blue, .green, .orange, .pink, .teal, .red])
                        .frame(height: 10)
                        .clipShape(Capsule())
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(subStore.methodsWithTotalsMonthly, id: \.method) { item in
                                VStack(alignment: .leading) {
                                    Text(item.method)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(store.currencySymbol + String(format: "%.2f", item.total))
                                        .font(.headline)
                                }
                                .padding(8)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }
            
            Section(header: HStack { Image(systemName: "bell"); Text("Notifications") }) {
                Toggle("Enable reminders", isOn: $subStore.notificationsEnabled)
                Stepper("Remind \(subStore.reminderDaysBefore) day(s) before", value: $subStore.reminderDaysBefore, in: 0...14)
            }
            
            if !subStore.topSubscriptionsByMonthly.isEmpty {
                Section(header: Text("Subscriptions (Highest Monthly First)")) {
                    ForEach(subStore.topSubscriptionsByMonthly) { sub in
                        Button(action: { editing = sub }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Image(systemName: "repeat")
                                            .foregroundColor(.blue)
                                        Text(sub.name).font(.headline)
                                        if let method = sub.paymentMethod, !method.isEmpty {
                                            Text("• \(method)").foregroundColor(.secondary)
                                        }
                                    }
                                    Text("Due: " + formattedDate(sub.nextDueDate))
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(store.currencySymbol + String(format: "%.2f", sub.amount))
                                        .font(.headline)
                                    Text("~ " + store.currencySymbol + String(format: "%.2f/mo", sub.monthlyCost))
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .onDelete(perform: subStore.delete)
                }
            }
        }
    .listStyle(InsetGroupedListStyle())
    .scrollBackgroundHiddenCompat()
        .navigationTitle("Subscriptions")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showingAdd = true }) { Image(systemName: "plus.circle.fill") }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddOrEditSubscriptionView(subscription: nil) { created in
                subStore.add(created)
                showingAdd = false
            }
            .environmentObject(subStore)
            .environmentObject(store)
        }
        .sheet(item: $editing) { sub in
            AddOrEditSubscriptionView(subscription: sub) { updated in
                subStore.update(updated)
                editing = nil
            }
            .environmentObject(subStore)
            .environmentObject(store)
        }
    }
    
    private func statView(title: String, value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.headline)
        }
    }
    private func formattedDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; return f.string(from: d)
    }
}

struct AddOrEditSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var subStore: SubscriptionStore
    @EnvironmentObject var store: PortfolioStore
    
    @State private var name: String = ""
    @State private var amountText: String = ""
    @State private var frequency: BillingFrequency = .monthly
    @State private var customDaysText: String = "30"
    @State private var nextDueDate: Date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var paymentMethod: String = ""
    @State private var notes: String = ""
    @State private var showAddMethodAlert = false
    @State private var newMethodText: String = ""
    
    let subscription: Subscription?
    let onSave: (Subscription) -> Void
    
    init(subscription: Subscription?, onSave: @escaping (Subscription) -> Void) {
        self.subscription = subscription
        self.onSave = onSave
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Details")) {
                    TextField("Name", text: $name)
                    HStack {
                        Text("Amount")
                        Spacer()
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                    }
                    Picker("Frequency", selection: $frequency) {
                        Text("Weekly").tag(BillingFrequency.weekly)
                        Text("Monthly").tag(BillingFrequency.monthly)
                        Text("Custom").tag(BillingFrequency.custom(days: Int(customDaysText) ?? 30))
                    }
                    if case .custom = frequency {
                        HStack {
                            Text("Every")
                            TextField("Days", text: $customDaysText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 80)
                            Text("day(s)")
                            Spacer()
                        }
                    }
                    DatePicker("Next due date", selection: $nextDueDate, displayedComponents: [.date])
                }
                
                Section(header: Text("Payment Method")) {
                    Picker("Method", selection: $paymentMethod) {
                        ForEach(subStore.paymentMethods, id: \.self) { m in Text(m).tag(m) }
                        Text("Unspecified").tag("")
                        Text("+ Add new…").tag("__add_new__")
                    }
                    .onChange(of: paymentMethod) { _, newVal in
                        if newVal == "__add_new__" { newMethodText = ""; showAddMethodAlert = true; paymentMethod = "" }
                    }
                }
                
                Section(header: Text("Notes")) {
                    TextField("Optional notes", text: $notes)
                }
            }
            .navigationTitle(subscription == nil ? "Add Subscription" : "Edit Subscription")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
            }
            .onAppear { populateFromExisting() }
            .alert("Add Payment Method", isPresented: $showAddMethodAlert) {
                TextField("Method name", text: $newMethodText)
                Button("Add") { addMethod() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("e.g., Credit Card, Debit, PayPal")
            }
        }
    }
    
    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard Double(amountText) != nil else { return false }
        if case .custom = frequency { return Int(customDaysText) ?? 0 > 0 }
        return true
    }
    
    private func populateFromExisting() {
        if let s = subscription {
            name = s.name
            amountText = String(format: "%.2f", s.amount)
            if s.frequencyDays == 7 { frequency = .weekly }
            else if s.frequencyDays == 30 { frequency = .monthly }
            else { frequency = .custom(days: s.frequencyDays); customDaysText = String(s.frequencyDays) }
            nextDueDate = s.nextDueDate
            paymentMethod = s.paymentMethod ?? ""
            notes = s.notes ?? ""
        }
    }
    
    private func save() {
        let amt = Double(amountText) ?? 0
        let days: Int
        switch frequency {
        case .weekly: days = 7
        case .monthly: days = 30
        case .custom: days = max(1, Int(customDaysText) ?? 30)
        }
        var new = subscription ?? Subscription(name: name, amount: amt, frequencyDays: days, nextDueDate: nextDueDate, paymentMethod: paymentMethod.isEmpty ? nil : paymentMethod, notes: notes.isEmpty ? nil : notes)
        new.name = name
        new.amount = amt
        new.frequencyDays = days
        new.nextDueDate = nextDueDate
        new.paymentMethod = paymentMethod.isEmpty ? nil : paymentMethod
        new.notes = notes.isEmpty ? nil : notes
        onSave(new)
        haptic(.success)
        dismiss()
    }
    
    private func addMethod() {
        let trimmed = newMethodText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !subStore.paymentMethods.contains(trimmed) {
            subStore.paymentMethods.append(trimmed)
        }
        paymentMethod = trimmed
    }
}

// MARK: - Home View

struct HomeView: View {
    @EnvironmentObject var store: PortfolioStore
    @EnvironmentObject var subStore: SubscriptionStore
    
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Worthy").font(.title3).bold()
                    Text("Your money isn't your worth. You're already worthy. This app helps you see your finances clearly.")
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            }
            
            Section(header: Text("Investments Overview")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Net Worth").foregroundColor(.secondary)
                        Spacer()
                        Text(formatCurrency(store.netWorth))
                            .font(.headline)
                    }
                    BreakdownBar(values: AssetType.allCases.map { max(0, store.total(for: $0)) }, colors: [.blue, .orange, .green, .red])
                        .frame(height: 12)
                        .clipShape(Capsule())
                }
                .padding(.vertical, 4)
            }
            
            Section(header: Text("Subscriptions Overview")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Monthly Total").foregroundColor(.secondary)
                        Spacer()
                        Text(formatCurrency(subStore.totalMonthly))
                            .font(.headline)
                    }
                    BreakdownBar(values: subStore.methodsWithTotalsMonthly.map { $0.total }, colors: [.purple, .blue, .green, .orange, .pink, .teal, .red])
                        .frame(height: 12)
                        .clipShape(Capsule())
                    if let top = subStore.topSubscriptionsByMonthly.first {
                        Text("Top: \(top.name) ~ " + formatCurrency(top.monthlyCost))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    .listStyle(InsetGroupedListStyle())
    .scrollBackgroundHiddenCompat()
        .navigationTitle("Home")
    }
    
    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencySymbol = store.currencySymbol; return formatter.string(from: NSNumber(value: value)) ?? "\(store.currencySymbol)0"
    }
}

struct BreakdownBar: View {
    let values: [Double]
    let colors: [Color]
    private var sanitizedValues: [Double] {
        values.map { v in
            guard v.isFinite else { return 0 }
            return max(0, v)
        }
    }
    private var total: Double {
        let t = sanitizedValues.reduce(0, +)
        return t > 0 ? t : 0.0001
    }
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(sanitizedValues.indices, id: \.self) { idx in
                    let ratio = sanitizedValues[idx] / total
                    let safe = ratio.isFinite ? max(0, ratio) : 0
                    Rectangle()
                        .fill(colors[idx % colors.count])
                        .frame(width: CGFloat(safe) * geo.size.width)
                }
            }
        }
    }
}

struct AddOrEditHoldingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: PortfolioStore
    
    @State private var type: AssetType = .stock
    @State private var name: String = ""
    @State private var symbol: String = ""
    @State private var quantity: String = ""
    @State private var manualValue: String = ""
    @State private var notes: String = ""
    @State private var searchQuery: String = ""
    @State private var suggestions: [PortfolioStore.Suggestion] = []
    @State private var pendingSearchWorkItem: DispatchWorkItem?
    
    let holding: Holding?
    let onSave: (Holding) -> Void
    
    init(holding: Holding?, onSave: @escaping (Holding) -> Void) {
        self.holding = holding
        self.onSave = onSave
        // _state initializers will be set in body via onAppear
    }
    
    var body: some View {
        NavigationView {
            Form {
                Picker("Type", selection: $type) {
                    ForEach(AssetType.allCases) { t in
                        Label(t.title, systemImage: t.systemImage).tag(t)
                    }
                }
                TextField("Name", text: $name)
                if type == .stock || type == .crypto {
                    TextField(type == .crypto ? "Search crypto (e.g., BTC, ETH)" : "Search symbol or name", text: $searchQuery)
                        .onChange(of: searchQuery) { _, q in scheduleSearch(q) }
                    if !suggestions.isEmpty {
                        Section(header: Text("Suggestions")) {
                            ForEach(suggestions) { s in
                                Button(action: {
                                    symbol = s.symbol
                                    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = s.name }
                                    searchQuery = ""
                                    suggestions = []
                                }) {
                                    HStack { Text(s.symbol).bold(); Text(s.name).foregroundColor(.secondary) }
                                }
                            }
                        }
                    }
                    TextField(type == .crypto ? "Symbol (e.g., BTC)" : "Symbol (e.g., AAPL)", text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Quantity", text: $quantity)
                        .keyboardType(.decimalPad)
                }
                if type == .manual || type == .liability {
                    TextField("Current Balance", text: $manualValue)
                        .keyboardType(.decimalPad)
                }
                TextField("Notes (optional)", text: $notes)
            }
            .navigationTitle(holding == nil ? "Add Asset" : "Edit Asset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
            }
            .onAppear { populateFromExisting() }
        }
    }
    
    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch type {
        case .stock, .crypto:
            return !symbol.trimmingCharacters(in: .whitespaces).isEmpty && Double(quantity) != nil
        case .manual, .liability:
            return Double(manualValue) != nil
        }
    }
    
    private func populateFromExisting() {
        if let h = holding {
            type = h.type
            name = h.name
            symbol = h.symbol ?? ""
            if let q = h.quantity { quantity = String(q) }
            if let mv = h.manualValue { manualValue = String(mv) }
            notes = h.notes ?? ""
        }
    }
    
    private func save() {
        var new = holding ?? Holding(type: type, name: name, symbol: nil, quantity: nil, manualValue: nil, currentPrice: nil, lastUpdated: nil, notes: nil)
        new.type = type
        new.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .stock, .crypto:
            new.symbol = symbol.uppercased()
            new.quantity = Double(quantity) ?? 0
            new.manualValue = nil
        case .manual, .liability:
            new.symbol = nil
            new.quantity = nil
            new.manualValue = Double(manualValue) ?? 0
        }
        new.notes = notes.isEmpty ? nil : notes
        onSave(new)
        haptic(.success)
        dismiss()
    }
    private func scheduleSearch(_ q: String) {
        pendingSearchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak store] in
            guard let store = store else { return }
            switch type {
            case .stock:
                store.searchStocks(query: q) { self.suggestions = $0 }
            case .crypto:
                store.searchCrypto(query: q) { self.suggestions = $0 }
            case .manual, .liability:
                self.suggestions = []
            }
        }
        pendingSearchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: PortfolioStore
    @State private var currency: String = "$"
    @State private var hours: Int = 6
    @State private var biometrics: Bool = false
    @State private var apiKey: String = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("General")) {
                    Picker("Currency", selection: $currency) {
                        Text("$ USD").tag("$")
                        Text("€ EUR").tag("€")
                        Text("£ GBP").tag("£")
                        Text("¥ JPY").tag("¥")
                    }
                    Stepper("Refresh every \(hours)h", value: $hours, in: 1...48)
                    Toggle("Require Face ID/Touch ID", isOn: $biometrics)
                }
                Section(header: Text("APIs"), footer: Text("Quotes and search by Yahoo Finance public endpoints. No key required.")) {
                    SecureField("Alpha Vantage API Key", text: $apiKey)
                }
                Section(footer: Text("Your data stays on device.")) {
                    Button(role: .destructive) { resetAllData() } label: { Text("Reset/Clear All Data") }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { apply() } }
            }
            .onAppear { load() }
        }
    }
    private func load() {
        currency = store.currencySymbol
        hours = store.refreshHours
        biometrics = store.biometricLock
        apiKey = store.alphaVantageKey
    }
    private func apply() {
        store.currencySymbol = currency
        store.refreshHours = hours
        store.biometricLock = biometrics
        store.alphaVantageKey = apiKey
        dismiss()
    }
    private func resetAllData() {
        store.holdings = []
        store.hasOnboarded = false
    }
}

struct OnboardingView: View {
    var onDone: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome to Worthy")
                .font(.title2).bold()
            Text("Add assets with +, refresh prices with ⟳, manage settings with ⚙︎. Your data stays on device.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button("Get started") { onDone() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial)
    }
}

struct SimpleError: Identifiable { let id = UUID(); let message: String }

// UIKit share sheet wrapper
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Feedback
func haptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
    UINotificationFeedbackGenerator().notificationOccurred(type)
}

// MARK: - Keychain Helper
enum KeychainHelper {
    private static let service = "com.worthy.app"
    static func save(data: Data, for key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    static func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }
}

// MARK: - Space Theme UI Additions

// Animated, layered space background with gradients, stars and subtle parallax
struct SpaceBackground: View {
    @State private var animate = false
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let maxDim = max(w, h)
            ZStack {
                // Deep space gradient, sized to fill
                AngularGradient(gradient: Gradient(colors: [Color.black, Color(hue: 0.64, saturation: 0.45, brightness: 0.25), Color.black, Color(hue: 0.78, saturation: 0.5, brightness: 0.28), .black]), center: .center)
                    .opacity(0.85)
                    .blur(radius: maxDim * 0.12)
                    .frame(width: w, height: h)

                // Nebula blobs (relative sizing/position)
                Circle()
                    .fill(LinearGradient(colors: [Color.purple.opacity(0.35), Color.blue.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: maxDim * 0.6, height: maxDim * 0.6)
                    .offset(x: -w * 0.35, y: -h * 0.35)
                    .blur(radius: maxDim * 0.08)
                    .blendMode(.screen)
                Circle()
                    .fill(LinearGradient(colors: [Color.cyan.opacity(0.25), Color.mint.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                    .frame(width: maxDim * 0.65, height: maxDim * 0.65)
                    .offset(x: w * 0.33, y: h * 0.3)
                    .blur(radius: maxDim * 0.1)
                    .blendMode(.screen)

                Starfield(layerCount: 3)
                    .opacity(0.9)

                // Slow moving aurora sweep
                RoundedRectangle(cornerRadius: maxDim * 0.35)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.05), Color.cyan.opacity(0.12), Color.clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: maxDim * 1.2, height: max(h * 0.5, 380))
                    .rotationEffect(.degrees(animate ? 8 : -8))
                    .offset(x: animate ? -w * 0.15 : w * 0.15, y: -h * 0.45)
                    .blur(radius: maxDim * 0.05)
                    .animation(.easeInOut(duration: 10).repeatForever(autoreverses: true), value: animate)
            }
            .frame(width: w, height: h)
            .background(Color.black)
            .onAppear { animate = true }
        }
    }
}

// MARK: - Compatibility helpers
extension View {
    @ViewBuilder
    func scrollBackgroundHiddenCompat() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

struct Starfield: View {
    let layerCount: Int
    var body: some View {
        ZStack {
            ForEach(0..<layerCount, id: \.self) { i in
                StarLayer(seed: i + 123, count: 100 + i*40, speed: Double(i+1) * 0.6, scale: 0.6 + Double(i) * 0.2)
                    .opacity(0.6 + Double(i) * 0.15)
            }
        }
    }
}

struct StarLayer: View {
    let seed: Int
    let count: Int
    let speed: Double
    let scale: Double
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                // derive a smooth phase from current time; no state mutation during draw
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = CGFloat(t * speed * 0.65)
                var rng = SeededRandom(number: UInt64(seed))
                for _ in 0..<count {
                    let x = CGFloat(rng.nextDouble()) * size.width
                    let y = CGFloat(rng.nextDouble()) * size.height
                    let sparkle = 0.8 + 0.2 * sin((x + y) * 0.01 + phase)
                    let starSize: CGFloat = 1.8 * scale
                    let rect = CGRect(x: x - starSize/2, y: y - starSize/2, width: starSize, height: starSize)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(sparkle)))
                }
            }
        }
    }
}

// Simple deterministic RNG for stable star positions per layer
struct SeededRandom {
    private var state: UInt64
    init(number: UInt64) { self.state = number &* 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextDouble() -> Double { Double(next()) / Double(UInt64.max) }
}

// no Symbols needed; stars are drawn directly

// Glass morphism bottom dock with tabs
struct GlassDock: View {
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 18) {
            DockButton(icon: "house.fill", title: "Home", tag: 0, selection: $selection)
            DockButton(icon: "briefcase.fill", title: "Assets", tag: 1, selection: $selection)
            DockButton(icon: "list.bullet.rectangle.portrait", title: "Subs", tag: 2, selection: $selection)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.6), radius: 20, x: 0, y: 10)
    }
}

struct DockButton: View {
    let icon: String
    let title: String
    let tag: Int
    @Binding var selection: Int
    var isSelected: Bool { selection == tag }
    var body: some View {
        Button(action: { selection = tag; haptic(.success) }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.9))
                    .frame(width: 24)
                if isSelected {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.black)
                        .padding(.trailing, 6)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, isSelected ? 14 : 10)
            .background(
                ZStack {
                    if isSelected {
                        LinearGradient(colors: [Color.cyan, Color.mint], startPoint: .topLeading, endPoint: .bottomTrailing)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().fill(.white.opacity(0.25)).blur(radius: 6)
                                    .blendMode(.softLight)
                            )
                            .shadow(color: Color.cyan.opacity(0.5), radius: 12, x: 0, y: 6)
                    } else {
                        Color.clear
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: isSelected)
    }
}
