import SwiftUI

/// Keep the native pull-to-refresh gesture, with visible data age and pull guidance.
struct FreshnessScrollView<Content: View>: View {
    let lastUpdated: Date?
    let isRefreshing: Bool
    let refresh: () async -> Void
    @ViewBuilder var content: () -> Content
    @Namespace private var space
    @State private var pull: CGFloat = 0
    var body: some View {
        ScrollView {
            VStack(spacing:0) {
                GeometryReader { geometry in
                    Color.clear.preference(key:RefreshPullPreference.self,value:max(0,geometry.frame(in:.named(space)).minY))
                }.frame(height:0)
                TimelineView(.periodic(from:.now,by:1)) { context in
                    VStack(spacing:5) {
                        Text(lastUpdated.map { "Last updated \(FlightTime.relative($0,now:context.date))" } ?? "Not updated yet")
                            .font(.system(size:11)).accessibilityIdentifier("dataFreshness")
                        HStack(spacing:5) {
                            Image(systemName:"arrow.down").rotationEffect(.degrees(-min(pull/100,1)*180))
                            Text(isRefreshing ? "Refreshing…":pull>12 ? "Pull further to refresh":"Pull down to refresh")
                        }.font(.system(size:10)).opacity(isRefreshing || pull>6 ? 1:0.65)
                            .accessibilityIdentifier("pullToRefreshHint")
                    }.foregroundStyle(Deck.muted).frame(maxWidth:.infinity).padding(.top,10).padding(.bottom,4)
                }
                content()
            }
        }.coordinateSpace(name:space)
            .onPreferenceChange(RefreshPullPreference.self) { if abs(pull-$0)>0.5 { pull=$0 } }
            .refreshable {
                // SwiftUI can replace the refresh action as loading/pull state changes.
                // Finish the request independently so that replacement cannot cancel it.
                await Task { await refresh() }.value
            }
    }
}

private struct RefreshPullPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat,nextValue: () -> CGFloat) { value=max(value,nextValue()) }
}

struct RefreshIssueView: View {
    let issue: RefreshIssue
    var flightNumber: String? = nil
    var body: some View {
        VStack(alignment:.leading,spacing:5) {
            Label((flightNumber.map { "\($0): " } ?? "")+issue.message,systemImage:"info.circle").font(.footnote)
            if let attempted=FlightTime.date(issue.attemptedAt) {
                TimelineView(.periodic(from:.now,by:1)) { context in
                    Text("Last attempt \(FlightTime.relative(attempted,now:context.date))")
                        .font(.system(size:10)).foregroundStyle(Deck.muted)
                }
            }
        }.foregroundStyle(Deck.orange)
    }
}
