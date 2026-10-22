import SwiftUI

struct UsageView: View {
    @Environment(FlightStore.self) private var store
    @State private var showingKey = false
    var body: some View {
        NavigationStack {
            FreshnessScrollView(lastUpdated:FlightTime.date(store.usage?.accountCheckedAt),isRefreshing:store.isRefreshingUsage,refresh:{ await store.fetchUsage(refreshProvider:true) }) {
                VStack(alignment:.leading,spacing:24) {
                    Text("YOUR ACCOUNT, AT A GLANCE").eyebrow().foregroundStyle(Deck.muted)
                    Text("API usage").font(.system(size:34,weight:.bold)).tracking(-1.2)
                    if store.isSignedIn,let account = store.account {
                        HStack(spacing:7) {
                            Image(systemName:"person.crop.circle")
                            Text(account.username).fontWeight(.semibold)
                            Text("· \(URL(string:store.address)?.host ?? store.address)")
                        }.font(.system(size:12)).foregroundStyle(Deck.muted)
                        if let usage = store.usage {
                            VStack(alignment:.leading,spacing:20) {
                                HStack {
                                    Text(usage.month).eyebrow().foregroundStyle(.white.opacity(0.65))
                                    Spacer()
                                    Text(usage.blocked ? "LOOKUPS PAUSED":"SAFETY BUDGET").eyebrow().foregroundStyle(.white.opacity(0.65))
                                }
                                HStack(alignment:.firstTextBaseline,spacing:8) {
                                    Text(amount(usage.conservativeUsedUsd)).font(.system(size:40,weight:.semibold,design:.rounded))
                                        .lineLimit(1).minimumScaleFactor(0.65).accessibilityIdentifier("safetyUsageTotal")
                                    Text("/ \(usage.limitUsd.formatted(.currency(code:"USD")))").font(.system(size:17)).foregroundStyle(.white.opacity(0.6))
                                }
                                ProgressView(value:min(usage.conservativeUsedUsd,usage.limitUsd),total:usage.limitUsd).tint(usage.blocked ? Deck.orange:.mint)
                                HStack {
                                    Text("\(amount(usage.remainingUsd)) remaining")
                                    Spacer()
                                    Text("\(usage.requestCount) \(usage.requestCount == 1 ? "request":"requests")").accessibilityIdentifier("reservedLookupCount")
                                }.font(.system(size:11)).foregroundStyle(.white.opacity(0.7))
                            }.padding(24).foregroundStyle(.white).background(Deck.ink,in:RoundedRectangle(cornerRadius:26))
                            SectionTitle(title:"How it adds up")
                            VStack(spacing:16) {
                                metric("FlightAware reported",value:usage.providerReportedUsd)
                                Divider()
                                metric("Predicted pending costs",value:usage.predictedPendingCosts)
                                Divider()
                                metric("Conservative safety total",value:usage.conservativeUsedUsd,bold:true)
                            }.deckCard()
                            Text(usage.reportedThrough != nil ? "FlightAware updates usage every 10 minutes. We allow another 5 minutes for processing, then replace pending estimates with reported usage. Pending costs are conservative estimates and may exceed the final charge.":"Your server has not supplied a billing coverage time. Pending estimates may overlap reported usage until the server is updated.")
                                .font(.footnote).foregroundStyle(Deck.muted).lineSpacing(3)
                            if let through = FlightTime.date(usage.reportedThrough) {
                                Text("Reported period ends \(through.formatted(.dateTime.day().month(.abbreviated).hour().minute())). Newer requests are included in pending costs.")
                                    .font(.system(size:11)).foregroundStyle(Deck.muted).accessibilityIdentifier("usageReportedThrough")
                            }
                            if usage.blocked {
                                Label("New paid lookups are paused. Your saved flights remain available. Check the budget and pricing review date below.",systemImage:"pause.circle")
                                    .font(.footnote).foregroundStyle(Deck.orange).deckCard(padding:16)
                            }
                            Text("Safety limit: \(usage.limitUsd.formatted(.currency(code:"USD"))) per month. Price review due \(usage.pricingValidUntil). Limits are currently managed by the server.")
                                .font(.system(size:11)).foregroundStyle(Deck.muted)
                        }
                        if store.needsAPIKey {
                            Button { showingKey = true } label: { Label("Set up your AeroAPI key",systemImage:"key.horizontal").font(.subheadline.weight(.semibold)) }
                                .foregroundStyle(Deck.ink)
                        }
                        if !store.usageHistory.isEmpty {
                            SectionTitle(title:"Monthly history",detail:"Up to 12 months")
                            VStack(spacing:16) {
                                ForEach(store.usageHistory) { period in
                                    HStack {
                                        VStack(alignment:.leading,spacing:4) {
                                            Text(period.month).font(.system(size:14,weight:.semibold,design:.monospaced))
                                            Text("\(period.requestCount) \(period.requestCount == 1 ? "request":"requests")").font(.system(size:11)).foregroundStyle(Deck.muted)
                                        }
                                        Spacer()
                                        Text(amount(period.conservativeUsedUsd)).font(.system(size:16,weight:.semibold,design:.rounded))
                                    }
                                    if period.id != store.usageHistory.last?.id { Divider() }
                                }
                            }.deckCard()
                        }
                    } else {
                        VStack(alignment:.leading,spacing:16) {
                            Image(systemName:"chart.bar.xaxis").font(.system(size:36,weight:.light))
                            Text("Keep an eye on your allowance.").font(.system(size:22,weight:.bold))
                            Text("Connect to your server and sign in through Settings to see your account’s requests, spending estimates and monthly history.").font(.subheadline).foregroundStyle(Deck.muted)
                            Text("Demo flights do not use FlightAware or incur API charges.").font(.footnote).foregroundStyle(Deck.muted)
                        }.frame(maxWidth:.infinity,alignment:.leading).deckCard()
                    }
                    if let error = store.usageError { Text(error).font(.footnote).foregroundStyle(Deck.orange) }
                }.padding(24)
            }.background(Deck.paper).foregroundStyle(Deck.ink).toolbar(.hidden,for:.navigationBar)
                .task {
                    let checked=FlightTime.date(store.usage?.accountCheckedAt) ?? .distantPast
                    await store.fetchUsage(refreshProvider:Date().timeIntervalSince(checked)>60)
                }
                .sheet(isPresented:$showingKey) { APIKeySetupView() }
        }
    }
    private func metric(_ title: String, value: Double, bold: Bool = false) -> some View {
        HStack {
            Text(title).font(.system(size:13,weight:bold ? .semibold:.regular))
            Spacer()
            Text(amount(value)).font(.system(size:15,weight:.semibold,design:.rounded))
        }
    }
    private func amount(_ value: Double) -> String {
        value.formatted(.currency(code:"USD").precision(.fractionLength(2...6)))
    }
}
