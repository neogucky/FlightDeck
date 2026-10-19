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
            let number = leg.flightNumber.uppercased().replacingOccurrences(of:" ",with:"")
            if number.range(of:"^[A-Z0-9]{2,3}[0-9]{1,4}[A-Z]?$",options:.regularExpression) == nil {
                return "Enter a flight number for flight \(i+1), such as LX1055."
            }
            for code in [leg.originIata ?? "",leg.destinationIata ?? ""] where !code.isEmpty {
                if code.range(of:"^[A-Za-z]{3}$",options:.regularExpression) == nil { return "Use three-letter airport codes, such as HAM." }
            }
            if let origin = leg.originIata?.nonempty, origin.uppercased() == leg.destinationIata?.uppercased() {
                return "Departure and arrival airports must differ."
            }
        }
        for i in legs.indices.dropFirst() {
            if legs[i].departureDate < legs[i-1].departureDate { return "Keep connected flights in departure-date order." }
            if let dest = legs[i-1].destinationIata?.nonempty, let origin = legs[i].originIata?.nonempty,
               dest.uppercased() != origin.uppercased() { return "Connected flights must share the connecting airport." }
        }
        let signatures = legs.map { "\($0.flightNumber.uppercased())/\($0.departureDate)/\($0.originIata ?? "")" }
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
                            VStack(alignment:.leading,spacing:8) {
                                Text("FLIGHT NUMBER").eyebrow().foregroundStyle(Deck.muted)
                                TextField("LX1055",text:$leg.flightNumber).font(.system(size:23,weight:.medium,design:.monospaced))
                                    .focused($focusedField,equals:"number-\(leg.id)")
                                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                                    .accessibilityIdentifier("flightNumber\(legs.firstIndex(where:{$0.id == leg.id}) ?? 0)")
                            }
                            Divider()
                            DatePicker("Departure date",selection:Binding(get:{FlightTime.dayDate(leg.departureDate)},set:{leg.departureDate = FlightTime.day($0)}),displayedComponents:.date)
                                .font(.subheadline).tint(Deck.ink)
                            Divider()
                            HStack(spacing:20) {
                                airport("FROM",value:$leg.originIata,id:"origin\(legs.firstIndex(where:{$0.id == leg.id}) ?? 0)",placeholder:"HAM")
                                Image(systemName:"arrow.right").foregroundStyle(Deck.line)
                                airport("TO",value:$leg.destinationIata,id:"destination\(legs.firstIndex(where:{$0.id == leg.id}) ?? 0)",placeholder:"ZRH")
                            }
                            Text("Airport codes are optional, but help identify the right flight and preserve your route in history.")
                                .font(.system(size:11)).foregroundStyle(Deck.muted).fixedSize(horizontal:false,vertical:true)
                        }.deckCard()
                    }
                    if legs.count<8 {
                        Button {
                            var next = NewLeg()
                            next.departureDate = legs.last?.departureDate ?? FlightTime.day(Date())
                            next.originIata = legs.last?.destinationIata ?? ""
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
    private func airport(_ title:String,value:Binding<String?>,id:String,placeholder:String) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).eyebrow().foregroundStyle(Deck.muted)
            TextField(placeholder,text:Binding(get:{value.wrappedValue ?? ""},set:{value.wrappedValue = String($0.prefix(3)).uppercased()}))
                .focused($focusedField,equals:id)
                .font(.system(size:25,weight:.medium,design:.rounded)).textInputAutocapitalization(.characters).autocorrectionDisabled()
                .accessibilityIdentifier(id)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
