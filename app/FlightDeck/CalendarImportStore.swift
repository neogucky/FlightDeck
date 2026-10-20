import Foundation
import EventKit
import Observation

@MainActor @Observable
final class CalendarImportStore {
    var calendars: [FlightCalendar] = []
    var selectedCalendarIDs: Set<String> = []
    var automatic = false
    var dismissed: Set<String> = []
    var suggestions: [CalendarFlight] = []
    var isScanning = false
    var isImporting = false
    var error: String?
    var lastScan: Date?
    var hasAccess = false
    var permissionDenied = false
    @ObservationIgnored private let eventStore = EKEventStore()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var profile: String?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var dirty = true
    @ObservationIgnored private var knownKeys: Set<String> = []
    @ObservationIgnored private let fixture = ProcessInfo.processInfo.arguments.contains("--uitesting-calendar")
    private struct Preferences: Codable {
        var selected: Set<String>
        var automatic: Bool
        var dismissed: Set<String>
    }
    var journeys: [CalendarJourney] { CalendarFlightDetection.journeys(from:suggestions) }
    var canSearch: Bool { hasAccess && calendars.contains(where:{selectedCalendarIDs.contains($0.id)}) && !isScanning && !isImporting }
    private var preferencesKey: String? { profile.map { "calendar-import-v1-"+$0+(fixture ? "-fixture":"") } }

    func configure(profile: String?) {
        guard self.profile != profile else { return }
        self.profile = profile;revision+=1;dirty = true
        calendars = [];selectedCalendarIDs = [];automatic = false;dismissed = [];suggestions = []
        isScanning = false;isImporting = false;error = nil;lastScan = nil;knownKeys = []
        if fixture,ProcessInfo.processInfo.arguments.contains("--uitesting-calendar-reset"),let key = preferencesKey { defaults.removeObject(forKey:key) }
        if let key = preferencesKey,let data = defaults.data(forKey:key),let saved = try? JSONDecoder().decode(Preferences.self,from:data) {
            selectedCalendarIDs = saved.selected;automatic = saved.automatic;dismissed = saved.dismissed
        }
        reloadCalendars()
    }
    private func persist() {
        guard let key = preferencesKey,let data = try? JSONEncoder().encode(Preferences(selected:selectedCalendarIDs,automatic:automatic,dismissed:dismissed)) else { return }
        defaults.set(data,forKey:key)
    }
    func reloadCalendars() {
        let status = EKEventStore.authorizationStatus(for:.event)
        hasAccess = fixture || status == .fullAccess
        permissionDenied = !fixture && (status == .denied || status == .restricted || status == .writeOnly)
        guard hasAccess,profile != nil else { calendars = [];suggestions = [];return }
        if fixture {
            calendars = [FlightCalendar(id:"fixture",title:"Travel",source:"Calendar test fixture")]
        } else {
            calendars = eventStore.calendars(for:.event).map { FlightCalendar(id:$0.calendarIdentifier,title:$0.title,source:$0.source.title) }
                .sorted { ($0.source,$0.title,$0.id)<($1.source,$1.title,$1.id) }
        }
        if !calendars.contains(where:{selectedCalendarIDs.contains($0.id)}) { suggestions = [] }
    }
    func requestAccess() async {
        let target = profile
        do {
            if !fixture { _ = try await eventStore.requestFullAccessToEvents() }
            guard profile == target else { return }
            reloadCalendars();error = hasAccess ? nil:"Calendar access was not granted. You can enable it in iOS Settings."
        } catch { if profile == target { self.error = "Calendar access could not be requested. Please try again." } }
    }
    func select(_ id: String, enabled: Bool) {
        if enabled { selectedCalendarIDs.insert(id) } else { selectedCalendarIDs.remove(id) }
        revision+=1;isScanning = false;dirty = true;lastScan = nil;suggestions = [];error = nil;persist()
    }
    func setAutomatic(_ enabled: Bool) { automatic = enabled;dirty = true;persist() }
    func markChanged() { dirty = true }
    func reconcile(trips: [Trip]) {
        knownKeys = CalendarFlightDetection.existingKeys(trips)
        suggestions.removeAll { knownKeys.contains($0.id) || dismissed.contains($0.id) }
    }
    func dismiss(_ flights: [CalendarFlight]) {
        dismissed.formUnion(flights.map(\.id));suggestions.removeAll { dismissed.contains($0.id) };persist()
    }
    func resetDismissed() { dismissed = [];dirty = true;lastScan = nil;persist() }

    func automaticScan(trips: [Trip]) async {
        reloadCalendars()
        guard automatic,canSearch else { return }
        if let lastScan {
            let age = Date().timeIntervalSince(lastScan)
            if age<15 || (!dirty && age<300) { return }
        }
        await scan(trips:trips)
    }
    func scan(trips: [Trip]) async {
        guard profile != nil,canSearch else { return }
        let target = profile,version = revision
        reconcile(trips:trips)
        isScanning = true;error = nil
        // Let the progress indicator render before querying the local event store.
        await Task.yield()
        defer { if profile == target,revision == version { isScanning = false } }
        guard profile == target,revision == version else { return }
        let now = Date(),until = Calendar.current.date(byAdding:.day,value:180,to:Date())!
        let events: [FlightCalendarEvent]
        if fixture {
            events = Self.fixtureEvents(now:now)
        } else {
            let selected = eventStore.calendars(for:.event).filter { selectedCalendarIDs.contains($0.calendarIdentifier) }
            guard !selected.isEmpty else { error = "The selected calendars are no longer available. Choose a calendar below.";return }
            let predicate = eventStore.predicateForEvents(withStart:now.addingTimeInterval(-86400),end:until,calendars:selected)
            events = eventStore.events(matching:predicate).compactMap { event in
                guard let start = event.startDate,let end = event.endDate,let calendar = event.calendar else { return nil }
                return FlightCalendarEvent(id:event.eventIdentifier ?? UUID().uuidString,calendarID:calendar.calendarIdentifier,
                    calendarTitle:calendar.title,title:event.title ?? "",start:start,end:end,timeZone:event.timeZone ?? .current,
                    allDay:event.isAllDay,cancelled:event.status == .canceled,modified:event.lastModifiedDate ?? .distantPast)
            }
        }
        suggestions = CalendarFlightDetection.flights(in:events,now:now,until:until).filter { !knownKeys.contains($0.id) && !dismissed.contains($0.id) }
        lastScan = now;dirty = false
    }

    func add(_ journeys: [CalendarJourney], to store: FlightStore) async -> Bool {
        guard !isImporting,let target = profile,target == store.calendarProfileID else { return false }
        isImporting = true;error = nil
        defer { if profile == target { isImporting = false } }
        do {
            for journey in journeys {
                guard profile == target,store.calendarProfileID == target else { return false }
                try await store.add(journey.payload)
                guard profile == target,store.calendarProfileID == target else { return false }
                reconcile(trips:store.trips)
            }
            return true
        } catch {
            if profile == target { self.error = error.localizedDescription }
            return false
        }
    }

    static func fixtureEvents(now: Date) -> [FlightCalendarEvent] {
        let start = Calendar.current.startOfDay(for:now).addingTimeInterval(3*86400+8*3600)
        func event(_ id:String,_ title:String,_ offset:Double,_ duration:Double) -> FlightCalendarEvent {
            FlightCalendarEvent(id:id,calendarID:"fixture",calendarTitle:"Travel",title:title,
                start:start.addingTimeInterval(offset*3600),end:start.addingTimeInterval((offset+duration)*3600),timeZone:TimeZone(identifier:"Europe/Berlin")!)
        }
        return [event("a","Flight to Munich (LH 2055)",0,1.5),event("b","Flight to Zurich (LX 1107)",3,1),
                event("c","Flight to Frankfurt (LH 1189)",48,1.5),event("d","Team meeting (LH 1189)",72,1)]
    }
}
