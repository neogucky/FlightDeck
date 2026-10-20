import SwiftUI

struct AddTripView: View {
    @Environment(FlightStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var legs = [NewLeg()]
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focusedField: String?

    private var validation: String? {
        for (i,leg) in legs.enumerated() {
            let number = leg.flightNumber.canonicalFlightNumber
            if number.range(of:"^[A-Z0-9]{2,3}[0-9]{1,4}[A-Z]?$",options:.regularExpression) == nil {
                return "Enter a flight number for flight \(i+1), such as LX1055."
            }
        }
        for i in legs.indices.dropFirst() {
            if legs[i].departureDate < legs[i-1].departureDate { return "Keep connected flights in departure-date order." }
        }
        let signatures = legs.map { "\($0.flightNumber.canonicalFlightNumber)/\($0.departureDate)" }
        if Set(signatures).count != signatures.count { return "Each flight in your trip must be different." }
        return nil
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    VStack(alignment:.leading,spacing:9) {
                        Text("A NEW JOURNEY").eyebrow().foregroundStyle(Deck.orange)
                        Text("Let’s get you there.").font(.system(size:30,weight:.bold)).tracking(-1)
                        Text("Add one flight, or keep every connection together. Past flights are welcome too.")
                            .font(.subheadline).foregroundStyle(Deck.muted).lineSpacing(3)
                    }
                    ForEach($legs) { $leg in
                        VStack(alignment:.leading,spacing:18) {
                            HStack {
                                Text("FLIGHT \((legs.firstIndex(where:{$0.id == leg.id}) ?? 0)+1)").eyebrow().foregroundStyle(Deck.orange)
                                Spacer()
                                if legs.count>1 {
                                    Button(role:.destructive) { legs.removeAll { $0.id == leg.id } } label: { Image(systemName:"minus.circle") }
                                        .accessibilityLabel("Remove flight")
                                }
                            }
                            DeckField("FLIGHT NUMBER") {
                                TextField("LX1055",text:$leg.flightNumber).font(.system(size:23,weight:.medium,design:.monospaced))
                                    .focused($focusedField,equals:"number-\(leg.id)")
                                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                                    .accessibilityIdentifier("flightNumber\(legs.firstIndex(where:{$0.id == leg.id}) ?? 0)")
                            }.onTapGesture { focusedField = "number-\(leg.id)" }
                            Divider()
                            DatePicker("Departure date",selection:Binding(get:{FlightTime.dayDate(leg.departureDate)},set:{leg.departureDate = FlightTime.day($0)}),displayedComponents:.date)
                                .font(.subheadline).tint(Deck.ink)
                        }.deckCard()
                    }
                    if legs.count<8 {
                        Button {
                            var next = NewLeg()
                            next.departureDate = legs.last?.departureDate ?? FlightTime.day(Date())
                            legs.append(next)
                        } label: {
                            Label("Add connecting flight",systemImage:"plus.circle").font(.system(size:14,weight:.semibold))
                                .frame(maxWidth:.infinity).padding(18)
                                .background(Deck.ink.opacity(0.04),in:RoundedRectangle(cornerRadius:18))
                        }.foregroundStyle(Deck.ink).accessibilityIdentifier("addConnection")
                    }
                    if let message = error ?? validation {
                        Text(message).font(.footnote).foregroundStyle(error == nil ? Deck.muted:Deck.orange)
                    }
                    if store.isDemo {
                        Label("Saved in your demo journal. No API usage.",systemImage:"sparkles").font(.footnote).foregroundStyle(Deck.muted)
                    } else {
                        Text("Airports and times are filled in from your flight number and departure date when flight data is available.")
                            .font(.footnote).foregroundStyle(Deck.muted)
                    }
                }.padding(24)
            }.background(Deck.paper).foregroundStyle(Deck.ink).scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge:.bottom) {
                    Button {
                        saving = true; error = nil
                        Task {
                            do { try await store.add(NewTrip(title:"",legs:legs)); dismiss() }
                            catch { self.error = error.localizedDescription }
                            saving = false
                        }
                    } label: {
                        HStack {
                            if saving { ProgressView().tint(.white) }
                            Text(saving ? "Saving your journey…":legs.count>1 ? "Save connected trip":"Save flight").font(.system(size:16,weight:.semibold))
                            if !saving { Image(systemName:"arrow.right") }
                        }.frame(maxWidth:.infinity).padding(19).foregroundStyle(.white)
                            .background(validation == nil ? Deck.ink:Deck.ink.opacity(0.35),in:RoundedRectangle(cornerRadius:18))
                    }.disabled(saving || validation != nil).accessibilityIdentifier("saveTrip")
                        .padding(.horizontal,24).padding(.vertical,12).background(Deck.paper)
                }
                .navigationTitle("Add flights").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.topBarLeading) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItemGroup(placement:.keyboard) { Spacer(); Button("Done") { focusedField = nil } }
                }
                .interactiveDismissDisabled(saving)
        }
    }
}
